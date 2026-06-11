#!/usr/bin/env bash
# 01_setup_env.sh — Bootstrap host environment for the cloud-backed
# TerminalBench evaluation.
#
# Unlike the local-vLLM flow, this run uses Alibaba Cloud DashScope for
# inference, so no GPU / no CUDA / no torch is required on this box. We still
# need Docker (TerminalBench spins up a task container per problem) and a
# python ≥3.12 (terminal-bench requires it).
#
# Why uv?  terminal-bench requires Python ≥3.12, and we want a self-contained
# CPython 3.12 with no apt / PPA / conda dependency.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

# Safety net: config.env may predate these vars
EVAL_VENV_DIR="${EVAL_VENV_DIR:-${HOME}/eval_venv}"
PY_VERSION="${PY_VERSION:-3.12}"   # target Python for eval + agent venvs

log "=== Step 1: Environment setup (cloud / DashScope) ==="

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. DashScope API key sanity check (the run can't proceed without it)
# ---------------------------------------------------------------------------
if [[ -z "${DASHSCOPE_API_KEY:-}" ]]; then
    die "DASHSCOPE_API_KEY is not set. Add it to config.env (or export it) before running."
fi
ok "DashScope key present (${#DASHSCOPE_API_KEY} chars)"
log "DashScope base URL: ${DASHSCOPE_BASE_URL}"

# ---------------------------------------------------------------------------
# 2. System packages (build tools, git, curl, screen, etc.)
# ---------------------------------------------------------------------------
log "Installing system packages via apt…"
sudo apt-get update -qq 2>/dev/null || true
sudo apt-get install -y -qq \
    git curl wget screen htop jq \
    build-essential libssl-dev libffi-dev \
    ca-certificates gnupg lsb-release \
    2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Install uv (self-contained Python + package manager)
# ---------------------------------------------------------------------------
ensure_uv() {
    if command -v uv &>/dev/null; then echo "$(command -v uv)"; return 0; fi
    for c in "${HOME}/.local/bin/uv" "${HOME}/.cargo/bin/uv"; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    log "Installing uv…" >&2
    curl -LsSf https://astral.sh/uv/install.sh | sh >&2 2>&1 || return 1
    for c in "${HOME}/.local/bin/uv" "${HOME}/.cargo/bin/uv"; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

UV=$(ensure_uv) || die "Failed to install uv. Install manually: curl -LsSf https://astral.sh/uv/install.sh | sh"
export PATH="$(dirname "$UV"):${PATH}"
ok "uv: $("$UV" --version)"

# ---------------------------------------------------------------------------
# 4. Resolve a compatible Python (3.12+ — required by terminal-bench).
# ---------------------------------------------------------------------------
COMPAT_PYTHON=""
for v in "python${PY_VERSION}" python3.12 python3.13; do
    if command -v "$v" &>/dev/null; then
        minor=$("$v" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 0)
        if (( minor >= 12 && minor <= 13 )); then
            COMPAT_PYTHON=$(command -v "$v")
            log "Found system Python: ${COMPAT_PYTHON} ($($COMPAT_PYTHON --version))"
            break
        fi
    fi
done

if [[ -z "$COMPAT_PYTHON" ]]; then
    log "No system Python 3.12/3.13 found; fetching CPython ${PY_VERSION} via uv…"
    "$UV" python install "${PY_VERSION}" >&2
    COMPAT_PYTHON=$("$UV" python find "${PY_VERSION}")
    ok "uv-managed Python: ${COMPAT_PYTHON} ($($COMPAT_PYTHON --version))"
fi

[[ -x "$COMPAT_PYTHON" ]] || die "Could not resolve a Python 3.12+ interpreter."

# ---------------------------------------------------------------------------
# 5. Docker CE
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    log "Installing Docker CE…"
    curl -fsSL https://get.docker.com | sudo sh 2>/dev/null || \
        sudo apt-get install -y -qq docker.io 2>/dev/null || true
fi

sudo systemctl enable docker 2>/dev/null || true
sudo systemctl start  docker 2>/dev/null || \
    sudo service docker start 2>/dev/null || true
sleep 3

if docker info &>/dev/null 2>&1; then
    ok "Docker: $(docker --version)"
else
    warn "Docker not running — steps 8 (image pull) and 9 (TerminalBench) will fail."
    warn "Fix: sudo systemctl start docker"
fi

if command -v docker &>/dev/null && ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    warn "Added $USER to docker group — run 'newgrp docker' before docker commands"
fi

# ---------------------------------------------------------------------------
# 6. AWS CLI (for ECR auth — public ECR pulls don't strictly require login,
#    but `aws ecr-public get-login-password` raises the pull rate limit).
# ---------------------------------------------------------------------------
if ! command -v aws &>/dev/null; then
    log "Installing AWS CLI v2…"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip 2>/dev/null && \
        (cd /tmp && unzip -q -o awscliv2.zip && sudo ./aws/install --update 2>/dev/null) || \
        warn "AWS CLI install failed — public ECR pulls will use anonymous rate limits"
fi
command -v aws &>/dev/null && ok "AWS CLI: $(aws --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 7. Create the eval venv with the compatible Python (uv --seed adds pip)
# ---------------------------------------------------------------------------
_venv_is_compatible() {
    [[ -x "${EVAL_VENV_DIR}/bin/python" ]] || return 1
    local minor
    minor=$("${EVAL_VENV_DIR}/bin/python" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 0)
    (( minor >= 12 && minor <= 13 ))
}

if _venv_is_compatible; then
    ok "Eval venv already compatible: $(${EVAL_VENV_DIR}/bin/python --version)"
else
    if [[ -d "${EVAL_VENV_DIR}" ]]; then
        warn "Existing eval venv is incompatible — recreating"
        rm -rf "${EVAL_VENV_DIR}"
    fi
    log "Creating eval venv at ${EVAL_VENV_DIR} with $($COMPAT_PYTHON --version)…"
    "$UV" venv "${EVAL_VENV_DIR}" --python "${COMPAT_PYTHON}" --seed
    ok "Eval venv created"
fi

"${EVAL_VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --quiet
"${EVAL_VENV_DIR}/bin/pip" install --quiet \
    "openai>=1.35.0" \
    "requests>=2.31.0" \
    "tqdm>=4.66.0"
ok "Venv pip: $(${EVAL_VENV_DIR}/bin/pip --version)"

# ---------------------------------------------------------------------------
# 8. Record paths for downstream scripts
# ---------------------------------------------------------------------------
mkdir -p "${SCRIPT_DIR}/../results"
echo "${EVAL_VENV_DIR}/bin/python" > "${SCRIPT_DIR}/../results/.eval_python"
echo "${COMPAT_PYTHON}"            > "${SCRIPT_DIR}/../results/.compat_python"
echo "${UV}"                       > "${SCRIPT_DIR}/../results/.uv_bin"
echo "RUN_TAG=${RUN_TAG}"          > "${SCRIPT_DIR}/../results/.run_tag"

mkdir -p "${RESULTS_DIR}/${RUN_TAG}"
ok "Results dir: ${RESULTS_DIR}/${RUN_TAG}"

ok "=== Environment setup complete ==="
log "uv:             ${UV}"
log "Compatible py:  ${COMPAT_PYTHON} ($($COMPAT_PYTHON --version))"
log "Eval venv:      ${EVAL_VENV_DIR} ($(${EVAL_VENV_DIR}/bin/python --version))"

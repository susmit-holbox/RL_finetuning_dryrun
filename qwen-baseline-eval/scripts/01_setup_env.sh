#!/usr/bin/env bash
# 01_setup_env.sh — Bootstrap a fresh Ubuntu EC2 GPU instance.
#
# Why uv?  vLLM + PyTorch only publish wheels for CPython 3.10–3.13 (there are
# ZERO torch wheels for 3.14).  This box ships Python 3.14 as its system python,
# and apt / deadsnakes / conda all failed to provide a 3.12 cleanly.  `uv`
# downloads a fully self-contained CPython 3.12 with no apt, no PPA, no conda
# ToS prompts, and no PEP 668 restrictions.  It is the one method that always
# works, so we standardise on it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

# Safety net: config.env may predate these vars
EVAL_VENV_DIR="${EVAL_VENV_DIR:-${HOME}/eval_venv}"
PY_VERSION="${PY_VERSION:-3.12}"   # target Python for eval + agent venvs

log "=== Step 1: Environment setup ==="

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. GPU check
# ---------------------------------------------------------------------------
NVIDIA_SMI=""
for p in nvidia-smi /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi \
          /opt/nvidia/bin/nvidia-smi; do
    if command -v "$p" &>/dev/null || [[ -x "$p" ]]; then
        NVIDIA_SMI=$(command -v "$p" 2>/dev/null || echo "$p")
        break
    fi
done

if [[ -z "$NVIDIA_SMI" ]]; then
    if [[ "${SKIP_GPU_CHECK:-0}" == "1" ]]; then
        warn "nvidia-smi not found — SKIP_GPU_CHECK=1, continuing"
        warn "Install NVIDIA drivers before Step 4: sudo ubuntu-drivers autoinstall && sudo reboot"
    else
        die "$(cat <<'MSG'
nvidia-smi not found. On Ubuntu EC2:

  sudo apt-get update
  sudo apt-get install -y ubuntu-drivers-common
  sudo ubuntu-drivers autoinstall
  sudo reboot

Or skip this check: SKIP_GPU_CHECK=1 bash run.sh
MSG
)"
    fi
else
    log "GPU(s) detected:"
    "$NVIDIA_SMI" --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | \
        while IFS=',' read -r name mem; do log "  • ${name} (${mem})"; done
    ok "$(detect_gpu_count) GPU(s) available"
fi

# ---------------------------------------------------------------------------
# 2. System packages (build tools, git, curl, screen, etc.)
# ---------------------------------------------------------------------------
log "Installing system packages via apt…"
sudo apt-get update -qq 2>/dev/null || true
sudo apt-get install -y -qq \
    git curl wget screen htop jq pciutils \
    build-essential libssl-dev libffi-dev \
    ca-certificates gnupg lsb-release \
    2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Install uv (self-contained Python + package manager)
# ---------------------------------------------------------------------------
ensure_uv() {
    # Already on PATH?
    if command -v uv &>/dev/null; then echo "$(command -v uv)"; return 0; fi
    # Common install locations from a previous run
    for c in "${HOME}/.local/bin/uv" "${HOME}/.cargo/bin/uv"; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    # Fresh install
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
# 4. Resolve a torch-compatible Python (3.10–3.13)
#    Prefer an existing system python3.12/3.13; otherwise let uv fetch one.
# ---------------------------------------------------------------------------
COMPAT_PYTHON=""
for v in "python${PY_VERSION}" python3.12 python3.13 python3.11 python3.10; do
    if command -v "$v" &>/dev/null; then
        minor=$("$v" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 99)
        if (( minor >= 10 && minor <= 13 )); then
            COMPAT_PYTHON=$(command -v "$v")
            log "Found system Python: ${COMPAT_PYTHON} ($($COMPAT_PYTHON --version))"
            break
        fi
    fi
done

if [[ -z "$COMPAT_PYTHON" ]]; then
    log "No system Python 3.10–3.13 found; fetching CPython ${PY_VERSION} via uv…"
    "$UV" python install "${PY_VERSION}" >&2
    COMPAT_PYTHON=$("$UV" python find "${PY_VERSION}")
    ok "uv-managed Python: ${COMPAT_PYTHON} ($($COMPAT_PYTHON --version))"
fi

[[ -x "$COMPAT_PYTHON" ]] || die "Could not resolve a Python 3.10–3.13 interpreter."

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
    warn "Docker not running — steps 7-10 (image pull + eval) will fail."
    warn "Fix: sudo systemctl start docker"
fi

if command -v docker &>/dev/null && ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    warn "Added $USER to docker group — run 'newgrp docker' before docker commands"
fi

# ---------------------------------------------------------------------------
# 6. Create the eval venv with the compatible Python (via uv, --seed adds pip)
# ---------------------------------------------------------------------------
_venv_is_compatible() {
    [[ -x "${EVAL_VENV_DIR}/bin/python" ]] || return 1
    local minor
    minor=$("${EVAL_VENV_DIR}/bin/python" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 99)
    (( minor >= 10 && minor <= 13 ))
}

if _venv_is_compatible; then
    ok "Eval venv already compatible: $(${EVAL_VENV_DIR}/bin/python --version)"
else
    if [[ -d "${EVAL_VENV_DIR}" ]]; then
        warn "Existing eval venv is incompatible (likely Python 3.14) — recreating"
        rm -rf "${EVAL_VENV_DIR}"
    fi
    log "Creating eval venv at ${EVAL_VENV_DIR} with $($COMPAT_PYTHON --version)…"
    "$UV" venv "${EVAL_VENV_DIR}" --python "${COMPAT_PYTHON}" --seed
    ok "Eval venv created"
fi

"${EVAL_VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --quiet
ok "Venv pip: $(${EVAL_VENV_DIR}/bin/pip --version)"

# ---------------------------------------------------------------------------
# 7. Record paths for downstream scripts
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

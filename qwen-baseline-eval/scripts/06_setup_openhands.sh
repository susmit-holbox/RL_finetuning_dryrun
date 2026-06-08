#!/usr/bin/env bash
# 06_setup_openhands.sh — Clone and install OpenHands + evaluation dependencies.
#
# OpenHands 0.62.0 requires Python >=3.12,<3.14.
# This script creates a dedicated Python 3.12/3.13 virtual environment for
# OpenHands, separate from the system Python used for vLLM (which may be 3.14+).
# The venv is written to ${OPENHANDS_DIR}/.venv and its Python path is stored in
# ${OPENHANDS_DIR}/.venv_python for use by evaluation runner scripts.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 6: Setup OpenHands ==="

# ---------------------------------------------------------------------------
# Find Python 3.12 or 3.13 (OpenHands requires >=3.12,<3.14)
# ---------------------------------------------------------------------------
OH_PYTHON=""
for candidate in python3.12 python3.13; do
    if command -v "$candidate" &>/dev/null; then
        ver=$($candidate --version 2>&1 | awk '{print $2}')
        minor=$(echo "$ver" | cut -d. -f2)
        if (( minor >= 12 && minor <= 13 )); then
            OH_PYTHON=$(command -v "$candidate")
            log "Found compatible Python for OpenHands: ${OH_PYTHON} (${ver})"
            break
        fi
    fi
done

if [[ -z "$OH_PYTHON" ]]; then
    # Try to install python3.12 via apt (Ubuntu/Debian GPU instances)
    warn "No Python 3.12/3.13 found. Attempting to install python3.12…"
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y -qq python3.12 python3.12-venv 2>/dev/null && \
            OH_PYTHON=$(command -v python3.12) || true
    fi
    [[ -z "$OH_PYTHON" ]] && die \
        "OpenHands requires Python 3.12 or 3.13 (not 3.14+). Install with:\n  sudo apt install python3.12 python3.12-venv\nor use pyenv/conda."
fi

# ---------------------------------------------------------------------------
# Clone OpenHands (pin to 0.62.0 — last tag with evaluation/)
# ---------------------------------------------------------------------------
OPENHANDS_TAG="0.62.0"

if [[ -d "${OPENHANDS_DIR}/.git" ]]; then
    CURRENT_TAG=$(git -C "${OPENHANDS_DIR}" describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_TAG" == "$OPENHANDS_TAG" ]]; then
        ok "OpenHands ${OPENHANDS_TAG} already at ${OPENHANDS_DIR}"
    else
        log "Existing checkout is '${CURRENT_TAG}', re-cloning to ${OPENHANDS_TAG}…"
        rm -rf "${OPENHANDS_DIR}"
        retry 3 15 \
            git clone --depth 1 --branch "${OPENHANDS_TAG}" \
                https://github.com/All-Hands-AI/OpenHands.git \
                "${OPENHANDS_DIR}"
    fi
else
    log "Cloning OpenHands ${OPENHANDS_TAG} into ${OPENHANDS_DIR}…"
    retry 3 15 \
        git clone --depth 1 --branch "${OPENHANDS_TAG}" \
            https://github.com/All-Hands-AI/OpenHands.git \
            "${OPENHANDS_DIR}"
fi

[[ -f "${OPENHANDS_DIR}/evaluation/benchmarks/swe_bench/run_infer.py" ]] || \
    die "run_infer.py not found — clone of ${OPENHANDS_TAG} may have failed"
ok "run_infer.py and run_infer.sh present"

# ---------------------------------------------------------------------------
# Create / reuse a dedicated venv with the compatible Python
# ---------------------------------------------------------------------------
VENV_DIR="${OPENHANDS_DIR}/.venv"
VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"

if [[ ! -x "${VENV_PYTHON}" ]]; then
    log "Creating OpenHands venv at ${VENV_DIR} using ${OH_PYTHON}…"
    "${OH_PYTHON}" -m venv "${VENV_DIR}"
    ok "venv created"
else
    EXISTING_VER=$("${VENV_PYTHON}" --version 2>&1)
    ok "venv already exists (${EXISTING_VER})"
fi

# Store the venv python path so other scripts can source it
echo "${VENV_PYTHON}" > "${OPENHANDS_DIR}/.venv_python"

# ---------------------------------------------------------------------------
# Install OpenHands inside the venv
# ---------------------------------------------------------------------------
log "Installing OpenHands inside venv (this takes several minutes)…"
cd "${OPENHANDS_DIR}"

"${VENV_PIP}" install --upgrade pip wheel --quiet

retry 3 30 \
    "${VENV_PIP}" install -e ".[llms]" --quiet \
    2>&1 | grep -v "^Requirement already"

# Evaluation extras
for req in \
    "evaluation/benchmarks/swe_bench/requirements.txt" \
    "evaluation/requirements.txt"; do
    [[ -f "$req" ]] && \
        "${VENV_PIP}" install -r "$req" --quiet \
            2>&1 | grep -v "^Requirement already" || true
done

"${VENV_PIP}" install --quiet \
    "datasets>=2.19.0" \
    "huggingface_hub[cli]>=0.24.0" \
    "openai>=1.35.0" \
    2>&1 | grep -v "^Requirement already"

# ---------------------------------------------------------------------------
# Install TerminalBench into the venv
# ---------------------------------------------------------------------------
log "Installing terminal-bench…"
retry 3 15 \
    "${VENV_PIP}" install --quiet \
        "git+https://github.com/harbor-framework/terminal-bench.git" \
    2>&1 | grep -v "^Requirement already" || \
    warn "terminal-bench install failed — will retry at run time"

TB_BIN="${VENV_DIR}/bin/tb"
if [[ -x "$TB_BIN" ]]; then
    ok "terminal-bench installed: $("${TB_BIN}" --version 2>/dev/null || echo 'version unknown')"
else
    warn "'tb' not found in venv — may need manual install"
fi

# ---------------------------------------------------------------------------
# Write OpenHands config.toml
# ---------------------------------------------------------------------------
log "Writing OpenHands config.toml…"
cat > "${OPENHANDS_DIR}/config.toml" <<TOML
[core]
workspace_base = "${RESULTS_DIR}/${RUN_TAG}/openhands_workspace"
run_as_openhands = false

[llm.eval_model]
model = "openai/${MODEL_NAME}"
base_url = "${OPENHANDS_LLM_BASE_URL}"
api_key = "${OPENHANDS_LLM_API_KEY}"
temperature = 0.0
max_output_tokens = 4096
timeout = 300
num_retries = 5
retry_min_wait = 10
retry_max_wait = 60

[agent]
max_iterations = ${OPENHANDS_MAX_ITER}
TOML

mkdir -p "${RESULTS_DIR}/${RUN_TAG}/openhands_workspace"
ok "config.toml written"

ok "=== OpenHands setup complete ==="
log "OpenHands dir:  ${OPENHANDS_DIR}"
log "Python venv:    ${VENV_PYTHON}"
log "tb binary:      ${TB_BIN}"

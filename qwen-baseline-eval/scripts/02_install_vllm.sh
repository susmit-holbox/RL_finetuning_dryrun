#!/usr/bin/env bash
# 02_install_vllm.sh — Install vLLM into the eval venv (never system Python).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 2: Install vLLM ==="

# Use the eval venv created in step 1 (isolated from system Python)
PYTHON=$(eval_python)
PIP=$(dirname "$PYTHON")/pip

# Ensure venv exists with a Python version that has torch wheels (3.10-3.13)
_check_venv_python_ok() {
    local py="$1"
    [[ -x "$py" ]] || return 1
    local minor
    minor=$("$py" -c "import sys; print(sys.version_info.minor)" 2>/dev/null)
    (( minor <= 13 ))
}

if ! _check_venv_python_ok "$PYTHON"; then
    if _check_venv_python_ok "$PYTHON"; then
        : # already OK
    else
        log "Eval venv missing or uses Python 3.14+ (no torch wheels) — creating with python3.12/3.13"
        # Find compatible Python
        COMPAT=""
        for v in python3.12 python3.13 python3.11 python3.10; do
            command -v "$v" &>/dev/null && { COMPAT=$(command -v "$v"); break; }
        done
        [[ -n "$COMPAT" ]] || die "No Python 3.10–3.13 found. Run step 1 first: bash scripts/01_setup_env.sh"
        [[ -d "${EVAL_VENV_DIR}" ]] && rm -rf "${EVAL_VENV_DIR}"
        "$COMPAT" -m venv "${EVAL_VENV_DIR}"
        "${EVAL_VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --quiet
        mkdir -p "${SCRIPT_DIR}/../results"
        echo "${EVAL_VENV_DIR}/bin/python" > "${SCRIPT_DIR}/../results/.eval_python"
        PYTHON=$(eval_python)
        PIP=$(dirname "$PYTHON")/pip
    fi
fi

log "Using Python: $PYTHON ($($PYTHON --version))"
# Verify Python version is torch-compatible
_MINOR=$("$PYTHON" -c "import sys; print(sys.version_info.minor)")
(( _MINOR >= 10 && _MINOR <= 13 )) || die "Python 3.${_MINOR} in eval venv has no PyTorch CUDA wheels. Re-run step 1."

# ---------------------------------------------------------------------------
# Already installed?
# ---------------------------------------------------------------------------
if "$PYTHON" -c "import vllm; print('vLLM', vllm.__version__)" 2>/dev/null; then
    ok "vLLM already installed — skipping"
else
    # Detect CUDA version for correct torch wheel
    CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -1 \
               || "$PYTHON" -c "import torch; print(torch.version.cuda)" 2>/dev/null \
               || echo "12.1")
    CUDA_SHORT=$(echo "$CUDA_VER" | tr -d '.')
    log "CUDA: ${CUDA_VER}  →  torch wheel index: cu${CUDA_SHORT}"

    log "Installing PyTorch (CUDA build)…"
    retry 3 30 "$PIP" install --quiet \
        "torch>=2.3.0" \
        --index-url "https://download.pytorch.org/whl/cu${CUDA_SHORT}"

    log "Installing vLLM…"
    retry 3 30 "$PIP" install --quiet "vllm>=0.8.5"

    ok "vLLM $("$PYTHON" -c "import vllm; print(vllm.__version__)") installed"
fi

# ---------------------------------------------------------------------------
# Evaluation helper packages (into same venv)
# ---------------------------------------------------------------------------
log "Installing evaluation helper packages…"
retry 3 30 "$PIP" install --quiet \
    "huggingface_hub[cli]>=0.24.0" \
    "datasets>=2.19.0" \
    "openai>=1.35.0" \
    "requests>=2.31.0" \
    "tqdm>=4.66.0" \
    "python-dotenv>=1.0.0" \
    "boto3>=1.34.0"

ok "=== vLLM installation complete ==="

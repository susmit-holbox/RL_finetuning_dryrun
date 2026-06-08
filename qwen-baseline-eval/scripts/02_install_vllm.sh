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

# Ensure venv exists (in case step 1 was skipped or run separately)
if [[ ! -x "$PYTHON" ]]; then
    log "Eval venv not found — creating at ${EVAL_VENV_DIR}…"
    python3 -m venv "${EVAL_VENV_DIR}"
    "${EVAL_VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --quiet
    echo "${EVAL_VENV_DIR}/bin/python" > "${SCRIPT_DIR}/../results/.eval_python"
    PYTHON=$(eval_python)
    PIP=$(dirname "$PYTHON")/pip
fi

log "Using Python: $PYTHON ($($PYTHON --version))"

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

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

# The eval venv must use Python 3.10–3.13 (no torch wheels for 3.14).
# Step 1 creates it via uv; this is a safety net if step 1 was skipped.
_venv_minor() {
    [[ -x "$1" ]] || { echo 99; return; }
    "$1" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 99
}

if ! [[ -x "$PYTHON" ]] || (( $(_venv_minor "$PYTHON") > 13 )); then
    warn "Eval venv missing or Python 3.14+ (no torch wheels) — rebuilding via uv"
    # Resolve uv (recorded by step 1, else on PATH, else known locations)
    UV=""
    if [[ -f "${SCRIPT_DIR}/../results/.uv_bin" ]]; then UV=$(cat "${SCRIPT_DIR}/../results/.uv_bin"); fi
    if ! [[ -x "$UV" ]]; then UV=$(command -v uv 2>/dev/null || true); fi
    if ! [[ -x "$UV" ]] && [[ -x "${HOME}/.local/bin/uv" ]]; then UV="${HOME}/.local/bin/uv"; fi
    if ! [[ -x "$UV" ]] && [[ -x "${HOME}/.cargo/bin/uv" ]]; then UV="${HOME}/.cargo/bin/uv"; fi
    [[ -x "$UV" ]] || die "uv not found. Run step 1 first: bash scripts/01_setup_env.sh"

    # Compatible Python: recorded by step 1, else uv-managed 3.12
    COMPAT=""
    [[ -f "${SCRIPT_DIR}/../results/.compat_python" ]] && COMPAT=$(cat "${SCRIPT_DIR}/../results/.compat_python")
    if ! [[ -x "$COMPAT" ]]; then
        "$UV" python install 3.12
        COMPAT=$("$UV" python find 3.12)
    fi

    [[ -d "${EVAL_VENV_DIR}" ]] && rm -rf "${EVAL_VENV_DIR}"
    "$UV" venv "${EVAL_VENV_DIR}" --python "${COMPAT}" --seed
    "${EVAL_VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --quiet
    mkdir -p "${SCRIPT_DIR}/../results"
    echo "${EVAL_VENV_DIR}/bin/python" > "${SCRIPT_DIR}/../results/.eval_python"
    PYTHON=$(eval_python)
    PIP=$(dirname "$PYTHON")/pip
fi

log "Using Python: $PYTHON ($($PYTHON --version))"
(( $(_venv_minor "$PYTHON") <= 13 )) || die "Python in eval venv has no PyTorch CUDA wheels. Re-run step 1."

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
    "huggingface_hub>=0.24.0" \
    "datasets>=2.19.0" \
    "openai>=1.35.0" \
    "requests>=2.31.0" \
    "tqdm>=4.66.0" \
    "python-dotenv>=1.0.0" \
    "boto3>=1.34.0"

ok "=== vLLM installation complete ==="

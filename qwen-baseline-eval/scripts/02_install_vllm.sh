#!/usr/bin/env bash
# 02_install_vllm.sh — Install vLLM (GPU build) and evaluation Python deps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 2: Install vLLM ==="

PYTHON=$(command -v python3)

# Ensure pip works (in case step 1 was skipped)
if ! "$PYTHON" -m pip --version &>/dev/null 2>&1; then
    log "pip missing — bootstrapping…"
    curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$PYTHON"
fi

# ---------------------------------------------------------------------------
# Already installed?
# ---------------------------------------------------------------------------
if "$PYTHON" -c "import vllm; print('vLLM', vllm.__version__)" 2>/dev/null; then
    ok "vLLM already installed — skipping"
    # Still install eval helper packages in case they're missing
else
    # ---------------------------------------------------------------------------
    # Detect CUDA version for correct torch wheel
    # ---------------------------------------------------------------------------
    CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -1 \
               || python3 -c "import torch; print(torch.version.cuda)" 2>/dev/null \
               || echo "12.1")
    CUDA_SHORT=$(echo "$CUDA_VER" | tr -d '.')   # e.g. "121"
    log "CUDA version: ${CUDA_VER} (wheel suffix: cu${CUDA_SHORT})"

    log "Installing vLLM (GPU) — this may take 5-10 minutes…"

    # Install torch first with the right CUDA index (avoids pulling CPU-only torch)
    retry 3 30 "$PYTHON" -m pip install --quiet \
        "torch>=2.3.0" \
        --index-url "https://download.pytorch.org/whl/cu${CUDA_SHORT}"

    # Install vLLM (picks up the already-installed torch)
    retry 3 30 "$PYTHON" -m pip install --quiet \
        "vllm>=0.8.5"

    VLLM_VER=$("$PYTHON" -c "import vllm; print(vllm.__version__)")
    ok "vLLM ${VLLM_VER} installed"
fi

# ---------------------------------------------------------------------------
# Helper packages used by this evaluation harness
# (safe to re-run, pip no-ops if already satisfied)
# ---------------------------------------------------------------------------
log "Installing evaluation helper packages…"
retry 3 30 "$PYTHON" -m pip install --quiet \
    "huggingface_hub[cli]>=0.24.0" \
    "datasets>=2.19.0" \
    "openai>=1.35.0" \
    "requests>=2.31.0" \
    "tqdm>=4.66.0" \
    "python-dotenv>=1.0.0" \
    "boto3>=1.34.0"     # for ECR login / S3 uploads

ok "=== vLLM installation complete ==="

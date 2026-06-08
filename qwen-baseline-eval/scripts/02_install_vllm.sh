#!/usr/bin/env bash
# 02_install_vllm.sh — Install vLLM and Python dependencies.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 2: Install vLLM ==="

PYTHON=$(command -v python3 || command -v python)

# ---------------------------------------------------------------------------
# Check if vLLM is already installed at an acceptable version
# ---------------------------------------------------------------------------
if $PYTHON -c "import vllm; print(vllm.__version__)" &>/dev/null; then
    INSTALLED=$($PYTHON -c "import vllm; print(vllm.__version__)")
    ok "vLLM $INSTALLED already installed — skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# Install vLLM (GPU build)
# vLLM publishes CUDA-specific wheels; the default pip install pulls the
# correct wheel based on the installed CUDA toolkit.
# ---------------------------------------------------------------------------
log "Installing vLLM (GPU) — this can take several minutes…"

# Detect CUDA version for wheel selection
CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -1 || echo "12.1")
CUDA_MAJOR=$(echo "$CUDA_VER" | cut -d. -f1)
CUDA_MINOR=$(echo "$CUDA_VER" | cut -d. -f2)
log "CUDA $CUDA_VER detected"

$PYTHON -m pip install \
    "vllm>=0.8.5" \
    "torch>=2.3.0" \
    --quiet \
    --extra-index-url "https://download.pytorch.org/whl/cu${CUDA_MAJOR}${CUDA_MINOR}" \
    2>&1 | grep -v "^Requirement already"

# Install additional dependencies used by this evaluation harness
$PYTHON -m pip install --quiet \
    "huggingface_hub[cli]>=0.24.0" \
    "datasets>=2.19.0" \
    "openai>=1.35.0" \
    "requests>=2.31.0" \
    "tqdm>=4.66.0" \
    "python-dotenv>=1.0.0"

INSTALLED=$($PYTHON -c "import vllm; print(vllm.__version__)")
ok "vLLM $INSTALLED installed"

ok "=== vLLM installation complete ==="

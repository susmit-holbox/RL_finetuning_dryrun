#!/usr/bin/env bash
# 03_download_model.sh — Download model weights from HuggingFace Hub.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 3: Download model ${MODEL_ID} ==="

PYTHON=$(eval_python)
HF_CLI="$(dirname "$PYTHON")/huggingface-cli"

# ---------------------------------------------------------------------------
# Configure HuggingFace cache
# ---------------------------------------------------------------------------
export HF_HOME="${HF_HOME:-/data/models}"
export HUGGINGFACE_HUB_VERBOSITY="warning"
# Fall back to ~/models if the configured path isn't writable (e.g., no /data volume)
if ! mkdir -p "${HF_HOME}" 2>/dev/null; then
    HF_HOME="${HOME}/models"
    warn "HF_HOME not writable — falling back to ${HF_HOME}"
    mkdir -p "${HF_HOME}"
fi

# Model will land at: ${HF_HOME}/models--${ORG}--${NAME}/snapshots/...
LOCAL_DIR="${HF_HOME}/models--$(echo "${MODEL_ID}" | tr '/' '--')"

# ---------------------------------------------------------------------------
# Skip if already downloaded
# ---------------------------------------------------------------------------
if [[ -d "$LOCAL_DIR" ]] && find "$LOCAL_DIR" -name "*.safetensors" | grep -q .; then
    ok "Model weights found at $LOCAL_DIR — skipping download"
    exit 0
fi

# ---------------------------------------------------------------------------
# Authenticate (optional, needed for gated models)
# ---------------------------------------------------------------------------
if [[ -n "${HF_TOKEN:-}" ]]; then
    log "Logging in to HuggingFace Hub…"
    "${HF_CLI}" login --token "$HF_TOKEN" --add-to-git-credential 2>/dev/null || \
        $PYTHON -c "from huggingface_hub import login; login('${HF_TOKEN}')"
fi

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
log "Downloading ${MODEL_ID} to ${HF_HOME}…"
log "This may take a long time for large models (14B ≈ 28 GB)"

retry 3 30 \
    "${HF_CLI}" download \
        "${MODEL_ID}" \
        --cache-dir "${HF_HOME}" \
        --local-dir-use-symlinks False \
        --resume-download

ok "Model downloaded: $MODEL_ID"

# Verify at least one weight file exists
WEIGHT_COUNT=$(find "$LOCAL_DIR" -name "*.safetensors" 2>/dev/null | wc -l)
if (( WEIGHT_COUNT == 0 )); then
    # huggingface-cli download may store in a different layout
    WEIGHT_COUNT=$(find "${HF_HOME}" -path "*${MODEL_ID/\//-}*" -name "*.safetensors" 2>/dev/null | wc -l)
fi
log "Weight shards found: $WEIGHT_COUNT"
(( WEIGHT_COUNT == 0 )) && warn "No .safetensors files found — vLLM may still load from Hub cache"

ok "=== Model download complete ==="

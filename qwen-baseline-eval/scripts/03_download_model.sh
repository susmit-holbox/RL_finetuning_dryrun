#!/usr/bin/env bash
# 03_download_model.sh — Download model weights from HuggingFace Hub.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 3: Download model ${MODEL_ID} ==="

PYTHON=$(eval_python)

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
# Downstream steps (vLLM) read HF_HOME from results/.hf_home so cache location is consistent
echo "${HF_HOME}" > "${SCRIPT_DIR}/../results/.hf_home"

# Model lands at: ${HF_HOME}/hub/models--${ORG}--${NAME}/snapshots/...
# NB: HF uses DOUBLE dashes and replaces '/' with '--'.  Use bash substitution
# (NOT `tr '/' '--'`, which translates to a single dash — tr works on char sets).
MODEL_DIR_NAME="models--${MODEL_ID//\//--}"
LOCAL_DIR="${HF_HOME}/hub/${MODEL_DIR_NAME}"
[[ -d "$LOCAL_DIR" ]] || LOCAL_DIR="${HF_HOME}/${MODEL_DIR_NAME}"

# ---------------------------------------------------------------------------
# Skip if already downloaded
# ---------------------------------------------------------------------------
if [[ -d "$LOCAL_DIR" ]] && find "$LOCAL_DIR" -name "*.safetensors" 2>/dev/null | grep -q .; then
    ok "Model weights found at $LOCAL_DIR — skipping download"
    exit 0
fi

# ---------------------------------------------------------------------------
# Download via the huggingface_hub Python API (snapshot_download).
#
# NOTE: the `huggingface-cli` command was REMOVED in huggingface_hub 1.x
# (replaced by `hf`).  The Python API is stable across versions, so we use it
# directly instead of depending on any CLI binary name.  Resume is automatic.
# ---------------------------------------------------------------------------
log "Downloading ${MODEL_ID} to ${HF_HOME} (HF_HOME)…"
log "This may take a long time for large models (14B ≈ 28 GB). Resume is automatic on retry."

retry 3 30 env HF_HOME="${HF_HOME}" HF_TOKEN="${HF_TOKEN:-}" \
    "${PYTHON}" - "${MODEL_ID}" <<'PYDL'
import os, sys
from huggingface_hub import snapshot_download

model_id = sys.argv[1]
token = os.environ.get("HF_TOKEN") or None
path = snapshot_download(
    repo_id=model_id,
    token=token,
    # Skip files vLLM never needs (saves bandwidth/disk)
    ignore_patterns=["*.pth", "*.onnx", "*.msgpack", "*.h5"],
    max_workers=8,
)
print(f"SNAPSHOT_PATH={path}")
PYDL

ok "Model downloaded: $MODEL_ID"

# ---------------------------------------------------------------------------
# Verify at least one weight file exists (search the whole HF_HOME tree)
# ---------------------------------------------------------------------------
WEIGHT_COUNT=$(find "${HF_HOME}" -name "*.safetensors" 2>/dev/null | wc -l)
log "Weight shards found under ${HF_HOME}: $WEIGHT_COUNT"
(( WEIGHT_COUNT == 0 )) && warn "No .safetensors files found — vLLM may still load from Hub cache"

ok "=== Model download complete ==="

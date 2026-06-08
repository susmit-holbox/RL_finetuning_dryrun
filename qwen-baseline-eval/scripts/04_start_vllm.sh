#!/usr/bin/env bash
# 04_start_vllm.sh — Launch the vLLM OpenAI-compatible server in a screen session.
#
# Tool-call parser selection (verified research findings):
#   qwen2.5 / qwen2.5_coder → hermes
#       WARNING: Qwen2.5-Coder silently fails with hermes — the model emits
#       ```json``` blocks instead of <tool_call> tags.  tool_calls will be
#       empty in the response.  The test_toolcall.py step will surface this.
#   qwen3_coder              → qwen3_coder
#   qwen3                    → hermes
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 4: Start vLLM server ==="

PYTHON=$(command -v python3 || command -v python)
VLLM_BIN=$(command -v vllm || $PYTHON -m vllm --help &>/dev/null && echo "$PYTHON -m vllm" || true)
[[ -z "$VLLM_BIN" ]] && VLLM_BIN="vllm"

# ---------------------------------------------------------------------------
# Already running?
# ---------------------------------------------------------------------------
if screen_running "$VLLM_SCREEN"; then
    log "vLLM screen '$VLLM_SCREEN' already running — checking health…"
    if curl -sf "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
        ok "vLLM already healthy at port ${VLLM_PORT}"
        exit 0
    else
        warn "Screen exists but server not healthy — restarting"
        kill_screen "$VLLM_SCREEN"
        sleep 3
    fi
fi

# ---------------------------------------------------------------------------
# Select tool-call parser
# ---------------------------------------------------------------------------
select_tool_call_parser() {
    case "${MODEL_FAMILY}" in
        qwen3_coder)   echo "qwen3_coder" ;;
        qwen3)         echo "hermes" ;;
        qwen2.5_coder) echo "hermes" ;;
        qwen2.5)       echo "hermes" ;;
        *)             echo "hermes" ;;
    esac
}
TOOL_CALL_PARSER=$(select_tool_call_parser)
log "Tool-call parser: $TOOL_CALL_PARSER (MODEL_FAMILY=${MODEL_FAMILY})"
if [[ "$MODEL_FAMILY" == "qwen2.5_coder" ]]; then
    warn "Known issue: hermes parser may silently fail on Qwen2.5-Coder models."
    warn "tool_calls field may be empty even when the model produces tool invocations."
    warn "Consider switching to Qwen3-Coder (MODEL_FAMILY=qwen3_coder) for reliable tool calling."
fi

# ---------------------------------------------------------------------------
# Resolve tensor-parallel size
# ---------------------------------------------------------------------------
NGPUS=$(resolve_num_gpus)
log "Using ${NGPUS} GPU(s) for tensor parallelism"

# For MoE models (Qwen3-Coder) expert parallel can be beneficial
EXTRA_PARALLEL_FLAGS=""
if [[ "$MODEL_FAMILY" == "qwen3_coder" ]] && (( NGPUS > 1 )); then
    EXTRA_PARALLEL_FLAGS="--enable-expert-parallel"
fi

# ---------------------------------------------------------------------------
# Build the vllm serve command
# ---------------------------------------------------------------------------
VLLM_CMD="vllm serve ${MODEL_ID} \
    --host ${VLLM_HOST} \
    --port ${VLLM_PORT} \
    --tensor-parallel-size ${NGPUS} \
    --max-model-len ${MAX_MODEL_LEN} \
    --enable-auto-tool-choice \
    --tool-call-parser ${TOOL_CALL_PARSER} \
    --served-model-name ${MODEL_NAME} \
    --trust-remote-code \
    ${EXTRA_PARALLEL_FLAGS} \
    ${VLLM_EXTRA_FLAGS:-}"

# Pass HF_HOME so vLLM finds cached weights
VLLM_ENV="HF_HOME=${HF_HOME}"
[[ -n "${HF_TOKEN:-}" ]] && VLLM_ENV="${VLLM_ENV} HF_TOKEN=${HF_TOKEN}"

log "Starting vLLM in screen '${VLLM_SCREEN}'…"
log "Command: $VLLM_CMD"

# Write a launcher script so we can inspect it and the screen session can source it
cat > /tmp/vllm_launcher.sh <<LAUNCHER
#!/usr/bin/env bash
export ${VLLM_ENV}
set -x
${VLLM_CMD}
LAUNCHER
chmod +x /tmp/vllm_launcher.sh

# Launch in a detached screen
screen -dmS "$VLLM_SCREEN" bash /tmp/vllm_launcher.sh

log "Waiting for vLLM to load model (large models may take 5-15 min)…"
wait_for_vllm "localhost" "${VLLM_PORT}" 900   # 15 min timeout

# ---------------------------------------------------------------------------
# Verify model is listed
# ---------------------------------------------------------------------------
MODELS=$(curl -sf "http://localhost:${VLLM_PORT}/v1/models" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print([m['id'] for m in data.get('data', [])])
" 2>/dev/null || echo "[]")
log "Models served: $MODELS"

ok "=== vLLM server running on port ${VLLM_PORT} ==="
log "Attach to screen: screen -r ${VLLM_SCREEN}"

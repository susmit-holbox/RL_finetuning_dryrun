#!/usr/bin/env bash
# 10_run_sweBench.sh — Run SWE-bench evaluation using OpenHands.
#
# OpenHands SWE-bench (verified research findings):
#   • Docker images: swebench/sweb.eval.x86_64.<instance_id>:latest
#   • 4 500+ images on Docker Hub, 99.8% of all instances covered
#   • OpenHands evaluation runner is a Python script in the cloned repo
#   • LLM configured via config.toml [llm.eval_model] section
#   • Evaluation runner runs on the HOST (not in a container), so
#     base_url = http://localhost:<port>/v1  is correct here
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 10: SWE-bench evaluation ==="

# Use the OpenHands venv Python (requires Python 3.12/3.13, not 3.14)
VENV_PYTHON_FILE="${OPENHANDS_DIR}/.venv_python"
if [[ -f "$VENV_PYTHON_FILE" ]]; then
    PYTHON=$(cat "$VENV_PYTHON_FILE")
else
    PYTHON=$(command -v python3.12 || command -v python3.13 || command -v python3)
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[[ -d "${OPENHANDS_DIR}" ]] || \
    die "OpenHands not found at ${OPENHANDS_DIR}. Run 06_setup_openhands.sh first."

if ! curl -sf "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
    die "vLLM not healthy at localhost:${VLLM_PORT}. Run 04_start_vllm.sh first."
fi

RUNNER_SH="${OPENHANDS_DIR}/evaluation/benchmarks/swe_bench/scripts/run_infer.sh"
RUNNER_PY="${OPENHANDS_DIR}/evaluation/benchmarks/swe_bench/run_infer.py"
[[ -f "$RUNNER_SH" || -f "$RUNNER_PY" ]] || \
    die "SWE-bench runner not found. Expected: $RUNNER_SH. Check OpenHands installation (needs tag 0.62.0)."

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------
OUT_DIR="${RESULTS_DIR}/${RUN_TAG}/sweBench"
mkdir -p "$OUT_DIR"
LOG_FILE="${OUT_DIR}/swe_run.log"

# ---------------------------------------------------------------------------
# Ensure OpenHands config.toml is up to date
# (might have been written by 06_setup_openhands.sh with stale RUN_TAG)
# ---------------------------------------------------------------------------
cat > "${OPENHANDS_DIR}/config.toml" <<TOML
[core]
workspace_base = "${OUT_DIR}/openhands_workspace"
run_as_openhands = false

[llm.eval_model]
model = "openai/${MODEL_NAME}"
base_url = "http://localhost:${VLLM_PORT}/v1"
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
mkdir -p "${OUT_DIR}/openhands_workspace"

# ---------------------------------------------------------------------------
# Run SWE-bench via OpenHands evaluation runner
# ---------------------------------------------------------------------------
log "Starting SWE-bench (dataset=${SWEBENCH_DATASET}, limit=${SWEBENCH_LIMIT})…"
log "Results: ${OUT_DIR}"
log "Log: ${LOG_FILE}"
log "Workers: ${SWEBENCH_WORKERS} | Max iterations per task: ${OPENHANDS_MAX_ITER}"

START_TS=$(date +%s)

cd "${OPENHANDS_DIR}"

# run_infer.sh interface (OpenHands ≤ 0.62.0):
#   run_infer.sh [model_config] [git-version] [agent] [eval_limit] [max_iter]
#                [num_workers] [dataset] [dataset_split]
if [[ -f "$RUNNER_SH" ]]; then
    log "Using run_infer.sh (shell interface)"
    bash "$RUNNER_SH" \
        "eval_model" \
        "HEAD" \
        "CodeActAgent" \
        "${SWEBENCH_LIMIT}" \
        "${OPENHANDS_MAX_ITER}" \
        "${SWEBENCH_WORKERS}" \
        "${SWEBENCH_DATASET}" \
        "${SWEBENCH_SPLIT}" \
        2>&1 | tee "$LOG_FILE"
else
    log "Using run_infer.py (Python interface)"
    $PYTHON evaluation/benchmarks/swe_bench/run_infer.py \
        --agent-cls CodeActAgent \
        --llm-config eval_model \
        --max-iterations "${OPENHANDS_MAX_ITER}" \
        --eval-num-workers "${SWEBENCH_WORKERS}" \
        --eval-note "qwen-baseline-${RUN_TAG}" \
        --eval-output-dir "${OUT_DIR}" \
        --dataset "${SWEBENCH_DATASET}" \
        --split "${SWEBENCH_SPLIT}" \
        --eval-limit "${SWEBENCH_LIMIT}" \
        2>&1 | tee "$LOG_FILE"
fi

SWE_EXIT=${PIPESTATUS[0]}
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

# ---------------------------------------------------------------------------
# Score the predictions
# ---------------------------------------------------------------------------
log "SWE-bench runner finished in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

PRED_FILE=$(find "${OUT_DIR}" -name "*.jsonl" | head -1 2>/dev/null || true)
if [[ -n "$PRED_FILE" ]]; then
    log "Scoring predictions: $PRED_FILE"
    # swebench evaluate_predictions is the scoring tool
    $PYTHON -m swebench.harness.run_evaluation \
        --dataset_name "${SWEBENCH_DATASET}" \
        --split "${SWEBENCH_SPLIT}" \
        --predictions_path "$PRED_FILE" \
        --max_workers "${SWEBENCH_WORKERS}" \
        --run_id "qwen-baseline-${RUN_TAG}" \
        2>&1 | tee "${OUT_DIR}/scoring.log" || \
        warn "Scoring step failed — raw predictions still available at $PRED_FILE"
fi

# Summarise resolve rate from log
RESOLVED=$(grep -oP 'Resolved: \K[0-9]+' "${OUT_DIR}/scoring.log" 2>/dev/null | tail -1 || echo "?")
TOTAL_SCORED=$(grep -oP 'Total: \K[0-9]+' "${OUT_DIR}/scoring.log" 2>/dev/null | tail -1 || echo "?")
log "Resolved: ${RESOLVED} / ${TOTAL_SCORED}"

# Write summary
cat > "${OUT_DIR}/run_summary.json" <<SUMMARY
{
  "model": "${MODEL_ID}",
  "model_name": "${MODEL_NAME}",
  "dataset": "${SWEBENCH_DATASET}",
  "split": "${SWEBENCH_SPLIT}",
  "limit": ${SWEBENCH_LIMIT},
  "max_iterations": ${OPENHANDS_MAX_ITER},
  "workers": ${SWEBENCH_WORKERS},
  "vllm_url": "http://localhost:${VLLM_PORT}/v1",
  "run_tag": "${RUN_TAG}",
  "resolved": "${RESOLVED}",
  "total": "${TOTAL_SCORED}",
  "elapsed_seconds": ${ELAPSED},
  "exit_code": ${SWE_EXIT}
}
SUMMARY

if [[ -n "${S3_RESULTS_URI:-}" ]]; then
    log "Uploading SWE-bench results to ${S3_RESULTS_URI}…"
    aws s3 sync "${OUT_DIR}" "${S3_RESULTS_URI}/sweBench/${RUN_TAG}/" --quiet || \
        warn "S3 upload failed"
fi

(( SWE_EXIT == 0 )) && ok "=== SWE-bench complete ===" || \
    warn "=== SWE-bench finished with exit code ${SWE_EXIT} ==="

#!/usr/bin/env bash
# 10_run_sweBench.sh — Run SWE-bench evaluation using mini-swe-agent.
#
# Why mini-swe-agent (vs the old OpenHands CodeActAgent):
#   • It is the SWE-bench team's canonical apples-to-apples harness: a minimal
#     bash ReAct loop, no special scaffold — so results are directly comparable
#     to the public "bash-only" SWE-bench Verified slice.
#   • We force TEXT parsing with TWO settings (both required):
#       -c swebench_backticks.yaml           → prompts the model to emit a single
#                                              fenced ```mswea_bash_command``` block
#       -c model.model_class=litellm_textbased → uses the model class that PARSES
#                                              that block from text
#     mini-swe-agent v2's DEFAULT model class (LitellmModel) parses OpenAI
#     `tool_calls` instead — which the Qwen2.5-Coder `hermes` parser silently
#     breaks. The backticks config alone does NOT set model_class, so without the
#     explicit litellm_textbased override the run would still use tool_calls and
#     fail. (Verified against mini-swe-agent 2.3.1.)
#   • Each instance runs in its SWE-bench Docker image
#     (swebench/sweb.eval.x86_64.<id _1776_ form>:latest) — pre-pulled by step 8.
#
# Output: <out>/preds/preds.json  (standard SWE-bench predictions dict), scored
# with the official swebench.harness.run_evaluation.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 10: SWE-bench evaluation (agent: mini-swe-agent) ==="

# ---------------------------------------------------------------------------
# Resolve the mini-swe-agent venv (python + mini-extra) from step-6 markers.
# ---------------------------------------------------------------------------
SWE_PY=""
if [[ -f "${SCRIPT_DIR}/../results/.swe_agent_python" ]]; then SWE_PY=$(cat "${SCRIPT_DIR}/../results/.swe_agent_python"); fi
if [[ ! -x "$SWE_PY" ]] && [[ -x "${SWE_AGENT_VENV_DIR:-}/bin/python" ]]; then SWE_PY="${SWE_AGENT_VENV_DIR}/bin/python"; fi
[[ -x "$SWE_PY" ]] || die "mini-swe-agent venv python not found — run 06_setup_agents.sh first."

MINI_BIN=""
if [[ -f "${SCRIPT_DIR}/../results/.mini_swe_bin" ]]; then MINI_BIN=$(cat "${SCRIPT_DIR}/../results/.mini_swe_bin"); fi
if [[ ! -x "$MINI_BIN" ]] && [[ -x "${SWE_AGENT_VENV_DIR:-}/bin/mini-extra" ]]; then MINI_BIN="${SWE_AGENT_VENV_DIR}/bin/mini-extra"; fi
[[ -x "$MINI_BIN" ]] || die "'mini-extra' not found — run 06_setup_agents.sh first."

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! curl -sf "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
    die "vLLM not healthy at localhost:${VLLM_PORT}. Run 04_start_vllm.sh first."
fi
docker info &>/dev/null 2>&1 || die "Docker is not running — each SWE-bench instance needs its container."

# ---------------------------------------------------------------------------
# Resolve the builtin text-parsing (backticks) config.
# mini-swe-agent prints a startup banner to stdout on import, so we tag the
# real value with a sentinel and grep it back out.
# ---------------------------------------------------------------------------
BACKTICKS_CFG=$("$SWE_PY" - <<'PY' 2>/dev/null | sed -n 's/^CFGPATH=//p' || true
from minisweagent.config import builtin_config_dir
print("CFGPATH=" + str(builtin_config_dir / "benchmarks" / "swebench_backticks.yaml"))
PY
)
[[ -f "$BACKTICKS_CFG" ]] || die "swebench_backticks.yaml not found (resolved: '${BACKTICKS_CFG}')."
log "Using text-parsing config: ${BACKTICKS_CFG}"

# ---------------------------------------------------------------------------
# Output directories
# ---------------------------------------------------------------------------
OUT_DIR="${RESULTS_DIR}/${RUN_TAG}/sweBench"
PRED_DIR="${OUT_DIR}/preds"
mkdir -p "$PRED_DIR"
LOG_FILE="${OUT_DIR}/swe_run.log"
RUN_ID="qwen-baseline-${RUN_TAG}"
HOST_LLM_BASE_URL="http://localhost:${VLLM_PORT}/v1"

# ---------------------------------------------------------------------------
# Run mini-swe-agent over the dataset.
#
# LLM wiring (litellm): model "openai/<name>" + api_base/api_key in model_kwargs.
# MSWEA_COST_TRACKING=ignore_errors: a local model has no litellm price table;
# without this, cost lookup raises. cost_limit is also set high as a backstop.
# ---------------------------------------------------------------------------
export MSWEA_COST_TRACKING="ignore_errors"

log "Starting SWE-bench (dataset=${SWEBENCH_DATASET}, split=${SWEBENCH_SPLIT}, limit=${SWEBENCH_LIMIT})…"
log "Model: openai/${MODEL_NAME} @ ${HOST_LLM_BASE_URL}"
log "Workers: ${SWEBENCH_WORKERS} | step_limit: ${SWE_STEP_LIMIT} | Results: ${OUT_DIR}"

START_TS=$(date +%s)

# --subset accepts a dataset path directly; --slice "0:N" limits instances.
# First -c MUST be the config file (it disables the default config); the
# remaining -c key=value pairs are recursively merged on top.
"$MINI_BIN" swebench \
    --subset "${SWEBENCH_DATASET}" \
    --split "${SWEBENCH_SPLIT}" \
    --slice "0:${SWEBENCH_LIMIT}" \
    --workers "${SWEBENCH_WORKERS}" \
    --output "${PRED_DIR}" \
    -c "${BACKTICKS_CFG}" \
    -c "model.model_class=litellm_textbased" \
    -c "model.model_name=openai/${MODEL_NAME}" \
    -c "model.model_kwargs.api_base=${HOST_LLM_BASE_URL}" \
    -c "model.model_kwargs.api_key=${LLM_API_KEY:-dummy}" \
    -c "model.model_kwargs.temperature=0.0" \
    -c "agent.step_limit=${SWE_STEP_LIMIT}" \
    -c "agent.cost_limit=${SWE_COST_LIMIT}" \
    2>&1 | tee "$LOG_FILE"

SWE_EXIT=${PIPESTATUS[0]}
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
log "mini-swe-agent finished in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# ---------------------------------------------------------------------------
# Score the predictions with the official SWE-bench harness.
# Run from ${OUT_DIR} so the report JSON lands there (harness writes it to cwd).
# ---------------------------------------------------------------------------
PREDS="${PRED_DIR}/preds.json"
RESOLVED="?"; TOTAL_SCORED="?"
if [[ -f "$PREDS" ]]; then
    log "Scoring predictions: ${PREDS}"
    ( cd "${OUT_DIR}" && "$SWE_PY" -m swebench.harness.run_evaluation \
        --dataset_name "${SWEBENCH_DATASET}" \
        --split "${SWEBENCH_SPLIT}" \
        --predictions_path "${PREDS}" \
        --max_workers "${SWEBENCH_WORKERS}" \
        --run_id "${RUN_ID}" \
        2>&1 | tee "${OUT_DIR}/scoring.log" ) || \
        warn "Scoring step failed — raw predictions still available at ${PREDS}"

    # The harness writes <model_name_or_path with / → __>.<run_id>.json to cwd.
    REPORT_JSON=$(find "${OUT_DIR}" -maxdepth 1 -name "*${RUN_ID}.json" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$REPORT_JSON" ]]; then
        log "Score report: ${REPORT_JSON}"
        read -r RESOLVED TOTAL_SCORED < <("$SWE_PY" - "$REPORT_JSON" <<'PYPARSE'
import json, sys
from pathlib import Path
d = json.loads(Path(sys.argv[1]).read_text())
print(d.get("resolved_instances", "?"), d.get("total_instances", "?"))
PYPARSE
) || true
    else
        warn "No score report (*${RUN_ID}.json) found — see ${OUT_DIR}/scoring.log"
    fi
else
    warn "No preds.json produced at ${PREDS} — check ${LOG_FILE}"
fi
log "Resolved: ${RESOLVED} / ${TOTAL_SCORED}"

# ---------------------------------------------------------------------------
# Write summary (self-describing for cross-run comparability)
# ---------------------------------------------------------------------------
cat > "${OUT_DIR}/run_summary.json" <<SUMMARY
{
  "benchmark": "swebench",
  "agent": "mini-swe-agent",
  "agent_config": "swebench_backticks.yaml + model_class=litellm_textbased (text-parsed bash, no tool_calls)",
  "harness": "swebench.harness.run_evaluation",
  "model": "${MODEL_ID}",
  "model_name": "${MODEL_NAME}",
  "dataset": "${SWEBENCH_DATASET}",
  "split": "${SWEBENCH_SPLIT}",
  "limit": ${SWEBENCH_LIMIT},
  "step_limit": ${SWE_STEP_LIMIT},
  "workers": ${SWEBENCH_WORKERS},
  "vllm_url": "${HOST_LLM_BASE_URL}",
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

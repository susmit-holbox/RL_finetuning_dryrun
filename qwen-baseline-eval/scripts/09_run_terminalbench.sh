#!/usr/bin/env bash
# 09_run_terminalbench.sh — Run TerminalBench evaluation using the Terminus agent.
#
# Why Terminus (vs the old in-container OpenHands tb-agent):
#   • Terminus is terminal-bench's own reference agent. It runs IN THE HOST
#     `tb` process and drives each task container purely over tmux
#     (send_keys / capture_pane). The LLM HTTP calls are therefore made FROM
#     THE HOST, so vLLM is reached at http://localhost:${VLLM_PORT}/v1 directly
#     — NO Docker bridge gateway IP and NO iptables workaround (unlike the old
#     OpenHands agent, which pip-installed itself INSIDE every container).
#   • Terminus parses a JSON (terminus-1) or JSON/XML (terminus-2) command batch
#     from plain text — it does NOT use the OpenAI tool_calls API, so the
#     Qwen2.5-Coder `hermes` tool-call silent-failure does not affect it.
#
# Both the agent name (terminus / terminus-2) and the terminus-2 parser
# (xml / json) are configurable via TB_AGENT / TB_PARSER in config.env.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 9: TerminalBench evaluation (agent: ${TB_AGENT}) ==="

# ---------------------------------------------------------------------------
# Resolve tb (terminal-bench venv) — marker from step 6, then venv, then PATH.
# ---------------------------------------------------------------------------
TB_BIN=""
if [[ -f "${SCRIPT_DIR}/../results/.tb_bin" ]]; then TB_BIN=$(cat "${SCRIPT_DIR}/../results/.tb_bin"); fi
if [[ ! -x "$TB_BIN" ]] && [[ -x "${TB_VENV_DIR:-}/bin/tb" ]]; then TB_BIN="${TB_VENV_DIR}/bin/tb"; fi
if [[ ! -x "$TB_BIN" ]]; then TB_BIN=$(command -v tb 2>/dev/null || echo ""); fi
[[ -x "$TB_BIN" ]] || die "'tb' not found — run 06_setup_agents.sh first."

# Python for parsing results.json (the tb venv python).
TB_PY=""
if [[ -f "${SCRIPT_DIR}/../results/.tb_python" ]]; then TB_PY=$(cat "${SCRIPT_DIR}/../results/.tb_python"); fi
[[ -x "$TB_PY" ]] || TB_PY=$(eval_python)

# ---------------------------------------------------------------------------
# Pre-flight: vLLM must be healthy ON THE HOST (Terminus calls it from here).
# ---------------------------------------------------------------------------
if ! curl -sf "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
    die "vLLM not healthy at localhost:${VLLM_PORT}. Run 04_start_vllm.sh first."
fi
HOST_LLM_BASE_URL="http://localhost:${VLLM_PORT}/v1"
log "Terminus → vLLM URL (host): ${HOST_LLM_BASE_URL}"

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------
OUT_DIR="${RESULTS_DIR}/${RUN_TAG}/terminalbench"
mkdir -p "$OUT_DIR"
LOG_FILE="${OUT_DIR}/tb_run.log"

# ---------------------------------------------------------------------------
# LLM wiring for litellm (Terminus uses litellm under the hood).
#   --model openai/<served-name>     → generic OpenAI-compatible routing
#   --agent-kwarg api_base/api_key   → forwarded into the Terminus LiteLLM client
#   OPENAI_* env                     → belt-and-suspenders for litellm's client
# ---------------------------------------------------------------------------
export OPENAI_API_KEY="${LLM_API_KEY:-dummy}"
export OPENAI_API_BASE="${HOST_LLM_BASE_URL}"
export OPENAI_BASE_URL="${HOST_LLM_BASE_URL}"

AGENT_KWARGS=(
    --agent-kwarg "api_base=${HOST_LLM_BASE_URL}"
    --agent-kwarg "api_key=${LLM_API_KEY:-dummy}"
    --agent-kwarg "temperature=0.0"
)
# parser_name is a terminus-2-only kwarg (terminus-1 has no such argument).
if [[ "${TB_AGENT}" == "terminus-2" && -n "${TB_PARSER:-}" ]]; then
    AGENT_KWARGS+=( --agent-kwarg "parser_name=${TB_PARSER}" )
fi

# ---------------------------------------------------------------------------
# Run TerminalBench
# ---------------------------------------------------------------------------
log "Starting TerminalBench (dataset=${TERMINALBENCH_DATASET}==${TERMINALBENCH_VERSION})…"
log "Agent: ${TB_AGENT}${TB_PARSER:+ (parser=${TB_PARSER})} | Model: openai/${MODEL_NAME}"
log "Concurrency: ${TERMINALBENCH_WORKERS} | Results: ${OUT_DIR}"
log "This will take a long time — each task spins up a Docker container."

START_TS=$(date +%s)

# Current `tb run` CLI (terminal-bench 0.2.x):
#   --dataset name==version   --agent terminus|terminus-2   --model openai/<name>
#   --agent-kwarg key=value   --n-concurrent N   --output-path DIR
# --cleanup (default) removes per-run images afterwards.
"$TB_BIN" run \
    --dataset "${TERMINALBENCH_DATASET}==${TERMINALBENCH_VERSION}" \
    --agent "${TB_AGENT}" \
    --model "openai/${MODEL_NAME}" \
    "${AGENT_KWARGS[@]}" \
    --n-concurrent "${TERMINALBENCH_WORKERS}" \
    --output-path "${OUT_DIR}" \
    --cleanup \
    2>&1 | tee "$LOG_FILE"

TB_EXIT=${PIPESTATUS[0]}
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

# ---------------------------------------------------------------------------
# Parse and summarise results
# ---------------------------------------------------------------------------
log "TerminalBench finished in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# tb writes results.json under ${OUT_DIR}/<run-id>/ — find the newest one.
RESULTS_JSON=$(find "${OUT_DIR}" -name "results.json" -type f 2>/dev/null \
                  | xargs -r ls -t 2>/dev/null | head -1 || true)
N_RESOLVED="?"; N_TOTAL="?"; ACCURACY="?"
if [[ -n "$RESULTS_JSON" ]]; then
    log "Results file: ${RESULTS_JSON}"
    # terminal-bench BenchmarkResults schema: n_resolved, n_unresolved, accuracy
    read -r N_RESOLVED N_TOTAL ACCURACY < <("$TB_PY" - "$RESULTS_JSON" <<'PYPARSE'
import json, sys
from pathlib import Path
d = json.loads(Path(sys.argv[1]).read_text())
res = d.get("n_resolved")
unres = d.get("n_unresolved")
total = (res or 0) + (unres or 0) if res is not None else len(d.get("results", []))
acc = d.get("accuracy")
print(res if res is not None else "?",
      total if total else "?",
      f"{acc:.4f}" if isinstance(acc, (int, float)) else "?")
PYPARSE
) || true
    log "  Resolved : ${N_RESOLVED} / ${N_TOTAL}"
    log "  Accuracy : ${ACCURACY}"
else
    warn "No results.json found under ${OUT_DIR} — check ${LOG_FILE}"
fi

# Write summary (self-describing for cross-run comparability)
cat > "${OUT_DIR}/run_summary.json" <<SUMMARY
{
  "benchmark": "terminalbench",
  "agent": "${TB_AGENT}",
  "agent_parser": "${TB_PARSER:-}",
  "harness": "terminal-bench ${TB_VERSION:-latest}",
  "model": "${MODEL_ID}",
  "model_name": "${MODEL_NAME}",
  "dataset": "${TERMINALBENCH_DATASET}",
  "version": "${TERMINALBENCH_VERSION}",
  "n_concurrent": ${TERMINALBENCH_WORKERS},
  "vllm_url": "${HOST_LLM_BASE_URL}",
  "run_tag": "${RUN_TAG}",
  "resolved": "${N_RESOLVED}",
  "total": "${N_TOTAL}",
  "accuracy": "${ACCURACY}",
  "elapsed_seconds": ${ELAPSED},
  "exit_code": ${TB_EXIT}
}
SUMMARY

if [[ -n "${S3_RESULTS_URI:-}" ]]; then
    log "Uploading TerminalBench results to ${S3_RESULTS_URI}…"
    aws s3 sync "${OUT_DIR}" "${S3_RESULTS_URI}/terminalbench/${RUN_TAG}/" --quiet || \
        warn "S3 upload failed"
fi

(( TB_EXIT == 0 )) && ok "=== TerminalBench complete ===" || \
    warn "=== TerminalBench finished with exit code ${TB_EXIT} ==="

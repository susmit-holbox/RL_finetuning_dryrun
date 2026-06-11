#!/usr/bin/env bash
# 09_run_terminalbench.sh — Run TerminalBench against the DashScope
# (Alibaba Cloud) OpenAI-compatible endpoint.
#
# Terminus runs IN THE HOST `tb` process and drives each task container over
# tmux. The LLM HTTP calls are made FROM THE HOST, directly to the DashScope
# base URL — so no docker-bridge gateway IP and no iptables workaround.
#
# Terminus parses a JSON (terminus-1) or JSON/XML (terminus-2) command batch
# from plain text, so this run does NOT depend on the model exposing
# OpenAI-style tool_calls correctly.
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
# Pre-flight: DashScope creds present, Docker running.
# ---------------------------------------------------------------------------
[[ -n "${DASHSCOPE_API_KEY:-}" ]] || die "DASHSCOPE_API_KEY missing — set it in config.env"
[[ -n "${DASHSCOPE_BASE_URL:-}" ]] || die "DASHSCOPE_BASE_URL missing — set it in config.env"
docker info &>/dev/null 2>&1 || die "Docker is not running — each TB task needs its container."

log "DashScope base URL: ${DASHSCOPE_BASE_URL}"
log "Model:              ${MODEL_NAME}"

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------
OUT_DIR="${RESULTS_DIR}/${RUN_TAG}/terminalbench"
mkdir -p "$OUT_DIR"
LOG_FILE="${OUT_DIR}/tb_run.log"

# ---------------------------------------------------------------------------
# LLM wiring for litellm (Terminus uses litellm under the hood).
#   --model openai/<served-name>     → generic OpenAI-compatible routing
#   --agent-kwarg api_base/api_key   → forwarded into Terminus' LiteLLM client
#   OPENAI_* env                     → belt-and-suspenders for litellm's client
# ---------------------------------------------------------------------------
export OPENAI_API_KEY="${DASHSCOPE_API_KEY}"
export OPENAI_API_BASE="${DASHSCOPE_BASE_URL}"
export OPENAI_BASE_URL="${DASHSCOPE_BASE_URL}"

AGENT_KWARGS=(
    --agent-kwarg "api_base=${DASHSCOPE_BASE_URL}"
    --agent-kwarg "api_key=${DASHSCOPE_API_KEY}"
    --agent-kwarg "temperature=0.0"
)

# Tell litellm the model's REAL context window so Terminus-2 trims correctly
# (otherwise it assumes a 1,000,000-token window and loops on
# context_length_exceeded). See lib.sh:ensure_litellm_hook.
HOOK_DIR=$(ensure_litellm_hook)
log "Context window advertised to agent: ${MAX_MODEL_LEN} tokens (via litellm hook)"

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
PYTHONPATH="${HOOK_DIR}:${PYTHONPATH:-}" \
MODEL_REG_NAME="${MODEL_NAME}" \
MODEL_CONTEXT_WINDOW="${MAX_MODEL_LEN}" \
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
  "provider": "dashscope",
  "dataset": "${TERMINALBENCH_DATASET}",
  "version": "${TERMINALBENCH_VERSION}",
  "n_concurrent": ${TERMINALBENCH_WORKERS},
  "llm_base_url": "${DASHSCOPE_BASE_URL}",
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

#!/usr/bin/env bash
# 09_run_terminalbench.sh — Run TerminalBench 2.0 via Harbor against the
# DashScope (Alibaba Cloud) OpenAI-compatible endpoint.
#
# Harbor's Terminus-2 agent runs IN THE HOST `harbor` process and drives each
# task container over tmux. The LLM HTTP calls are made FROM THE HOST, directly
# to the DashScope base URL — so no docker-bridge gateway IP and no iptables
# workaround. Terminus-2 parses a JSON or XML command batch from plain text,
# so this run does NOT depend on the model exposing OpenAI-style tool_calls
# correctly.
#
# CLI mapping (vs. the old `tb run`):
#     tb run --dataset name==version --output-path DIR --cleanup
#     ↳ harbor run --dataset name@version --jobs-dir DIR     (no --cleanup)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 9: TerminalBench evaluation via Harbor (agent: ${TB_AGENT}) ==="

# ---------------------------------------------------------------------------
# Resolve harbor (harbor venv) — marker from step 6, then venv, then PATH.
# ---------------------------------------------------------------------------
HARBOR_BIN=""
if [[ -f "${SCRIPT_DIR}/../results/.harbor_bin" ]]; then HARBOR_BIN=$(cat "${SCRIPT_DIR}/../results/.harbor_bin"); fi
if [[ ! -x "$HARBOR_BIN" ]] && [[ -x "${HARBOR_VENV_DIR:-}/bin/harbor" ]]; then HARBOR_BIN="${HARBOR_VENV_DIR}/bin/harbor"; fi
if [[ ! -x "$HARBOR_BIN" ]]; then HARBOR_BIN=$(command -v harbor 2>/dev/null || echo ""); fi
[[ -x "$HARBOR_BIN" ]] || die "'harbor' not found — run 06_setup_agents.sh first."

# Python for parsing results.json (the harbor venv python).
HARBOR_PY=""
if [[ -f "${SCRIPT_DIR}/../results/.harbor_python" ]]; then HARBOR_PY=$(cat "${SCRIPT_DIR}/../results/.harbor_python"); fi
[[ -x "$HARBOR_PY" ]] || HARBOR_PY=$(eval_python)

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
# LLM wiring for litellm (Harbor's Terminus-2 uses litellm under the hood).
#
# Terminus-2 has NO api_key constructor parameter; litellm reads OPENAI_API_KEY
# from the environment for the openai/ provider. We set it on the host AND pass
# it through with --agent-env (which Harbor injects into the agent process).
# ---------------------------------------------------------------------------
export OPENAI_API_KEY="${DASHSCOPE_API_KEY}"
export OPENAI_API_BASE="${DASHSCOPE_BASE_URL}"
export OPENAI_BASE_URL="${DASHSCOPE_BASE_URL}"

AGENT_KWARGS=(
    --agent-kwarg "api_base=${DASHSCOPE_BASE_URL}"
    --agent-kwarg "temperature=0.0"
)
AGENT_ENV=(
    --agent-env "OPENAI_API_KEY=${DASHSCOPE_API_KEY}"
    --agent-env "OPENAI_API_BASE=${DASHSCOPE_BASE_URL}"
)

# parser_name (terminus-2 only): "xml" (forgiving) or "json".
if [[ "${TB_AGENT}" == "terminus-2" && -n "${TB_PARSER:-}" ]]; then
    AGENT_KWARGS+=( --agent-kwarg "parser_name=${TB_PARSER}" )
fi

# Tell litellm the model's REAL context window so Terminus-2 trims correctly
# (otherwise it assumes a 1,000,000-token window and loops on
# context_length_exceeded). See lib.sh:ensure_litellm_hook.
HOOK_DIR=$(ensure_litellm_hook)
log "Context window advertised to agent: ${MAX_MODEL_LEN} tokens (via litellm hook)"

# ---------------------------------------------------------------------------
# Run TerminalBench via Harbor
# ---------------------------------------------------------------------------
log "Starting TerminalBench (dataset=${TERMINALBENCH_DATASET}@${TERMINALBENCH_VERSION})…"
log "Agent: ${TB_AGENT}${TB_PARSER:+ (parser=${TB_PARSER})} | Model: openai/${MODEL_NAME}"
log "Concurrency: ${TERMINALBENCH_WORKERS} | Results: ${OUT_DIR}"
log "This will take a long time — each task spins up a Docker container."

START_TS=$(date +%s)

# Harbor CLI (current):
#   harbor run --dataset name@version  --agent terminus-2  --model openai/<name>
#              --agent-kwarg key=value  --agent-env KEY=VALUE
#              --n-concurrent N         --jobs-dir DIR
PYTHONPATH="${HOOK_DIR}:${PYTHONPATH:-}" \
MODEL_REG_NAME="${MODEL_NAME}" \
MODEL_CONTEXT_WINDOW="${MAX_MODEL_LEN}" \
"$HARBOR_BIN" run \
    --dataset "${TERMINALBENCH_DATASET}@${TERMINALBENCH_VERSION}" \
    --agent "${TB_AGENT}" \
    --model "openai/${MODEL_NAME}" \
    "${AGENT_KWARGS[@]}" \
    "${AGENT_ENV[@]}" \
    --n-concurrent "${TERMINALBENCH_WORKERS}" \
    --jobs-dir "${OUT_DIR}" \
    2>&1 | tee "$LOG_FILE"

TB_EXIT=${PIPESTATUS[0]}
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

# ---------------------------------------------------------------------------
# Parse and summarise results
# ---------------------------------------------------------------------------
log "TerminalBench finished in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# Harbor writes results.json under ${OUT_DIR}/<run-id>/ — find the newest one.
# (Field names match terminal-bench's BenchmarkResults schema: n_resolved,
# n_unresolved, accuracy.)
RESULTS_JSON=$(find "${OUT_DIR}" -name "results.json" -type f 2>/dev/null \
                  | xargs -r ls -t 2>/dev/null | head -1 || true)
N_RESOLVED="?"; N_TOTAL="?"; ACCURACY="?"
if [[ -n "$RESULTS_JSON" ]]; then
    log "Results file: ${RESULTS_JSON}"
    read -r N_RESOLVED N_TOTAL ACCURACY < <("$HARBOR_PY" - "$RESULTS_JSON" <<'PYPARSE'
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
  "harness": "harbor ${HARBOR_VERSION:-latest}",
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

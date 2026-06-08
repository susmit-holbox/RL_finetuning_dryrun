#!/usr/bin/env bash
# 09_run_terminalbench.sh — Run TerminalBench evaluation using OpenHands.
#
# TerminalBench integration (verified research findings):
#   • tb run --agent openhands --model <model>
#   • OpenHands runs INSIDE each task container with RUNTIME=local
#   • LLM_BASE_URL must resolve from INSIDE the container
#     → Use Docker bridge gateway IP (e.g. 172.17.0.1), NOT localhost
#   • LLM_API_KEY and LLM_MODEL passed as env vars
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 9: TerminalBench evaluation ==="

PYTHON=$(command -v python3 || command -v python)

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v tb &>/dev/null; then
    warn "'tb' not found — trying to install terminal-bench…"
    $PYTHON -m pip install --quiet \
        "git+https://github.com/harbor-framework/terminal-bench.git" || \
        die "terminal-bench installation failed"
fi

if ! curl -sf "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
    die "vLLM not healthy at localhost:${VLLM_PORT}. Run 04_start_vllm.sh first."
fi

# ---------------------------------------------------------------------------
# Resolve the LLM base URL for inside-container access
#
# TerminalBench runs OpenHands INSIDE each task Docker container.
# From inside a container, 'localhost' is the container itself, not the host.
# We need the Docker bridge gateway IP to reach the vLLM server on the host.
#
# Method: use 'docker network inspect bridge' to get the gateway IP.
# ---------------------------------------------------------------------------
DOCKER_GW=$(docker_host_ip)
CONTAINER_LLM_BASE_URL="http://${DOCKER_GW}:${VLLM_PORT}/v1"
log "Docker gateway IP: ${DOCKER_GW}"
log "Container→vLLM URL: ${CONTAINER_LLM_BASE_URL}"

# Sanity check: can we reach vLLM via the gateway IP?
if ! curl -sf "http://${DOCKER_GW}:${VLLM_PORT}/health" &>/dev/null; then
    warn "Cannot reach vLLM via gateway IP ${DOCKER_GW}:${VLLM_PORT}"
    warn "Trying to add iptables rule to allow container→host traffic…"
    sudo iptables -I DOCKER-USER -j ACCEPT 2>/dev/null || true
    if ! curl -sf "http://${DOCKER_GW}:${VLLM_PORT}/health" &>/dev/null; then
        warn "Still unreachable. Containers may not be able to reach vLLM."
        warn "Proceeding anyway — some tasks may fail with connection errors."
    fi
fi

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------
OUT_DIR="${RESULTS_DIR}/${RUN_TAG}/terminalbench"
mkdir -p "$OUT_DIR"
LOG_FILE="${OUT_DIR}/tb_run.log"

# ---------------------------------------------------------------------------
# Run TerminalBench
# ---------------------------------------------------------------------------
log "Starting TerminalBench (dataset=${TERMINALBENCH_DATASET} v${TERMINALBENCH_VERSION})…"
log "Results: ${OUT_DIR}"
log "Log: ${LOG_FILE}"
log "This will take a long time — each task spins up a Docker container"

START_TS=$(date +%s)

# Terminal-bench environment variables:
#   LLM_BASE_URL  → vLLM endpoint (from inside container = docker gateway)
#   LLM_API_KEY   → dummy value
#   LLM_MODEL     → openai/<model-name> (OpenHands format)
#
# --cleanup removes task containers after each run (saves disk space)
# --num-workers controls parallel task execution
export LLM_BASE_URL="${CONTAINER_LLM_BASE_URL}"
export LLM_API_KEY="${OPENHANDS_LLM_API_KEY}"
export LLM_MODEL="openai/${MODEL_NAME}"

tb run \
    --dataset-name "${TERMINALBENCH_DATASET}" \
    --dataset-version "${TERMINALBENCH_VERSION}" \
    --agent openhands \
    --model "openai/${MODEL_NAME}" \
    --num-workers "${TERMINALBENCH_WORKERS}" \
    --output-dir "${OUT_DIR}" \
    --cleanup \
    2>&1 | tee "$LOG_FILE"

TB_EXIT=${PIPESTATUS[0]}
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

# ---------------------------------------------------------------------------
# Parse and summarise results
# ---------------------------------------------------------------------------
log "TerminalBench finished in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# tb typically writes results.json in the output dir
if [[ -f "${OUT_DIR}/results.json" ]]; then
    $PYTHON - <<PYPARSE
import json
from pathlib import Path
p = Path("${OUT_DIR}/results.json")
data = json.loads(p.read_text())
total = data.get("total", "?")
passed = data.get("passed", "?")
rate = data.get("pass_rate", "?")
print(f"  Total tasks : {total}")
print(f"  Passed      : {passed}")
print(f"  Pass rate   : {rate}")
PYPARSE
fi

# Write summary
cat > "${OUT_DIR}/run_summary.json" <<SUMMARY
{
  "model": "${MODEL_ID}",
  "model_name": "${MODEL_NAME}",
  "dataset": "${TERMINALBENCH_DATASET}",
  "version": "${TERMINALBENCH_VERSION}",
  "vllm_url_host": "http://localhost:${VLLM_PORT}/v1",
  "vllm_url_container": "${CONTAINER_LLM_BASE_URL}",
  "run_tag": "${RUN_TAG}",
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

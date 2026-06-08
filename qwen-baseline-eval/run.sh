#!/usr/bin/env bash
# =============================================================================
# qwen-baseline-eval / run.sh
#
# End-to-end baseline evaluation of a Qwen model on SWE-bench and TerminalBench.
# Intended to be run inside a screen session on a GPU instance:
#
#   screen -S baseline_eval
#   bash run.sh 2>&1 | tee ~/baseline_run.log
#   # Ctrl+A, D  →  detach
#   # screen -r baseline_eval  →  reattach
#
# Steps executed:
#   1.  System environment check (CUDA, Docker, Python)
#   2.  Install vLLM (GPU)
#   3.  Download model from HuggingFace
#   4.  Start vLLM server (in a sub-screen session)
#   5.  Test tool-call endpoint
#   6.  Install OpenHands + TerminalBench
#   7.  Set up local Docker pull-through cache (rate-limit mitigation)
#   8.  Pre-pull SWE-bench Docker images (ghcr.io primary, Docker Hub fallback)
#   9.  Run TerminalBench evaluation
#   10. Run SWE-bench evaluation
#   11. Collect and archive all results
#
# Edit config.env before running.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${REPO_DIR}/scripts"

# Logging
_CYN='\033[0;36m'; _GRN='\033[0;32m'; _RED='\033[0;31m'; _NC='\033[0m'
banner() { echo -e "\n${_CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_NC}"; \
           echo -e "${_CYN}  $*${_NC}"; \
           echo -e "${_CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_NC}"; }
ok()   { echo -e "${_GRN}[run.sh] ✓ $*${_NC}"; }
die()  { echo -e "${_RED}[run.sh] ✗ $*${_NC}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Source config (sets RUN_TAG if blank)
# ---------------------------------------------------------------------------
[[ -f "${REPO_DIR}/config.env" ]] || die "config.env not found in ${REPO_DIR}"
source "${REPO_DIR}/config.env"
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
export RUN_TAG

banner "Qwen Baseline Eval  |  model: ${MODEL_ID}  |  run: ${RUN_TAG}"
echo "  Config:     ${REPO_DIR}/config.env"
echo "  Results:    ${RESULTS_DIR}/${RUN_TAG}"
echo "  vLLM port:  ${VLLM_PORT}"
echo "  SWE-bench:  ${SWEBENCH_DATASET} (${SWEBENCH_LIMIT} instances)"
echo "  TermBench:  ${TERMINALBENCH_DATASET} v${TERMINALBENCH_VERSION}"
echo ""

# ---------------------------------------------------------------------------
# Helper: run a numbered script and exit on failure
# ---------------------------------------------------------------------------
run_step() {
    local n="$1" script="$2" desc="$3"
    banner "Step ${n}: ${desc}"
    bash "${SCRIPT_DIR}/${script}" || die "Step ${n} (${script}) failed"
    ok "Step ${n} done"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
run_step  1  "01_setup_env.sh"      "System environment check"
run_step  2  "02_install_vllm.sh"   "Install vLLM"
run_step  3  "03_download_model.sh" "Download model from HuggingFace"
run_step  4  "04_start_vllm.sh"     "Start vLLM server"

# Tool-call test (non-fatal: Qwen2.5-Coder may fail silently — we log and continue)
banner "Step 5: Tool-call endpoint test"
# Resolve eval venv python (written by step 1)
_EVAL_PY=$(cat "${REPO_DIR}/results/.eval_python" 2>/dev/null || command -v python3)
VLLM_BASE_URL="http://localhost:${VLLM_PORT}/v1" \
MODEL_NAME="${MODEL_NAME}" \
RESULTS_DIR="${RESULTS_DIR}" \
RUN_TAG="${RUN_TAG}" \
"${_EVAL_PY}" "${SCRIPT_DIR}/05_test_toolcall.py" && ok "Step 5 done (tool calls OK)" || {
    TC_EXIT=$?
    if (( TC_EXIT == 1 )); then
        echo -e "\033[0;33m[run.sh] ⚠ Tool calls not populated (parser issue) — proceeding with eval\033[0m"
    else
        die "Step 5 (tool call test) failed — vLLM unreachable"
    fi
}

run_step  6  "06_setup_openhands.sh" "Install OpenHands + TerminalBench"
run_step  7  "07_setup_registry.sh"  "Local Docker registry (rate-limit cache)"

banner "Step 8: Pre-pull SWE-bench Docker images"
_EVAL_PY=$(cat "${REPO_DIR}/results/.eval_python" 2>/dev/null || command -v python3)
SWEBENCH_DATASET="${SWEBENCH_DATASET}" \
SWEBENCH_SPLIT="${SWEBENCH_SPLIT}" \
RESULTS_DIR="${RESULTS_DIR}" \
RUN_TAG="${RUN_TAG}" \
DOCKER_USERNAME="${DOCKER_USERNAME:-}" \
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}" \
LOCAL_REGISTRY_PORT="${LOCAL_REGISTRY_PORT}" \
ECR_REGISTRY="${ECR_REGISTRY:-}" \
"${_EVAL_PY}" "${SCRIPT_DIR}/08_pull_images.py"
ok "Step 8 done"

run_step  9  "09_run_terminalbench.sh" "TerminalBench evaluation"
run_step 10  "10_run_sweBench.sh"      "SWE-bench evaluation"
run_step 11  "11_collect_results.sh"   "Collect and archive results"

# ---------------------------------------------------------------------------
# Final banner
# ---------------------------------------------------------------------------
banner "All steps complete"
ok "Results at: ${RESULTS_DIR}/${RUN_TAG}"
ok "Summary:    ${RESULTS_DIR}/${RUN_TAG}/SUMMARY.json"
[[ -n "${S3_RESULTS_URI:-}" ]] && ok "S3 backup:  ${S3_RESULTS_URI}/${RUN_TAG}/"
echo ""

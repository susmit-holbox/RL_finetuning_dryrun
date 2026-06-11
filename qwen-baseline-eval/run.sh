#!/usr/bin/env bash
# =============================================================================
# qwen-baseline-eval / run.sh   (cloud branch — DashScope + public ECR)
#
# End-to-end TerminalBench evaluation of `qwen3.7-max` (or any DashScope
# model) using Alibaba Cloud's OpenAI-compatible API for inference and a
# public AWS ECR mirror for TerminalBench-2 task images.
#
# Intended to be run inside a screen session:
#
#   screen -S baseline_eval
#   bash run.sh 2>&1 | tee ~/baseline_run.log
#   # Ctrl+A, D  →  detach
#   # screen -r baseline_eval  →  reattach
#
# Steps executed:
#   1.  System environment check (Docker, Python; NO GPU/CUDA required)
#   5.  Test DashScope OpenAI-compatible endpoint (basic chat + tool-call probe)
#   6.  Install eval agent (Terminus / terminal-bench)
#   8.  Pre-pull TerminalBench-2 task images from public ECR and re-tag them
#       locally as the docker_image names task.toml expects
#   9.  Run TerminalBench evaluation (Terminus → DashScope)
#   11. Collect and archive all results
#
# (Steps 2–4 / 7 / 10 from the local-vLLM flow are gone: cloud inference
# means no vLLM install, no model download, no GPU, no SWE-bench, no local
# docker registry.)
#
# Edit config.env before running. At minimum set DASHSCOPE_API_KEY and (for
# the Singapore region) DASHSCOPE_WORKSPACE_ID.
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
# shellcheck source=/dev/null
source "${REPO_DIR}/config.env"
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
MODEL_NAME="${MODEL_NAME:-qwen3.7-max}"
MODEL_ID="${MODEL_ID:-${MODEL_NAME}}"
RESULTS_DIR="${RESULTS_DIR:-${HOME}/baseline-results}"
TERMINALBENCH_DATASET="${TERMINALBENCH_DATASET:-terminal-bench}"
TERMINALBENCH_VERSION="${TERMINALBENCH_VERSION:-2.0}"
export RUN_TAG MODEL_NAME MODEL_ID RESULTS_DIR TERMINALBENCH_DATASET TERMINALBENCH_VERSION

# Resolve base URL once for the banner (each step also resolves it via lib.sh).
DASHSCOPE_REGION="${DASHSCOPE_REGION:-ap-southeast-1}"
if [[ -z "${DASHSCOPE_BASE_URL:-}" ]]; then
    case "${DASHSCOPE_REGION}" in
        ap-southeast-1|singapore|sg)
            [[ -n "${DASHSCOPE_WORKSPACE_ID:-}" ]] \
                || die "DASHSCOPE_WORKSPACE_ID required for region ${DASHSCOPE_REGION}"
            DASHSCOPE_BASE_URL="https://${DASHSCOPE_WORKSPACE_ID}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
            ;;
        us|us-east-1|virginia)
            DASHSCOPE_BASE_URL="https://dashscope-us.aliyuncs.com/compatible-mode/v1" ;;
        cn-beijing|beijing|cn)
            DASHSCOPE_BASE_URL="https://dashscope.aliyuncs.com/compatible-mode/v1" ;;
        cn-hongkong|hongkong|hk)
            [[ -n "${DASHSCOPE_WORKSPACE_ID:-}" ]] \
                || die "DASHSCOPE_WORKSPACE_ID required for region ${DASHSCOPE_REGION}"
            DASHSCOPE_BASE_URL="https://${DASHSCOPE_WORKSPACE_ID}.cn-hongkong.maas.aliyuncs.com/compatible-mode/v1" ;;
        eu-central-1|frankfurt|eu)
            [[ -n "${DASHSCOPE_WORKSPACE_ID:-}" ]] \
                || die "DASHSCOPE_WORKSPACE_ID required for region ${DASHSCOPE_REGION}"
            DASHSCOPE_BASE_URL="https://${DASHSCOPE_WORKSPACE_ID}.eu-central-1.maas.aliyuncs.com/compatible-mode/v1" ;;
        *) die "Unknown DASHSCOPE_REGION='${DASHSCOPE_REGION}'" ;;
    esac
fi
export DASHSCOPE_BASE_URL

[[ -n "${DASHSCOPE_API_KEY:-}" ]] \
    || die "DASHSCOPE_API_KEY not set in config.env (or environment)."

banner "Qwen Cloud Baseline Eval  |  model: ${MODEL_NAME}  |  run: ${RUN_TAG}"
echo "  Config:      ${REPO_DIR}/config.env"
echo "  Results:     ${RESULTS_DIR}/${RUN_TAG}"
echo "  DashScope:   ${DASHSCOPE_BASE_URL}"
echo "  Benchmark:   ${TERMINALBENCH_DATASET} v${TERMINALBENCH_VERSION} (agent=${TB_AGENT:-terminus-2})"
echo "  TB image ECR: ${TB_PUBLIC_ECR:-public.ecr.aws/l7z4o9j8/holboxai/terminal-bench-2}"
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

# Step 5: DashScope endpoint sanity check.
banner "Step 5: DashScope endpoint test"
_EVAL_PY=$(cat "${REPO_DIR}/results/.eval_python" 2>/dev/null || command -v python3)
DASHSCOPE_BASE_URL="${DASHSCOPE_BASE_URL}" \
DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY}" \
MODEL_NAME="${MODEL_NAME}" \
RESULTS_DIR="${RESULTS_DIR}" \
RUN_TAG="${RUN_TAG}" \
"${_EVAL_PY}" "${SCRIPT_DIR}/05_test_endpoint.py" && ok "Step 5 done (tool calls OK)" || {
    EP_EXIT=$?
    if (( EP_EXIT == 1 )); then
        echo -e "\033[0;33m[run.sh] ⚠ Tool calls not populated (informational) — proceeding\033[0m"
    else
        die "Step 5 (endpoint test) failed — DashScope unreachable or auth bad"
    fi
}

run_step  6  "06_setup_agents.sh"    "Install eval agent (Terminus / terminal-bench)"

banner "Step 8: Pre-pull TerminalBench task images from public ECR"
_EVAL_PY=$(cat "${REPO_DIR}/results/.eval_python" 2>/dev/null || command -v python3)
TB_PUBLIC_ECR="${TB_PUBLIC_ECR:-public.ecr.aws/l7z4o9j8/holboxai/terminal-bench-2}" \
TB_TAG_PREFIX="${TB_TAG_PREFIX:-}" \
TB2_REPO_URL="${TB2_REPO_URL:-https://github.com/laude-institute/terminal-bench-2.git}" \
TB2_REF="${TB2_REF:-main}" \
TB2_WORK_DIR="${TB2_WORK_DIR:-${HOME}/terminal-bench-2-src}" \
TASK_FILTER="${TASK_FILTER:-}" \
PULL_WORKERS="${PULL_WORKERS:-4}" \
RESULTS_DIR="${RESULTS_DIR}" \
RUN_TAG="${RUN_TAG}" \
"${_EVAL_PY}" "${SCRIPT_DIR}/08_pull_tb_images.py"
ok "Step 8 done"

run_step  9  "09_run_terminalbench.sh" "TerminalBench evaluation (Terminus → DashScope)"
run_step 11  "11_collect_results.sh"   "Collect and archive results"

# ---------------------------------------------------------------------------
# Final banner
# ---------------------------------------------------------------------------
banner "All steps complete"
ok "Results at: ${RESULTS_DIR}/${RUN_TAG}"
ok "Summary:    ${RESULTS_DIR}/${RUN_TAG}/SUMMARY.json"
[[ -n "${S3_RESULTS_URI:-}" ]] && ok "S3 backup:  ${S3_RESULTS_URI}/${RUN_TAG}/"
echo ""

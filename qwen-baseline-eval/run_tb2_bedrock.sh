#!/usr/bin/env bash
# =============================================================================
# run_tb2_bedrock.sh
#
# Run **Terminal-Bench 2.0** (the Harbor harness) with the **Terminus-2** agent
# driven by **Claude Opus 4.8 on Amazon Bedrock** — NO local GPU, NO vLLM, NO
# SWE-bench. The sibling run.sh hosts a local model with vLLM and runs two
# benchmarks; this is the single-benchmark, Bedrock-hosted variant.
#
# What it does:
#   1. Pre-flight (docker, aws, harbor, python).
#   2. Verify AWS / Bedrock credentials.
#   3. (optional) HYDRATE task images from your public ECR — pull them and retag
#      to the names task.toml expects, so Harbor runs them locally and never
#      pulls Docker Hub.
#   4. Run `harbor run -d terminal-bench@2.0 -a terminus-2 -m bedrock/<opus-4.8>`.
#   5. Parse jobs/<run>/result.json and write a self-describing summary.
#
# Usage:
#   bash run_tb2_bedrock.sh 2>&1 | tee ~/tb2_bedrock.log
#   # smoke test 1 task first:
#   N_TASKS=1 bash run_tb2_bedrock.sh
#
# Every CONFIG value below can be overridden via an environment variable.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${REPO_DIR}/scripts"

# ---------------------------------------------------------------------------
# CONFIG (override via env)
# ---------------------------------------------------------------------------
# Your public ECR repo holding the mirrored TB2 task images (from
# scripts/tb2_images_to_ecr.py). Used only when HYDRATE=1.
ECR_REGISTRY="${ECR_REGISTRY:-public.ecr.aws/l7z4o9j8/holboxai/terminal-bench-2}"

# LiteLLM Bedrock model string for Claude Opus 4.8.
#   • Newer Claude (Opus 4.x) requires a CROSS-REGION INFERENCE PROFILE — note the
#     `us.` geography prefix. Plain `bedrock/anthropic.claude-opus-4-8` will fail
#     with "on-demand throughput isn't supported".
#   • Confirmed profile IDs in this account (aws bedrock list-inference-profiles):
#       us.anthropic.claude-opus-4-8       (US cross-region — default below)
#       global.anthropic.claude-opus-4-8   (global cross-region — set if preferred)
#     NOTE: no `-vN:0` version suffix on these profile IDs.
#   • If you use an application-inference-profile ARN, use bedrock/converse/<arn>.
BEDROCK_MODEL="${BEDROCK_MODEL:-bedrock/us.anthropic.claude-opus-4-8}"

# AWS region where Bedrock model access is granted (litellm reads AWS_REGION_NAME).
AWS_REGION="${AWS_REGION:-us-east-1}"

# Harbor dataset id. The TB2 repo uses `terminal-bench@2.0`; some docs use
# `terminal-bench/terminal-bench-2`. Verify with `harbor dataset list`.
DATASET="${DATASET:-terminal-bench@2.0}"

TB_AGENT="${TB_AGENT:-terminus-2}"
# Thinking effort for Opus 4.8 (terminus-2 reasoning_effort kwarg): low|medium|high|xhigh|max.
# Leave blank to use the agent default. high/xhigh is recommended for agentic work.
EFFORT="${EFFORT:-high}"

N_CONCURRENT="${N_CONCURRENT:-4}"      # concurrent trials (Bedrock throttles — keep modest)
N_TASKS="${N_TASKS:-0}"               # 0 = all 89; >0 caps task count (smoke test)
TASK_FILTER="${TASK_FILTER:-}"        # glob for harbor -i (and hydrate subset), e.g. 'chess*'

HYDRATE="${HYDRATE:-1}"               # 1 = pre-load images from ECR before running
HYDRATE_WORKERS="${HYDRATE_WORKERS:-4}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
JOBS_DIR="${JOBS_DIR:-${HOME}/tb2-bedrock-results}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_CYN='\033[0;36m'; _GRN='\033[0;32m'; _YEL='\033[0;33m'; _RED='\033[0;31m'; _NC='\033[0m'
banner(){ echo -e "\n${_CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_NC}"; \
          echo -e "${_CYN}  $*${_NC}"; \
          echo -e "${_CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_NC}"; }
log(){  echo -e "${_CYN}[tb2] $*${_NC}"; }
ok(){   echo -e "${_GRN}[tb2] ✓ $*${_NC}"; }
warn(){ echo -e "${_YEL}[tb2] ⚠ $*${_NC}"; }
die(){  echo -e "${_RED}[tb2] ✗ $*${_NC}" >&2; exit 1; }

banner "TerminalBench 2.0 | agent: ${TB_AGENT} | model: ${BEDROCK_MODEL} | run: ${RUN_TAG}"
echo "  Dataset:     ${DATASET}"
echo "  Region:      ${AWS_REGION}"
echo "  Concurrency: ${N_CONCURRENT}  | Tasks: $([[ "$N_TASKS" == 0 ]] && echo all || echo "$N_TASKS")"
echo "  Hydrate ECR: $([[ "$HYDRATE" == 1 ]] && echo "yes (${ECR_REGISTRY})" || echo no)"
echo "  Results:     ${JOBS_DIR}/${RUN_TAG}"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — Pre-flight
# ---------------------------------------------------------------------------
banner "Step 1: Pre-flight"
command -v docker >/dev/null || die "docker not found."
docker info >/dev/null 2>&1 || die "Docker daemon not running."
command -v aws >/dev/null || die "aws CLI not found."
command -v python3 >/dev/null || die "python3 not found (needed for the hydrate/parse helpers)."

# Resolve / install harbor.
HARBOR_BIN="$(command -v harbor 2>/dev/null || true)"
if [[ -z "$HARBOR_BIN" ]]; then
    warn "harbor not found — installing…"
    if command -v uv >/dev/null; then
        uv tool install harbor >/dev/null 2>&1 || true
    fi
    HARBOR_BIN="$(command -v harbor 2>/dev/null || true)"
    [[ -z "$HARBOR_BIN" && -x "${HOME}/.local/bin/harbor" ]] && HARBOR_BIN="${HOME}/.local/bin/harbor"
    if [[ -z "$HARBOR_BIN" ]]; then
        python3 -m pip install --quiet --user harbor 2>/dev/null || pip install --quiet harbor 2>/dev/null || true
        HARBOR_BIN="$(command -v harbor 2>/dev/null || echo "${HOME}/.local/bin/harbor")"
    fi
fi
[[ -x "$HARBOR_BIN" ]] || die "Could not install harbor. Try: uv tool install harbor"
ok "harbor: ${HARBOR_BIN} ($("$HARBOR_BIN" --version 2>/dev/null | head -1 || echo '?'))"

# ---------------------------------------------------------------------------
# Step 2 — AWS / Bedrock credentials
# ---------------------------------------------------------------------------
banner "Step 2: AWS / Bedrock auth"
# LiteLLM (used by Terminus-2) reads AWS_REGION_NAME + standard boto3 credentials
# from the environment. Bedrock uses IAM, NOT an API key.
export AWS_REGION_NAME="${AWS_REGION}"
export AWS_REGION="${AWS_REGION}"
if aws sts get-caller-identity >/dev/null 2>&1; then
    ok "AWS identity: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
else
    warn "aws sts get-caller-identity failed — relying on an instance/role credential."
    warn "Bedrock needs: bedrock:InvokeModel + bedrock:InvokeModelWithResponseStream on the"
    warn "Opus 4.8 inference profile, and model access granted in region ${AWS_REGION}."
fi
case "$BEDROCK_MODEL" in
    bedrock/us.*|bedrock/eu.*|bedrock/apac.*|bedrock/global.*|bedrock/converse/*) : ;;
    *) warn "BEDROCK_MODEL='${BEDROCK_MODEL}' has no us./eu./apac. inference-profile prefix —"
       warn "Opus 4.x usually requires one. If you get 'on-demand throughput isn't supported',"
       warn "look the profile up: aws bedrock list-inference-profiles --region ${AWS_REGION}" ;;
esac

# ---------------------------------------------------------------------------
# Step 3 — Hydrate task images from ECR (optional)
# ---------------------------------------------------------------------------
if [[ "$HYDRATE" == 1 ]]; then
    banner "Step 3: Hydrate TB2 images from ECR"
    log "Pulling task images from ${ECR_REGISTRY} and retagging to the names Harbor expects…"
    HYDRATE_ARGS=(--ecr-registry "$ECR_REGISTRY" --hydrate --workers "$HYDRATE_WORKERS")
    [[ -n "$TASK_FILTER" ]] && HYDRATE_ARGS+=(--task-filter "${TASK_FILTER//\*/.*}")
    python3 "${SCRIPT_DIR}/tb2_images_to_ecr.py" "${HYDRATE_ARGS[@]}" \
        || warn "Hydrate had failures — Harbor will pull missing images from Docker Hub on demand."
else
    banner "Step 3: Hydrate skipped (HYDRATE=0)"
    warn "Harbor will pull task images straight from Docker Hub (alexgshaw/<task>:…)."
fi

# ---------------------------------------------------------------------------
# Step 4 — Run Terminal-Bench 2.0 via Harbor
# ---------------------------------------------------------------------------
banner "Step 4: harbor run (${DATASET}, ${TB_AGENT}, ${BEDROCK_MODEL})"
mkdir -p "$JOBS_DIR"
LOG_FILE="${JOBS_DIR}/${RUN_TAG}.log"

HARBOR_ARGS=(
    run
    -d "$DATASET"
    -a "$TB_AGENT"
    -m "$BEDROCK_MODEL"
    -n "$N_CONCURRENT"
    -o "$JOBS_DIR"
    --job-name "$RUN_TAG"
)
[[ "$N_TASKS" != 0 ]] && HARBOR_ARGS+=(-l "$N_TASKS")
[[ -n "$TASK_FILTER" ]] && HARBOR_ARGS+=(-i "$TASK_FILTER")
[[ -n "$EFFORT" ]] && HARBOR_ARGS+=(--ak "reasoning_effort=${EFFORT}")
# Forward the region to the agent process too (belt-and-suspenders alongside the export).
HARBOR_ARGS+=(--ae "AWS_REGION_NAME=${AWS_REGION}")

log "Command: ${HARBOR_BIN} ${HARBOR_ARGS[*]}"
log "Each task spins up a Docker container — this takes a while."
START_TS=$(date +%s)
"$HARBOR_BIN" "${HARBOR_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
HARBOR_EXIT=${PIPESTATUS[0]}
ELAPSED=$(( $(date +%s) - START_TS ))
log "harbor finished in $(( ELAPSED/60 ))m $(( ELAPSED%60 ))s (exit ${HARBOR_EXIT})"

# ---------------------------------------------------------------------------
# Step 5 — Parse results + summary
# ---------------------------------------------------------------------------
banner "Step 5: Results"
RESULT_JSON="${JOBS_DIR}/${RUN_TAG}/result.json"
PASS=""; NTRIALS=""; NERR=""
if [[ -f "$RESULT_JSON" ]]; then
    log "Result file: ${RESULT_JSON}"
    read -r PASS NTRIALS NERR < <(python3 - "$RESULT_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def walk(o):
    if isinstance(o, dict):
        if "pass_at_k" in o and isinstance(o["pass_at_k"], dict): yield o["pass_at_k"]
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
paks = list(walk(d))
pak = next((p for p in paks if p), {})
# pass@1 if present, else first value
pass1 = pak.get("1") or pak.get(1) or (next(iter(pak.values()), "?") if pak else "?")
st = d.get("stats", {}) if isinstance(d, dict) else {}
nt = st.get("n_trials") if isinstance(st, dict) else None
ne = st.get("n_errors") if isinstance(st, dict) else None
print(pass1 if pass1 is not None else "?", nt if nt is not None else "?", ne if ne is not None else "?")
PY
) || true
    ok "pass@1: ${PASS}   (trials: ${NTRIALS}, errors: ${NERR})"
else
    warn "No result.json at ${RESULT_JSON} — check ${LOG_FILE}"
fi

cat > "${JOBS_DIR}/${RUN_TAG}/run_summary.json" <<SUMMARY
{
  "benchmark": "terminal-bench-2.0",
  "harness": "harbor",
  "agent": "${TB_AGENT}",
  "effort": "${EFFORT}",
  "provider": "bedrock",
  "model": "${BEDROCK_MODEL}",
  "aws_region": "${AWS_REGION}",
  "dataset": "${DATASET}",
  "n_concurrent": ${N_CONCURRENT},
  "n_tasks": "${N_TASKS}",
  "images_from_ecr": $([[ "$HYDRATE" == 1 ]] && echo true || echo false),
  "ecr_registry": "${ECR_REGISTRY}",
  "run_tag": "${RUN_TAG}",
  "pass_at_1": "${PASS:-?}",
  "n_trials": "${NTRIALS:-?}",
  "n_errors": "${NERR:-?}",
  "elapsed_seconds": ${ELAPSED},
  "exit_code": ${HARBOR_EXIT}
}
SUMMARY
ok "Summary: ${JOBS_DIR}/${RUN_TAG}/run_summary.json"

(( HARBOR_EXIT == 0 )) && banner "Done — results at ${JOBS_DIR}/${RUN_TAG}" \
    || warn "harbor exited ${HARBOR_EXIT} — inspect ${LOG_FILE}"

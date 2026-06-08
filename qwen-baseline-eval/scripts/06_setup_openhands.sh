#!/usr/bin/env bash
# 06_setup_openhands.sh — Clone and install OpenHands + evaluation dependencies.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 6: Setup OpenHands ==="

PYTHON=$(command -v python3 || command -v python)

# ---------------------------------------------------------------------------
# Clone OpenHands
# ---------------------------------------------------------------------------
# Pin to 0.62.0 — the last tag that includes evaluation/benchmarks/swe_bench/
# The evaluation directory was removed from main after this tag.
OPENHANDS_TAG="0.62.0"

if [[ -d "${OPENHANDS_DIR}/.git" ]]; then
    CURRENT_TAG=$(git -C "${OPENHANDS_DIR}" describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_TAG" == "$OPENHANDS_TAG" ]]; then
        ok "OpenHands ${OPENHANDS_TAG} already checked out at ${OPENHANDS_DIR}"
    else
        log "Existing checkout is ${CURRENT_TAG} — re-cloning to pin ${OPENHANDS_TAG}…"
        rm -rf "${OPENHANDS_DIR}"
        retry 3 15 \
            git clone --depth 1 --branch "${OPENHANDS_TAG}" \
                https://github.com/All-Hands-AI/OpenHands.git \
                "${OPENHANDS_DIR}"
    fi
else
    log "Cloning OpenHands ${OPENHANDS_TAG} into ${OPENHANDS_DIR}…"
    retry 3 15 \
        git clone --depth 1 --branch "${OPENHANDS_TAG}" \
            https://github.com/All-Hands-AI/OpenHands.git \
            "${OPENHANDS_DIR}"
fi

# Verify the evaluation runner exists
[[ -f "${OPENHANDS_DIR}/evaluation/benchmarks/swe_bench/run_infer.py" ]] || \
    die "run_infer.py not found after clone — clone may have failed"
ok "run_infer.py present"

# ---------------------------------------------------------------------------
# Install OpenHands + evaluation extras
# ---------------------------------------------------------------------------
log "Installing OpenHands Python package…"
cd "${OPENHANDS_DIR}"

# Core install
retry 3 30 \
    $PYTHON -m pip install -e ".[llms]" --quiet \
    2>&1 | grep -v "^Requirement already"

# Evaluation benchmarks have their own requirements
if [[ -f "evaluation/benchmarks/swe_bench/requirements.txt" ]]; then
    $PYTHON -m pip install -r evaluation/benchmarks/swe_bench/requirements.txt --quiet \
        2>&1 | grep -v "^Requirement already" || true
fi
if [[ -f "evaluation/requirements.txt" ]]; then
    $PYTHON -m pip install -r evaluation/requirements.txt --quiet \
        2>&1 | grep -v "^Requirement already" || true
fi

# datasets is needed to enumerate SWE-bench instances
$PYTHON -m pip install --quiet "datasets>=2.19.0" "huggingface_hub[cli]>=0.24.0"

# ---------------------------------------------------------------------------
# Install TerminalBench (terminal-bench)
# ---------------------------------------------------------------------------
log "Installing terminal-bench…"
retry 3 15 \
    $PYTHON -m pip install --quiet \
        "git+https://github.com/harbor-framework/terminal-bench.git" \
    2>&1 | grep -v "^Requirement already" || \
    warn "terminal-bench install failed — will retry at run time"

if command -v tb &>/dev/null; then
    ok "terminal-bench (tb) installed: $(tb --version 2>/dev/null || echo 'version unknown')"
else
    warn "'tb' command not found in PATH — terminal-bench may not be installed"
fi

# ---------------------------------------------------------------------------
# Write OpenHands config.toml
# The evaluation runner reads LLM settings from config.toml using the
# [llm.<name>] section format.  We write an 'eval_model' section that the
# run_infer.py script can reference via --llm-config eval_model.
#
# On Linux, vLLM runs on the HOST so the correct URL for the evaluation
# runner (which also runs on the host) is localhost:<port>.
# TerminalBench containers need the Docker bridge gateway IP instead —
# that is set separately via LLM_BASE_URL env var in 09_run_terminalbench.sh
# ---------------------------------------------------------------------------
log "Writing OpenHands config.toml…"
cat > "${OPENHANDS_DIR}/config.toml" <<TOML
[core]
workspace_base = "${RESULTS_DIR}/${RUN_TAG}/openhands_workspace"
run_as_openhands = false

[llm.eval_model]
model = "openai/${MODEL_NAME}"
base_url = "${OPENHANDS_LLM_BASE_URL}"
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

ok "config.toml written to ${OPENHANDS_DIR}/config.toml"

# Create workspace directory
mkdir -p "${RESULTS_DIR}/${RUN_TAG}/openhands_workspace"

ok "=== OpenHands setup complete ==="
log "OpenHands dir: ${OPENHANDS_DIR}"

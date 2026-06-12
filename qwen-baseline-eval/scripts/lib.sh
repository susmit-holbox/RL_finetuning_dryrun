#!/usr/bin/env bash
# Common utilities — source this at the top of every script.
set -euo pipefail

# ---------------------------------------------------------------------------
# Colour / logging
# ---------------------------------------------------------------------------
_RED='\033[0;31m'; _YEL='\033[0;33m'; _GRN='\033[0;32m'; _CYN='\033[0;36m'; _NC='\033[0m'

log()  { echo -e "${_CYN}[$(date '+%H:%M:%S')] $*${_NC}"; }
ok()   { echo -e "${_GRN}[$(date '+%H:%M:%S')] ✓ $*${_NC}"; }
warn() { echo -e "${_YEL}[$(date '+%H:%M:%S')] ⚠ $*${_NC}"; }
die()  { echo -e "${_RED}[$(date '+%H:%M:%S')] ✗ $*${_NC}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load config (idempotent)
# ---------------------------------------------------------------------------
load_config() {
    local cfg="${SCRIPT_DIR:-$(dirname "$0")}/../config.env"
    [[ -f "$cfg" ]] || die "config.env not found at $cfg"
    # shellcheck source=/dev/null
    source "$cfg"

    # --- Safety-net defaults --------------------------------------------------
    # config.env is GITIGNORED, so a freshly-synced box may carry an older copy
    # that predates these vars. Scripts run under `set -u`, so any unset var is a
    # hard error. `: "${VAR:=default}"` fills it in ONLY when unset/empty.
    # Harbor (TB-2 / Terminal-Bench 2.0 harness) — installed into HARBOR_VENV_DIR.
    # HARBOR_VENV_DIR replaces the older TB_VENV_DIR; we honour the latter for
    # backwards compatibility with config.env files written for the old flow.
    : "${HARBOR_VENV_DIR:=${TB_VENV_DIR:-${HOME}/harbor_venv}}"
    : "${HARBOR_VERSION:=}"                      # blank = pip-install latest
    : "${TB_AGENT:=terminus-2}"
    : "${TB_PARSER:=xml}"
    : "${TERMINALBENCH_WORKERS:=4}"
    : "${TERMINALBENCH_DATASET:=terminal-bench}"
    : "${TERMINALBENCH_VERSION:=2.0}"
    : "${MAX_MODEL_LEN:=131072}"
    : "${RESULTS_DIR:=${HOME}/baseline-results}"
    : "${EVAL_VENV_DIR:=${HOME}/eval_venv}"

    # DashScope (Alibaba Cloud) configuration
    : "${DASHSCOPE_REGION:=ap-southeast-1}"
    : "${DASHSCOPE_WORKSPACE_ID:=}"
    : "${DASHSCOPE_API_KEY:=${LLM_API_KEY:-}}"
    : "${MODEL_NAME:=qwen3.7-max}"
    : "${MODEL_ID:=${MODEL_NAME}}"

    # Public ECR for TerminalBench task images
    : "${TB_PUBLIC_ECR:=public.ecr.aws/l7z4o9j8/holboxai/terminal-bench-2}"
    : "${TB_TAG_PREFIX:=}"
    : "${TB2_REPO_URL:=https://github.com/laude-institute/terminal-bench-2.git}"
    : "${TB2_REF:=main}"
    : "${TB2_WORK_DIR:=${HOME}/terminal-bench-2-src}"

    # Resolve DASHSCOPE_BASE_URL from region + workspace if not explicitly set
    if [[ -z "${DASHSCOPE_BASE_URL:-}" ]]; then
        DASHSCOPE_BASE_URL=$(resolve_dashscope_base_url)
    fi
    export DASHSCOPE_BASE_URL

    # Set RUN_TAG if not already set
    if [[ -z "${RUN_TAG:-}" ]]; then
        RUN_TAG="$(date +%Y%m%d_%H%M%S)"
        export RUN_TAG
    fi
}

# ---------------------------------------------------------------------------
# Resolve the DashScope OpenAI-compatible base URL from the configured region
# and (where required) DASHSCOPE_WORKSPACE_ID.
# ---------------------------------------------------------------------------
resolve_dashscope_base_url() {
    case "${DASHSCOPE_REGION}" in
        ap-southeast-1|singapore|sg)
            [[ -n "${DASHSCOPE_WORKSPACE_ID}" ]] \
                || die "DASHSCOPE_WORKSPACE_ID required for region ${DASHSCOPE_REGION}"
            echo "https://${DASHSCOPE_WORKSPACE_ID}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
            ;;
        us|us-east-1|virginia)
            echo "https://dashscope-us.aliyuncs.com/compatible-mode/v1"
            ;;
        cn-beijing|beijing|cn)
            echo "https://dashscope.aliyuncs.com/compatible-mode/v1"
            ;;
        cn-hongkong|hongkong|hk)
            [[ -n "${DASHSCOPE_WORKSPACE_ID}" ]] \
                || die "DASHSCOPE_WORKSPACE_ID required for region ${DASHSCOPE_REGION}"
            echo "https://${DASHSCOPE_WORKSPACE_ID}.cn-hongkong.maas.aliyuncs.com/compatible-mode/v1"
            ;;
        eu-central-1|frankfurt|eu)
            [[ -n "${DASHSCOPE_WORKSPACE_ID}" ]] \
                || die "DASHSCOPE_WORKSPACE_ID required for region ${DASHSCOPE_REGION}"
            echo "https://${DASHSCOPE_WORKSPACE_ID}.eu-central-1.maas.aliyuncs.com/compatible-mode/v1"
            ;;
        *)
            die "Unknown DASHSCOPE_REGION='${DASHSCOPE_REGION}' (expected ap-southeast-1|us|cn-beijing|cn-hongkong|eu-central-1)"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Retry with exponential backoff
# Usage: retry <max_attempts> <initial_delay_s> <command…>
# ---------------------------------------------------------------------------
retry() {
    local max_attempts="$1" delay="$2"; shift 2
    local attempt=1
    until "$@"; do
        if (( attempt >= max_attempts )); then
            warn "Command failed after $max_attempts attempts: $*"
            return 1
        fi
        warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s…"
        sleep "$delay"
        delay=$(( delay * 2 ))
        (( attempt++ ))
    done
}

# ---------------------------------------------------------------------------
# litellm context-window hook.
#
# Terminus calls litellm under the hood. For a cloud-served model that
# litellm doesn't know about (e.g. `qwen3.7-max` via the OpenAI-compatible
# DashScope endpoint), litellm.get_max_tokens returns None and Terminus-2
# falls back to a 1,000,000-token assumption and never trims the
# conversation — once history exceeds the real window, every call dies in
# an unrecoverable `context_length_exceeded` loop.
#
# Fix: drop a sitecustomize.py on PYTHONPATH that runs at python startup and
# registers the served model's real context window with litellm. The agent
# then trims to fit. Activated by exporting MODEL_REG_NAME + MODEL_CONTEXT_WINDOW
# and prepending the returned dir to PYTHONPATH for the agent invocation.
#
# Usage:
#   HOOK_DIR=$(ensure_litellm_hook)
#   PYTHONPATH="${HOOK_DIR}:${PYTHONPATH:-}" MODEL_REG_NAME="$MODEL_NAME" \
#     MODEL_CONTEXT_WINDOW="$MAX_MODEL_LEN" <agent-command>
# ---------------------------------------------------------------------------
ensure_litellm_hook() {
    local dir="${SCRIPT_DIR}/../results/litellm_hook"
    mkdir -p "$dir"
    cat > "${dir}/sitecustomize.py" <<'PYHOOK'
# Auto-injected via PYTHONPATH. Tells litellm the served model's real
# context window so agents (esp. Terminus-2) trim the conversation correctly
# instead of assuming a 1,000,000-token window. See lib.sh:ensure_litellm_hook.
import os
try:
    _name = os.environ.get("MODEL_REG_NAME")
    _ctx = int(os.environ.get("MODEL_CONTEXT_WINDOW") or 0)
    if _name and _ctx > 0:
        import litellm
        _entry = {
            "max_tokens": _ctx,
            "max_input_tokens": _ctx,
            "max_output_tokens": _ctx,
            "litellm_provider": "openai",
            "mode": "chat",
            "input_cost_per_token": 0.0,
            "output_cost_per_token": 0.0,
        }
        # Register both the bare served name and the openai/ litellm form.
        litellm.register_model({_name: _entry, f"openai/{_name}": _entry})
except Exception:
    pass
PYHOOK
    echo "$dir"
}

# ---------------------------------------------------------------------------
# Python helpers
#   eval_python  → venv python for tools/utilities (any python3 ≥3.10)
# ---------------------------------------------------------------------------
eval_python() {
    local venv_file="${SCRIPT_DIR}/../results/.eval_python"
    if [[ -f "$venv_file" ]]; then
        cat "$venv_file"
    elif [[ -x "${EVAL_VENV_DIR:-}/bin/python" ]]; then
        echo "${EVAL_VENV_DIR}/bin/python"
    else
        command -v python3
    fi
}

# ---------------------------------------------------------------------------
# Screen helpers
# ---------------------------------------------------------------------------
screen_running() {
    screen -list | grep -q "\.${1}\b"
}

kill_screen() {
    screen -S "$1" -X quit 2>/dev/null || true
}

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

    # --- Safety-net defaults for the eval-agent vars --------------------------
    # config.env is GITIGNORED, so a freshly-synced box may carry an older copy
    # that predates these vars. Scripts run under `set -u`, so any unset var is a
    # hard error. `: "${VAR:=default}"` fills it in ONLY when unset/empty, so a
    # value present in config.env still wins. (Mirrors 01_setup_env.sh's
    # EVAL_VENV_DIR safety net.)
    : "${LLM_API_KEY:=dummy}"
    : "${SWE_AGENT_VENV_DIR:=${HOME}/mini_swe_venv}"
    : "${MINI_SWE_VERSION:=}"
    : "${SWE_STEP_LIMIT:=250}"
    : "${SWE_COST_LIMIT:=1000}"
    : "${TB_VENV_DIR:=${HOME}/tb_venv}"
    : "${TB_VERSION:=0.2.18}"
    : "${TB_AGENT:=terminus-2}"
    : "${TB_PARSER:=xml}"
    : "${MAX_MODEL_LEN:=16384}"

    # Set RUN_TAG if not already set
    if [[ -z "${RUN_TAG:-}" ]]; then
        RUN_TAG="$(date +%Y%m%d_%H%M%S)"
        export RUN_TAG
    fi
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
# Docker pull with rate-limit awareness
# Tries ghcr.io/epoch-research first (less rate-limited), then Docker Hub
# with exponential backoff.
# Usage: docker_pull_swebench <instance_id>
# ---------------------------------------------------------------------------
docker_pull_swebench() {
    local iid="$1"
    local dh_image="swebench/sweb.eval.x86_64.${iid}:latest"
    local gh_image="ghcr.io/epoch-research/swe-bench.eval.x86_64.${iid}:latest"
    local local_image="localhost:${LOCAL_REGISTRY_PORT:-5001}/swebench/sweb.eval.x86_64.${iid}:latest"

    # Already pulled (check local registry tag)
    if docker image inspect "$local_image" &>/dev/null 2>&1; then
        return 0
    fi
    if docker image inspect "$dh_image" &>/dev/null 2>&1; then
        _cache_image_locally "$dh_image" "swebench/sweb.eval.x86_64.${iid}"
        return 0
    fi

    # Try ghcr.io first (Epoch AI mirror — no Docker Hub rate limit)
    if docker pull "$gh_image" 2>/dev/null; then
        docker tag "$gh_image" "$dh_image"
        _cache_image_locally "$dh_image" "swebench/sweb.eval.x86_64.${iid}"
        return 0
    fi

    # Fall back to Docker Hub with retry / backoff
    local attempt=1 delay=30
    while (( attempt <= 8 )); do
        local pull_out
        pull_out=$(docker pull "$dh_image" 2>&1) && {
            _cache_image_locally "$dh_image" "swebench/sweb.eval.x86_64.${iid}"
            return 0
        }
        if echo "$pull_out" | grep -qiE "toomanyrequests|429|rate limit"; then
            warn "Docker Hub rate limit hit for $iid (attempt $attempt). Waiting ${delay}s…"
            sleep "$delay"
            delay=$(( delay * 2 ))
        else
            warn "Pull failed for $iid: $pull_out"
            return 1
        fi
        (( attempt++ ))
    done
    warn "Could not pull $iid after 8 attempts"
    return 1
}

_cache_image_locally() {
    local src="$1" name="$2"
    local dst="localhost:${LOCAL_REGISTRY_PORT:-5001}/${name}:latest"
    if docker image inspect "$dst" &>/dev/null 2>&1; then return 0; fi
    docker tag "$src" "$dst" 2>/dev/null && docker push "$dst" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Wait for vLLM server to become ready
# Usage: wait_for_vllm [host] [port] [timeout_s]
# ---------------------------------------------------------------------------
wait_for_vllm() {
    local host="${1:-localhost}" port="${2:-8000}" timeout="${3:-300}"
    local url="http://${host}:${port}/health"
    log "Waiting for vLLM at $url (timeout ${timeout}s)…"
    local start elapsed=0
    start=$(date +%s)
    until curl -sf "$url" &>/dev/null; do
        elapsed=$(( $(date +%s) - start ))
        (( elapsed >= timeout )) && die "vLLM did not become healthy within ${timeout}s"
        sleep 5
    done
    ok "vLLM is healthy"
}

# ---------------------------------------------------------------------------
# litellm context-window hook.
#
# Both agents call litellm. For a locally-served vLLM model, litellm has NO
# model_info, so litellm.get_max_tokens(<name>) returns None. Terminus-2 then
# falls back to assuming a 1,000,000-token context window
# (terminus_2.py:_get_model_context_limit) and NEVER trims the conversation, so
# once a task's history exceeds the REAL window every call dies with
# `context_length_exceeded` in an unrecoverable loop.
#
# Fix: drop a sitecustomize.py on PYTHONPATH that runs at python startup and
# registers the served model's real context window with litellm. The agent then
# trims to fit. Activated by exporting MODEL_REG_NAME + MODEL_CONTEXT_WINDOW and
# prepending the returned dir to PYTHONPATH for the agent invocation.
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
# Auto-injected via PYTHONPATH. Tells litellm the locally-served model's real
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
# Get Docker bridge gateway IP (for containers to reach host services)
# ---------------------------------------------------------------------------
docker_host_ip() {
    docker network inspect bridge \
        --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null \
        | head -1 \
        || echo "172.17.0.1"
}

# ---------------------------------------------------------------------------
# Python helpers
# eval_python  → venv python for vLLM/tools  (any python3 ≥3.10, incl 3.14)
# oh_python    → venv python for OpenHands   (python3.12/3.13 only)
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

oh_python() {
    local oh_dir="${OPENHANDS_DIR:-${HOME}/OpenHands}"
    local venv_file="${oh_dir}/.venv_python"
    if [[ -f "$venv_file" ]]; then
        cat "$venv_file"
    elif [[ -x "${oh_dir}/.venv/bin/python" ]]; then
        echo "${oh_dir}/.venv/bin/python"
    else
        command -v python3.12 2>/dev/null || command -v python3.13 2>/dev/null || command -v python3
    fi
}

# ---------------------------------------------------------------------------
# GPU helpers
# ---------------------------------------------------------------------------
detect_gpu_count() {
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l
    else
        echo 1
    fi
}

resolve_num_gpus() {
    local cfg="${NUM_GPUS:-0}"
    if (( cfg == 0 )); then
        detect_gpu_count
    else
        echo "$cfg"
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

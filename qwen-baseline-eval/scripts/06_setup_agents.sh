#!/usr/bin/env bash
# 06_setup_agents.sh — Install the TerminalBench evaluation harness.
#
# We use Terminus (terminal-bench's own reference agent) in its own uv venv.
# Terminus runs IN THE HOST `tb` process and drives each task container over
# tmux (send_keys / capture_pane), so the LLM HTTP calls are made FROM THE
# HOST to the DashScope endpoint — no docker-bridge gateway IP or iptables
# workaround needed (unlike the old in-container OpenHands agent).
#
# Terminus parses a JSON (terminus-1) or JSON/XML (terminus-2) command batch
# from plain text — it does NOT use the OpenAI tool_calls API, so any
# tool-call parser quirks on the DashScope side don't affect it.
#
# Markers written for downstream steps:
#   results/.tb_python  → terminal-bench venv python (step 9 parsing)
#   results/.tb_bin     → `tb` entry point          (step 9)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 6: Setup TerminalBench (Terminus) ==="

RESULTS_MARKER_DIR="${SCRIPT_DIR}/../results"
mkdir -p "${RESULTS_MARKER_DIR}"

# ---------------------------------------------------------------------------
# Resolve uv and a terminal-bench-compatible Python (>=3.12).
# ---------------------------------------------------------------------------
resolve_uv() {
    local u=""
    [[ -f "${RESULTS_MARKER_DIR}/.uv_bin" ]] && u=$(cat "${RESULTS_MARKER_DIR}/.uv_bin")
    [[ -x "$u" ]] || u=$(command -v uv 2>/dev/null || true)
    [[ -x "$u" ]] || { [[ -x "${HOME}/.local/bin/uv" ]] && u="${HOME}/.local/bin/uv"; }
    [[ -x "$u" ]] || { [[ -x "${HOME}/.cargo/bin/uv" ]] && u="${HOME}/.cargo/bin/uv"; }
    echo "$u"
}
UV=$(resolve_uv)
[[ -x "$UV" ]] || die "uv not found — run 01_setup_env.sh first (it installs uv)."
export PATH="$(dirname "$UV"):${PATH}"
log "uv: $("$UV" --version)"

_minor_of() { "$1" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 0; }

PY312=""
if [[ -f "${RESULTS_MARKER_DIR}/.compat_python" ]]; then
    cand=$(cat "${RESULTS_MARKER_DIR}/.compat_python")
    if [[ -x "$cand" ]]; then
        m=$(_minor_of "$cand")
        (( m == 12 || m == 13 )) && PY312="$cand"
    fi
fi
if [[ -z "$PY312" ]]; then
    for c in python3.12 python3.13; do
        if command -v "$c" &>/dev/null; then PY312=$(command -v "$c"); break; fi
    done
fi
if [[ -z "$PY312" ]]; then
    log "No Python 3.12/3.13 found — fetching one via uv…"
    "$UV" python install 3.12 && PY312=$("$UV" python find 3.12) || true
fi
[[ -x "$PY312" ]] || die "Need Python 3.12/3.13 for Terminus. Run step 1 or: uv python install 3.12"
log "Agent Python: ${PY312} ($("$PY312" --version))"

# ---------------------------------------------------------------------------
# (Re)create the terminal-bench venv and install the harness.
# ---------------------------------------------------------------------------
make_agent_venv() {
    local venv_dir="$1"; shift
    local pyok=0
    if [[ -x "${venv_dir}/bin/python" ]]; then
        local m; m=$(_minor_of "${venv_dir}/bin/python")
        (( m == 12 || m == 13 )) && pyok=1
    fi
    if (( pyok == 0 )); then
        [[ -d "$venv_dir" ]] && { warn "Recreating incompatible venv ${venv_dir}"; rm -rf "$venv_dir"; }
        log "Creating venv ${venv_dir} ($("$PY312" --version))…"
        "$UV" venv "${venv_dir}" --python "${PY312}" --seed
    fi
    log "Installing into ${venv_dir}: $*"
    retry 3 15 "$UV" pip install --python "${venv_dir}/bin/python" "$@"
}

TB_PKG="terminal-bench"
[[ -n "${TB_VERSION:-}" ]] && TB_PKG="terminal-bench==${TB_VERSION}"
make_agent_venv "${TB_VENV_DIR}" "${TB_PKG}"

TB_PY="${TB_VENV_DIR}/bin/python"
TB_BIN="${TB_VENV_DIR}/bin/tb"
[[ -x "$TB_BIN" ]] || die "tb not found at ${TB_BIN} after install."

# Confirm the requested Terminus agent variant is registered in this version.
"$TB_PY" - "$TB_AGENT" <<'PY' || die "Requested TB_AGENT not available in installed terminal-bench."
import sys
from terminal_bench.agents.agent_name import AgentName
want = sys.argv[1]
names = [a.value for a in AgentName]
assert want in names, f"agent '{want}' not in {names}"
print(f"[ok] TB agent '{want}' available")
PY

echo "${TB_PY}"  > "${RESULTS_MARKER_DIR}/.tb_python"
echo "${TB_BIN}" > "${RESULTS_MARKER_DIR}/.tb_bin"
ok "terminal-bench: $("$TB_BIN" --version 2>/dev/null | tr -d '\n' || echo installed) | agent=${TB_AGENT}${TB_PARSER:+ parser=${TB_PARSER}}"

ok "=== Agent setup complete ==="
log "terminal-bench venv: ${TB_VENV_DIR}  (tb / Terminus)"

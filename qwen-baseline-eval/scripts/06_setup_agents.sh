#!/usr/bin/env bash
# 06_setup_agents.sh — Install the Harbor harness (TB-2 / Terminal-Bench 2.0).
#
# Terminal-Bench 2.0 (the `terminal-bench@2.0` dataset) is NOT runnable by the
# `tb` CLI from the `terminal-bench` package — that CLI's registry only knows
# `terminal-bench-core@*`. TB-2 ships under a different harness, **Harbor**:
#
#     pip install harbor
#     harbor run --dataset terminal-bench@2.0 --agent terminus-2 \
#                --model openai/<name> --agent-kwarg api_base=…
#
# Harbor's Terminus-2 agent (`harbor.agents.terminus_2.terminus_2.Terminus2`)
# uses litellm under the hood, runs in the host process, and drives each task
# container via tmux. It accepts model_name / api_base / temperature / parser_name
# kwargs through `--agent-kwarg key=value`. API keys flow through environment
# variables (e.g. `OPENAI_API_KEY`) — Terminus-2 has no api_key constructor
# parameter, so we set the env var on the host (and via `--agent-env` for
# belt-and-suspenders).
#
# Markers written for downstream steps:
#   results/.harbor_python  → harbor venv python (step 9 parsing)
#   results/.harbor_bin     → `harbor` entry point (step 9)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 6: Setup Harbor (TB-2 / Terminus-2) ==="

RESULTS_MARKER_DIR="${SCRIPT_DIR}/../results"
mkdir -p "${RESULTS_MARKER_DIR}"

# ---------------------------------------------------------------------------
# Resolve uv and a harbor-compatible Python (>=3.12).
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
[[ -x "$PY312" ]] || die "Need Python 3.12/3.13 for Harbor. Run step 1 or: uv python install 3.12"
log "Agent Python: ${PY312} ($("$PY312" --version))"

# ---------------------------------------------------------------------------
# (Re)create the harbor venv and install the harness.
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

HARBOR_PKG="harbor"
[[ -n "${HARBOR_VERSION:-}" ]] && HARBOR_PKG="harbor==${HARBOR_VERSION}"
make_agent_venv "${HARBOR_VENV_DIR}" "${HARBOR_PKG}"

HARBOR_PY="${HARBOR_VENV_DIR}/bin/python"
HARBOR_BIN="${HARBOR_VENV_DIR}/bin/harbor"
[[ -x "$HARBOR_BIN" ]] || die "harbor not found at ${HARBOR_BIN} after install."

# Confirm the requested agent is registered in this Harbor version.
"$HARBOR_PY" - "$TB_AGENT" <<'PY' || die "Requested TB_AGENT not available in installed Harbor."
import sys
want = sys.argv[1]
try:
    from harbor.agents.factory import _AGENT_MAP as M
    names = list(M.keys())
except Exception:
    # Older / alternate layouts: try the AgentName enum
    from harbor.agents.factory import AgentName
    names = [a.value for a in AgentName]
assert want in names, f"agent '{want}' not in {names}"
print(f"[ok] Harbor agent '{want}' available")
PY

echo "${HARBOR_PY}"  > "${RESULTS_MARKER_DIR}/.harbor_python"
echo "${HARBOR_BIN}" > "${RESULTS_MARKER_DIR}/.harbor_bin"
# Backwards-compatible aliases so older marker readers don't break.
echo "${HARBOR_PY}"  > "${RESULTS_MARKER_DIR}/.tb_python"
echo "${HARBOR_BIN}" > "${RESULTS_MARKER_DIR}/.tb_bin"
ok "Harbor: $("$HARBOR_BIN" --version 2>/dev/null | tr -d '\n' || echo installed) | agent=${TB_AGENT}${TB_PARSER:+ parser=${TB_PARSER}}"

ok "=== Agent setup complete ==="
log "Harbor venv: ${HARBOR_VENV_DIR}  (harbor / Terminus-2)"

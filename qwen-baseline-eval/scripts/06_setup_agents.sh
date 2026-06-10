#!/usr/bin/env bash
# 06_setup_agents.sh — Install the two evaluation executor agents.
#
# Replaces the old OpenHands + Poetry setup.  We use one best-of-breed,
# text-parsing agent per benchmark, each in its OWN uv venv so their deps never
# collide with each other or with vLLM:
#
#   • SWE-bench    → mini-swe-agent  (pip: mini-swe-agent) + swebench (scoring)
#                    venv: ${SWE_AGENT_VENV_DIR}   (Python 3.12)
#   • TerminalBench→ terminal-bench  (pip: terminal-bench, agent "Terminus")
#                    venv: ${TB_VENV_DIR}          (Python >=3.12)
#
# Neither agent uses the OpenAI function-calling / tool_calls API:
#   - mini-swe-agent parses a fenced ```mswea_bash_command``` block from text
#     (swebench_backticks.yaml config — used by step 10).
#   - Terminus parses a JSON/XML command batch from text.
# So the Qwen2.5-Coder `hermes` tool-call silent-failure does not affect them.
#
# Markers written for downstream steps:
#   results/.swe_agent_python  → mini-swe-agent venv python   (step 10)
#   results/.mini_swe_bin      → `mini-extra` entry point      (step 10)
#   results/.tb_python         → terminal-bench venv python    (step 9 parsing)
#   results/.tb_bin            → `tb` entry point               (step 9)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 6: Setup evaluation agents (mini-swe-agent + Terminus) ==="

RESULTS_MARKER_DIR="${SCRIPT_DIR}/../results"
mkdir -p "${RESULTS_MARKER_DIR}"

# ---------------------------------------------------------------------------
# Resolve uv and a torch/agent-compatible Python 3.12 (reuse step 1's choice).
# Both agents require >=3.10 (terminal-bench needs >=3.12), so 3.12 satisfies
# both.
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

_minor_of() { "$1" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 99; }

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
[[ -x "$PY312" ]] || die "Need Python 3.12/3.13 for the agents. Run step 1 or: uv python install 3.12"
log "Agent Python: ${PY312} ($("$PY312" --version))"

# ---------------------------------------------------------------------------
# Helper: (re)create an isolated venv and pip-install packages into it.
# Recreates the venv only if missing or on the wrong Python minor version.
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

# ---------------------------------------------------------------------------
# 1) mini-swe-agent venv (+ swebench for scoring)
# ---------------------------------------------------------------------------
MINI_PKG="mini-swe-agent"
[[ -n "${MINI_SWE_VERSION:-}" ]] && MINI_PKG="mini-swe-agent==${MINI_SWE_VERSION}"
make_agent_venv "${SWE_AGENT_VENV_DIR}" "${MINI_PKG}" "swebench"

SWE_PY="${SWE_AGENT_VENV_DIR}/bin/python"
MINI_BIN="${SWE_AGENT_VENV_DIR}/bin/mini-extra"
[[ -x "$MINI_BIN" ]] || die "mini-extra not found at ${MINI_BIN} after install."
# Confirm the swebench batch runner and the text-parsing config both exist.
"$SWE_PY" - <<'PY' || die "mini-swe-agent SWE-bench runner / backticks config missing."
import sys
from minisweagent.config import builtin_config_dir
cfg = builtin_config_dir / "benchmarks" / "swebench_backticks.yaml"
import minisweagent.run.benchmarks.swebench  # importable runner
assert cfg.exists(), f"missing {cfg}"
print(f"[ok] swebench_backticks.yaml present: {cfg}")
PY
"$SWE_PY" -c "import swebench" 2>/dev/null \
    && ok "swebench package importable (scoring will work)" \
    || warn "swebench not importable — step 10 scoring may fail"
echo "${SWE_PY}"   > "${RESULTS_MARKER_DIR}/.swe_agent_python"
echo "${MINI_BIN}" > "${RESULTS_MARKER_DIR}/.mini_swe_bin"
ok "mini-swe-agent: $("$MINI_BIN" --version 2>/dev/null | tr -d '\n' || echo installed)"

# ---------------------------------------------------------------------------
# 2) terminal-bench venv (Terminus agent)
# ---------------------------------------------------------------------------
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
log "mini-swe-agent venv: ${SWE_AGENT_VENV_DIR}  (mini-extra + swebench)"
log "terminal-bench venv: ${TB_VENV_DIR}  (tb / Terminus)"

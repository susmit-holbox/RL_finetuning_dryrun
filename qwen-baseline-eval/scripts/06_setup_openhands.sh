#!/usr/bin/env bash
# 06_setup_openhands.sh — Clone and install OpenHands + evaluation dependencies.
#
# OpenHands 0.62.0 requires Python >=3.12,<3.14 and is a POETRY project.  Its
# SWE-bench eval runner (run_infer.sh) calls `poetry run python …`, so we must
# install via Poetry, not a plain pip venv.  SWE-bench eval deps (swebench,
# datasets, …) are in the OPTIONAL poetry group `evaluation`.
#
# Markers written for downstream steps:
#   ${OPENHANDS_DIR}/.venv_python  → poetry venv python (steps 9/10 scoring)
#   results/.poetry_bin            → poetry binary (step 10 uses `poetry run`)
#   results/.tb_bin                → terminal-bench binary (in the eval venv)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 6: Setup OpenHands ==="

# ---------------------------------------------------------------------------
# Find Python 3.12 or 3.13 (OpenHands requires >=3.12,<3.14)
# Priority: the compatible Python step 1 recorded → system 3.12/3.13 → uv.
# ---------------------------------------------------------------------------
_minor_of() { "$1" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 99; }

OH_PYTHON=""

# 1. Reuse what step 1 resolved (it targets 3.12 by default)
if [[ -f "${SCRIPT_DIR}/../results/.compat_python" ]]; then
    cand=$(cat "${SCRIPT_DIR}/../results/.compat_python")
    if [[ -x "$cand" ]]; then
        m=$(_minor_of "$cand")
        if (( m >= 12 && m <= 13 )); then
            OH_PYTHON="$cand"
            log "Reusing step-1 Python for OpenHands: ${OH_PYTHON} ($($cand --version))"
        fi
    fi
fi

# 2. Any system python3.12/3.13
if [[ -z "$OH_PYTHON" ]]; then
    for candidate in python3.12 python3.13; do
        if command -v "$candidate" &>/dev/null; then
            m=$(_minor_of "$(command -v "$candidate")")
            if (( m >= 12 && m <= 13 )); then
                OH_PYTHON=$(command -v "$candidate")
                log "Found compatible Python for OpenHands: ${OH_PYTHON}"
                break
            fi
        fi
    done
fi

# 3. uv-managed Python 3.12
if [[ -z "$OH_PYTHON" ]]; then
    warn "No Python 3.12/3.13 found — fetching one via uv…"
    UV=""
    if [[ -f "${SCRIPT_DIR}/../results/.uv_bin" ]]; then UV=$(cat "${SCRIPT_DIR}/../results/.uv_bin"); fi
    if ! [[ -x "$UV" ]]; then UV=$(command -v uv 2>/dev/null || true); fi
    if ! [[ -x "$UV" ]] && [[ -x "${HOME}/.local/bin/uv" ]]; then UV="${HOME}/.local/bin/uv"; fi
    if ! [[ -x "$UV" ]] && [[ -x "${HOME}/.cargo/bin/uv" ]]; then UV="${HOME}/.cargo/bin/uv"; fi
    if [[ -x "$UV" ]]; then
        "$UV" python install 3.12 && OH_PYTHON=$("$UV" python find 3.12) || true
    fi
    [[ -x "$OH_PYTHON" ]] || die \
        "OpenHands requires Python 3.12/3.13. Could not find or install one.\n  Run step 1 first, or: curl -LsSf https://astral.sh/uv/install.sh | sh && uv python install 3.12"
fi

# ---------------------------------------------------------------------------
# Clone OpenHands (pin to 0.62.0 — last tag with evaluation/)
# ---------------------------------------------------------------------------
OPENHANDS_TAG="0.62.0"

if [[ -d "${OPENHANDS_DIR}/.git" ]]; then
    CURRENT_TAG=$(git -C "${OPENHANDS_DIR}" describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_TAG" == "$OPENHANDS_TAG" ]]; then
        ok "OpenHands ${OPENHANDS_TAG} already at ${OPENHANDS_DIR}"
    else
        log "Existing checkout is '${CURRENT_TAG}', re-cloning to ${OPENHANDS_TAG}…"
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

[[ -f "${OPENHANDS_DIR}/evaluation/benchmarks/swe_bench/run_infer.py" ]] || \
    die "run_infer.py not found — clone of ${OPENHANDS_TAG} may have failed"
ok "run_infer.py and run_infer.sh present"

# ---------------------------------------------------------------------------
# Install OpenHands with POETRY (REQUIRED).
#
# OpenHands 0.62.0 is a Poetry project, and the eval runner
# evaluation/benchmarks/swe_bench/scripts/run_infer.sh invokes the model via
# `poetry run python …`.  A plain pip/venv install is therefore NOT usable by
# the eval harness — we must create a Poetry-managed environment.
#
# The SWE-bench eval dependencies (swebench, datasets, …) live in the OPTIONAL
# Poetry group `evaluation`, so we install with `--with evaluation`.
# ---------------------------------------------------------------------------

# --- Resolve / install poetry (prefer uv tool install) ---
resolve_uv() {
    local u=""
    [[ -f "${SCRIPT_DIR}/../results/.uv_bin" ]] && u=$(cat "${SCRIPT_DIR}/../results/.uv_bin")
    [[ -x "$u" ]] || u=$(command -v uv 2>/dev/null || true)
    [[ -x "$u" ]] || { [[ -x "${HOME}/.local/bin/uv" ]] && u="${HOME}/.local/bin/uv"; }
    [[ -x "$u" ]] || { [[ -x "${HOME}/.cargo/bin/uv" ]] && u="${HOME}/.cargo/bin/uv"; }
    echo "$u"
}

POETRY_BIN=$(command -v poetry 2>/dev/null || true)
[[ -x "$POETRY_BIN" ]] || { [[ -x "${HOME}/.local/bin/poetry" ]] && POETRY_BIN="${HOME}/.local/bin/poetry"; }

if [[ -z "$POETRY_BIN" || ! -x "$POETRY_BIN" ]]; then
    log "Installing Poetry…"
    UV=$(resolve_uv)
    if [[ -x "$UV" ]]; then
        "$UV" tool install poetry 2>&1 | tail -3 || true
    fi
    POETRY_BIN=$(command -v poetry 2>/dev/null || true)
    [[ -x "$POETRY_BIN" ]] || { [[ -x "${HOME}/.local/bin/poetry" ]] && POETRY_BIN="${HOME}/.local/bin/poetry"; }
    # Fallback: official installer
    if [[ -z "$POETRY_BIN" || ! -x "$POETRY_BIN" ]]; then
        curl -sSL https://install.python-poetry.org | "${OH_PYTHON}" - 2>&1 | tail -3 || true
        [[ -x "${HOME}/.local/bin/poetry" ]] && POETRY_BIN="${HOME}/.local/bin/poetry"
    fi
fi
[[ -x "$POETRY_BIN" ]] || die "Could not install Poetry. Install manually: curl -sSL https://install.python-poetry.org | python3 -"
export PATH="$(dirname "$POETRY_BIN"):${PATH}"
ok "Poetry: $("$POETRY_BIN" --version 2>&1)"

# --- Create the Poetry environment with the compatible Python ---
cd "${OPENHANDS_DIR}"
log "Pointing Poetry at ${OH_PYTHON} ($($OH_PYTHON --version))…"
"$POETRY_BIN" env use "${OH_PYTHON}" 2>&1 | tail -2

log "Running 'poetry install --with evaluation' (heavy — several minutes, pulls git deps)…"
retry 3 30 "$POETRY_BIN" install --with evaluation

# --- Resolve the Poetry venv python and record it for steps 9/10 ---
POETRY_VENV_PATH=$("$POETRY_BIN" env info --path 2>/dev/null)
VENV_PYTHON="${POETRY_VENV_PATH}/bin/python"
[[ -x "$VENV_PYTHON" ]] || die "Poetry venv python not found at ${VENV_PYTHON}"
echo "${VENV_PYTHON}"  > "${OPENHANDS_DIR}/.venv_python"
echo "${POETRY_BIN}"   > "${SCRIPT_DIR}/../results/.poetry_bin"
ok "OpenHands installed. Poetry venv python: ${VENV_PYTHON} ($(${VENV_PYTHON} --version))"

# Sanity: confirm swebench (scoring tool, from evaluation group) is importable
if "${VENV_PYTHON}" -c "import swebench" 2>/dev/null; then
    ok "swebench package importable (scoring will work)"
else
    warn "swebench not importable — scoring in step 10 may fail (eval group install incomplete)"
fi

# ---------------------------------------------------------------------------
# Install TerminalBench into the EVAL venv (decoupled from OpenHands' poetry
# env to avoid dependency conflicts).  'tb' orchestrates Docker on the host;
# it does not need to share OpenHands' environment.
# ---------------------------------------------------------------------------
EVAL_PY=$(eval_python)
EVAL_PIP="$(dirname "$EVAL_PY")/pip"
TB_BIN="$(dirname "$EVAL_PY")/tb"
log "Installing terminal-bench into eval venv ($EVAL_PY)…"
retry 3 15 \
    "${EVAL_PIP}" install --quiet \
        "git+https://github.com/harbor-framework/terminal-bench.git" || \
    warn "terminal-bench install failed — will retry at run time"

if [[ -x "$TB_BIN" ]]; then
    echo "${TB_BIN}" > "${SCRIPT_DIR}/../results/.tb_bin"
    ok "terminal-bench installed: $("${TB_BIN}" --version 2>/dev/null || echo 'version unknown')"
else
    warn "'tb' not found in eval venv — step 9 will retry installation"
fi

# ---------------------------------------------------------------------------
# Write OpenHands config.toml
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

mkdir -p "${RESULTS_DIR}/${RUN_TAG}/openhands_workspace"
ok "config.toml written"

ok "=== OpenHands setup complete ==="
log "OpenHands dir:    ${OPENHANDS_DIR}"
log "Poetry binary:    ${POETRY_BIN}"
log "Poetry venv py:   ${VENV_PYTHON}"
log "tb binary:        ${TB_BIN}  (eval venv)"

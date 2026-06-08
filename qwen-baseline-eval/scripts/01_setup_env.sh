#!/usr/bin/env bash
# 01_setup_env.sh — Bootstrap a fresh Ubuntu EC2 GPU instance.
#
# vLLM + PyTorch require Python 3.10–3.13.  Python 3.14+ has no torch wheels.
# This script installs a compatible Python and creates the eval venv with it.
# OpenHands uses a separate python3.12/3.13 venv (step 6).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

# Safety net: config.env may be an older version that predates EVAL_VENV_DIR
EVAL_VENV_DIR="${EVAL_VENV_DIR:-${HOME}/eval_venv}"

log "=== Step 1: Environment setup ==="

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. GPU check
# ---------------------------------------------------------------------------
NVIDIA_SMI=""
for p in nvidia-smi /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi \
          /opt/nvidia/bin/nvidia-smi; do
    if command -v "$p" &>/dev/null || [[ -x "$p" ]]; then
        NVIDIA_SMI=$(command -v "$p" 2>/dev/null || echo "$p")
        break
    fi
done

if [[ -z "$NVIDIA_SMI" ]]; then
    if [[ "${SKIP_GPU_CHECK:-0}" == "1" ]]; then
        warn "nvidia-smi not found — SKIP_GPU_CHECK=1, continuing"
        warn "Install NVIDIA drivers before Step 4: sudo ubuntu-drivers autoinstall && sudo reboot"
    else
        die "$(cat <<'MSG'
nvidia-smi not found. On Ubuntu EC2:

  sudo apt-get update
  sudo apt-get install -y ubuntu-drivers-common
  sudo ubuntu-drivers autoinstall
  sudo reboot

Or skip this check: SKIP_GPU_CHECK=1 bash run.sh
MSG
)"
    fi
else
    log "GPU(s) detected:"
    "$NVIDIA_SMI" --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | \
        while IFS=',' read -r name mem; do log "  • ${name} (${mem})"; done
    ok "$(detect_gpu_count) GPU(s) available"
fi

# ---------------------------------------------------------------------------
# 2. System packages
# ---------------------------------------------------------------------------
log "Installing system packages via apt…"
sudo apt-get update -qq 2>/dev/null

sudo apt-get install -y -qq \
    git curl wget screen htop jq pciutils \
    build-essential libssl-dev libffi-dev \
    ca-certificates gnupg lsb-release \
    python3 python3-venv python3-full \
    2>/dev/null || true

# ---------------------------------------------------------------------------
# 2b. Install Python 3.12 or 3.13 — required for vLLM + PyTorch (no 3.14 wheels)
#
# Try in order:
#   1. Already installed
#   2. Direct apt (Ubuntu 24.04 main/universe repos)
#   3. deadsnakes PPA
#   4. Miniconda with python=3.12 (last resort)
# ---------------------------------------------------------------------------
_find_compat_python() {
    for v in python3.12 python3.13 python3.11 python3.10; do
        command -v "$v" &>/dev/null && { echo "$(command -v "$v")"; return 0; }
    done
    return 1
}

COMPAT_PYTHON=$(_find_compat_python || true)

if [[ -z "$COMPAT_PYTHON" ]]; then
    log "No Python 3.10–3.13 found; system has $(python3 --version). Attempting install…"

    # Attempt 1: direct apt (no PPA needed on some Ubuntu versions)
    for pyver in 3.12 3.13; do
        if sudo apt-get install -y -qq "python${pyver}" "python${pyver}-venv" "python${pyver}-dev" 2>/dev/null; then
            command -v "python${pyver}" &>/dev/null && {
                COMPAT_PYTHON=$(command -v "python${pyver}")
                log "Installed python${pyver} via apt"
                break
            }
        fi
    done
fi

if [[ -z "$COMPAT_PYTHON" ]]; then
    # Attempt 2: deadsnakes PPA
    log "Trying deadsnakes PPA…"
    sudo apt-get install -y -qq software-properties-common 2>/dev/null || true
    sudo add-apt-repository -y ppa:deadsnakes/ppa 2>&1 | tail -3 || true
    sudo apt-get update -qq 2>/dev/null
    for pyver in 3.12 3.13; do
        if sudo apt-get install -y -qq "python${pyver}" "python${pyver}-venv" "python${pyver}-dev" 2>/dev/null; then
            command -v "python${pyver}" &>/dev/null && {
                COMPAT_PYTHON=$(command -v "python${pyver}")
                log "Installed python${pyver} via deadsnakes PPA"
                break
            }
        fi
    done
fi

if [[ -z "$COMPAT_PYTHON" ]]; then
    # Attempt 3: Miniconda
    warn "apt methods failed — installing Miniconda to get Python 3.12"
    CONDA_DIR="${HOME}/miniconda3"
    CONDA_INSTALLER="/tmp/miniconda_install.sh"
    if [[ ! -x "${CONDA_DIR}/bin/conda" ]]; then
        curl -fsSL "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" \
            -o "$CONDA_INSTALLER"
        bash "$CONDA_INSTALLER" -b -p "${CONDA_DIR}"
    fi
    if [[ ! -x "${CONDA_DIR}/envs/eval312/bin/python" ]]; then
        "${CONDA_DIR}/bin/conda" create -n eval312 python=3.12 -y -q
    fi
    COMPAT_PYTHON="${CONDA_DIR}/envs/eval312/bin/python"
fi

if [[ -z "$COMPAT_PYTHON" ]] || [[ ! -x "$COMPAT_PYTHON" ]]; then
    die "Cannot find or install Python 3.10–3.13. PyTorch/vLLM have no wheels for $(python3 --version)."
fi

ok "Compatible Python for vLLM/torch: $($COMPAT_PYTHON --version) at ${COMPAT_PYTHON}"

# ---------------------------------------------------------------------------
# 3. Docker CE
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    log "Installing Docker CE…"
    curl -fsSL https://get.docker.com | sudo sh 2>/dev/null || \
        sudo apt-get install -y -qq docker.io 2>/dev/null || true
fi

sudo systemctl enable docker 2>/dev/null || true
sudo systemctl start  docker 2>/dev/null || \
    sudo service docker start 2>/dev/null || true
sleep 3

if docker info &>/dev/null 2>&1; then
    ok "Docker: $(docker --version)"
else
    warn "Docker not running — steps 7-10 (image pull + eval) will fail."
    warn "Fix: sudo systemctl start docker"
fi

if command -v docker &>/dev/null && ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    warn "Added $USER to docker group — run 'newgrp docker' before docker commands"
fi

# ---------------------------------------------------------------------------
# 4. Create eval venv using the compatible Python (3.12 or 3.13, NOT 3.14+)
#
# PyTorch CUDA wheels exist for cp310-cp313; cp314 is not yet published.
# All vLLM + eval tool installs go into this venv.
# OpenHands uses a SEPARATE venv (step 6).
# ---------------------------------------------------------------------------
log "System Python: $(python3 --version)"
log "Eval venv Python: $($COMPAT_PYTHON --version)"

if [[ ! -x "${EVAL_VENV_DIR}/bin/python" ]]; then
    log "Creating eval venv at ${EVAL_VENV_DIR}…"
    "$COMPAT_PYTHON" -m venv "${EVAL_VENV_DIR}"
    ok "Eval venv created"
else
    EXISTING_VER=$("${EVAL_VENV_DIR}/bin/python" --version 2>&1)
    # If existing venv is Python 3.14, recreate it with compatible Python
    if echo "$EXISTING_VER" | grep -q "3\.14"; then
        warn "Existing eval venv uses Python 3.14 (no torch wheels) — recreating with $($COMPAT_PYTHON --version)"
        rm -rf "${EVAL_VENV_DIR}"
        "$COMPAT_PYTHON" -m venv "${EVAL_VENV_DIR}"
        ok "Eval venv recreated"
    else
        ok "Eval venv already exists: ${EXISTING_VER}"
    fi
fi

"${EVAL_VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --quiet
ok "Venv pip: $(${EVAL_VENV_DIR}/bin/pip --version)"

# Write venv path for downstream scripts
mkdir -p "${SCRIPT_DIR}/../results"
echo "${EVAL_VENV_DIR}/bin/python" > "${SCRIPT_DIR}/../results/.eval_python"
echo "RUN_TAG=${RUN_TAG}" > "${SCRIPT_DIR}/../results/.run_tag"

# ---------------------------------------------------------------------------
# 5. Results directory
# ---------------------------------------------------------------------------
mkdir -p "${RESULTS_DIR}/${RUN_TAG}"
ok "Results dir: ${RESULTS_DIR}/${RUN_TAG}"

ok "=== Environment setup complete ==="
log "Eval venv: ${EVAL_VENV_DIR} ($($COMPAT_PYTHON --version))"
log "Use this Python for all steps: ${EVAL_VENV_DIR}/bin/python"

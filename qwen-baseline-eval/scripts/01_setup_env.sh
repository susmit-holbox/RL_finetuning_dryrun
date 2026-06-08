#!/usr/bin/env bash
# 01_setup_env.sh — Bootstrap a fresh Ubuntu EC2 GPU instance.
#
# PEP 668 note: Ubuntu 24.04 marks the system Python as "externally managed",
# meaning `pip install` on it is blocked.  This script NEVER installs packages
# into the system Python.  Instead it creates a project-level virtual
# environment (EVAL_VENV_DIR) for vLLM + evaluation tools, and a separate
# python3.12 venv for OpenHands (step 6).
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
# 2. System packages — use apt only, never pip on system Python
# ---------------------------------------------------------------------------
log "Installing system packages via apt…"
sudo apt-get update -qq 2>/dev/null

sudo apt-get install -y -qq \
    git curl wget screen htop jq pciutils \
    build-essential libssl-dev libffi-dev \
    ca-certificates gnupg lsb-release \
    python3 python3-venv python3-full \
    2>/dev/null || true

# python3.12 (required by OpenHands; system Python may be 3.14)
if ! command -v python3.12 &>/dev/null; then
    log "Installing python3.12 via apt…"
    if ! apt-cache show python3.12 &>/dev/null 2>&1; then
        sudo apt-get install -y -qq software-properties-common 2>/dev/null || true
        sudo add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
        sudo apt-get update -qq 2>/dev/null
    fi
    sudo apt-get install -y -qq python3.12 python3.12-venv python3.12-dev 2>/dev/null || \
        warn "python3.12 install failed — OpenHands step will try python3.13"
fi
command -v python3.12 &>/dev/null && ok "python3.12: $(python3.12 --version)" || true

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
# 4. Create project eval venv (avoids PEP 668 on system Python)
#
# This venv is used by ALL steps that need Python packages (vLLM, HF tools,
# datasets, boto3).  It uses the system python3 which may be 3.14 — that is
# fine for vLLM (supports 3.10-3.14) and general tools.
#
# OpenHands uses a SEPARATE venv with python3.12 (step 6).
# ---------------------------------------------------------------------------
SYS_PYTHON=$(command -v python3)
log "System Python: $($SYS_PYTHON --version)"

if [[ ! -x "${EVAL_VENV_DIR}/bin/python" ]]; then
    log "Creating eval venv at ${EVAL_VENV_DIR}…"
    "$SYS_PYTHON" -m venv "${EVAL_VENV_DIR}"
    ok "Eval venv created"
else
    ok "Eval venv already exists: $(${EVAL_VENV_DIR}/bin/python --version)"
fi

# Upgrade pip INSIDE the venv (safe — venv pip is isolated from system Python)
"${EVAL_VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --quiet
ok "Venv pip: $(${EVAL_VENV_DIR}/bin/pip --version)"

# Write venv path for downstream scripts
echo "${EVAL_VENV_DIR}/bin/python" > "${SCRIPT_DIR}/../results/.eval_python"

# ---------------------------------------------------------------------------
# 5. Results directory
# ---------------------------------------------------------------------------
mkdir -p "${RESULTS_DIR}/${RUN_TAG}"
ok "Results dir: ${RESULTS_DIR}/${RUN_TAG}"
echo "RUN_TAG=${RUN_TAG}" > "${SCRIPT_DIR}/../results/.run_tag"

ok "=== Environment setup complete ==="
log "Eval venv: ${EVAL_VENV_DIR}"
log "Use this Python for all steps: ${EVAL_VENV_DIR}/bin/python"

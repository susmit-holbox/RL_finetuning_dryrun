#!/usr/bin/env bash
# 01_setup_env.sh — Bootstrap a fresh Ubuntu EC2 GPU instance.
# Installs: system packages, pip, python3.12, Docker CE, CUDA check.
# Safe to re-run — all installs are idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 1: Environment setup ==="

# ---------------------------------------------------------------------------
# 1. GPU / nvidia-smi
# ---------------------------------------------------------------------------
NVIDIA_SMI=""
for p in nvidia-smi /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi \
          /opt/nvidia/bin/nvidia-smi; do
    if [[ -x "$p" ]] || command -v "$p" &>/dev/null; then
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
nvidia-smi not found. To fix on Ubuntu EC2:

  sudo apt-get update
  sudo apt-get install -y ubuntu-drivers-common
  sudo ubuntu-drivers autoinstall
  sudo reboot

After reboot re-run: bash run.sh
To skip this check: SKIP_GPU_CHECK=1 bash run.sh
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
# 2. apt packages — everything needed for this pipeline
# ---------------------------------------------------------------------------
log "Updating apt and installing system packages…"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq

# Core tools
sudo apt-get install -y -qq \
    git curl wget screen htop jq pciutils \
    build-essential libssl-dev libffi-dev \
    ca-certificates gnupg lsb-release \
    2>/dev/null

# Python 3 base + pip (pip is NOT included by default on some Ubuntu images)
sudo apt-get install -y -qq \
    python3 python3-pip python3-venv python3-dev \
    2>/dev/null

# Python 3.12 (required by OpenHands — system python may be 3.14 which OpenHands rejects)
if ! command -v python3.12 &>/dev/null; then
    log "Installing python3.12…"
    # Ubuntu 22.04/24.04: add deadsnakes PPA for python3.12 if not in default repos
    if ! apt-cache show python3.12 &>/dev/null 2>&1; then
        sudo apt-get install -y -qq software-properties-common 2>/dev/null
        sudo add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null
        sudo apt-get update -qq
    fi
    sudo apt-get install -y -qq python3.12 python3.12-venv python3.12-dev 2>/dev/null || \
        warn "python3.12 install failed — OpenHands step will try to fall back to python3.13"
fi
command -v python3.12 &>/dev/null && ok "python3.12: $(python3.12 --version)"

# ---------------------------------------------------------------------------
# 3. Ensure pip works (bootstrap if python3-pip package was unavailable)
# ---------------------------------------------------------------------------
PYTHON=$(command -v python3)
if ! "$PYTHON" -m pip --version &>/dev/null 2>&1; then
    log "pip not found — bootstrapping via get-pip.py…"
    curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
    "$PYTHON" /tmp/get-pip.py --quiet
    rm -f /tmp/get-pip.py
fi
ok "pip: $("$PYTHON" -m pip --version)"

log "Upgrading pip/wheel/setuptools…"
"$PYTHON" -m pip install --upgrade pip wheel setuptools --quiet

# ---------------------------------------------------------------------------
# 4. Docker CE
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    log "Installing Docker CE…"
    # Official Docker install script (handles Ubuntu 22.04 and 24.04)
    curl -fsSL https://get.docker.com | sudo sh 2>/dev/null || {
        # Fallback: distro package
        sudo apt-get install -y -qq docker.io 2>/dev/null || true
    }
fi

# Start + enable Docker
if ! docker info &>/dev/null 2>&1; then
    sudo systemctl enable docker 2>/dev/null || true
    sudo systemctl start  docker 2>/dev/null || \
    sudo service docker start     2>/dev/null || true
    sleep 4
fi

if docker info &>/dev/null 2>&1; then
    ok "Docker: $(docker --version)"
else
    warn "Docker not running after install attempt."
    warn "Run manually: sudo systemctl start docker"
    warn "Steps 1-6 (vLLM, model download, OpenHands) will still proceed."
fi

# Add user to docker group
if command -v docker &>/dev/null && ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    warn "Added $USER to docker group — run 'newgrp docker' or re-login before running Docker commands"
fi

# ---------------------------------------------------------------------------
# 5. Results directory
# ---------------------------------------------------------------------------
mkdir -p "${RESULTS_DIR}/${RUN_TAG}"
ok "Results dir: ${RESULTS_DIR}/${RUN_TAG}"
echo "RUN_TAG=${RUN_TAG}" > "${SCRIPT_DIR}/../results/.run_tag"

ok "=== Environment setup complete ==="

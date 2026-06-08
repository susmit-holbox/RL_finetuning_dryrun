#!/usr/bin/env bash
# 01_setup_env.sh — Verify system requirements, install base packages.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 1: Environment setup ==="

# ---------------------------------------------------------------------------
# CUDA / GPU check
# ---------------------------------------------------------------------------
if ! command -v nvidia-smi &>/dev/null; then
    die "nvidia-smi not found. A CUDA-capable GPU is required for vLLM."
fi
log "GPU(s) detected:"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | while IFS=',' read -r name mem; do
    log "  • ${name} (${mem})"
done
NGPUS=$(detect_gpu_count)
ok "$NGPUS GPU(s) available"

# ---------------------------------------------------------------------------
# Python / pip
# -----------------------------------------------------------Qwen2.5-Coder-14B-Instruct----------------
PYTHON=$(command -v python3 || command -v python || true)
[[ -z "$PYTHON" ]] && die "Python 3 not found"
PY_VER=$($PYTHON --version 2>&1 | awk '{print $2}')
log "Python: $PY_VER at $PYTHON"

# Require Python ≥ 3.10
PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
(( PY_MINOR < 10 )) && die "Python 3.10+ required, found $PY_VER"

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
log "Installing system packages…"
if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        git curl wget screen htop jq \
        build-essential libssl-dev \
        docker.io docker-compose-plugin \
        2>/dev/null || true
elif command -v yum &>/dev/null; then
    sudo yum install -y -q \
        git curl wget screen htop jq \
        gcc gcc-c++ make openssl-devel \
        docker docker-compose-plugin \
        2>/dev/null || true
fi

# Docker running?
if ! docker info &>/dev/null; then
    log "Starting Docker daemon…"
    sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
    sleep 3
fi
docker info &>/dev/null || die "Docker is not running"
ok "Docker is running"

# Add current user to docker group (takes effect in new shell)
if ! groups | grep -q docker; then
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    warn "Added $USER to docker group — you may need to log out/in for docker to work without sudo"
fi

# ---------------------------------------------------------------------------
# pip upgrade + essential Python tools
# ---------------------------------------------------------------------------
log "Upgrading pip + wheel…"
$PYTHON -m pip install --upgrade pip wheel setuptools --quiet

# ---------------------------------------------------------------------------
# Create results directory
# ---------------------------------------------------------------------------
mkdir -p "${RESULTS_DIR}/${RUN_TAG}"
ok "Results will be written to ${RESULTS_DIR}/${RUN_TAG}"

# ---------------------------------------------------------------------------
# Persist the RUN_TAG so later scripts share it
# ---------------------------------------------------------------------------
echo "RUN_TAG=${RUN_TAG}" > "${SCRIPT_DIR}/../results/.run_tag"

ok "=== Environment setup complete ==="

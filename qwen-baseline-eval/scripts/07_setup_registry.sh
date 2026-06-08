#!/usr/bin/env bash
# 07_setup_registry.sh — Start a local Docker registry as a pull-through cache.
#
# Two-tier strategy:
#   Tier 1 (no root needed): Start a registry:2 container that stores
#     images locally.  After each pull, 08_pull_images.py pushes a copy
#     to localhost:LOCAL_REGISTRY_PORT so the next run skips the network.
#
#   Tier 2 (root needed, skipped gracefully if unavailable): Configure
#     /etc/docker/daemon.json to use the local registry as a pull-through
#     mirror so ALL docker pull commands are intercepted automatically.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
load_config

log "=== Step 7: Local Docker registry setup ==="

# ---------------------------------------------------------------------------
# Resolve data directory (no root needed for fallback)
# ---------------------------------------------------------------------------
_parent_dir=$(dirname "${LOCAL_REGISTRY_DATA_DIR}")
if mkdir -p "${LOCAL_REGISTRY_DATA_DIR}" 2>/dev/null; then
    ok "Registry data dir: ${LOCAL_REGISTRY_DATA_DIR}"
else
    LOCAL_REGISTRY_DATA_DIR="${HOME}/.docker-registry-cache"
    warn "Falling back to ${LOCAL_REGISTRY_DATA_DIR}"
    mkdir -p "${LOCAL_REGISTRY_DATA_DIR}"
fi

# ---------------------------------------------------------------------------
# Write registry config alongside the data directory (Docker-Desktop safe,
# avoids /tmp file-sharing restrictions)
# ---------------------------------------------------------------------------
REGISTRY_CFG="${LOCAL_REGISTRY_DATA_DIR}/registry-config.yml"

cat > "${REGISTRY_CFG}" <<REGCFG
version: 0.1
log:
  level: warn
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  cache:
    blobdescriptor: inmemory
  delete:
    enabled: true
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
proxy:
  remoteurl: https://registry-1.docker.io
REGCFG

if [[ -n "${DOCKER_USERNAME:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
    cat >> "${REGISTRY_CFG}" <<AUTHCFG
  username: "${DOCKER_USERNAME}"
  password: "${DOCKER_PASSWORD}"
AUTHCFG
    log "Docker Hub credentials added to registry proxy config"
fi

# ---------------------------------------------------------------------------
# Start registry container (always runs as current user via Docker)
# ---------------------------------------------------------------------------
REGISTRY_CTR="swebench-registry"

if docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_CTR}$"; then
    ok "Registry container '${REGISTRY_CTR}' already running"
else
    docker rm -f "$REGISTRY_CTR" 2>/dev/null || true

    log "Starting local registry on port ${LOCAL_REGISTRY_PORT}…"
    # Port mapping: host:LOCAL_REGISTRY_PORT → container:5000 (registry default)
    docker run -d \
        --name "$REGISTRY_CTR" \
        --restart always \
        -p "${LOCAL_REGISTRY_PORT}:5000" \
        -v "${LOCAL_REGISTRY_DATA_DIR}:/var/lib/registry" \
        -v "${REGISTRY_CFG}:/etc/docker/registry/config.yml:ro" \
        registry:2

    sleep 3
    if docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_CTR}$"; then
        ok "Registry container started"
    else
        warn "Registry container may have failed to start"
        docker logs "$REGISTRY_CTR" 2>&1 | tail -5
    fi
fi

# ---------------------------------------------------------------------------
# Verify registry is reachable
# ---------------------------------------------------------------------------
if curl -sf "http://localhost:${LOCAL_REGISTRY_PORT}/v2/" &>/dev/null; then
    ok "Local registry responding at localhost:${LOCAL_REGISTRY_PORT}"
else
    warn "Registry not responding yet — this is non-fatal; images will still be"
    warn "pulled from ghcr.io/Docker Hub and cached after the first pull."
    exit 0
fi

# ---------------------------------------------------------------------------
# Tier 2: Configure daemon.json mirror (optional, requires root)
# Skip gracefully on dev machines without passwordless sudo.
# On AWS GPU instances with passwordless sudo this will activate automatically.
# ---------------------------------------------------------------------------
DAEMON_JSON="/etc/docker/daemon.json"
MIRROR_URL="http://localhost:${LOCAL_REGISTRY_PORT}"

_has_sudo() { sudo -n true 2>/dev/null; }

if _has_sudo; then
    EXISTING=$(sudo cat "$DAEMON_JSON" 2>/dev/null || echo "{}")

    if echo "$EXISTING" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if '${MIRROR_URL}' in d.get('registry-mirrors', []) else 1)
" 2>/dev/null; then
        ok "Docker daemon already configured with local mirror"
    else
        log "Updating /etc/docker/daemon.json to add pull-through mirror…"
        NEW_CONFIG=$(echo "$EXISTING" | python3 -c "
import json, sys
d = json.load(sys.stdin)
m = d.get('registry-mirrors', [])
if '${MIRROR_URL}' not in m: m.append('${MIRROR_URL}')
d['registry-mirrors'] = m
i = d.get('insecure-registries', [])
if 'localhost:${LOCAL_REGISTRY_PORT}' not in i: i.append('localhost:${LOCAL_REGISTRY_PORT}')
d['insecure-registries'] = i
d['live-restore'] = True
print(json.dumps(d, indent=2))
")
        echo "$NEW_CONFIG" | sudo tee "$DAEMON_JSON" > /dev/null
        log "Restarting Docker daemon (live-restore keeps running containers safe)…"
        sudo systemctl restart docker 2>/dev/null || \
            sudo service docker restart 2>/dev/null || \
            warn "Could not restart Docker automatically — run: sudo systemctl restart docker"
        sleep 5
        # Restart registry (daemon restart stopped it)
        docker start "$REGISTRY_CTR" 2>/dev/null || true
        ok "Pull-through mirror configured in daemon.json"
    fi
else
    warn "No passwordless sudo — skipping daemon.json mirror configuration"
    warn "The registry will still cache images pushed to it by 08_pull_images.py"
    warn "On your GPU instance (with sudo), this step will activate the full mirror"
fi

ok "=== Registry setup complete ==="
log "Local registry: localhost:${LOCAL_REGISTRY_PORT}"
log "Data stored at: ${LOCAL_REGISTRY_DATA_DIR}"

#!/bin/bash
set -euo pipefail

RUNTIME_USER="${RUNTIME_USER:-claw}"

ensure_dir_owned() {
  local dir="$1"
  sudo -n mkdir -p "$dir"
  sudo -n chown -R "$RUNTIME_USER:$RUNTIME_USER" "$dir"
}

# Railway volume may mount /data as root-owned. Normalize required paths only.
ensure_dir_owned /data/.openclaw
ensure_dir_owned /data/workspace
ensure_dir_owned /data/tailscale
ensure_dir_owned /data/npm
ensure_dir_owned /data/npm-cache
ensure_dir_owned /data/pnpm
ensure_dir_owned /data/pnpm-store

# Ensure Tailscale state directory exists (persisted on Railway volume)
sudo -n mkdir -p /data/tailscale

# Start tailscaled in userspace networking mode (no TUN device needed in containers)
# - SOCKS5 proxy on localhost:1055 for apps that support SOCKS
# - HTTP proxy on localhost:1056 for apps that use HTTP_PROXY/HTTPS_PROXY
sudo -n tailscaled --tun=userspace-networking \
  --socks5-server=localhost:1055 \
  --outbound-http-proxy-listen=localhost:1056 \
  --state=/data/tailscale/state &

# Wait for tailscaled to be ready
sleep 2

# Connect to Tailscale if auth key is provided
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    echo "[tailscale] Connecting with auth key..."
    sudo -n tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh --hostname="${TAILSCALE_HOSTNAME:-railway-openclaw}"
    echo "[tailscale] Connected. SSH enabled."

    # Make proxy vars available to interactive shells (railway ssh)
    # Create a sourceable script in /usr/local/bin and source it from bashrc
    if [ ! -f /usr/local/bin/tailscale-proxy-env ]; then
        sudo -n tee /usr/local/bin/tailscale-proxy-env > /dev/null <<'EOF'
# Tailscale HTTP proxy for accessing other tailnet nodes
export HTTP_PROXY="http://localhost:1056"
export HTTPS_PROXY="http://localhost:1056"
export NO_PROXY="localhost,127.0.0.1"
EOF
        sudo -n chmod +r /usr/local/bin/tailscale-proxy-env
    fi
else
    echo "[tailscale] TAILSCALE_AUTHKEY not set, skipping Tailscale connection."
fi

# Start the main application
exec node src/server.js

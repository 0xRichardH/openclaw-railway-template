#!/bin/bash
set -e

# Ensure Tailscale state directory exists (persisted on Railway volume)
mkdir -p /data/tailscale

# Start tailscaled in userspace networking mode (no TUN device needed in containers)
# - SOCKS5 proxy on localhost:1055 for apps that support SOCKS
# - HTTP proxy on localhost:1056 for apps that use HTTP_PROXY/HTTPS_PROXY
tailscaled --tun=userspace-networking \
  --socks5-server=localhost:1055 \
  --outbound-http-proxy-listen=localhost:1056 \
  --state=/data/tailscale/state &

# Wait for tailscaled to be ready
sleep 2

# Connect to Tailscale if auth key is provided
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo "[tailscale] Connecting with auth key..."
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh --hostname="${TAILSCALE_HOSTNAME:-railway-openclaw}"
    echo "[tailscale] Connected. SSH enabled."
    
    # Export proxy environment variables so child processes can reach other Tailscale nodes
    export HTTP_PROXY="http://localhost:1056"
    export HTTPS_PROXY="http://localhost:1056"
    export NO_PROXY="localhost,127.0.0.1"
    echo "[tailscale] HTTP proxy available at localhost:1056"
else
    echo "[tailscale] TAILSCALE_AUTHKEY not set, skipping Tailscale connection."
fi

# Start the main application
exec node src/server.js

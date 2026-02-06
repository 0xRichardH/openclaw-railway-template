#!/bin/bash
set -e

# Ensure Tailscale state directory exists (persisted on Railway volume)
mkdir -p /data/tailscale

# Start tailscaled in userspace networking mode (no TUN device needed in containers)
tailscaled --tun=userspace-networking --socks5-server=localhost:1055 --state=/data/tailscale/state &

# Wait for tailscaled to be ready
sleep 2

# Connect to Tailscale if auth key is provided
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo "[tailscale] Connecting with auth key..."
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh --hostname="${TAILSCALE_HOSTNAME:-railway-openclaw}"
    echo "[tailscale] Connected. SSH enabled."
else
    echo "[tailscale] TAILSCALE_AUTHKEY not set, skipping Tailscale connection."
fi

# Start the main application
exec node src/server.js

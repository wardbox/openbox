#!/bin/bash
set -e

# Create state directories with restricted permissions
mkdir -p /data/tailscale /data/credentials
chmod 700 /data /data/credentials

# Copy default config if none exists
if [ ! -f /data/openclaw.json ]; then
  cp /openclaw.json /data/openclaw.json
  echo "Copied default openclaw.json to /data/"
fi

# Lock down config file permissions
chmod 600 /data/openclaw.json

# Start tailscaled in userspace networking mode (no /dev/net/tun on Fly.io)
tailscaled --state=/data/tailscale/tailscaled.state \
           --socket=/var/run/tailscale/tailscaled.sock \
           --tun=userspace-networking &

# Wait for tailscaled socket
sleep 2

# Authenticate with Tailscale
tailscale up --authkey="${TAILSCALE_AUTHKEY}" \
             --hostname="${FLY_APP_NAME:-openclaw}"

# Get Tailscale IP for logging
TAILSCALE_IP=$(tailscale ip -4)
echo "============================================"
echo "OpenClaw accessible at http://${TAILSCALE_IP}:3000"
echo "MagicDNS: http://${FLY_APP_NAME:-openclaw}:3000"
echo "============================================"
echo "NOTE: Tailscale Serve (HTTPS) is not supported with"
echo "      userspace networking. Using HTTP + token auth."
echo "============================================"

# Graceful shutdown
trap 'tailscale logout; kill $(jobs -p); exit 0' SIGTERM SIGINT

# --bind lan: listens on all interfaces, reachable via Tailscale IP
# Tailscale Serve (HTTPS) requires kernel networking (/dev/net/tun),
# which is unavailable on Fly.io — so we use HTTP + token auth.
# controlUi.allowInsecureAuth: true in openclaw.json bypasses the
# secure-context check. Security is enforced by Tailscale (no public IPs).
exec openclaw gateway \
  --allow-unconfigured \
  --port 3000 \
  --bind lan

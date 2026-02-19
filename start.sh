#!/bin/bash
set -e

# Persist ~/.openclaw to volume so config/approvals survive redeploys
mkdir -p /data/.openclaw
if [ ! -L "${HOME}/.openclaw" ]; then
  [ -d "${HOME}/.openclaw" ] && cp -rn "${HOME}/.openclaw/." /data/.openclaw/ 2>/dev/null || true
  rm -rf "${HOME}/.openclaw"
  ln -s /data/.openclaw "${HOME}/.openclaw"
fi

# Create state directory
mkdir -p /data/credentials

# Copy default config if none exists
if [ ! -f /data/openclaw.json ]; then
  cp /openclaw.json /data/openclaw.json
  echo "Copied default openclaw.json to /data/"
fi

# Start tailscaled in userspace networking mode (no /dev/net/tun on Fly.io)
tailscaled --state=mem: \
           --socket=/var/run/tailscale/tailscaled.sock \
           --tun=userspace-networking &

# Wait for tailscaled socket to be ready
TAILSCALED_SOCK="/var/run/tailscale/tailscaled.sock"
TS_WAIT=0
TS_TIMEOUT=30
until [ -S "$TAILSCALED_SOCK" ]; do
  if [ "$TS_WAIT" -ge "$TS_TIMEOUT" ]; then
    echo "ERROR: tailscaled socket not available after ${TS_TIMEOUT}s" >&2
    exit 1
  fi
  sleep 1
  TS_WAIT=$((TS_WAIT + 1))
done

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

# Start gateway in background
openclaw gateway \
  --allow-unconfigured \
  --port 3000 \
  --bind lan &
GATEWAY_PID=$!

# Wait for gateway to be ready
echo "Waiting for gateway..."
until curl -sf http://127.0.0.1:3000/health > /dev/null 2>&1; do
  sleep 1
done
echo "Gateway ready."

# Start headless node host
openclaw node run \
  --host 127.0.0.1 \
  --port 3000 \
  --display-name "fly-node" &
NODE_PID=$!

echo "Headless node started (PID $NODE_PID) — approve pairing in Control UI"

# Graceful shutdown
trap 'tailscale logout; kill $GATEWAY_PID $NODE_PID 2>/dev/null; exit 0' SIGTERM SIGINT

# Block until gateway exits
wait $GATEWAY_PID

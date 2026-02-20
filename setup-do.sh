#!/bin/bash
set -e

# ──────────────────────────────────────────────
# OpenClaw on DigitalOcean + Tailscale
# ──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USE_GUM=false
if command -v gum &>/dev/null; then
  USE_GUM=true
fi

# ── Helpers ───────────────────────────────────

header() {
  echo ""
  if $USE_GUM; then
    gum style \
      --border double \
      --border-foreground 212 \
      --padding "1 3" \
      --margin "0 0" \
      --bold \
      "$@"
  else
    echo "┌──────────────────────────────────────────┐"
    for line in "$@"; do
      printf "│ %-40s │\n" "$line"
    done
    echo "└──────────────────────────────────────────┘"
  fi
  echo ""
}

section() {
  echo ""
  if $USE_GUM; then
    gum style --foreground 212 --bold "── $1 ──"
  else
    echo "── $1 ──"
  fi
  echo ""
}

info() {
  if $USE_GUM; then
    gum log --level info "$1"
  else
    echo "→ $1"
  fi
}

success() {
  if $USE_GUM; then
    gum log --level info --prefix "✓" --prefix.foreground 78 "$1"
  else
    echo "✓ $1"
  fi
}

warn() {
  if $USE_GUM; then
    gum log --level warn "$1"
  else
    echo "! $1"
  fi
}

error() {
  if $USE_GUM; then
    gum log --level error "$1"
  else
    echo "✗ $1" >&2
  fi
}

markdown() {
  if $USE_GUM; then
    echo "$1" | gum format
  else
    echo "$1" | sed 's/\*\*//g; s/`//g'
  fi
}

prompt_input() {
  local label="$1" default="$2"
  if $USE_GUM; then
    gum input --placeholder "$default" --header "$label" --header.foreground 117 --width 60 --cursor.foreground 212
  else
    local value
    read -rp "$label [$default]: " value
    echo "${value:-$default}"
  fi
}

prompt_secret() {
  local label="$1"
  if $USE_GUM; then
    gum input --password --header "$label" --header.foreground 117 --width 60 --cursor.foreground 212
  else
    local value
    read -rsp "$label: " value
    echo ""
    echo "$value"
  fi
}

prompt_choose() {
  local label="$1"
  shift
  if $USE_GUM; then
    gum choose --header "$label" --header.foreground 117 --cursor.foreground 212 --selected.foreground 78 "$@"
  else
    echo "$label"
    local i=1
    for opt in "$@"; do
      echo "  $i) $opt"
      ((i++))
    done
    local choice
    read -rp "Choice [1]: " choice
    choice=${choice:-1}
    local j=1
    for opt in "$@"; do
      if [ "$j" -eq "$choice" ]; then
        echo "$opt"
        return
      fi
      ((j++))
    done
    echo "$1"
  fi
}

prompt_filter() {
  local label="$1"
  shift
  if $USE_GUM; then
    printf '%s\n' "$@" | gum filter --header "$label" --header.foreground 117 \
      --indicator.foreground 212 --match.foreground 78 --placeholder "Type to search..."
  else
    prompt_choose "$label" "$@"
  fi
}

confirm() {
  if $USE_GUM; then
    gum confirm --affirmative "Yes" --negative "No" --prompt.foreground 117 "$1"
  else
    local answer
    read -rp "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy] ]]
  fi
}

spin() {
  local title="$1"
  shift
  if $USE_GUM; then
    gum spin --spinner dot --spinner.foreground 212 --title "$title" --show-error -- "$@"
  else
    echo "$title..." >&2
    "$@"
  fi
}

# ── SSH helpers ───────────────────────────────

SSH_KEY_PATH=""
DROPLET_IP=""

ssh_opts() {
  echo -n "-i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
}

remote() {
  ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "root@${DROPLET_IP}" "$@"
}

# ── Preflight ─────────────────────────────────

preflight() {
  for cmd in doctl jq ssh-keygen openssl; do
    if ! command -v "$cmd" &>/dev/null; then
      case "$cmd" in
        doctl)    error "doctl not found. Install: https://docs.digitalocean.com/reference/doctl/how-to/install/" ;;
        jq)       error "jq not found. Install: brew install jq" ;;
        openssl)  error "openssl not found. Install: brew install openssl" ;;
        *)        error "$cmd not found." ;;
      esac
      exit 1
    fi
  done

  if ! doctl account get &>/dev/null 2>&1; then
    error "Not logged in to DigitalOcean. Run: doctl auth init"
    exit 1
  fi
}

# ══════════════════════════════════════════════
# DEPLOY
# ══════════════════════════════════════════════

do_deploy() {
  header "Deploy OpenClaw" "DigitalOcean + Tailscale · Private Deployment"

  CURRENT_USER=$(doctl account get --format Email --no-header 2>/dev/null)
  success "Logged in as: $CURRENT_USER"

  # ── Configuration
  section "Configuration"

  APP_NAME=$(prompt_input "Droplet name" "openclaw")
  APP_NAME=${APP_NAME:-openclaw}

  REGION=$(prompt_filter "Select a region" \
    "nyc1 — New York 1" \
    "nyc3 — New York 3" \
    "sfo3 — San Francisco 3" \
    "ams3 — Amsterdam" \
    "sgp1 — Singapore" \
    "lon1 — London, UK" \
    "fra1 — Frankfurt, Germany" \
    "tor1 — Toronto, Canada" \
    "blr1 — Bangalore, India" \
    "syd1 — Sydney, Australia")
  REGION_CODE=$(echo "$REGION" | cut -d' ' -f1)

  SIZE_CHOICE=$(prompt_choose "Droplet size" \
    "s-1vcpu-2gb  (~\$12/mo — 1 vCPU, 2 GB RAM)" \
    "s-2vcpu-2gb  (~\$18/mo — 2 vCPU, 2 GB RAM)" \
    "s-2vcpu-4gb  (~\$24/mo — 2 vCPU, 4 GB RAM)")
  SIZE_CODE=$(echo "$SIZE_CHOICE" | awk '{print $1}')

  # ── SSH Key
  section "SSH Key"

  SSH_KEY_PATH="${HOME}/.ssh/openclaw_${APP_NAME}_ed25519"
  if [ ! -f "$SSH_KEY_PATH" ]; then
    info "Generating SSH key for this deployment..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "openclaw-${APP_NAME}" -q
    success "Key created: $SSH_KEY_PATH"
  else
    success "Using existing key: $SSH_KEY_PATH"
  fi

  # Upload to DO if not already there
  FINGERPRINT=$(ssh-keygen -lf "${SSH_KEY_PATH}.pub" -E md5 | awk '{print $2}' | sed 's/MD5://')
  KEY_ID=$(doctl compute ssh-key list --format ID,Fingerprint --no-header 2>/dev/null \
    | awk -v fp="$FINGERPRINT" '$2==fp{print $1}' | head -1)
  if [ -z "$KEY_ID" ]; then
    KEY_ID=$(doctl compute ssh-key import "openclaw-${APP_NAME}" \
      --public-key-file "${SSH_KEY_PATH}.pub" --format ID --no-header)
    success "SSH key uploaded to DigitalOcean"
  else
    success "SSH key already in DigitalOcean (ID: $KEY_ID)"
  fi

  # ── Tailscale
  section "Tailscale"

  TAILSCALE_AUTHKEY=""
  markdown "Generate a key at **https://login.tailscale.com/admin/settings/keys**
Enable \`Reusable\` and \`Ephemeral\` when creating the key."
  echo ""
  TAILSCALE_AUTHKEY=$(prompt_secret "Tailscale auth key")
  if [ -z "$TAILSCALE_AUTHKEY" ]; then
    error "Tailscale auth key is required."
    exit 1
  fi
  success "Tailscale key set"

  # ── AI Provider
  section "AI Provider"

  ANTHROPIC_API_KEY=""
  OPENAI_API_KEY=""

  PROVIDER=$(prompt_choose "Which provider?" \
    "Anthropic" "OpenAI" "Both" "Skip (set later)")

  if [[ "$PROVIDER" == "Anthropic" || "$PROVIDER" == "Both" ]]; then
    ANTHROPIC_API_KEY=$(prompt_secret "Anthropic API key")
    [ -n "$ANTHROPIC_API_KEY" ] && success "Anthropic key set"
  fi

  if [[ "$PROVIDER" == "OpenAI" || "$PROVIDER" == "Both" ]]; then
    OPENAI_API_KEY=$(prompt_secret "OpenAI API key")
    [ -n "$OPENAI_API_KEY" ] && success "OpenAI key set"
  fi

  # ── Channels
  section "Channels"

  DISCORD_BOT_TOKEN=""
  TELEGRAM_BOT_TOKEN=""

  if confirm "Set up Discord bot?"; then
    echo ""
    markdown "### Discord Bot Setup

1. Go to **https://discord.com/developers/applications**
2. **New Application** → name it → go to **Bot** tab
3. Enable intents: \`Message Content\`, \`Server Members\`
4. **Reset Token** → copy it
5. **OAuth2** → scopes: \`bot\` + \`applications.commands\`
6. Bot Permissions: View Channels, Send/Read Messages, Embed Links, Attach Files
7. Copy generated URL → open it → add bot to server"
    echo ""
    DISCORD_BOT_TOKEN=$(prompt_secret "Discord bot token")
    [ -n "$DISCORD_BOT_TOKEN" ] && success "Discord token set"
  fi

  echo ""
  if confirm "Set up Telegram bot?"; then
    echo ""
    markdown "### Telegram Bot Setup

1. Open Telegram → message **@BotFather**
2. Send \`/newbot\` → follow prompts → copy token
3. Send \`/setprivacy\` → **Disable**
4. Send \`/setjoingroups\` → **Allow**"
    echo ""
    TELEGRAM_BOT_TOKEN=$(prompt_secret "Telegram bot token")
    [ -n "$TELEGRAM_BOT_TOKEN" ] && success "Telegram token set"
  fi

  GATEWAY_TOKEN=$(openssl rand -hex 32)
  success "Generated gateway token"

  # ── Summary
  section "Summary"

  if $USE_GUM; then
    MD_TABLE="| Setting | Value |\n| --- | --- |\n"
    MD_TABLE+="| Droplet | $APP_NAME |\n"
    MD_TABLE+="| Region | $REGION_CODE |\n"
    MD_TABLE+="| Size | $SIZE_CODE |\n"
    MD_TABLE+="| Tailscale | configured |\n"
    if [ -n "$ANTHROPIC_API_KEY" ]; then MD_TABLE+="| Anthropic | configured |\n"; fi
    if [ -n "$OPENAI_API_KEY" ]; then MD_TABLE+="| OpenAI | configured |\n"; fi
    if [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$OPENAI_API_KEY" ]; then MD_TABLE+="| AI Provider | *set later* |\n"; fi
    if [ -n "$DISCORD_BOT_TOKEN" ]; then MD_TABLE+="| Discord | configured |\n"; fi
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then MD_TABLE+="| Telegram | configured |\n"; fi
    MD_TABLE+="| Gateway Auth | auto-generated |\n"
    MD_TABLE+="| Est. Cost | ~\$12/mo |"
    echo -e "$MD_TABLE" | gum format
  else
    info "Droplet:      $APP_NAME"
    info "Region:       $REGION_CODE"
    info "Size:         $SIZE_CODE"
    info "Tailscale:    configured"
    if [ -n "$ANTHROPIC_API_KEY" ]; then info "Anthropic:    configured"; fi
    if [ -n "$OPENAI_API_KEY" ]; then info "OpenAI:       configured"; fi
    if [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$OPENAI_API_KEY" ]; then info "AI provider:  — (set later)"; fi
    if [ -n "$DISCORD_BOT_TOKEN" ]; then info "Discord:      configured"; fi
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then info "Telegram:     configured"; fi
    info "Gateway auth: auto-generated"
    info "Est. cost:    ~\$12/mo"
  fi

  echo ""
  if ! confirm "Ready to deploy?"; then
    info "Aborted. Re-run ./setup-do.sh anytime."
    exit 0
  fi

  # ── Create Droplet
  section "Deploying"

  # Check for existing droplet
  DROPLET_ID=$(doctl compute droplet list --format ID,Name --no-header 2>/dev/null \
    | awk -v n="$APP_NAME" '$2==n{print $1}' | head -1)

  if [ -z "$DROPLET_ID" ]; then
    info "Creating droplet (this takes about a minute)..."

    # Write cloud-init to temp file
    CLOUD_INIT_FILE=$(mktemp)
    cat > "$CLOUD_INIT_FILE" << 'CLOUDINIT_EOF'
#cloud-config
runcmd:
  # Swap
  - fallocate -l 512M /swapfile
  - chmod 600 /swapfile
  - mkswap /swapfile
  - swapon /swapfile
  - echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
  # Node.js 22
  - curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  - apt-get install -y nodejs
  # pnpm
  - npm install -g pnpm
  # Tailscale
  - curl -fsSL https://tailscale.com/install.sh | sh
  # OpenClaw + Claude CLI
  - npm install -g openclaw @anthropic-ai/claude-code
  # Pre-configure OpenClaw service files, wipe build-time tokens
  - openclaw doctor --repair || true
  - rm -rf /root/.openclaw
  # Data directory
  - mkdir -p /data/credentials /opt/openclaw
  - chmod 700 /data
  # Done sentinel
  - touch /var/lib/cloud/instance/openclaw-ready
CLOUDINIT_EOF

    DROPLET_ID=$(doctl compute droplet create "$APP_NAME" \
      --region "$REGION_CODE" \
      --size "$SIZE_CODE" \
      --image ubuntu-22-04-x64 \
      --ssh-keys "$KEY_ID" \
      --user-data-file "$CLOUD_INIT_FILE" \
      --wait \
      --format ID \
      --no-header 2>/dev/null)
    rm -f "$CLOUD_INIT_FILE"

    success "Droplet created: $DROPLET_ID"
  else
    info "Droplet '$APP_NAME' already exists ($DROPLET_ID) — updating configuration..."
  fi

  # Get public IP
  DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header 2>/dev/null)
  success "IP: $DROPLET_IP"

  # ── Wait for SSH
  info "Waiting for SSH..."
  for i in $(seq 1 36); do
    if ssh -i "$SSH_KEY_PATH" \
          -o StrictHostKeyChecking=no \
          -o ConnectTimeout=5 \
          -o BatchMode=yes \
          "root@${DROPLET_IP}" exit 2>/dev/null; then
      success "SSH ready"
      break
    fi
    if [ "$i" -eq 36 ]; then
      error "SSH not available after 3 minutes. Check DO console."
      exit 1
    fi
    sleep 5
  done

  # ── Wait for cloud-init (installs Node, Tailscale, OpenClaw)
  info "Waiting for packages to install — Node.js, Tailscale, OpenClaw (~3 min)..."
  remote "cloud-init status --wait 2>&1 | tail -1" || true

  if ! remote "[ -f /var/lib/cloud/instance/openclaw-ready ]" 2>/dev/null; then
    error "OpenClaw installation may have failed."
    error "Debug: ssh -i $SSH_KEY_PATH root@$DROPLET_IP 'cloud-init status --long'"
    exit 1
  fi
  success "Packages installed"

  # ── Configure server
  section "Configuring"

  # Write env file
  info "Writing secrets..."
  {
    [ -n "$TAILSCALE_AUTHKEY" ]   && echo "TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY}"
    [ -n "$GATEWAY_TOKEN" ]       && echo "OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}"
    [ -n "$ANTHROPIC_API_KEY" ]   && echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
    [ -n "$OPENAI_API_KEY" ]      && echo "OPENAI_API_KEY=${OPENAI_API_KEY}"
    [ -n "$DISCORD_BOT_TOKEN" ]   && echo "DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}"
    [ -n "$TELEGRAM_BOT_TOKEN" ]  && echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
  } | remote "cat > /data/.env && chmod 600 /data/.env"
  success "Secrets written to /data/.env"

  # Copy seed openclaw.json config
  if [ -f "${SCRIPT_DIR}/openclaw.json" ]; then
    remote "cat > /opt/openclaw/openclaw.json" < "${SCRIPT_DIR}/openclaw.json"
    remote "chmod 640 /opt/openclaw/openclaw.json"
    success "Seed config copied"
  fi

  # Write openclaw start wrapper
  info "Writing service files..."
  remote "cat > /usr/local/bin/openclaw-start && chmod +x /usr/local/bin/openclaw-start" << 'STARTEOF'
#!/bin/bash
set -e
export PATH="/usr/local/bin:/usr/bin:/bin"

# Persist ~/.openclaw to volume so approvals survive restarts
mkdir -p /data/.openclaw
if [ ! -L "${HOME}/.openclaw" ]; then
  [ -d "${HOME}/.openclaw" ] && cp -rn "${HOME}/.openclaw/." /data/.openclaw/ 2>/dev/null || true
  rm -rf "${HOME}/.openclaw"
  ln -s /data/.openclaw "${HOME}/.openclaw"
fi

mkdir -p /data/credentials

# Copy seed config if none exists on volume
if [ ! -f /data/openclaw.json ] && [ -f /opt/openclaw/openclaw.json ]; then
  cp /opt/openclaw/openclaw.json /data/openclaw.json
  chmod 600 /data/openclaw.json
  echo "Copied seed config to /data/openclaw.json"
fi

echo "Starting OpenClaw gateway on :${OPENCLAW_GATEWAY_PORT:-3000}"

# Ensure gateway config is set for clean security audit
openclaw config set gateway.mode local 2>/dev/null || true
if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
  openclaw config set gateway.auth.token "$OPENCLAW_GATEWAY_TOKEN" 2>/dev/null || true
fi

# Install gateway as systemd-managed service for auto-restart
openclaw gateway install 2>/dev/null || true

# Start gateway
openclaw gateway \
  --port "${OPENCLAW_GATEWAY_PORT:-3000}" \
  --bind lan &
GATEWAY_PID=$!

# Wait for gateway to be ready
WAIT=0
until curl -sf "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-3000}/health" > /dev/null 2>&1; do
  WAIT=$((WAIT + 1))
  if [ $WAIT -gt 60 ]; then
    echo "ERROR: gateway failed to start after 60s" >&2
    kill $GATEWAY_PID 2>/dev/null
    exit 1
  fi
  sleep 1
done
echo "Gateway ready."

# Start headless node host
openclaw node run \
  --host 127.0.0.1 \
  --port "${OPENCLAW_GATEWAY_PORT:-3000}" \
  --display-name "${HOSTNAME:-openclaw}" &
NODE_PID=$!

echo "Headless node started — approve pairing in Control UI"

trap 'kill $GATEWAY_PID $NODE_PID 2>/dev/null; exit 0' SIGTERM SIGINT

wait $GATEWAY_PID
STARTEOF

  # Write systemd unit
  remote "cat > /etc/systemd/system/openclaw.service" << 'UNITEOF'
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
EnvironmentFile=-/data/.env
Environment=OPENCLAW_STATE_DIR=/data
Environment=OPENCLAW_CONFIG_PATH=/data/openclaw.json
Environment=OPENCLAW_PREFER_PNPM=1
Environment=OPENCLAW_GATEWAY_PORT=3000
Environment=NODE_OPTIONS=--max-old-space-size=1536
Environment=OPENCLAW_DISABLE_BONJOUR=1
ExecStart=/usr/local/bin/openclaw-start

[Install]
WantedBy=multi-user.target
UNITEOF

  remote "systemctl daemon-reload && systemctl enable openclaw"
  success "Service configured"

  # ── Start Tailscale
  section "Connecting"

  info "Starting Tailscale..."
  remote "tailscale up --authkey='${TAILSCALE_AUTHKEY}' --hostname='${APP_NAME}' --ssh" 2>/dev/null || \
  remote "tailscale up --authkey='${TAILSCALE_AUTHKEY}' --hostname='${APP_NAME}'" 2>/dev/null || true

  TS_IP=$(remote "tailscale ip -4 2>/dev/null" | tr -d '[:space:]' | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' || true)
  if [ -n "$TS_IP" ]; then
    success "Tailscale connected: $TS_IP"
  else
    warn "Tailscale not yet connected — check: ssh -i $SSH_KEY_PATH root@$DROPLET_IP 'tailscale status'"
  fi

  # ── Start OpenClaw
  info "Starting OpenClaw..."
  remote "systemctl start openclaw" 2>/dev/null || true

  info "Waiting for gateway..."
  for i in $(seq 1 24); do
    if remote "curl -sf http://127.0.0.1:3000/health" >/dev/null 2>&1; then
      success "Gateway listening on :3000"
      break
    fi
    if [ "$i" -eq 24 ]; then
      warn "Gateway not yet ready. Check: ssh -i $SSH_KEY_PATH root@$DROPLET_IP 'journalctl -u openclaw -n 50'"
    fi
    sleep 5
  done

  # ── Harden: apply DO Firewall
  section "Hardening"

  info "Applying firewall — blocking all public inbound..."

  # Remove existing firewall for this app if present
  EXISTING_FW=$(doctl compute firewall list --format ID,Name --no-header 2>/dev/null \
    | awk -v n="${APP_NAME}-fw" '$2==n{print $1}' | head -1)
  if [ -n "$EXISTING_FW" ]; then
    doctl compute firewall delete "$EXISTING_FW" --force 2>/dev/null || true
  fi

  FW_ID=$(doctl compute firewall create \
    --name "${APP_NAME}-fw" \
    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,address:0.0.0.0/0,address:::/0" \
    --droplet-ids "$DROPLET_ID" \
    --format ID --no-header 2>/dev/null) || {
    warn "Could not create firewall. Add manually in DO console: https://cloud.digitalocean.com/networking/firewalls"
    FW_ID=""
  }

  if [ -n "$FW_ID" ]; then
    success "Firewall applied — no public inbound access"
  fi

  # ── Verify
  do_verify "$APP_NAME" "$DROPLET_ID" "$TS_IP"

  # ── Done
  header "Deployment complete!"

  GATEWAY_URL="http://${APP_NAME}:3000"

  section "Step 1 — Open your gateway"

  if $USE_GUM; then
    echo "$GATEWAY_URL" | gum style --border rounded --border-foreground 78 --padding "0 2" --bold --foreground 78
  else
    echo "  $GATEWAY_URL"
  fi

  if [ -n "$TS_IP" ]; then
    if $USE_GUM; then
      gum style --faint "Direct IP fallback: http://${TS_IP}:3000"
    else
      echo "  Direct IP fallback: http://${TS_IP}:3000"
    fi
  fi

  echo ""
  if confirm "Open in your browser?"; then
    if command -v open &>/dev/null; then
      open "$GATEWAY_URL" || true
    elif command -v xdg-open &>/dev/null; then
      xdg-open "$GATEWAY_URL" || true
    fi
  fi

  section "Step 2 — Connect with your token"

  if $USE_GUM; then
    gum style --faint "Paste this into the \"Gateway Token\" field, then hit Connect."
    echo ""
    echo "$GATEWAY_TOKEN" | gum style --border rounded --border-foreground 214 --padding "0 2" --bold --foreground 214
  else
    echo "  Paste this into the \"Gateway Token\" field, then hit Connect."
    echo ""
    echo "  $GATEWAY_TOKEN"
  fi

  echo ""
  if confirm "Connected successfully?"; then
    success "You're in!"
  else
    echo ""
    warn "Troubleshooting:"
    if $USE_GUM; then
      markdown "- Make sure your device is connected to **Tailscale**
- Check the service: \`ssh root@${APP_NAME} 'systemctl status openclaw'\`
- Check logs: \`ssh root@${APP_NAME} 'journalctl -u openclaw -n 50'\`
- Verify: \`./setup-do.sh verify\`"
    else
      echo "  - Make sure your device is connected to Tailscale"
      echo "  - Check the service: ssh root@${APP_NAME} 'systemctl status openclaw'"
      echo "  - Check logs: ssh root@${APP_NAME} 'journalctl -u openclaw -n 50'"
      echo "  - Verify: ./setup-do.sh verify"
    fi
  fi

  echo ""
  if $USE_GUM; then
    gum style --faint "Save the token above somewhere safe — it can't be retrieved later."
    gum style --faint "SSH access (via Tailscale): ssh root@${APP_NAME}"
    gum style --faint "Rotate token: ssh root@${APP_NAME} 'openclaw secret set gateway-token \$(openssl rand -hex 32)'"
  else
    echo "  Save the token above somewhere safe — it can't be retrieved later."
    echo "  SSH access (via Tailscale): ssh root@${APP_NAME}"
  fi

  section "Step 3 — Configure via Control UI"

  if $USE_GUM; then
    markdown "Open the **Control UI** in your browser to configure channels, providers, and models."
  else
    echo "  Open the Control UI in your browser to configure channels, providers, and models."
  fi
  echo ""
}

# ══════════════════════════════════════════════
# VERIFY
# ══════════════════════════════════════════════

do_verify() {
  local APP="${1:-}"
  local DROPLET_ID_ARG="${2:-}"
  local TS_IP_HINT="${3:-}"

  if [ -z "$APP" ]; then
    APP=$(prompt_input "Droplet name to verify" "openclaw")
    APP=${APP:-openclaw}
  fi

  if [ -z "$DROPLET_ID_ARG" ]; then
    DROPLET_ID_ARG=$(doctl compute droplet list --format ID,Name --no-header 2>/dev/null \
      | awk -v n="$APP" '$2==n{print $1}' | head -1)
  fi

  header "Verifying: $APP"

  PASSED=0
  FAILED=0
  WARNED=0

  add_result() {
    local check="$1" status="$2" detail="$3"
    if [ "$status" = "pass" ]; then
      PASSED=$((PASSED + 1))
      success "$check: $detail"
    elif [ "$status" = "fail" ]; then
      FAILED=$((FAILED + 1))
      error "$check: $detail"
    elif [ "$status" = "warn" ]; then
      WARNED=$((WARNED + 1))
      warn "$check: $detail"
    fi
  }

  # 1. Droplet exists
  if [ -n "$DROPLET_ID_ARG" ]; then
    add_result "Droplet" "pass" "$APP (ID: $DROPLET_ID_ARG)"
  else
    add_result "Droplet" "fail" "not found"
    return 1
  fi

  # 2. Droplet status
  DROPLET_STATUS=$(doctl compute droplet get "$DROPLET_ID_ARG" --format Status --no-header 2>/dev/null || echo "unknown")
  if [ "$DROPLET_STATUS" = "active" ]; then
    add_result "Droplet status" "pass" "active"
  else
    add_result "Droplet status" "fail" "$DROPLET_STATUS"
  fi

  # Get IP if not already set
  if [ -z "$DROPLET_IP" ]; then
    DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID_ARG" --format PublicIPv4 --no-header 2>/dev/null || echo "")
  fi

  if [ -z "$DROPLET_IP" ]; then
    add_result "Public IP" "fail" "not found"
    return 1
  fi
  add_result "Public IP" "pass" "$DROPLET_IP (blocked by firewall)"

  # 3. Firewall
  FW_CHECK=$(doctl compute firewall list --format Name,DropletIDs --no-header 2>/dev/null \
    | grep "${APP}-fw" | head -1)
  if [ -n "$FW_CHECK" ]; then
    add_result "Firewall" "pass" "${APP}-fw applied"
  else
    add_result "Firewall" "warn" "not found — public access may be open"
  fi

  # 4. SSH reachable (via public IP — will fail once firewall blocks port 22)
  if ssh -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        "root@${DROPLET_IP}" exit 2>/dev/null; then
    SSH_OK=true
    add_result "SSH" "pass" "reachable (public)"
  else
    SSH_OK=false
    add_result "SSH" "warn" "blocked via public IP (use Tailscale SSH)"
  fi

  if $SSH_OK; then
    # 5. Tailscale
    TS_IP=$(remote "tailscale ip -4 2>/dev/null" | tr -d '[:space:]' | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    if [ -n "$TS_IP" ]; then
      add_result "Tailscale" "pass" "$TS_IP"
    elif [ -n "$TS_IP_HINT" ]; then
      TS_IP="$TS_IP_HINT"
      add_result "Tailscale" "pass" "$TS_IP (from deploy)"
    else
      add_result "Tailscale" "fail" "not connected"
    fi

    # 6. OpenClaw service
    SVC_STATUS=$(remote "systemctl is-active openclaw 2>/dev/null" | tr -d '[:space:]' || echo "unknown")
    if [ "$SVC_STATUS" = "active" ]; then
      add_result "OpenClaw service" "pass" "active"
    else
      add_result "OpenClaw service" "fail" "$SVC_STATUS"
    fi

    # 7. Gateway port
    if remote "curl -sf http://127.0.0.1:3000/health" >/dev/null 2>&1; then
      add_result "Gateway port" "pass" "listening on :3000"
    else
      add_result "Gateway port" "fail" "not responding on :3000"
    fi

    # 8. Volume / data dir
    if remote "[ -d /data ] && df /data" >/dev/null 2>&1; then
      add_result "Data directory" "pass" "/data exists"
    else
      add_result "Data directory" "fail" "/data not found"
    fi

    # 9. Config file
    if remote "[ -f /data/openclaw.json ]" 2>/dev/null; then
      add_result "Config file" "pass" "/data/openclaw.json"
    else
      add_result "Config file" "warn" "missing — configure via Control UI"
    fi

    # 10. Config permissions
    PERMS=$(remote "stat -c %a /data/openclaw.json 2>/dev/null" | tr -d '[:space:]' || echo "")
    if [ "$PERMS" = "600" ]; then
      add_result "Config permissions" "pass" "600 (owner-only)"
    elif [ -n "$PERMS" ]; then
      add_result "Config permissions" "warn" "$PERMS (should be 600)"
    fi
  fi

  # Summary
  TOTAL=$((PASSED + FAILED))
  echo ""
  if [ "$FAILED" -eq 0 ]; then
    if $USE_GUM; then
      gum style --foreground 78 --bold "All checks passed ($PASSED/$TOTAL)"
    else
      success "All checks passed ($PASSED/$TOTAL)"
    fi
  else
    if $USE_GUM; then
      gum style --foreground 196 --bold "$FAILED of $TOTAL checks failed"
    else
      error "$FAILED of $TOTAL checks failed"
    fi
  fi
}

# ══════════════════════════════════════════════
# TEARDOWN
# ══════════════════════════════════════════════

do_teardown() {
  local APP="${1:-}"
  if [ -z "$APP" ]; then
    APP=$(prompt_input "Droplet name to destroy" "openclaw")
    APP=${APP:-openclaw}
  fi

  DROPLET_ID=$(doctl compute droplet list --format ID,Name --no-header 2>/dev/null \
    | awk -v n="$APP" '$2==n{print $1}' | head -1)

  if [ -z "$DROPLET_ID" ]; then
    error "Droplet '$APP' not found"
    exit 1
  fi

  header "Teardown: $APP"

  if $USE_GUM; then
    gum style --foreground 196 --bold "This will permanently destroy:"
    echo ""
    markdown "- Droplet: **$APP** (ID: $DROPLET_ID)
- All data on the droplet
- Associated firewall rules
- Tailscale node registration"
  else
    warn "This will permanently destroy:"
    warn "  - Droplet: $APP (ID: $DROPLET_ID)"
    warn "  - All data on the droplet"
    warn "  - Associated firewall rules"
    warn "  - Tailscale node registration"
  fi

  echo ""
  if ! confirm "Destroy '$APP'? This cannot be undone."; then
    info "Aborted."
    exit 0
  fi

  DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header 2>/dev/null || echo "")

  # Tailscale logout
  echo ""
  info "Logging out of Tailscale..."
  if [ -n "$DROPLET_IP" ] && [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
    if ssh -i "$SSH_KEY_PATH" \
          -o StrictHostKeyChecking=no \
          -o ConnectTimeout=5 \
          -o BatchMode=yes \
          "root@${DROPLET_IP}" "tailscale logout" 2>/dev/null; then
      success "Tailscale node logged out"
    else
      warn "Could not reach droplet — remove Tailscale node manually:"
      warn "  https://login.tailscale.com/admin/machines"
    fi
  else
    warn "No SSH key path set — remove Tailscale node manually:"
    warn "  https://login.tailscale.com/admin/machines"
  fi

  # Delete firewall
  info "Removing firewall..."
  FW_ID=$(doctl compute firewall list --format ID,Name --no-header 2>/dev/null \
    | awk -v n="${APP}-fw" '$2==n{print $1}' | head -1)
  if [ -n "$FW_ID" ]; then
    doctl compute firewall delete "$FW_ID" --force 2>/dev/null && success "Firewall removed" || warn "Could not remove firewall"
  else
    info "No firewall found for $APP"
  fi

  # Destroy droplet
  info "Destroying droplet..."
  if doctl compute droplet delete "$DROPLET_ID" --force 2>/dev/null; then
    success "Droplet '$APP' destroyed"
  else
    error "Failed to destroy droplet. Try: doctl compute droplet delete $DROPLET_ID --force"
    exit 1
  fi

  header "Teardown complete"
  info "All resources for '$APP' have been destroyed."
  info "If Tailscale node persists: https://login.tailscale.com/admin/machines"
  info "Run ./setup-do.sh to deploy again."
  echo ""
}

# ══════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════

preflight

if ! $USE_GUM; then
  echo ""
  echo "Tip: install 'gum' for a nicer experience → brew install gum"
  echo ""
fi

# Direct subcommand: ./setup-do.sh deploy|verify|teardown
if [ -n "$1" ]; then
  # For verify/teardown, find the SSH key path if we can
  if [ -n "$2" ]; then
    SSH_KEY_PATH="${HOME}/.ssh/openclaw_${2}_ed25519"
    [ ! -f "$SSH_KEY_PATH" ] && SSH_KEY_PATH=""
  fi

  case "$1" in
    deploy)   do_deploy ;;
    verify)   do_verify "$2" ;;
    teardown) do_teardown "$2" ;;
    *)
      echo "Usage: ./setup-do.sh [deploy|verify|teardown [droplet-name]]"
      exit 1
      ;;
  esac
  exit 0
fi

# Interactive menu
header "OpenClaw" "Private AI Gateway on DigitalOcean + Tailscale"

ACTION=$(prompt_choose "What would you like to do?" \
  "Deploy — set up a new instance" \
  "Verify — check existing deployment" \
  "Teardown — destroy everything")

case "$ACTION" in
  Deploy*)   do_deploy ;;
  Verify*)   do_verify ;;
  Teardown*) do_teardown ;;
esac

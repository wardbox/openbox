#!/bin/bash
set -e

# ──────────────────────────────────────────────
# OpenClaw on Fly.io + Tailscale
# ──────────────────────────────────────────────

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

# Render markdown (gum format) or plain text fallback
markdown() {
  if $USE_GUM; then
    echo "$1" | gum format
  else
    # Strip markdown formatting for plain output
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

# Fuzzy-searchable filter for long lists
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

# Run a command with a spinner (gum) or plain output (no gum)
spin() {
  local title="$1"
  shift
  if $USE_GUM; then
    gum spin --spinner dot --spinner.foreground 212 --title "$title" --show-error -- "$@"
  else
    echo "$title..."
    "$@"
  fi
}

# Run a command with a spinner, capture output
spin_output() {
  local title="$1"
  shift
  if $USE_GUM; then
    gum spin --spinner dot --spinner.foreground 212 --title "$title" --show-output --show-error -- "$@"
  else
    echo "$title..."
    "$@"
  fi
}

# Read values from fly.toml
get_app_name() {
  grep '^app = ' fly.toml 2>/dev/null | sed 's/app = "//; s/"//' || echo ""
}

get_region() {
  grep '^primary_region = ' fly.toml 2>/dev/null | sed 's/primary_region = "//; s/"//' || echo ""
}

# ── Preflight ─────────────────────────────────

preflight() {
  if ! command -v fly &>/dev/null; then
    error "flyctl not found. Install it: https://fly.io/docs/flyctl/install/"
    exit 1
  fi

  if ! fly auth whoami &>/dev/null 2>&1; then
    error "Not logged in to Fly.io. Run: fly auth login"
    exit 1
  fi
}

# ══════════════════════════════════════════════
# DEPLOY
# ══════════════════════════════════════════════

do_deploy() {
  header "Deploy OpenClaw" "Fly.io + Tailscale · Private Deployment"

  CURRENT_USER=$(fly auth whoami 2>/dev/null)
  success "Logged in as: $CURRENT_USER"

  # ── Organization
  section "Organization"

  ORG_JSON=$(spin_output "Fetching orgs" fly orgs list --json) || true
  if [ -z "$ORG_JSON" ] || [ "$ORG_JSON" = "{}" ]; then
    error "No Fly.io orgs found. Create one at https://fly.io/dashboard"
    exit 1
  fi

  ORG_ARRAY=()
  ORG_LABELS=()
  while IFS= read -r line; do
    slug=$(echo "$line" | cut -d'|' -f1)
    name=$(echo "$line" | cut -d'|' -f2)
    ORG_ARRAY+=("$slug")
    ORG_LABELS+=("$slug ($name)")
  done <<< "$(echo "$ORG_JSON" | grep -o '"[^"]*": *"[^"]*"' | sed 's/": */|/; s/"//g')"

  if [ ${#ORG_ARRAY[@]} -eq 0 ]; then
    error "No Fly.io orgs found. Create one at https://fly.io/dashboard"
    exit 1
  fi

  if [ ${#ORG_ARRAY[@]} -eq 1 ]; then
    ORG_NAME="${ORG_ARRAY[0]}"
    success "Using org: ${ORG_LABELS[0]}"
  else
    ORG_SELECTION=$(prompt_choose "Select Fly.io org" "${ORG_LABELS[@]}")
    ORG_NAME=$(echo "$ORG_SELECTION" | cut -d' ' -f1)
  fi

  # ── App name & region
  section "Configuration"

  DEFAULT_APP=$(get_app_name)
  DEFAULT_APP="${DEFAULT_APP:-openclaw}"

  APP_NAME=$(prompt_input "App name" "$DEFAULT_APP")
  APP_NAME=${APP_NAME:-$DEFAULT_APP}

  EXISTING_REGION=$(get_region)
  if [ -n "$EXISTING_REGION" ]; then
    REGION_CODE="$EXISTING_REGION"
    success "Using region: $REGION_CODE (from fly.toml)"
  else
    REGION=$(prompt_filter "Select a region" \
      "iad — Ashburn, Virginia" \
      "ord — Chicago, Illinois" \
      "sjc — San Jose, California" \
      "lax — Los Angeles, California" \
      "sea — Seattle, Washington" \
      "ewr — Secaucus, New Jersey" \
      "dfw — Dallas, Texas" \
      "atl — Atlanta, Georgia" \
      "yul — Montreal, Canada" \
      "yyz — Toronto, Canada" \
      "lhr — London, UK" \
      "ams — Amsterdam, Netherlands" \
      "fra — Frankfurt, Germany" \
      "cdg — Paris, France" \
      "mad — Madrid, Spain" \
      "waw — Warsaw, Poland" \
      "nrt — Tokyo, Japan" \
      "hkg — Hong Kong" \
      "sin — Singapore" \
      "bom — Mumbai, India" \
      "syd — Sydney, Australia" \
      "gru — Sao Paulo, Brazil" \
      "jnb — Johannesburg, South Africa")
    REGION_CODE=$(echo "$REGION" | cut -d' ' -f1)
  fi

  # ── Check for existing secrets (skip prompts for what's already set)
  EXISTING_SECRETS=""
  if fly apps list --json 2>/dev/null | grep -q "\"$APP_NAME\""; then
    info "App '$APP_NAME' already exists — checking existing secrets..."
    EXISTING_SECRETS=$(fly secrets list -a "$APP_NAME" 2>/dev/null || true)
  fi

  has_secret() { echo "$EXISTING_SECRETS" | grep -q "$1"; }

  # ── Tailscale
  section "Tailscale"

  TAILSCALE_AUTHKEY=""
  if has_secret "TAILSCALE_AUTHKEY"; then
    success "Tailscale key already set (keeping existing)"
  else
    markdown "Generate a key at **https://login.tailscale.com/admin/settings/keys**
Enable \`Reusable\` and \`Ephemeral\` when creating the key."
    echo ""
    TAILSCALE_AUTHKEY=$(prompt_secret "Tailscale auth key")

    if [ -z "$TAILSCALE_AUTHKEY" ]; then
      error "Tailscale auth key is required."
      exit 1
    fi
    success "Tailscale key set"
  fi

  # ── AI providers
  section "AI Provider"

  ANTHROPIC_API_KEY=""
  OPENAI_API_KEY=""

  HAS_ANTHROPIC=false && has_secret "ANTHROPIC_API_KEY" && HAS_ANTHROPIC=true
  HAS_OPENAI=false && has_secret "OPENAI_API_KEY" && HAS_OPENAI=true

  if $HAS_ANTHROPIC; then success "Anthropic key already set (keeping existing)"; fi
  if $HAS_OPENAI; then success "OpenAI key already set (keeping existing)"; fi

  if ! $HAS_ANTHROPIC || ! $HAS_OPENAI; then
    CHOICES=()
    if ! $HAS_ANTHROPIC && ! $HAS_OPENAI; then
      CHOICES=("Anthropic" "OpenAI" "Both" "Skip (set later)")
    elif ! $HAS_ANTHROPIC; then
      CHOICES=("Anthropic" "Skip (set later)")
    elif ! $HAS_OPENAI; then
      CHOICES=("OpenAI" "Skip (set later)")
    fi

    if [ ${#CHOICES[@]} -gt 0 ]; then
      PROVIDER=$(prompt_choose "Which provider?" "${CHOICES[@]}")

      if [[ "$PROVIDER" == "Anthropic" || "$PROVIDER" == "Both" ]]; then
        ANTHROPIC_API_KEY=$(prompt_secret "Anthropic API key")
        [ -n "$ANTHROPIC_API_KEY" ] && success "Anthropic key set"
      fi

      if [[ "$PROVIDER" == "OpenAI" || "$PROVIDER" == "Both" ]]; then
        OPENAI_API_KEY=$(prompt_secret "OpenAI API key")
        [ -n "$OPENAI_API_KEY" ] && success "OpenAI key set"
      fi
    fi
  fi

  # ── Channels (optional)
  section "Channels"

  DISCORD_BOT_TOKEN=""
  TELEGRAM_BOT_TOKEN=""

  if has_secret "DISCORD_BOT_TOKEN"; then
    success "Discord token already set (keeping existing)"
  elif confirm "Set up Discord bot?"; then
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
  if has_secret "TELEGRAM_BOT_TOKEN"; then
    success "Telegram token already set (keeping existing)"
  elif confirm "Set up Telegram bot?"; then
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

  # Gateway token — keep existing or generate new
  if has_secret "OPENCLAW_GATEWAY_TOKEN"; then
    info "Gateway token already set."
    if confirm "Rotate it? (generates a new one)"; then
      GATEWAY_TOKEN=$(openssl rand -hex 32)
      success "Generated new gateway token"
    else
      GATEWAY_TOKEN=""
      success "Keeping existing gateway token"
    fi
  else
    GATEWAY_TOKEN=$(openssl rand -hex 32)
    success "Generated gateway token"
  fi

  # ── Summary
  section "Summary"

  # Build summary as markdown table
  MD_TABLE="| Setting | Value |\n"
  MD_TABLE+="| --- | --- |\n"
  MD_TABLE+="| Org | $ORG_NAME |\n"
  MD_TABLE+="| App | $APP_NAME |\n"
  MD_TABLE+="| Region | $REGION_CODE |\n"
  if [ -n "$TAILSCALE_AUTHKEY" ]; then MD_TABLE+="| Tailscale | configured |\n"; else MD_TABLE+="| Tailscale | *already set* |\n"; fi
  if [ -n "$ANTHROPIC_API_KEY" ]; then MD_TABLE+="| Anthropic | configured |\n"
  elif has_secret "ANTHROPIC_API_KEY"; then MD_TABLE+="| Anthropic | *already set* |\n"; fi
  if [ -n "$OPENAI_API_KEY" ]; then MD_TABLE+="| OpenAI | configured |\n"
  elif has_secret "OPENAI_API_KEY"; then MD_TABLE+="| OpenAI | *already set* |\n"; fi
  if [ -z "$ANTHROPIC_API_KEY" ] && ! has_secret "ANTHROPIC_API_KEY" && [ -z "$OPENAI_API_KEY" ] && ! has_secret "OPENAI_API_KEY"; then MD_TABLE+="| AI Provider | *set later* |\n"; fi
  if [ -n "$DISCORD_BOT_TOKEN" ]; then MD_TABLE+="| Discord | configured |\n"
  elif has_secret "DISCORD_BOT_TOKEN"; then MD_TABLE+="| Discord | *already set* |\n"; fi
  if [ -n "$TELEGRAM_BOT_TOKEN" ]; then MD_TABLE+="| Telegram | configured |\n"
  elif has_secret "TELEGRAM_BOT_TOKEN"; then MD_TABLE+="| Telegram | *already set* |\n"; fi
  if [ -n "$GATEWAY_TOKEN" ]; then MD_TABLE+="| Gateway Auth | auto-generated |\n"; else MD_TABLE+="| Gateway Auth | *already set* |\n"; fi
  MD_TABLE+="| VM | shared-cpu-1x, 2 GB RAM |\n"
  MD_TABLE+="| Est. Cost | ~\$5–7/mo (running 24/7) |"

  if $USE_GUM; then
    echo -e "$MD_TABLE" | gum format
    echo ""
    gum style --faint "Fly.io pricing: shared-cpu-1x + 2 GB RAM + 1 GB volume."
    gum style --faint "Stopped machines cost nothing. See https://fly.io/docs/about/pricing/"
  else
    info "Org:          $ORG_NAME"
    info "App:          $APP_NAME"
    info "Region:       $REGION_CODE"
    if [ -n "$TAILSCALE_AUTHKEY" ]; then info "Tailscale:    configured"; else info "Tailscale:    already set"; fi
    if [ -n "$ANTHROPIC_API_KEY" ]; then info "Anthropic:    configured"
    elif has_secret "ANTHROPIC_API_KEY"; then info "Anthropic:    already set"; fi
    if [ -n "$OPENAI_API_KEY" ]; then info "OpenAI:       configured"
    elif has_secret "OPENAI_API_KEY"; then info "OpenAI:       already set"; fi
    if [ -z "$ANTHROPIC_API_KEY" ] && ! has_secret "ANTHROPIC_API_KEY" && [ -z "$OPENAI_API_KEY" ] && ! has_secret "OPENAI_API_KEY"; then info "AI provider:  — (set later)"; fi
    if [ -n "$DISCORD_BOT_TOKEN" ]; then info "Discord:      configured"
    elif has_secret "DISCORD_BOT_TOKEN"; then info "Discord:      already set"; fi
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then info "Telegram:     configured"
    elif has_secret "TELEGRAM_BOT_TOKEN"; then info "Telegram:     already set"; fi
    if [ -n "$GATEWAY_TOKEN" ]; then info "Gateway auth: auto-generated"; else info "Gateway auth: already set"; fi
    info "VM:           shared-cpu-1x, 2 GB RAM"
    info "Est. cost:    ~\$5–7/mo (running 24/7)"
    echo ""
    echo "  Fly.io pricing: shared-cpu-1x + 2 GB RAM + 1 GB volume."
    echo "  Stopped machines cost nothing. See https://fly.io/docs/about/pricing/"
  fi

  echo ""
  if ! confirm "Ready to deploy?"; then
    info "Aborted. Re-run ./setup.sh anytime."
    exit 0
  fi

  # ── Execute
  section "Deploying"

  sed -i.bak "s/^app = .*/app = \"$APP_NAME\"/" fly.toml && rm -f fly.toml.bak
  sed -i.bak "s/^primary_region = .*/primary_region = \"$REGION_CODE\"/" fly.toml && rm -f fly.toml.bak
  success "Updated fly.toml"

  # Create app — run directly to surface errors
  info "Creating app..."
  CREATE_OUT=$(fly apps create "$APP_NAME" --org "$ORG_NAME" --machines 2>&1) || {
    if echo "$CREATE_OUT" | grep -qi "already exists"; then
      info "App already exists, continuing"
    elif fly apps list --json 2>/dev/null | grep -q "\"$APP_NAME\""; then
      info "App already exists, continuing"
    else
      error "Failed to create app '$APP_NAME'"
      error "$CREATE_OUT"
      exit 1
    fi
  }
  success "App ready: $APP_NAME"

  # Create volume
  info "Creating volume..."
  VOL_OUT=$(fly volumes create openclaw_data --region "$REGION_CODE" --size 1 -a "$APP_NAME" -y 2>&1) || {
    if echo "$VOL_OUT" | grep -qi "already"; then
      info "Volume already exists, continuing"
    else
      warn "Volume creation issue: $VOL_OUT"
    fi
  }
  success "Volume ready"

  # Set secrets — only include new/changed values (skip existing ones)
  SECRETS_ARGS=()
  [ -n "$TAILSCALE_AUTHKEY" ] && SECRETS_ARGS+=("TAILSCALE_AUTHKEY=$TAILSCALE_AUTHKEY")
  [ -n "$GATEWAY_TOKEN" ] && SECRETS_ARGS+=("OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN")
  [ -n "$ANTHROPIC_API_KEY" ] && SECRETS_ARGS+=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  [ -n "$OPENAI_API_KEY" ] && SECRETS_ARGS+=("OPENAI_API_KEY=$OPENAI_API_KEY")
  [ -n "$DISCORD_BOT_TOKEN" ] && SECRETS_ARGS+=("DISCORD_BOT_TOKEN=$DISCORD_BOT_TOKEN")
  [ -n "$TELEGRAM_BOT_TOKEN" ] && SECRETS_ARGS+=("TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN")

  if [ ${#SECRETS_ARGS[@]} -gt 0 ]; then
    info "Setting secrets..."
    SECRETS_OUT=$(fly secrets set "${SECRETS_ARGS[@]}" -a "$APP_NAME" 2>&1) || {
      error "Failed to set secrets"
      error "$SECRETS_OUT"
      exit 1
    }
    success "Secrets configured"
  else
    success "All secrets already set — nothing to update"
  fi

  # Deploy
  echo ""
  info "Building and deploying (this takes a few minutes)..."
  fly deploy -a "$APP_NAME" || {
    error "Deploy failed. Check output above for details."
    exit 1
  }
  success "Deployed!"

  # Release public IPs
  section "Hardening"

  info "Checking IPs..."
  IP_JSON=$(fly ips list -a "$APP_NAME" --json 2>&1 || echo "[]")
  RELEASED=0
  echo "$IP_JSON" | \
    grep -o '"Address": *"[^"]*"' | \
    sed 's/.*": *"//; s/"//' | \
    while read -r ip; do
      IP_TYPE=$(echo "$IP_JSON" | grep -A2 "\"$ip\"" | grep -o '"Type": *"[^"]*"' | sed 's/.*": *"//; s/"//')
      if [[ "$IP_TYPE" != "private_v6" ]]; then
        if fly ips release "$ip" -a "$APP_NAME" -y 2>&1; then
          success "Released $ip ($IP_TYPE)"
        else
          warn "Could not release $ip — remove manually: fly ips release $ip -a $APP_NAME"
        fi
      fi
    done

  HAS_PRIVATE=$(echo "$IP_JSON" | grep -c "private_v6" || true)
  if [ "$HAS_PRIVATE" -eq 0 ]; then
    info "Allocating private IPv6..."
    fly ips allocate-v6 --private -a "$APP_NAME" 2>&1 || warn "Could not allocate private IPv6"
  fi
  success "Network hardened — no public access"

  # Wait for Tailscale + gateway to be fully ready
  section "Connecting"

  info "Waiting for Tailscale..."
  TS_IP=""
  for i in 1 2 3 4 5 6; do
    TS_IP=$(fly ssh console -a "$APP_NAME" -C "tailscale ip -4" 2>/dev/null | tr -d '[:space:]' | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    if [ -n "$TS_IP" ]; then
      success "Tailscale connected: $TS_IP"
      break
    fi
    sleep 5
  done

  if [ -z "$TS_IP" ]; then
    warn "Could not verify Tailscale connection. Check: fly logs -a $APP_NAME"
  fi

  # MagicDNS hostname matches the app name (set via --hostname in start.sh)
  # Tailscale Serve (HTTPS) requires kernel networking unavailable on Fly.io,
  # so we use HTTP — access is restricted to Tailscale network only.
  GATEWAY_URL="http://${APP_NAME}:3000"

  # Wait for gateway to start listening (OpenClaw takes ~30-40s to initialize)
  info "Waiting for gateway to start..."
  GW_READY=false
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if fly ssh console -a "$APP_NAME" -C "node -e \"require('http').get('http://localhost:3000',r=>{process.exit(r.statusCode?0:1)}).on('error',()=>process.exit(1))\"" 2>/dev/null; then
      GW_READY=true
      success "Gateway listening on :3000"
      break
    fi
    sleep 5
  done

  if ! $GW_READY; then
    warn "Gateway not yet listening. It may still be starting — check: fly logs -a $APP_NAME"
  fi

  # Run verification
  echo ""
  do_verify "$APP_NAME"

  # ── Interactive walkthrough ──
  header "Deployment complete!"

  # Step 1: Open the URL
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
  # Try to auto-open the URL in the user's default browser
  if confirm "Open in your browser?"; then
    OPENED_BROWSER=false
    if command -v open &>/dev/null; then
      open "$GATEWAY_URL" && OPENED_BROWSER=true
    elif command -v xdg-open &>/dev/null; then
      xdg-open "$GATEWAY_URL" && OPENED_BROWSER=true
    fi
    if $OPENED_BROWSER; then
      success "Opened in browser"
    else
      warn "Couldn't open browser — open the URL above manually."
    fi
  fi

  # Step 2: paste gateway token to connect
  if [ -n "$GATEWAY_TOKEN" ]; then
    section "Step 2 — Connect with your token"

    if $USE_GUM; then
      gum style --faint "Paste the token below into the \"Gateway Token\" field, then hit Connect."
      echo ""
      echo "$GATEWAY_TOKEN" | gum style --border rounded --border-foreground 214 --padding "0 2" --bold --foreground 214
    else
      echo "  Paste this token into the \"Gateway Token\" field, then hit Connect."
      echo ""
      echo "  $GATEWAY_TOKEN"
    fi

    echo ""
    if confirm "Connected successfully?"; then
      echo ""
      success "You're in!"
    else
      echo ""
      warn "Troubleshooting:"
      if $USE_GUM; then
        markdown "- Make sure your device is connected to **Tailscale**
- Check the machine is running: \`fly status -a $APP_NAME\`
- Check logs for errors: \`fly logs -a $APP_NAME\`
- Verify the gateway: \`./setup.sh verify\`"
      else
        echo "  - Make sure your device is connected to Tailscale"
        echo "  - Check the machine is running: fly status -a $APP_NAME"
        echo "  - Check logs for errors: fly logs -a $APP_NAME"
        echo "  - Verify the gateway: ./setup.sh verify"
      fi
    fi

    # Save the token reminder
    echo ""
    if $USE_GUM; then
      gum style --faint "Fly secrets are write-only — save the token somewhere safe."
      gum style --faint "Rotate with: fly secrets set OPENCLAW_GATEWAY_TOKEN=\"\$(openssl rand -hex 32)\" -a $APP_NAME"
    else
      echo "  Fly secrets are write-only — save the token somewhere safe."
      echo "  Rotate with: fly secrets set OPENCLAW_GATEWAY_TOKEN=\"\$(openssl rand -hex 32)\" -a $APP_NAME"
    fi
  else
    info "Gateway token unchanged — use your existing token to connect."
  fi

  # Onboarding — guide to Control UI
  section "Step 3 — Configure via Control UI"

  if $USE_GUM; then
    markdown "Open the **Control UI** in your browser and configure channels, providers, and models from there.

> **Note:** Configure via the web UI — not \`openclaw onboard\` in SSH.
> When you save config, the gateway briefly restarts, which drops SSH sessions.
> The browser reconnects automatically."
  else
    echo "  Open the Control UI in your browser and configure channels, providers, and models."
    echo ""
    echo "  NOTE: Configure via the web UI — not 'openclaw onboard' in SSH."
    echo "  When you save config, the gateway briefly restarts and drops SSH sessions."
    echo "  The browser reconnects automatically."
  fi

  # Done
  section "You're all set"

  if $USE_GUM; then
    STEPS="Your gateway is live at **$GATEWAY_URL**\n\n"
    STEPS+="From the **web UI** you can:\n"
    STEPS+="- **Chat** with your agent directly\n"
    STEPS+="- **Channels** — manage connected services\n"
    STEPS+="- **Config** — edit settings with validation\n"
    STEPS+="- **Logs** — live gateway log viewer\n"
    if [ -n "$DISCORD_BOT_TOKEN" ] || [ -n "$TELEGRAM_BOT_TOKEN" ]; then
      STEPS+="\nTo **pair a channel account**, DM your bot — then approve:\n"
      STEPS+="\`\`\`\nfly ssh console -a $APP_NAME\n"
      [ -n "$DISCORD_BOT_TOKEN" ] && STEPS+="openclaw pairing approve discord <CODE>\n"
      [ -n "$TELEGRAM_BOT_TOKEN" ] && STEPS+="openclaw pairing approve telegram <CODE>\n"
      STEPS+="\`\`\`\n"
    fi
    STEPS+="\n**Run a security audit:**\n"
    STEPS+="\`\`\`\nfly ssh console -a $APP_NAME\nopenclaw security audit\n\`\`\`"
    echo -e "$STEPS" | gum format
  else
    echo "  Your gateway is live at $GATEWAY_URL"
    echo ""
    echo "  From the web UI you can:"
    echo "  - Chat with your agent directly"
    echo "  - Channels — manage connected services"
    echo "  - Config — edit settings with validation"
    echo "  - Logs — live gateway log viewer"
    if [ -n "$DISCORD_BOT_TOKEN" ] || [ -n "$TELEGRAM_BOT_TOKEN" ]; then
      echo ""
      echo "  To pair a channel account, DM your bot — then approve:"
      echo "     fly ssh console -a $APP_NAME"
      [ -n "$DISCORD_BOT_TOKEN" ] && echo "     openclaw pairing approve discord <CODE>"
      [ -n "$TELEGRAM_BOT_TOKEN" ] && echo "     openclaw pairing approve telegram <CODE>"
    fi
    echo ""
    echo "  Run a security audit:"
    echo "     fly ssh console -a $APP_NAME"
    echo "     openclaw security audit"
  fi
  echo ""
}

# ══════════════════════════════════════════════
# VERIFY
# ══════════════════════════════════════════════

do_verify() {
  local APP="${1:-$(get_app_name)}"
  if [ -z "$APP" ]; then
    APP=$(prompt_input "App name to verify" "openclaw")
    APP=${APP:-openclaw}
  fi

  header "Verifying: $APP"

  PASSED=0
  FAILED=0
  WARNED=0

  # Collect results for final markdown table
  MD_RESULTS="| | Check | Detail |\n| --- | --- | --- |\n"

  add_result() {
    local check="$1" status="$2" detail="$3"
    if [ "$status" = "pass" ]; then
      ((PASSED++))
      success "$check: $detail"
      MD_RESULTS+="| ✓ | $check | $detail |\n"
    elif [ "$status" = "fail" ]; then
      ((FAILED++))
      error "$check: $detail"
      MD_RESULTS+="| ✗ | $check | $detail |\n"
    elif [ "$status" = "warn" ]; then
      ((WARNED++))
      warn "$check: $detail"
      MD_RESULTS+="| ! | $check | $detail |\n"
    fi
  }

  run_check() {
    local label="$1" cmd="$2"
    local result
    if $USE_GUM; then
      result=$(gum spin --spinner dot --spinner.foreground 212 --title "$label" --show-output -- bash -c "$cmd" 2>/dev/null) || true
    else
      echo -n "  Checking: $label... "
      result=$(bash -c "$cmd" 2>/dev/null) || true
    fi
    echo "$result"
  }

  # 1. App exists
  APP_CHECK=$(run_check "App exists" "fly apps list --json 2>/dev/null | grep -q '\"$APP\"' && echo yes || echo no")
  if [[ "$APP_CHECK" == *"yes"* ]]; then
    add_result "App exists" "pass" "$APP"
  else
    add_result "App exists" "fail" "not found"
    return 1
  fi

  # 2. Machine is running
  MACHINE_CHECK=$(run_check "Machine status" "fly status -a $APP 2>/dev/null | grep -q started && echo yes || echo no")
  if [[ "$MACHINE_CHECK" == *"yes"* ]]; then
    add_result "Machine running" "pass" "started"
  else
    add_result "Machine running" "fail" "not running"
  fi

  # 3. No public IPs
  IP_CHECK=$(run_check "Public IPs" "fly ips list -a $APP --json 2>/dev/null | grep -c '\"v4\"\|\"shared_v4\"\|\"v6\"' || echo 0")
  PUBLIC_COUNT=$(echo "$IP_CHECK" | grep -o '[0-9]*' | tail -1)
  if [ "${PUBLIC_COUNT:-0}" -eq 0 ]; then
    add_result "Public IPs" "pass" "none (hidden from internet)"
  else
    add_result "Public IPs" "fail" "$PUBLIC_COUNT found — run: fly ips list -a $APP"
  fi

  # 4. Private IPv6
  PRIV_CHECK=$(run_check "Private IPv6" "fly ips list -a $APP --json 2>/dev/null | grep -q private_v6 && echo yes || echo no")
  if [[ "$PRIV_CHECK" == *"yes"* ]]; then
    add_result "Private IPv6" "pass" "allocated"
  else
    add_result "Private IPv6" "warn" "missing — run: fly ips allocate-v6 --private -a $APP"
  fi

  # 5. Tailscale connected
  TS_IP=$(run_check "Tailscale" "fly ssh console -a $APP -C 'tailscale ip -4' 2>/dev/null | tr -d '[:space:]'")
  TS_IP=$(echo "$TS_IP" | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' || true)
  if [ -n "$TS_IP" ]; then
    add_result "Tailscale" "pass" "$TS_IP"
  else
    add_result "Tailscale" "fail" "not connected"
  fi

  # 6. Tailscale state — use simple "tailscale status" (non-JSON) to avoid gum spin mangling large JSON
  TS_STATE_OUT=$(run_check "Tailscale state" "fly ssh console -a $APP -C 'tailscale status 2>&1 | head -1'")
  if echo "$TS_STATE_OUT" | grep -qE '100\.[0-9]'; then
    add_result "Tailscale state" "pass" "Running"
  elif echo "$TS_STATE_OUT" | grep -qi 'stopped\|needslogin\|not running'; then
    add_result "Tailscale state" "fail" "not running"
  else
    # If we already confirmed TS_IP above, trust that
    if [ -n "$TS_IP" ]; then
      add_result "Tailscale state" "pass" "Running"
    else
      add_result "Tailscale state" "fail" "${TS_STATE_OUT:-unknown}"
    fi
  fi

  # 7. Gateway listening
  GW_CHECK=$(run_check "Gateway port" "fly ssh console -a $APP -C \"node -e \\\"require('http').get('http://localhost:3000',r=>{process.exit(r.statusCode?0:1)}).on('error',()=>process.exit(1))\\\"\" 2>/dev/null && echo yes || echo no")
  if [[ "$GW_CHECK" == *"yes"* ]]; then
    add_result "Gateway port" "pass" "listening on :3000"
  else
    add_result "Gateway port" "fail" "not listening on :3000"
  fi

  # 8. Volume mounted
  VOL_CHECK=$(run_check "Volume mount" "fly ssh console -a $APP -C 'df /data' 2>/dev/null | grep -q /data && echo yes || echo no")
  if [[ "$VOL_CHECK" == *"yes"* ]]; then
    add_result "Volume" "pass" "mounted at /data"
  else
    add_result "Volume" "fail" "not mounted at /data"
  fi

  # 9. Config file
  CFG_CHECK=$(run_check "Config file" "fly ssh console -a $APP -C 'test -f /data/openclaw.json && echo yes || echo no' 2>/dev/null | tr -d '[:space:]'")
  if [[ "$CFG_CHECK" == *"yes"* ]]; then
    add_result "Config file" "pass" "/data/openclaw.json"
  else
    add_result "Config file" "warn" "missing — run openclaw onboard"
  fi

  # 10. Config permissions
  PERM_CHECK=$(run_check "Config permissions" "fly ssh console -a $APP -C 'stat -c %a /data/openclaw.json' 2>/dev/null | tr -d '[:space:]'")
  PERMS=$(echo "$PERM_CHECK" | grep -oE '[0-9]{3}' | tail -1 || true)
  if [ "$PERMS" = "600" ]; then
    add_result "Config permissions" "pass" "600 (owner-only)"
  elif [ -n "$PERMS" ]; then
    add_result "Config permissions" "warn" "$PERMS (should be 600)"
  fi

  # Final summary
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

do_sync_config() {
  local APP="${1:-$(get_app_name)}"
  if [ -z "$APP" ]; then
    APP=$(prompt_input "App name" "openclaw")
    APP=${APP:-openclaw}
  fi

  section "Sync Config — $APP"

  if $USE_GUM; then
    markdown "This rebuilds the Docker image with the current \`openclaw.json\` from this repo, removes the stale config from the volume, then restarts the machine so the fresh config is applied."
  else
    echo "  This rebuilds the Docker image with the current openclaw.json from this repo,"
    echo "  removes the stale config from the volume, then restarts the machine."
  fi
  echo ""

  if ! confirm "Continue?"; then
    info "Aborted."
    return
  fi

  info "Removing stale config and lock files from volume..."
  RM_OUT=$(fly ssh console -a "$APP" --command "rm -f /data/openclaw.json /data/openclaw.json.bak /data/gateway.*.lock && echo ok" 2>&1) || {
    error "Could not remove config: $RM_OUT"
    return 1
  }
  success "Config and lock files removed"

  info "Rebuilding image and deploying with current openclaw.json..."
  fly deploy -a "$APP" 2>&1 || {
    error "Deploy failed — check output above"
    return 1
  }
  success "Deployed — fresh seed config applied on boot"

  if $USE_GUM; then
    gum style --faint "Watch it come up: fly logs -a $APP"
  else
    echo "  Watch it come up: fly logs -a $APP"
  fi
}

do_teardown() {
  local APP="${1:-$(get_app_name)}"
  if [ -z "$APP" ]; then
    APP=$(prompt_input "App name to destroy" "openclaw")
    APP=${APP:-openclaw}
  fi

  header "Teardown: $APP"

  # Verify app exists
  if ! fly apps list --json 2>/dev/null | grep -q "\"$APP\""; then
    error "App '$APP' not found"
    exit 1
  fi

  if $USE_GUM; then
    gum style --foreground 196 --bold "This will permanently destroy:"
    echo ""
    markdown "- App: **$APP**
- All volumes and data
- All secrets and IPs
- Tailscale node registration"
  else
    warn "This will permanently destroy:"
    warn "  - App: $APP"
    warn "  - All volumes and data"
    warn "  - All secrets and IPs"
    warn "  - Tailscale node registration"
  fi

  echo ""
  if ! confirm "Destroy '$APP'? This cannot be undone."; then
    info "Aborted."
    exit 0
  fi

  # Tailscale cleanup — run directly, not under gum spin
  echo ""
  info "Logging out of Tailscale..."
  if fly ssh console -a "$APP" -C "tailscale logout" 2>&1; then
    success "Tailscale node logged out"
  else
    warn "Could not log out Tailscale (machine may not be running)"
    warn "Remove the node manually: https://login.tailscale.com/admin/machines"
  fi

  # Destroy app — run directly, not under gum spin
  info "Destroying app..."
  if fly apps destroy "$APP" -y 2>&1; then
    success "App '$APP' destroyed"
  else
    error "Failed to destroy app. Try: fly apps destroy $APP"
    exit 1
  fi

  if $USE_GUM; then
    header "Teardown complete"
    markdown "All resources for **$APP** have been destroyed.

If the Tailscale node still appears in your admin console,
remove it at **https://login.tailscale.com/admin/machines**

Run \`./setup.sh\` to deploy again."
  else
    header "Teardown complete"
    info "All resources for '$APP' have been destroyed."
    info "If Tailscale node persists: https://login.tailscale.com/admin/machines"
    info "Run ./setup.sh to deploy again."
  fi
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

# Allow direct subcommand: ./setup.sh deploy|verify|teardown
if [ -n "$1" ]; then
  case "$1" in
    deploy)      do_deploy ;;
    verify)      do_verify "$2" ;;
    teardown)    do_teardown "$2" ;;
    sync-config) do_sync_config "$2" ;;
    *)
      echo "Usage: ./setup.sh [deploy|verify|sync-config|teardown]"
      exit 1
      ;;
  esac
  exit 0
fi

# Interactive menu
header "OpenClaw" "Private AI Gateway on Fly.io + Tailscale"

ACTION=$(prompt_choose "What would you like to do?" \
  "Deploy — set up a new instance" \
  "Verify — check existing deployment" \
  "Sync Config — push updated seed config to running machine" \
  "Teardown — destroy everything")

case "$ACTION" in
  Deploy*)      do_deploy ;;
  Verify*)      do_verify ;;
  "Sync Config"*) do_sync_config ;;
  Teardown*)    do_teardown ;;
esac

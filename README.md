# OpenClaw on Fly.io + Tailscale

Deploy [OpenClaw](https://github.com/openclaw-ai/openclaw) (self-hosted AI agent gateway) on Fly.io, accessible **only** via your Tailscale network. No public IPs, no public services. Clone, set secrets, deploy.

## Architecture

```text
[Your Devices on Tailscale] --> [Tailscale Mesh] --> [Fly.io Machine (no public IP)]
                                                         |
                                                    [OpenClaw Gateway :3000]
                                                    [Tailscale daemon]
                                                    [Fly Volume /data]
```

- Single Fly.io machine running OpenClaw + Tailscale in one container
- No `[[services]]` in fly.toml = no public HTTP/HTTPS routing
- All public IPs released after deploy
- Only reachable via Tailscale IP (e.g., `http://100.x.y.z:3000`)
- Persistent volume at `/data` for OpenClaw state + Tailscale state

## Prerequisites

- [Fly.io](https://fly.io) account with `flyctl` installed and logged in (`fly auth login`)
- [Tailscale](https://tailscale.com) account with an auth key ([generate one here](https://login.tailscale.com/admin/settings/keys) — use **reusable** + **ephemeral**)
- An AI provider API key (e.g., Anthropic)
- Optional: [gum](https://github.com/charmbracelet/gum) for a nicer setup experience (`brew install gum`)

## Quick Start

```bash
git clone https://github.com/YOUR_USER/openclaw-flyio.git
cd openclaw-flyio
./setup.sh
```

The setup script walks you through everything interactively:

1. **Fly.io org** — picks from your existing orgs (auto-selects if you only have one)
2. **App name & region** — names the deployment and picks the datacenter
3. **Secrets** — Tailscale auth key, API keys, auto-generates a gateway token
4. **Deploy** — builds the image, creates the volume, deploys the machine
5. **IP hardening** — releases public IPs, allocates private-only IPv6

After the script finishes, open the Control UI from any device on your tailnet to complete setup — see [Accessing Your Instance](#accessing-your-instance) and [Configuring Channels & Providers](#configuring-channels--providers).

<details>
<summary>Manual setup (without script)</summary>

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USER/openclaw-flyio.git
cd openclaw-flyio
```

Edit `fly.toml` and set your app name:

```toml
app = "your-app-name"
```

### 2. Create Fly.io resources

```bash
# List your orgs to find the right one
fly orgs list

fly apps create your-app-name --org your-org
fly volumes create openclaw_data --region iad --size 1 -a your-app-name
```

### 3. Set secrets

```bash
fly secrets set \
  TAILSCALE_AUTHKEY="tskey-auth-..." \
  OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)" \
  ANTHROPIC_API_KEY="sk-ant-..." \
  -a your-app-name
```

### 4. Deploy

```bash
fly deploy
```

### 5. Release public IPs

Fly.io allocates public IPs by default. Remove them and allocate a private-only IPv6 so the machine is only reachable via Tailscale:

```bash
fly ips list -a your-app-name
fly ips release <ipv4-address> -a your-app-name
fly ips release <ipv6-address> -a your-app-name
fly ips allocate-v6 --private -a your-app-name
```

Verify only a `private` type IP remains:

```bash
fly ips list -a your-app-name
```

### 6. Configure OpenClaw

Open the Control UI in your browser at `http://your-app-name:3000` from any device on your tailnet. Configure channels, providers, and models from there. Config is written to `/data/openclaw.json` on the persistent volume and survives gateway restarts and redeploys.

> **Do not use `openclaw onboard` in SSH.** When you save config, the gateway briefly restarts to apply changes, which drops SSH sessions mid-wizard. The browser reconnects automatically.

</details>

## Accessing Your Instance

Find the Tailscale IP in the deploy logs:

```bash
fly logs -a your-app-name  # Look for "OpenClaw accessible at http://100.x.y.z:3000"
```

Or check the [Tailscale admin console](https://login.tailscale.com/admin/machines) for your machine.

From any device on your tailnet, open in your browser:

```text
http://100.x.y.z:3000
```

On the overview page, paste your gateway token into the **Gateway Token** field and click **Connect**.

> **Note:** The control UI runs over HTTP (not HTTPS) because Fly.io containers use Tailscale userspace networking, which doesn't support Tailscale Serve. Security is maintained by Tailscale-only access (no public IPs) + token auth. The `controlUi.allowInsecureAuth` setting enables this.

## Configuring Channels & Providers

Configure everything through the **Control UI** in your browser at `http://your-app-name:3000`. Config is written to `/data/openclaw.json` on the persistent volume and survives gateway restarts — the browser reconnects automatically after each save, so configuration always completes safely.

> **Do not use `openclaw onboard` in SSH.** When you save config, the gateway briefly restarts to apply changes. This drops SSH sessions mid-wizard, making it impossible to complete. The browser reconnects automatically after the restart — the CLI does not.

To add channel tokens (Discord, Telegram, etc.), set them as Fly secrets so they're available as environment variables — do not put them in the config file:

```bash
fly secrets set DISCORD_BOT_TOKEN="..." -a your-app-name
```

See `.env.example` for all configurable values.

If you need to edit the config file directly:

```bash
# Write via tee (fly ssh console doesn't support shell redirection)
echo '{"your":"config"}' | fly ssh console -a your-app-name -C "tee /data/openclaw.json"

# Or use sftp
fly sftp shell -a your-app-name
> put /local/path/config.json /data/openclaw.json
```

## Updating OpenClaw

Redeploying rebuilds the Docker image, which installs the latest version of OpenClaw via npm. Use `--no-cache` to ensure you get the latest version (bypasses Docker layer caching):

```bash
fly deploy --no-cache -a your-app-name
```

Your configuration and state on the `/data` volume are preserved across deploys.

After updating, verify the deployment is healthy:

```bash
fly ssh console -a your-app-name
openclaw doctor
openclaw security audit
```

## Security Model

| Layer | Protection |
|-------|-----------|
| Network | No public IPs allocated. No `[[services]]` in fly.toml = no public HTTP routing. Hidden from internet scanners. |
| Access | Tailscale is the **only** network path to the gateway. |
| Transport | HTTP over Tailscale (no public exposure). `controlUi.allowInsecureAuth` enables token-only auth. Tailscale Serve unavailable due to userspace networking. |
| Auth | Token-based gateway auth (`OPENCLAW_GATEWAY_TOKEN`) required for all API access. |
| Secrets | API keys stored as Fly secrets (encrypted, never in config files or repo). |
| Tailscale | Auth key is ephemeral — node auto-removed from tailnet on shutdown. |
| Shutdown | Graceful `tailscale logout` on SIGTERM cleans up the mesh node. |
| Tools | High-risk groups (`automation`, `runtime`) + control-plane tools (`gateway`, `cron`, `sessions_spawn`, `sessions_send`) denied. File ops confined to workspace. |
| Logging | Sensitive tool output redacted in logs (`logging.redactSensitive: "tools"`). |
| Discovery | mDNS disabled in config + `OPENCLAW_DISABLE_BONJOUR=1` env var. |
| Filesystem | Config file permissions locked to `600`, state directory to `700`. |
| Container | Minimal `node:22-slim` base image. |
| Storage | State persisted on encrypted Fly volume at `/data`. |

### Running a security audit

OpenClaw includes a built-in security audit tool. Run it after initial setup and after any config changes:

```bash
fly ssh console -a your-app-name
openclaw security audit
# For a deeper check:
openclaw security audit --deep
```

#### Known audit findings

Running `openclaw security audit` will report one **CRITICAL** finding on this deployment:

```text
CRITICAL  gateway.control_ui.insecure_auth
          Control UI allows insecure HTTP auth
          gateway.controlUi.allowInsecureAuth=true allows token-only auth
          over HTTP and skips device identity.
          Fix: Disable it or switch to HTTPS (Tailscale Serve) or localhost.
```

**This is a known, accepted trade-off for this deployment pattern.** Here's why it's safe:

- Tailscale Serve (HTTPS) requires kernel-level networking (`/dev/net/tun`), which is not available on Fly.io machines. The setting exists because OpenClaw's default behavior requires HTTPS or localhost for the control UI — `allowInsecureAuth` opts out of that requirement.
- The gateway has **no public IP** and is **not routable from the internet**. The only network path to it is through your Tailscale mesh.
- All traffic still requires a valid `OPENCLAW_GATEWAY_TOKEN` to connect.
- Auth brute-forcing is mitigated by rate limiting (`gateway.auth.rateLimit` in `openclaw.json`).

In short: the "insecure" refers to the absence of TLS transport encryption, not an open gateway. Tailscale encrypts all traffic between your devices and the machine at the WireGuard layer, providing equivalent transport security.

### Rotating credentials

If you need to rotate the gateway token or API keys:

```bash
# Generate and set a new gateway token
fly secrets set OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)" -a your-app-name

# Rotate provider keys
fly secrets set ANTHROPIC_API_KEY="sk-ant-NEW..." -a your-app-name
```

Setting a secret automatically restarts the machine. Verify old credentials no longer work after rotation.

## Troubleshooting

### Machine won't start / OOM

The default VM is `shared-cpu-2x` with 2GB RAM. If OpenClaw needs more, bump it in `fly.toml`:

```toml
[[vm]]
  size = "shared-cpu-4x"
  memory = 4096
```

### Tailscale auth key expired

Generate a new auth key at [Tailscale admin](https://login.tailscale.com/admin/settings/keys) and update the secret:

```bash
fly secrets set TAILSCALE_AUTHKEY="tskey-auth-NEW..." -a your-app-name
```

### Can't reach the gateway

- Verify the machine is running: `fly status -a your-app-name`
- Check logs for the Tailscale IP: `fly logs -a your-app-name`
- Ensure your device is connected to the same tailnet
- Try the Tailscale IP directly: `curl http://100.x.y.z:3000`

### Re-running onboarding

Open the Control UI from any device on your tailnet (`http://your-app-name:3000`) to reconfigure channels, providers, and models. Config is written to `/data/openclaw.json` on the persistent volume and survives gateway restarts — the browser reconnects automatically after each save.

### Gateway lock file errors

If OpenClaw complains about lock files after a crash:

```bash
fly ssh console -a your-app-name
rm -f /data/gateway.*.lock
exit
fly machines restart -a your-app-name
```

### Viewing OpenClaw health

```bash
fly ssh console -a your-app-name
openclaw gateway status
```

This will show gateway health, the port it's listening on, and whether the probe succeeds. You'll see systemd-related warnings — these are expected and harmless in a container. What matters is the probe result at the bottom.

> **Note:** Do not run `openclaw doctor --repair` inside the container. It rewrites `/data/openclaw.json` on the volume, which can overwrite settings like the port. Use `openclaw doctor` (without `--repair`) for read-only diagnostics.

```bash
fly ssh console -a your-app-name
openclaw doctor
```

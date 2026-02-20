# OpenBox

Deploy [OpenClaw](https://github.com/openclaw-ai/openclaw) (self-hosted AI agent gateway) on DigitalOcean, accessible **only** via your Tailscale network. No public IPs, no public services. Clone, configure, deploy.

## Architecture

```text
[Your Devices on Tailscale] --> [Tailscale Mesh] --> [DigitalOcean Droplet (no public inbound)]
                                                         |
                                                    [OpenClaw Gateway :3000]
                                                    [Tailscale daemon]
                                                    [Persistent /data directory]
```

- Single droplet running OpenClaw + Tailscale natively (not containerized)
- DigitalOcean firewall blocks all public inbound traffic
- Only reachable via Tailscale (MagicDNS or IP, e.g., `http://openclaw:3000`)
- Persistent data at `/data` for OpenClaw state and config

## Prerequisites

- [DigitalOcean](https://www.digitalocean.com) account with `doctl` installed and authenticated (`doctl auth init`)
- [Tailscale](https://tailscale.com) account with an auth key ([generate one here](https://login.tailscale.com/admin/settings/keys) — use **reusable** + **ephemeral**)
- An AI provider API key (e.g., Anthropic)
- `jq` and `openssl` (usually pre-installed; `brew install jq` if needed)
- Optional: [gum](https://github.com/charmbracelet/gum) for a nicer setup experience (`brew install gum`)

## Quick Start

```bash
git clone https://github.com/YOUR_USER/openbox.git
cd openbox
./setup-do.sh deploy
```

The setup script walks you through everything interactively:

1. **Droplet name & region** — names the deployment and picks the datacenter
2. **Droplet size** — choose vCPU/RAM tier
3. **SSH key** — generates a dedicated ed25519 key and uploads it to DO
4. **Tailscale** — enter your auth key
5. **AI provider** — Anthropic, OpenAI, or both
6. **Channels** — optional Discord and Telegram bot setup
7. **Deploy** — creates the droplet, installs packages via cloud-init, writes secrets
8. **Hardening** — applies a DO firewall blocking all public inbound traffic
9. **Verify** — runs health checks on the deployment

After the script finishes, open the gateway URL from any device on your tailnet and paste the gateway token to connect.

## Managing Your Deployment

```bash
./setup-do.sh deploy       # Interactive deployment wizard
./setup-do.sh verify [name] # Check deployment health
./setup-do.sh teardown [name] # Destroy all resources
```

## Accessing Your Instance

From any device on your tailnet:

```text
http://openclaw:3000
```

Or use the Tailscale IP directly (`http://100.x.y.z:3000`). Check the [Tailscale admin console](https://login.tailscale.com/admin/machines) for your machine's IP.

On the overview page, paste your gateway token into the **Gateway Token** field and click **Connect**.

> **Note:** The control UI runs over HTTP (not HTTPS). Security is maintained by Tailscale-only access (no public inbound) + token auth. The `controlUi.allowInsecureAuth` setting in `openclaw.json` enables this.

## Configuring Channels & Providers

Configure everything through the **Control UI** in your browser at `http://openclaw:3000`. Config is written to `/data/openclaw.json` on the droplet and survives restarts.

To add or rotate secrets (channel tokens, API keys), update `/data/.env` on the droplet and restart the service:

```bash
ssh root@openclaw           # via Tailscale SSH
nano /data/.env              # edit secrets
systemctl restart openclaw   # apply changes
```

## Updating OpenClaw

SSH into the droplet and reinstall:

```bash
ssh root@openclaw
npm install -g openclaw
systemctl restart openclaw
```

Your configuration and state in `/data` are preserved across updates.

After updating, verify the deployment is healthy:

```bash
openclaw doctor
openclaw security audit
```

## Security Model

| Layer | Protection |
|-------|-----------|
| Network | DO firewall blocks all public inbound. No exposed ports. |
| Access | Tailscale is the **only** network path to the gateway. |
| Transport | HTTP over Tailscale (WireGuard-encrypted). `controlUi.allowInsecureAuth` enables token-only auth. |
| Auth | Token-based gateway auth (`OPENCLAW_GATEWAY_TOKEN`) required for all API access. Rate-limited. |
| Secrets | API keys stored in `/data/.env` (permissions 600), never in config files or git. |
| Tailscale | Auth key is ephemeral — node auto-removed from tailnet on key expiry. Tailscale SSH enabled. |
| Tools | Control-plane tools (`gateway`) denied. File ops confined to workspace. |
| Logging | Sensitive tool output redacted in logs (`logging.redactSensitive: "tools"`). |
| Discovery | mDNS disabled in config + `OPENCLAW_DISABLE_BONJOUR=1` env var. |
| Filesystem | Config file permissions locked to `600`, data directory to `700`. |

### Running a security audit

```bash
ssh root@openclaw
openclaw security audit
# For a deeper check:
openclaw security audit --deep
```

### Rotating credentials

```bash
ssh root@openclaw
nano /data/.env              # update the key
systemctl restart openclaw   # apply
```

## Troubleshooting

### Droplet won't start / OOM

The default droplet is `s-1vcpu-2gb`. If OpenClaw needs more, destroy and redeploy with a larger size, or resize via the DO console.

### Tailscale auth key expired

Generate a new auth key at [Tailscale admin](https://login.tailscale.com/admin/settings/keys) and update on the droplet:

```bash
ssh root@openclaw
# Update TAILSCALE_AUTHKEY in /data/.env, then:
tailscale up --authkey='tskey-auth-NEW...' --hostname='openclaw' --ssh
```

### Can't reach the gateway

- Ensure your device is connected to the same tailnet
- Check Tailscale status: `ssh root@openclaw 'tailscale status'` (via public IP if Tailscale SSH isn't working)
- Check the service: `ssh root@openclaw 'systemctl status openclaw'`
- Check logs: `ssh root@openclaw 'journalctl -u openclaw -n 50'`
- Run verify: `./setup-do.sh verify`

### OpenClaw command not found

The global npm install may have been corrupted. Reinstall:

```bash
ssh root@openclaw
rm -rf /usr/lib/node_modules/openclaw /usr/lib/node_modules/.openclaw-*
npm install -g openclaw
systemctl restart openclaw
```

### Viewing OpenClaw health

```bash
ssh root@openclaw
openclaw gateway status
openclaw doctor
```

<details>
<summary>Legacy: Fly.io deployment</summary>

The project originally targeted Fly.io. The `Dockerfile`, `start.sh`, and `fly.toml` files remain for this path. Key differences from the DO deployment:

- Runs as a Docker container instead of natively on the host
- Uses Tailscale in userspace networking mode (no `/dev/net/tun`), which means Tailscale Serve (HTTPS) is not available
- Public IPs must be manually released after deploy
- Secrets managed via `fly secrets set`

```bash
fly deploy
fly ips release <ipv4> -a your-app-name
fly ips release <ipv6> -a your-app-name
fly ips allocate-v6 --private -a your-app-name
```

See `fly.toml` for configuration. This path is no longer actively maintained.

</details>

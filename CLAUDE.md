# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenBox is a self-hosted deployment framework for [OpenClaw](https://github.com/openclaw-ai/openclaw), an AI agent gateway. It provides private access through a Tailscale mesh network, with no public IP exposure. The architecture is a single Docker container running OpenClaw + Tailscale, deployed to DigitalOcean (or Fly.io as legacy fallback).

## Commands

### Deployment (DigitalOcean)
```bash
./setup-do.sh deploy       # Interactive deployment wizard
./setup-do.sh verify [name] # Check deployment health
./setup-do.sh teardown [name] # Destroy all resources
```

### Docker
```bash
docker build -t openbox .
```

### On-host diagnostics (via SSH into droplet)
```bash
openclaw gateway status
openclaw doctor
openclaw security audit [--deep]
tailscale status
```

There are no local test, lint, or build commands — this is an orchestration/infrastructure project.

## Architecture

```
[Tailscale mesh devices] --> [Tailscale daemon] --> [OpenClaw Gateway :3000]
                                                          |
                                                   [Persistent /data volume]
```

### Key Files

- **setup-do.sh** — Main deployment orchestrator (~1000 lines). Interactive wizard using `gum` TUI with graceful fallback to plain shell. Handles droplet creation, SSH keys, secrets, firewall, and full lifecycle.
- **Dockerfile** — Container image: `node:22-slim` base, installs Tailscale + OpenClaw + GitHub CLI. No public services exposed.
- **start.sh** — Container entrypoint. Sets up persistent symlinks to `/data`, starts Tailscale in userspace mode, launches OpenClaw gateway + headless node, handles graceful shutdown (SIGTERM → Tailscale logout).
- **openclaw.json** — Default OpenClaw config. Agent defaults to Claude Sonnet 4.6, denies automation/runtime/gateway tools, HTTP on port 3000 with token auth, mDNS disabled.
- **fly.toml** — Legacy Fly.io config (shared-cpu-2x, 2GB RAM, volume at `/data`).

## Conventions

- **Secrets**: Managed via cloud provider (DO secrets / Fly secrets), never in config files or git. Required vars: `TAILSCALE_AUTHKEY`, `OPENCLAW_GATEWAY_TOKEN`, AI provider keys.
- **Shell scripting style**: Uses helper functions (`header()`, `section()`, `info()`, `success()`, `warn()`, `error()`) for consistent output. All scripts use `gum` when available with plain fallback.
- **Persistence**: `~/.openclaw` is symlinked to `/data` volume so config and state survive container restarts.
- **Security posture**: No public IPs, token-based gateway auth, file permissions hardened (config 600, state dirs 700), sensitive tool output redacted in logs, ephemeral Tailscale auth keys.

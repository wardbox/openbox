FROM node:22-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    iptables \
    iproute2 \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Tailscale via official apt repo
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y tailscale \
    && rm -rf /var/lib/apt/lists/*

# Set iptables to legacy mode for Fly.io nf_tables compatibility
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Install OpenClaw globally
RUN npm install -g openclaw

# Pre-configure OpenClaw service files so `openclaw gateway status` works cleanly.
# Running doctor during build (no systemd available) sets up the PATH and service
# config files in the image layer — without touching the runtime volume config.
RUN openclaw doctor --repair || true

# Copy entrypoint and default config
COPY start.sh /start.sh
COPY openclaw.json /openclaw.json
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]

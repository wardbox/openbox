FROM node:22-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
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
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Set iptables to legacy mode for Fly.io nf_tables compatibility
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Install OpenClaw and Claude CLI globally
RUN npm install -g openclaw @anthropic-ai/claude-code

# Create runtime directories
RUN mkdir -p /data /var/run/tailscale

# Pre-configure OpenClaw service files, then wipe any build-time device tokens.
# Leaving them in the image causes "device token mismatch" at runtime because
# the gateway is fresh but the copied tokens reference a build-time session.
RUN openclaw doctor --repair || true
RUN rm -rf /root/.openclaw

# Copy entrypoint and default config
COPY start.sh /start.sh
COPY openclaw.json /openclaw.json
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]

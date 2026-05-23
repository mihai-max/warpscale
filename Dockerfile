FROM debian:bookworm-slim

# Pin wgcf release (https://github.com/ViRb3/wgcf/releases)
ARG WGCF_VERSION=2.2.27

# Base tooling: WireGuard userspace tools, routing, NAT, TLS, sysctl, apt-key handling.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        iproute2 \
        iptables \
        wireguard-tools \
        procps \
    && rm -rf /var/lib/apt/lists/*

# Tailscale from the official Debian bookworm repo (provides tailscaled + tailscale).
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

# wgcf: anonymous Cloudflare WARP WireGuard profile generator (no Cloudflare login).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) wgcf_arch="amd64" ;; \
        arm64) wgcf_arch="arm64" ;; \
        armhf) wgcf_arch="armv7" ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wgcf_arch}" \
        -o /usr/local/bin/wgcf; \
    chmod +x /usr/local/bin/wgcf; \
    wgcf --version

COPY entrypoint.sh healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

# Persistent state lives on volumes mounted here.
VOLUME ["/var/lib/wgcf", "/var/lib/tailscale"]

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

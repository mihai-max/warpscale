#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# Cloudflare WARP egress + Tailscale exit node (Headscale)
#
# WARP (wg0) provides internet egress; Tailscale (tailscale0) joins Headscale and
# advertises this node as an exit node. Only packets that ingress on tailscale0
# (i.e. forwarded exit-node traffic) are policy-routed out WARP. The container's
# own traffic (Tailscale control/DERP, the WARP handshake, healthcheck underlay)
# keeps using the real default interface.
# ----------------------------------------------------------------------------

WGCF_DIR=/var/lib/wgcf
WGCF_ACCOUNT_FILE="${WGCF_DIR}/wgcf-account.toml"
WGCF_PROFILE_FILE="${WGCF_DIR}/wgcf-profile.conf"
TS_STATE_DIR=/var/lib/tailscale
TS_SOCK=/var/run/tailscale/tailscaled.sock
WG_CONF=/etc/wireguard/wg0.conf
WG_IF=wg0
TS_IF=tailscale0
RT_TABLE=51820
RULE_PRIO=100

: "${HEADSCALE_URL:?HEADSCALE_URL is required (e.g. https://headscale.example.com)}"
TS_AUTHKEY="${TS_AUTHKEY:-}"          # optional: blank => interactive login (URL printed below)
TS_HOSTNAME="${TS_HOSTNAME:-warp-exit}"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"

log() { echo "[entrypoint] $*"; }

mkdir -p "$WGCF_DIR" "$TS_STATE_DIR" /etc/wireguard /var/run/tailscale

TAILSCALED_PID=""

cleanup() {
    log "shutting down..."
    if [ -n "$TAILSCALED_PID" ] && kill -0 "$TAILSCALED_PID" 2>/dev/null; then
        tailscale --socket="$TS_SOCK" down 2>/dev/null || true
        kill "$TAILSCALED_PID" 2>/dev/null || true
    fi
    ip rule del iif "$TS_IF" lookup "$RT_TABLE" 2>/dev/null || true
    ip -6 rule del iif "$TS_IF" lookup "$RT_TABLE" 2>/dev/null || true
    wg-quick down "$WG_IF" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# ----- 1. WARP account (persisted across restarts) --------------------------
if [ ! -f "$WGCF_ACCOUNT_FILE" ]; then
    log "registering a new anonymous Cloudflare WARP account..."
    wgcf register --accept-tos --config "$WGCF_ACCOUNT_FILE"
else
    log "reusing existing WARP account ($WGCF_ACCOUNT_FILE)"
fi

# ----- 2. WARP+ license (optional; update re-binds only if changed) ----------
if [ -n "${WARP_LICENSE_KEY:-}" ]; then
    log "applying WARP+ license key..."
    wgcf update --config "$WGCF_ACCOUNT_FILE" --license-key "$WARP_LICENSE_KEY" \
        || log "warning: 'wgcf update' failed; continuing with existing account"
fi

# ----- 3. generate the WireGuard profile ------------------------------------
log "generating WARP WireGuard profile..."
wgcf generate --config "$WGCF_ACCOUNT_FILE" --profile "$WGCF_PROFILE_FILE"

# ----- 4. build wg0.conf (Table=off => leave the main route table untouched)-
cp "$WGCF_PROFILE_FILE" "$WG_CONF"
sed -i '/^[[:space:]]*[Dd][Nn][Ss][[:space:]]*=/d' "$WG_CONF"
grep -qiE '^[[:space:]]*Table' "$WG_CONF" || sed -i '/^\[Interface\]/a Table = off' "$WG_CONF"
grep -qiE '^[[:space:]]*MTU'   "$WG_CONF" || sed -i '/^\[Interface\]/a MTU = 1280'  "$WG_CONF"

# ----- 5. enable IP forwarding ----------------------------------------------
# /proc/sys is read-only in a non-privileged container, so `sysctl -w` usually
# fails; in that case the value must be supplied at run time with
# `docker run --sysctl ...` (or via the `sysctls:` block in docker-compose.yml).
# enable_forwarding succeeds if we can set it OR it is already on.
enable_forwarding() {
    # $1 = sysctl key, $2 = /proc path
    sysctl -w "$1=1" >/dev/null 2>&1 && return 0
    [ "$(cat "$2" 2>/dev/null || echo 0)" = "1" ]
}

if enable_forwarding net.ipv4.ip_forward /proc/sys/net/ipv4/ip_forward; then
    log "IPv4 forwarding enabled"
else
    log "FATAL: net.ipv4.ip_forward is off and cannot be set from inside the container."
    log "       Re-run with:  --sysctl net.ipv4.ip_forward=1   (already set in docker-compose.yml)"
    exit 1
fi

if enable_forwarding net.ipv6.conf.all.forwarding /proc/sys/net/ipv6/conf/all/forwarding; then
    log "IPv6 forwarding enabled"
else
    log "IPv6 forwarding unavailable; continuing IPv4-only"
fi

# ----- 6. bring up WARP -----------------------------------------------------
log "bringing up WARP interface ($WG_IF)..."
wg-quick up "$WG_IF"

# ----- 7. policy routing: dedicated table whose default route is WARP --------
ip route replace default dev "$WG_IF" table "$RT_TABLE"
ip -6 route replace default dev "$WG_IF" table "$RT_TABLE" 2>/dev/null || log "ipv6 WARP route skipped"

# ----- 8. NAT forwarded traffic onto WARP + clamp MSS to the small WARP MTU --
iptables  -t nat    -C POSTROUTING -o "$WG_IF" -j MASQUERADE 2>/dev/null \
    || iptables  -t nat    -A POSTROUTING -o "$WG_IF" -j MASQUERADE
iptables  -t mangle -C FORWARD -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables  -t mangle -A FORWARD -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t nat    -C POSTROUTING -o "$WG_IF" -j MASQUERADE 2>/dev/null \
    || ip6tables -t nat    -A POSTROUTING -o "$WG_IF" -j MASQUERADE 2>/dev/null || true
ip6tables -t mangle -C FORWARD -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || ip6tables -t mangle -A FORWARD -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# ----- 9. start tailscaled --------------------------------------------------
log "starting tailscaled..."
tailscaled \
    --state="${TS_STATE_DIR}/tailscaled.state" \
    --socket="$TS_SOCK" \
    --tun="$TS_IF" \
    --port=41641 &
TAILSCALED_PID=$!

# wait for the control socket and the TUN interface (created at tailscaled startup)
for _ in $(seq 1 60); do
    [ -S "$TS_SOCK" ] && ip link show "$TS_IF" >/dev/null 2>&1 && break
    sleep 0.5
done

# ----- 10. send forwarded (iif tailscale0) traffic into the WARP table ------
# Set up before `tailscale up` so routing is ready regardless of how auth completes.
ip rule del iif "$TS_IF" lookup "$RT_TABLE" 2>/dev/null || true
ip rule add iif "$TS_IF" lookup "$RT_TABLE" priority "$RULE_PRIO"
if ip -6 rule list >/dev/null 2>&1; then
    ip -6 rule del iif "$TS_IF" lookup "$RT_TABLE" 2>/dev/null || true
    ip -6 rule add iif "$TS_IF" lookup "$RT_TABLE" priority "$RULE_PRIO" 2>/dev/null || true
fi

# ----- 11. join Headscale and advertise as an exit node ---------------------
# Auth (node key) is saved to ${TS_STATE_DIR}/tailscaled.state on the ts-data
# volume, so login is only needed once; restarts reconnect automatically.
TS_UP_ARGS=(
    --login-server="$HEADSCALE_URL"
    --hostname="$TS_HOSTNAME"
    --advertise-exit-node
    --accept-dns=false
)
if [ -n "$TS_AUTHKEY" ]; then
    log "connecting to Headscale at $HEADSCALE_URL using a preauth key..."
    TS_UP_ARGS+=(--authkey="$TS_AUTHKEY")
else
    log "no TS_AUTHKEY set -> interactive login."
    log "=================================================================="
    log " An authentication URL will be printed below. Open it, then on your"
    log " Headscale server register the node, e.g.:"
    log "   headscale nodes register --user <user> --key <nodekey-from-URL>"
    log " The login is saved to the ts-data volume, so this is a one-time step."
    log "=================================================================="
fi
# shellcheck disable=SC2086
tailscale --socket="$TS_SOCK" up "${TS_UP_ARGS[@]}" $TS_EXTRA_ARGS

log "ready: exit-node traffic now egresses through Cloudflare WARP."
log "NOTE: approve this node's exit route on Headscale (0.0.0.0/0, ::/0) before clients can use it."

# ----- 12. stay alive on tailscaled -----------------------------------------
wait "$TAILSCALED_PID"

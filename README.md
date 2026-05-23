# WARP-egress Tailscale exit node (Headscale)

A single Docker container that:

1. **Generates a Cloudflare WARP WireGuard profile with no Cloudflare login** using
   [`wgcf`](https://github.com/ViRb3/wgcf) (registers a free anonymous WARP account over Cloudflare's
   API).
2. **Joins your self-hosted [Headscale](https://github.com/juanfont/headscale) control server and
   advertises itself as a Tailscale exit node.**
3. **Forwards only the exit-node traffic out through WARP.** A client that selects this node as its
   exit node appears on the internet as a Cloudflare WARP IP, while the node itself stays reachable
   on the tailnet over its real link.

## How it works

Two tunnels live in the container's network namespace:

- `wg0` — Cloudflare WARP (egress to the internet).
- `tailscale0` — the TUN created by `tailscaled` (ingress from the Headscale tailnet).

WARP is brought up with `Table = off`, so `wg-quick` does **not** touch the main routing table. A
dedicated routing table (`51820`) has its default route pointing at `wg0`, and a single policy rule
sends only packets that **ingress on `tailscale0`** into that table:

```
ip rule add iif tailscale0 lookup 51820   # forwarded exit-node traffic -> WARP
ip route add default dev wg0 table 51820
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
```

The container's own traffic — Tailscale control/DERP to Headscale, the WARP handshake itself, the
healthcheck underlay — is locally generated, never matches `iif tailscale0`, and keeps using the real
default interface. So the node can always reach Headscale even before WARP is up, and there is no
routing loop.

## Prerequisites

- A **Linux Docker host** (or Docker Desktop). The host kernel must support WireGuard (Linux ≥ 5.6 —
  true for any modern host); `wg-quick` uses the in-kernel module.
- A reachable **Headscale** server and a user to register the node under.
- The container needs `NET_ADMIN`, `/dev/net/tun`, and IP-forwarding sysctls — all wired up in
  `docker-compose.yml`.

## Usage

You can authenticate either **interactively** (an auth URL is printed in the logs) or
**headlessly** with a preauth key. Either way the login is saved to the `ts-data` volume, so
it is only needed once — restarts reconnect automatically.

1. **Configure the container:**

   ```sh
   cp .env.example .env
   # edit .env: set HEADSCALE_URL (and optionally WARP_LICENSE_KEY).
   # TS_AUTHKEY is optional - leave it blank to log in interactively.
   ```

2. **Build and run:**

   ```sh
   make build
   make up
   make logs        # watch for: WARP up, then the auth URL or "tailscale up success"
   ```

3. **Authenticate:**

   - **Interactive (no `TS_AUTHKEY`):** the logs print

     ```
     To authenticate, visit:
         https://headscale.example.com/register/nodekey:xxxxxxxx
     ```

     Open that URL, then on your Headscale server register the node:

     ```sh
     headscale nodes register --user <user> --key <nodekey-from-URL>
     ```

   - **Headless (preauth key):** create one on the Headscale host and put it in `.env` as
     `TS_AUTHKEY` before `make up`:

     ```sh
     headscale users create exitnodes        # once, if the user doesn't exist
     headscale preauthkeys create --user exitnodes --reusable --expiration 24h
     ```

4. **Approve the exit route on Headscale.** Advertising an exit node is a *request*; an admin must
   approve the `0.0.0.0/0` (and `::/0`) routes:

   ```sh
   headscale nodes list                                   # find the node id
   headscale nodes approve-routes -i <id> -r 0.0.0.0/0,::/0
   # older Headscale: headscale routes list / headscale routes enable -r <route-id>
   ```

5. **Use it from a client:**

   ```sh
   tailscale up --exit-node=warp-exit          # by hostname, or use the node's tailnet IP
   curl https://www.cloudflare.com/cdn-cgi/trace   # expect warp=on, and a Cloudflare IP
   ```

## Verifying

- `make status` — runs the in-container healthcheck (probes through `wg0`, expects `warp=on`).
- `make trace` — full `cdn-cgi/trace` through WARP.
- `docker compose exec warp-exit wg show` — confirms a recent WARP handshake.
- The container reports `healthy` once the WARP probe passes.

## Configuration (`.env`)

| Variable           | Required | Description                                                        |
|--------------------|----------|--------------------------------------------------------------------|
| `HEADSCALE_URL`    | yes      | Headscale control server URL, e.g. `https://headscale.example.com` |
| `TS_AUTHKEY`       | no       | Headscale preauth key. Blank => interactive login (URL in logs)   |
| `TS_HOSTNAME`      | no       | Node name in Headscale (default `warp-exit`)                       |
| `TS_EXTRA_ARGS`    | no       | Extra args appended to `tailscale up`                              |
| `WARP_LICENSE_KEY` | no       | Cloudflare WARP+ license key (free tier if blank)                 |

State is persisted in named volumes: `warp-data` (the WARP account, so the same identity is reused)
and `ts-data` (Tailscale state, so the node isn't re-created in Headscale on restart).

## Troubleshooting

- **`wg-quick: command not found` / module errors:** the host kernel lacks WireGuard. Use a newer
  kernel, or switch to userspace `wireguard-go` (not built in by default).
- **No connectivity through the exit node:** confirm the exit route was *approved* on Headscale
  (step 4) and the client ran `tailscale up --exit-node=...`.
- **Broken/large transfers stall:** an MTU/MSS issue. `wg0` is set to MTU 1280 and FORWARD MSS is
  clamped; if a peer still struggles, lower `MTU` further in `entrypoint.sh`.
- **iptables backend:** Debian bookworm uses `iptables-nft` by default, which Tailscale supports. If
  your host enforces the legacy backend, switch with
  `update-alternatives --set iptables /usr/sbin/iptables-legacy` in the image.

#!/usr/bin/env bash
# Verify the WARP tunnel actually works by probing through wg0 directly.
# Binding to wg0 (SO_BINDTODEVICE) forces this request through WARP even though
# the container's normal traffic bypasses it; Cloudflare reports warp=on only
# when the request really egressed via WARP.
set -euo pipefail

curl -fsS --interface wg0 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace \
    | grep -q '^warp=on'

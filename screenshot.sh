#!/bin/bash
# Grab a PNG screenshot from the connected iPhone over USB.
# Uses pymobiledevice3 (installed via pipx). iOS 17+ routes the screenshot
# service through a RemoteXPC tunnel, so `tunneld` must be running (once,
# in the background, needs sudo). This script checks that and tells you how
# to start it if it's not up.
#
# Usage: ./screenshot.sh [output.png]
#   default output: screenshots/screenshot-YYYYMMDD-HHMMSS.png
set -euo pipefail

cd "$(dirname "$0")"

# pipx installs into ~/.local/bin; make sure it's on PATH even in non-login shells.
export PATH="$HOME/.local/bin:$PATH"

if ! command -v pymobiledevice3 >/dev/null; then
    echo "✗ pymobiledevice3 not found." >&2
    echo "  install with: brew install pipx && pipx install pymobiledevice3" >&2
    exit 1
fi

# --- 1. Output path ---
OUT="${1:-screenshots/screenshot-$(date +%Y%m%d-%H%M%S).png}"
mkdir -p "$(dirname "$OUT")"

# --- 2. Find a connected iPhone ---
# Must use pymobiledevice3's view of the UDID (ECID-style, e.g.
# 00008150-000C11503661401C), NOT xcrun devicectl's UUID (e.g.
# 2AFE3E3A-...). iOS 17+ split those namespaces; tunneld only indexes the
# ECID form, so passing devicectl's UUID produces "Device not found".
DEVICE_ID=$(pymobiledevice3 usbmux list 2>/dev/null | python3 -c '
import json, sys
devices = json.load(sys.stdin)
for d in devices:
    if d.get("ConnectionType") == "USB" and d.get("DeviceClass") == "iPhone":
        print(d["UniqueDeviceID"])
        break
')

if [ -z "${DEVICE_ID:-}" ]; then
    echo "✗ no connected iPhone." >&2
    echo "  plug in via USB, unlock, and ensure Developer Mode is on." >&2
    exit 1
fi
echo "→ device: $DEVICE_ID"

# --- 3. Check tunneld ---
# tunneld listens on 49151 by default. Probe with `nc -z` (works regardless
# of whether tunneld was started under sudo — `lsof` would miss root-owned
# sockets when run as the non-root user).
if ! nc -z 127.0.0.1 49151 >/dev/null 2>&1; then
    cat >&2 <<'EOF'
✗ tunneld is not running.
  One-time setup (leave this running in a separate terminal):

      sudo pymobiledevice3 remote tunneld

  After it starts, re-run ./screenshot.sh.
EOF
    exit 1
fi

# --- 4. Fetch RSD host/port from tunneld ---
# On iOS 17+, the dvt screenshot service needs an explicit --rsd HOST PORT.
# tunneld's HTTP API at :49151 returns a JSON map keyed by UDID:
#   { "<udid>": [ { "tunnel-address": "...", "tunnel-port": <int>, ... } ] }
# The deprecated `developer screenshot` path no longer works on iOS 26;
# `developer dvt screenshot` does.
RSD_INFO=$(curl -sf "http://127.0.0.1:49151/" | python3 -c "
import json, sys
data = json.load(sys.stdin)
entries = data.get('$DEVICE_ID') or []
if not entries:
    sys.exit(1)
e = entries[0]
print(e['tunnel-address'], e['tunnel-port'])
") || {
    echo "✗ tunneld has no tunnel for $DEVICE_ID." >&2
    echo "  restart tunneld: sudo pymobiledevice3 remote tunneld" >&2
    exit 1
}
RSD_HOST="${RSD_INFO% *}"
RSD_PORT="${RSD_INFO#* }"

# --- 5. Screenshot ---
# pymobiledevice3 exits 0 even on failures (logs ERROR and returns), so
# we check that the output file got written and is non-empty.
echo "→ capturing → $OUT"
pymobiledevice3 developer dvt screenshot --rsd "$RSD_HOST" "$RSD_PORT" "$OUT"
if [ ! -s "$OUT" ]; then
    echo "✗ screenshot failed — no output file written." >&2
    echo "  (pymobiledevice3 logs ERROR but exits 0; see its output above.)" >&2
    rm -f "$OUT"
    exit 1
fi
echo "✓ saved $OUT"

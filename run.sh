#!/bin/bash
# Build Posture Buddy (iOS) and install + launch on the connected iPhone.
# Uses xcodebuild + xcrun devicectl so we don't depend on Xcode's GUI state or
# keyboard-send Cmd+R. Prereq: iPhone plugged in via USB, Developer Mode on,
# and Mac trusted by the phone. Xcode does not need to be open.
#
# Usage: ./run.sh [debug|release] [--logs|--bg]
#   debug:   -O0, full symbols, asserts on — fast to build, slower runtime (default)
#   release: -O, stripped symbols, asserts off — production perf + battery
#   --logs:  foreground attach to the launched app's stdout/stderr, tee to
#            build/latest.log; blocks until Ctrl+C.
#   --bg:    background-attach the same console stream; logs to build/latest.log
#            only (no terminal output), returns immediately. Use `tail -f
#            build/latest.log` to watch live, or just inspect after the session.
set -euo pipefail

cd "$(dirname "$0")"

# Clean up any leftover backgrounded devicectl from previous `--bg` runs so an
# old console-attach doesn't keep writing into build/latest.log alongside the
# new launch (or hold the device console busy). pkill returns nonzero when no
# match → swallow with `|| true` so set -e doesn't bail.
pkill -f "devicectl device process launch" 2>/dev/null && echo "→ killed stale backgrounded devicectl" || true

PROJECT="Posture Buddy.xcodeproj"
SCHEME="Posture Buddy"
BUNDLE_ID="akamko.Posture-Buddy"
DERIVED="build"

# --- 0. Parse args (config positional + --logs/--bg flag, in any order) ---
WITH_LOGS=0
WITH_BG=0
CONFIGURATION="Debug"
for arg in "$@"; do
    case "$arg" in
        debug|Debug)     CONFIGURATION="Debug" ;;
        release|Release) CONFIGURATION="Release" ;;
        --logs|-l)       WITH_LOGS=1 ;;
        --bg|-b)         WITH_BG=1 ;;
        *)
            echo "usage: $0 [debug|release] [--logs|--bg]" >&2
            exit 2
            ;;
    esac
done
echo "→ config: $CONFIGURATION"

# --- 1. Find a connected iPhone ---
# `xcrun devicectl list devices` output is fixed-column; the row for a physical
# phone says "connected" in the State column while paired-only devices (Watch,
# etc.) say "available (paired)". Grep for the UUID pattern to avoid fighting
# column widths.
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
    | awk '/connected/ && /iPhone/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/) {
                print $i
                exit
            }
        }
    }')

if [ -z "${DEVICE_ID:-}" ]; then
    echo "✗ no connected iPhone." >&2
    echo "  plug in via USB, unlock, and ensure Developer Mode is on" >&2
    echo "  (iPhone Settings → Privacy & Security → Developer Mode)." >&2
    exit 1
fi

DEVICE_NAME=$(xcrun devicectl list devices 2>/dev/null \
    | awk -v id="$DEVICE_ID" '$0 ~ id {
        # name is columns 1..N before the hostname; print everything up to the
        # first column that looks like a hostname (contains "local")
        name = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /local/) break
            name = (name == "" ? $i : name " " $i)
        }
        print name
        exit
    }')
echo "→ device: ${DEVICE_NAME:-$DEVICE_ID}"

# --- 2. Build ---
echo "→ building…"
BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "platform=iOS,id=$DEVICE_ID" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED" \
        -allowProvisioningUpdates \
        build > "$BUILD_LOG" 2>&1; then
    echo "✗ build failed. tail of log:" >&2
    tail -50 "$BUILD_LOG" >&2
    exit 1
fi

APP="$DERIVED/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
[ -d "$APP" ] || { echo "✗ app bundle missing at $APP" >&2; exit 1; }

# --- 3. Install + launch ---
echo "→ installing…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/dev/null

LOG_FILE="$DERIVED/latest.log"
if [ "$WITH_BG" = "1" ]; then
    # Background mode: nohup + & + disown so the console-attach survives this
    # script exiting and any terminal close. Logs go straight to the file (no
    # tee — there's no foreground terminal to write to).  `--logs` + `--bg`
    # together resolves here too, since you can't tee to a nonexistent term.
    echo "→ launching backgrounded; logs → $LOG_FILE"
    nohup xcrun devicectl device process launch \
        --console \
        --device "$DEVICE_ID" \
        "$BUNDLE_ID" > "$LOG_FILE" 2>&1 &
    BG_PID=$!
    disown
    echo "✓ launched (devicectl pid $BG_PID); kill it with: kill $BG_PID"
elif [ "$WITH_LOGS" = "1" ]; then
    echo "→ launching with --console; teeing to $LOG_FILE (Ctrl+C to detach)"
    # `--console` connects the app's stdout/stderr to ours and blocks until the
    # process exits. Pipe through tee so logs go to both terminal and file.
    xcrun devicectl device process launch \
        --console \
        --device "$DEVICE_ID" \
        "$BUNDLE_ID" 2>&1 | tee "$LOG_FILE"
else
    echo "→ launching…"
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null
    echo "✓ launched $BUNDLE_ID"
fi

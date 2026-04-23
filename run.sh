#!/bin/bash
# Build Posture Buddy (iOS) and install + launch on the connected iPhone.
# Uses xcodebuild + xcrun devicectl so we don't depend on Xcode's GUI state or
# keyboard-send Cmd+R. Prereq: iPhone plugged in via USB, Developer Mode on,
# and Mac trusted by the phone. Xcode does not need to be open.
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Posture Buddy.xcodeproj"
SCHEME="Posture Buddy"
BUNDLE_ID="akamko.Posture-Buddy"
CONFIGURATION="Debug"
DERIVED="build"

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

echo "→ launching…"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null

echo "✓ launched $BUNDLE_ID"

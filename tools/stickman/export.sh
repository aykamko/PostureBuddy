#!/bin/bash
# Bake the latest .blend → Posture Buddy/stickman.usdz + a preview PNG.
# Usage: ./tools/stickman/export.sh [optional/path/to.blend]
#
# Default source is the user-baked v3 file. Override by passing a different
# .blend path as the first argument.

set -euo pipefail

BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$SCRIPT_DIR/export_v2.py"
BLEND="${1:-$HOME/Downloads/GameReadyStickmanBlenderRig/posture_buddy_v3_baked.blend}"

if [[ ! -x "$BLENDER" ]]; then
    echo "ERROR: Blender not found at $BLENDER" >&2
    exit 1
fi
if [[ ! -f "$BLEND" ]]; then
    echo "ERROR: .blend not found at $BLEND" >&2
    exit 1
fi

echo "→ Blender: $BLENDER"
echo "→ Source : $BLEND"
echo "→ Script : $PY"
echo

"$BLENDER" -b "$BLEND" --python "$PY" 2>&1 \
  | grep -vE '^00:|WARNING|anim\.driver|^Blender [0-9]|^Read blend|^Saved' \
  | tail -25

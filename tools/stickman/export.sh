#!/bin/bash
# Bake the latest .blend → Posture Buddy/stickman.usdz + a preview PNG.
# Usage: ./tools/stickman/export.sh [optional/path/to.blend]
#
# Default source is `assets/posture_buddy_v6_baked.blend` (committed to the
# repo). The chair is embedded in this .blend — no separate chair file is
# required. Override by passing a different .blend path as the first arg.

set -euo pipefail

BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PY="$SCRIPT_DIR/export.py"
BLEND="${1:-$REPO_ROOT/assets/posture_buddy_v6_baked.blend}"

if [[ ! -x "$BLENDER" ]]; then
    echo "ERROR: Blender not found at $BLENDER" >&2
    exit 1
fi

# .blend files are tracked via Git LFS. On a fresh clone they start life as
# tiny pointer files (~133 bytes) until `git lfs pull` downloads the real
# thing. Blender happily opens those and silently gives us a T-pose. Fail
# early with a clear message instead.
is_lfs_pointer() {
    [[ -f "$1" ]] || return 1
    head -c 64 "$1" 2>/dev/null | grep -q '^version https://git-lfs\.github\.com/spec/'
}

if [[ ! -f "$BLEND" ]]; then
    echo "ERROR: .blend not found at $BLEND" >&2
    exit 1
fi
if is_lfs_pointer "$BLEND"; then
    echo "ERROR: $BLEND is a Git LFS pointer (not the real file)." >&2
    echo "       Run \`git lfs pull\` in the repo root to fetch the actual" >&2
    echo "       .blend asset, then rerun this script." >&2
    exit 1
fi

echo "→ Blender: $BLENDER"
echo "→ Source : $BLEND"
echo "→ Script : $PY"
echo

"$BLENDER" -b "$BLEND" --python "$PY" 2>&1 \
  | grep -vE '^00:|WARNING|anim\.driver|^Blender [0-9]|^Read blend|^Saved' \
  | tail -25

#!/usr/bin/env bash
#
# build-grok.sh — bundle Grok's `grk_decompress` (JPEG2000, AGPL-3.0) and its
# full dylib closure into Sources/AlphaSubToolBinaries/Resources/grok/, self-contained
# via @loader_path, for real-time DCP playback without a Homebrew install.
#
#   bash scripts/build-grok.sh
#
# Notes:
#  • Grok is AGPL-3.0. AlphaSub uses it STRICTLY as a bundled SUBPROCESS binary
#    (never linked into the app), so the AGPL stays contained — the same
#    aggregation boundary used for the bundled ffmpeg. The corresponding source
#    offer ships as Resources/grok/LICENSE-grok.txt.
#  • Source: Homebrew `grokj2k`. Currently arm64 only (no x86_64 bottle); on
#    Intel Macs the app gracefully falls back to the ffmpeg proxy. A universal
#    build would require compiling Grok + deps from source for x86_64.
#  • The bundle is ad-hoc signed here; the release re-signs it with Developer ID
#    inside package-manual.sh (nested-signing loop), then notarizes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/AlphaSubToolBinaries/Resources/grok"
SRC="$(command -v grk_decompress || echo /opt/homebrew/bin/grk_decompress)"

[ -x "$SRC" ] || { echo "✗ grk_decompress not found — brew install grokj2k" >&2; exit 1; }
command -v dylibbundler >/dev/null || { echo "✗ dylibbundler required — brew install dylibbundler" >&2; exit 1; }

echo "==> bundling $SRC → $DEST"
rm -rf "$DEST"; mkdir -p "$DEST"
cp "$SRC" "$DEST/grk_decompress"; chmod u+w "$DEST/grk_decompress"

# Collect the whole non-system dylib closure FLAT alongside the binary, with all
# references rewritten to @loader_path/<sibling> (flat layout so both the binary
# and the dylibs resolve their siblings correctly).
( cd "$DEST" && dylibbundler -of -cd -b -x ./grk_decompress -d . -p @loader_path/ >/dev/null )

echo "==> ad-hoc signing (release re-signs with Developer ID)…"
( cd "$DEST" && codesign -s - -f grk_decompress ./*.dylib >/dev/null 2>&1 )

# AGPL source offer.
cat > "$DEST/LICENSE-grok.txt" <<'EOF'
Grok (grk_decompress) — JPEG2000 codec — is licensed under the GNU Affero
General Public License v3.0 (AGPL-3.0). Copyright (c) Grok Image Compression.

AlphaSub bundles the unmodified grk_decompress binary and uses it ONLY as a
separate subprocess (it is not linked into AlphaSub). The complete corresponding
source code for this version of Grok is available at:

    https://github.com/GrokImageCompression/grok  (tag: v20.3.7)

A copy of the AGPL-3.0 is available at https://www.gnu.org/licenses/agpl-3.0.txt
EOF

echo "==> done. Files:"
( cd "$DEST" && ls -1 | sed 's/^/    /' )
echo "==> verify self-contained:"
otool -L "$DEST/grk_decompress" | tail -n +2 | grep -vE "/usr/lib/|/System/|@loader_path" \
    && { echo "✗ external deps remain" >&2; exit 1; } || echo "    OK (self-contained)"

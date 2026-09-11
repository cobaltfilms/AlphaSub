#!/usr/bin/env bash
#
# build-grok.sh — bundle Grok's `grk_decompress` and `grk_compress` (JPEG2000,
# AGPL-3.0) and their full dylib closure into
# Sources/AlphaSubToolBinaries/Resources/grok/, self-contained via
# @loader_path, for real-time DCP playback and DCP authoring without a
# Homebrew install.
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
#  • Never bundle Grok 20.3.x. Its lossy encoder damaged every picture — ripples
#    up to 515 codes around edges and a 36 dB ceiling at any rate, in cinema
#    mode too — and a green suite hid it (2026-09-10). 20.4.2 fixed it upstream
#    ("returning to floating point forward wavelet transform").
#    J2KEncoderTests.testLossyEncodeKeepsHardEdgesIntact fails on a bad build;
#    run it after every re-bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/AlphaSubToolBinaries/Resources/grok"
# Both directions ship: grk_decompress plays a DCP back, grk_compress authors
# one. They share the whole dylib closure, so bundling the pair costs one
# binary more, not one closure more.
TOOLS=(grk_decompress grk_compress)

rm -rf "$DEST"; mkdir -p "$DEST"
for tool in "${TOOLS[@]}"; do
    src="$(command -v "$tool" || echo "/opt/homebrew/bin/$tool")"
    [ -x "$src" ] || { echo "✗ $tool not found — brew install grokj2k" >&2; exit 1; }
    echo "==> bundling $src → $DEST"
    cp "$src" "$DEST/$tool"; chmod u+w "$DEST/$tool"
done
command -v dylibbundler >/dev/null || { echo "✗ dylibbundler required — brew install dylibbundler" >&2; exit 1; }

# Collect the whole non-system dylib closure FLAT alongside the binary, with all
# references rewritten to @loader_path/<sibling> (flat layout so both the binary
# and the dylibs resolve their siblings correctly).
# `-x` is repeatable: one pass over both binaries so the shared closure is
# collected once and both ends of it get the same rewritten install names.
( cd "$DEST" && dylibbundler -of -cd -b -x ./grk_decompress -x ./grk_compress -d . -p @loader_path/ >/dev/null )

echo "==> ad-hoc signing (release re-signs with Developer ID)…"
( cd "$DEST" && codesign -s - -f grk_decompress grk_compress ./*.dylib >/dev/null 2>&1 )

# AGPL source offer, naming the version actually bundled — read from the
# binary, so a re-bundle cannot leave the notice pointing at the old tag.
VERSION="$("$DEST/grk_compress" -V 2>/dev/null | head -1 | tr -d '[:space:]')"
[ -n "$VERSION" ] || { echo "✗ could not read the bundled Grok version" >&2; exit 1; }
cat > "$DEST/LICENSE-grok.txt" <<EOF
Grok (grk_decompress, grk_compress) — JPEG2000 codec — is licensed under the
GNU Affero General Public License v3.0 (AGPL-3.0). Copyright (c) Grok Image
Compression.

AlphaSub bundles the unmodified grk_decompress and grk_compress binaries and
uses them ONLY as separate subprocesses (they are not linked into AlphaSub).
The complete corresponding source code for this version of Grok is available
at:

    https://github.com/GrokImageCompression/grok  (tag: v${VERSION})

A copy of the AGPL-3.0 is available at https://www.gnu.org/licenses/agpl-3.0.txt
EOF

echo "==> done: Grok $VERSION. Files:"
( cd "$DEST" && ls -1 | sed 's/^/    /' )
echo "==> verify self-contained:"
for tool in "${TOOLS[@]}"; do
    otool -L "$DEST/$tool" | tail -n +2 | grep -vE "/usr/lib/|/System/|@loader_path" \
        && { echo "✗ $tool: external deps remain" >&2; exit 1; } || echo "    OK $tool (self-contained)"
done

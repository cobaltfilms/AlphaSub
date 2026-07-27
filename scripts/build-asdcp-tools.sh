#!/usr/bin/env bash
#
# build-asdcp-tools.sh — build asdcplib's `asdcp-unwrap` + `asdcp-info` CLI tools
# and bundle them (self-contained) into Sources/AlphaSub/App/Resources/asdcp/,
# so ClairMeta can do DEEP subtitle-content inspection during DCP QC without a
# Homebrew asdcplib install. (DCPValidator prepends this dir to ClairMeta's PATH.)
#
#   bash scripts/build-asdcp-tools.sh
#
# Notes:
#  • asdcplib is BSD-3 (CineCert); libcrypto (OpenSSL) is Apache-2.0 — both fine
#    for the closed app. Built WITHOUT_XML (unwrap only extracts essence — the
#    tools verified working WITHOUT Xerces).
#  • libcrypto is embedded via @loader_path so the tools run with no dylib
#    install. arm64 for now (matches the arm64 Grok bundle); Intel Macs get the
#    "deep inspection skipped" QC note.
#  • Ad-hoc signed here; the release re-signs with Developer ID (package-manual.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/AlphaSub/App/Resources/asdcp"
WORK="${ASDCP_WORK_DIR:-$HOME/.cache/alphasub-asdcp-tools}"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-/opt/homebrew/opt/openssl@3}"
LIBC="$OPENSSL_PREFIX/lib/libcrypto.3.dylib"

command -v cmake >/dev/null || { echo "✗ cmake required — brew install cmake" >&2; exit 1; }
[ -f "$LIBC" ] || { echo "✗ $LIBC not found — brew install openssl@3" >&2; exit 1; }

mkdir -p "$WORK"
[ -d "$WORK/asdcplib" ] || git clone --depth 1 https://github.com/cinecert/asdcplib.git "$WORK/asdcplib"

echo "==> building asdcp-unwrap + asdcp-info…"
mkdir -p "$WORK/asdcplib/build"; cd "$WORK/asdcplib/build"
cmake .. -DWITHOUT_XML=ON -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES="${ASDCP_ARCHS:-$(uname -m)}" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
make -j"$(sysctl -n hw.ncpu)" asdcp-unwrap asdcp-info >/dev/null 2>&1

echo "==> bundling into $DEST (libcrypto via @loader_path)…"
mkdir -p "$DEST"
cp src/asdcp-unwrap src/asdcp-info "$DEST/"
cp "$LIBC" "$DEST/"; chmod u+w "$DEST/libcrypto.3.dylib"
for t in asdcp-unwrap asdcp-info; do
    install_name_tool -change "$LIBC" "@loader_path/libcrypto.3.dylib" "$DEST/$t"
done
install_name_tool -id "@loader_path/libcrypto.3.dylib" "$DEST/libcrypto.3.dylib"
( cd "$DEST" && codesign --remove-signature libcrypto.3.dylib asdcp-unwrap asdcp-info 2>/dev/null || true
  codesign -s - -f libcrypto.3.dylib && codesign -s - -f asdcp-unwrap asdcp-info )

echo "==> done:"; ls -1 "$DEST" | sed 's/^/    /'
otool -L "$DEST/asdcp-unwrap" | tail -n +2 | grep -vE "/usr/lib/|/System/|@loader_path" \
    && { echo "✗ external deps remain" >&2; exit 1; } || echo "    OK (self-contained)"

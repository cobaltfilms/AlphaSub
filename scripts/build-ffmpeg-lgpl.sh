#!/usr/bin/env bash
#
# build-ffmpeg-lgpl.sh — build a minimal, fully-LGPL ffmpeg + ffprobe from
# source and install them into Sources/AlphaSub/App/Resources/ffmpeg/ for
# bundling. Unlike fetch-ffmpeg.sh (which downloads GPL static builds), this
# produces binaries AlphaSub can legally redistribute inside the DMG:
#
#   --disable-gpl --disable-nonfree     no x264/x265/fdk-aac ever linked
#   VideoToolbox enabled                hardware H.264/HEVC if ever needed
#   dnxhd encoder                       LGPL, in-tree (DNxHD/DNxHR export)
#   matroska/mov/mp4 muxers, aac, pcm   LGPL, in-tree
#
# AlphaSub only *needs* ffmpeg for: DNxHD/DNxHR encode, MKV muxing, mov_text,
# MKV import, and audio extraction — everything else is native AVFoundation.
# The component list below covers those plus common demux/decode so MKV
# import keeps working with the bundled binary.
#
# Usage:
#   bash scripts/build-ffmpeg-lgpl.sh              # build for the host arch
#   UNIVERSAL=1 bash scripts/build-ffmpeg-lgpl.sh  # arm64 + x86_64 + lipo
#   FFMPEG_VERSION=7.1 bash scripts/build-ffmpeg-lgpl.sh
#
# Requirements: Xcode CLT, yasm/nasm for x86_64 (brew install nasm), curl.
# Output: Resources/ffmpeg/{ffmpeg,ffprobe} + LICENSE.LGPL + BUILD-INFO.txt
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/AlphaSub/App/Resources/ffmpeg"
WORK="${FFMPEG_WORK_DIR:-$(mktemp -d)}"
KEEP_WORK="${FFMPEG_WORK_DIR:+1}"
[ -z "${KEEP_WORK}" ] && trap 'rm -rf "$WORK"' EXIT

echo "==> ffmpeg $FFMPEG_VERSION (LGPL) → $DEST"
mkdir -p "$DEST" "$WORK"

TARBALL="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
    echo "==> downloading source…"
    curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$TARBALL"
fi
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
[ -d "$SRC" ] || (cd "$WORK" && tar xf "$TARBALL")

# Minimal component set. --disable-everything, then whitelist.
CONFIG_COMMON=(
    --disable-gpl --disable-nonfree --disable-doc --disable-debug
    --disable-programs --enable-ffmpeg --enable-ffprobe
    --enable-static --disable-shared
    --disable-everything
    # --disable-everything does NOT stop external-library autodetection:
    # the native-arch pass found Homebrew's libX11 and dylib-linked it,
    # which dyld then refuses inside the signed app (Team ID mismatch —
    # broke DCP audio extraction on 1.5.0). Kill every desktop/display
    # dependency explicitly; devices are never used by AlphaSub.
    --disable-xlib --disable-libxcb --disable-sdl2
    --disable-indevs --disable-outdevs
    --enable-videotoolbox --enable-audiotoolbox

    # Encoders AlphaSub uses through ffmpeg.
    # prores_ks = the LGPL ProRes 4444 XQ encoder (AVFoundation rejects ap4x).
    # png + image2 = the still frames "Improve by Context" feeds to the
    # vision model (MediaClipExtractor writes frame_%04d.png).
    --enable-encoder=dnxhd,prores_ks,aac,pcm_s24le,pcm_s16le,mjpeg,png
    --enable-muxer=image2,image2pipe
    --enable-demuxer=image2,image2pipe
    --enable-decoder=png
    --enable-encoder=h264_videotoolbox,hevc_videotoolbox
    --enable-encoder=srt,ass,movtext,subrip,webvtt

    # Muxers (export) + demuxers (import/remux/extraction).
    # NB: the raw-PCM muxers are called `pcm_s16le`/`pcm_s24le` at configure
    # time even though ffmpeg lists (and `-f` takes) them as `s16le`/`s24le`.
    # Spelling them the short way here got them silently dropped, and audio
    # extraction died with "Requested output format 's16le' is not known".
    # configure ignores unknown component names without a word of warning —
    # the post-build check at the bottom of this script is the only guard.
    --enable-muxer=matroska,mov,mp4,mxf,wav,ipod,null,pcm_s16le,pcm_s24le,hls
    # rawvideo demuxer = the export engine's stdin pipe input (-f rawvideo).
    --enable-demuxer=rawvideo,matroska,mov,mpegts,wav,aac,mp3,flac,ogg,ass,srt,webvtt,mxf,avi

    # Decoders for MKV import remux/transcode + audio extraction + soft subs.
    --enable-decoder=h264,hevc,mpeg2video,mpeg4,vp8,vp9,av1,prores,dnxhd,mjpeg,rawvideo,jpeg2000
    --enable-decoder=aac,ac3,eac3,mp3,flac,vorbis,opus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le
    --enable-decoder=srt,ass,subrip,movtext,webvtt

    # Parsers/BSFs/protocols/filters the above need.
    --enable-parser=h264,hevc,mpegvideo,mpeg4video,aac,ac3,vp8,vp9,av1,mjpeg
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,aac_adtstoasc
    --enable-protocol=file,pipe
    # Filters. Missing ones are fatal at runtime ("No such filter: 'x'"),
    # not silently skipped: 7.1 shipped without `highpass` and every
    # transcription died in audio extraction. Keep this in sync with the
    # filter names used in Swift (grep for '"-af"' / '"-vf"').
    --enable-filter=scale,format,aresample,anull,null,pan,aformat,volume,concat
    --enable-filter=highpass,lowpass,fps,atrim,trim,amix,aselect,select,setpts,asetpts
    --enable-swscale --enable-swresample
)

build_arch() {  # $1 = arm64|x86_64
    local arch="$1"
    local prefix="$WORK/out-$arch"
    echo "==> configuring for ${arch}…"
    local build_dir="$WORK/build-$arch"
    rm -rf "$build_dir"; mkdir -p "$build_dir"
    local cross=""
    [ "$arch" != "$(uname -m)" ] && cross="--enable-cross-compile"
    (
        cd "$build_dir"
        # shellcheck disable=SC2086  # $cross is deliberately word-split (one flag or empty)
        "$SRC/configure" \
            --prefix="$prefix" \
            --arch="$arch" \
            --cc="clang -arch $arch" \
            $cross \
            --target-os=darwin \
            "${CONFIG_COMMON[@]}" > configure.log
        echo "==> building ${arch} (this takes a few minutes)…"
        make -j"$(sysctl -n hw.ncpu)" > build.log 2>&1
        make install > install.log 2>&1
    )
}

if [ "${UNIVERSAL:-0}" = "1" ]; then
    build_arch arm64
    build_arch x86_64
    for tool in ffmpeg ffprobe; do
        lipo -create "$WORK/out-arm64/bin/$tool" "$WORK/out-x86_64/bin/$tool" \
             -output "$DEST/$tool"
    done
else
    build_arch "$(uname -m)"
    for tool in ffmpeg ffprobe; do
        cp "$WORK/out-$(uname -m)/bin/$tool" "$DEST/$tool"
    done
fi
chmod +x "$DEST/ffmpeg" "$DEST/ffprobe"

# LGPL compliance: license text + build info (config line documents the
# LGPL configuration; source offer = the ffmpeg.org tarball URL + version).
cp "$SRC/COPYING.LGPLv2.1" "$DEST/LICENSE.LGPL"
cat > "$DEST/BUILD-INFO.txt" <<EOF
ffmpeg $FFMPEG_VERSION — LGPL v2.1+ build for AlphaSub
Source: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
Configured with: --disable-gpl --disable-nonfree (no GPL or nonfree
components are compiled in; see LICENSE.LGPL for terms).
Built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productVersion)
EOF

# Sanity: every component AlphaSub actually invokes must be in the binary.
# A missing one is not a graceful degradation — ffmpeg aborts the whole
# command ("No such filter: 'highpass'", "Requested output format 's16le'
# is not known"), which is how 1.5.5 shipped with transcription dead. These
# are ffmpeg's *runtime* names (what `-f`/`-af` take), which differ from the
# configure names above for the raw-PCM muxers.
check_components() {  # $1 = listing flag (filters|encoders|muxers|…), $@ = names
    local kind="$1"; shift
    local listing missing=()
    listing="$("$DEST/ffmpeg" -hide_banner "-$kind" 2>/dev/null)"
    for name in "$@"; do
        # Entries look like " TSC highpass  A->A  …" / " E s16le  PCM …",
        # and some (de)muxers share one line under comma-joined aliases
        # (" D  matroska,webm  Matroska / WebM"), so commas delimit too.
        grep -qE "(^|[[:space:],])$name([[:space:],]|$)" <<< "$listing" || missing+=("$name")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "✗ built ffmpeg is missing $kind: ${missing[*]}" >&2
        echo "  (check the --enable-$(sed 's/s$//' <<< "$kind")= names — configure" >&2
        echo "   ignores unknown component names silently)" >&2
        return 1
    fi
    echo "  ✓ $kind: $*"
}
echo "==> verifying components AlphaSub depends on…"
FAILED=0
check_components filters highpass pan fps scale format aresample concat || FAILED=1
check_components encoders dnxhd prores_ks aac pcm_s16le pcm_s24le png mjpeg \
    h264_videotoolbox hevc_videotoolbox || FAILED=1
check_components muxers matroska mov mp4 mxf wav s16le s24le image2 null || FAILED=1
check_components demuxers matroska mov mxf wav rawvideo image2 avi || FAILED=1
check_components decoders h264 hevc prores dnxhd jpeg2000 aac ac3 eac3 mp3 png || FAILED=1
if [ "$FAILED" -ne 0 ]; then
    echo "✗ the ffmpeg just installed into Resources/ cannot run AlphaSub's" >&2
    echo "  commands — fix the whitelist above and re-run before packaging." >&2
    exit 1
fi

# Sanity: the banner must NOT report --enable-gpl.
if "$DEST/ffmpeg" -version | head -3 | grep -q -- "--enable-gpl"; then
    echo "✗ built ffmpeg reports --enable-gpl — refusing to install" >&2
    exit 1
fi
"$DEST/ffmpeg" -version | head -2
echo "==> LGPL ffmpeg installed into Resources/ffmpeg/"

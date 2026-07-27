# Third-Party Components & Source Offer

AlphaSub bundles or links the open-source components below. This document is
the **written source offer** required by the LGPL/AGPL for the components we
redistribute in binary form. The same information is available inside the app
under **Help ▸ Open-Source Components…**, and the verbatim license texts ship
inside the app bundle next to each binary.

## Bundled subprocess tools

These run as **separate helper processes**; none is linked into AlphaSub.

### ffmpeg / ffprobe — LGPL-2.1-or-later
- **Version:** 7.1, built from the unmodified upstream tarball
  <https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz>
- **Configuration:** `--disable-gpl --disable-nonfree` — no GPL or non-free
  component is compiled in. The exact build script we use is public:
  [`scripts/build-ffmpeg-lgpl.sh`](scripts/build-ffmpeg-lgpl.sh)
  (also in the app bundle as `Resources/ffmpeg/BUILD-INFO.txt`).
- **License text:** bundled at `Resources/ffmpeg/LICENSE.LGPL`.
- Used for: DNxHD/DNxHR + ProRes 4444 XQ encode, MKV mux/import, mov_text,
  audio extraction.

### Grok (`grk_decompress`) — AGPL-3.0
- **Version:** v20.3.7, bundled **unmodified** (binary + dylib closure from the
  Homebrew `grokj2k` bottle).
- **Complete corresponding source:**
  <https://github.com/GrokImageCompression/grok> (tag `v20.3.7`).
- **Bundling script:** [`scripts/build-grok.sh`](scripts/build-grok.sh).
- **License text:** bundled at `Resources/grok/LICENSE-grok.txt`;
  AGPL-3.0 text at <https://www.gnu.org/licenses/agpl-3.0.txt>.
- Used for: real-time JPEG2000 decode during DCP playback.
- Its dylib closure (libtiff, libpng, libwebp/sharpyuv, liblcms2, liblzma,
  libzstd, libfmt, libjpeg) is under permissive/free licenses; sources for all
  of them are available from their upstream projects or `brew fetch --deps grokj2k`.

### asdcplib (`asdcp-unwrap`, `asdcp-info`) — BSD-3-Clause
- **Source:** <https://github.com/cinecert/asdcplib>, built without XML support
  by [`scripts/build-asdcp-tools.sh`](scripts/build-asdcp-tools.sh).
- Embedded `libcrypto` (OpenSSL 3) is Apache-2.0.
- **License text:** bundled at `Resources/asdcp/LICENSE-asdcplib.txt`.
- Used for: deep DCP QC (subtitle-content inspection).

## Spell-check dictionaries

Hunspell `.aff`/`.dic` files are fetched verbatim from
<https://github.com/wooorm/dictionaries> (per-language licenses — MPL, GPL,
LGPL, BSD… — accompany each dictionary upstream) and, for Arabic,
<https://sourceforge.net/projects/arramooz/>. Fetch script:
[`scripts/download_dictionaries.sh`](scripts/download_dictionaries.sh).
Dictionaries are data files read by the app; they are not linked code.

## Swift package dependencies (linked)

| Package | Source | License |
|---|---|---|
| mlx-swift | <https://github.com/ml-explore/mlx-swift> | MIT |
| mlx-swift-lm | <https://github.com/ml-explore/mlx-swift-lm> | MIT |
| swift-transformers | <https://github.com/huggingface/swift-transformers> | Apache-2.0 |
| FluidAudio | <https://github.com/FluidInference/FluidAudio> | Apache-2.0 |
| WhisperKit (argmax-oss fork) | <https://github.com/argmaxinc/WhisperKit> | MIT |

No copyleft code is linked into the AlphaSub binary.

---
If you cannot access any of the URLs above, write to <info@cobaltfilms.be> and
we will provide the corresponding source on physical media at cost.

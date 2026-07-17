# AlphaSub — open core

The open-source foundation of [**AlphaSub**](https://alpha-sub.com), a native
macOS subtitling app built by film-industry professionals.

This package is the **subtitle engine**: a frame-accurate data model and a set
of open subtitle **format handlers** (import/export). It's the same core the
AlphaSub app is built on, extracted as a reusable Swift package under Apache-2.0.

> The AlphaSub **application** — its editor UI, on-device AI (transcription,
> translation, diarization), professional broadcast/cinema delivery formats, and
> licensing — lives in a separate repository and is **not** part of this package.

## What's here

**`AlphaSubCore`** — the data model and format protocols:

- `SubtitleDocument` → `Track` → `Subtitle` → `TextBlock` → `TextSegment`
- `Timecode` — frame-accurate, SMPTE (`HH:MM:SS:FF`) + drop-frame (`;`) + millisecond parsing, stored as `Int64` frames + `FrameRate`
- `TextStyle` — an `OptionSet` for partial inline styling (italic, bold, underline, …)
- `FormatImporter` / `FormatExporter` protocols and the `FormatRegistry`

**`AlphaSubFormats`** — freely available format handlers:

| Format | Import | Export |
|---|:--:|:--:|
| SubRip (`.srt`) | ✅ | ✅ |
| WebVTT (`.vtt`) | ✅ | ✅ |
| TTML / IMSC (incl. DaVinci Resolve profile) | ✅ | ✅ |
| Advanced SubStation Alpha (`.ass`) | ✅ | ✅ |
| Final Cut Pro XML (`.fcpxml`) | ✅ | ✅ |
| Premiere Pro CC XML (`.xml`) | ✅ | ✅ |
| Avid DS/MC caption text (`.txt`) | ✅ | ✅ |
| Plain text (`.txt`) | ✅ | ✅ |
| Word (`.docx`) | — | ✅ |
| Excel (`.xlsx`) | ✅ | ✅ |

Professional delivery formats (EBU STL, SCC/CEA-608/708, DCP SMPTE & InterOp, and
the Netflix / Amazon / iTunes TTML profiles) are part of the AlphaSub app, not
this package.

## Usage

```swift
import AlphaSubCore
import AlphaSubFormats

// Register the bundled format handlers once.
registerAllFormats()

// Parse an .srt file…
let data = try Data(contentsOf: url)
let tracks = try SRTImporter.import(data, options: nil)

// …and write it back out as WebVTT.
let vtt = try WebVTTExporter.export(tracks, options: nil)
```

Add it to your `Package.swift`:

```swift
.package(url: "https://github.com/cobaltfilms/AlphaSub.git", branch: "main")
```

## Build & test

```bash
swift build
swift test
```

Requires macOS 14+ and a recent Swift toolchain.

## About

AlphaSub is a professional, native macOS subtitling tool. The app is free to
author and edit with; broadcast and cinema delivery formats are a paid Pro
feature. Learn more at **[alpha-sub.com](https://alpha-sub.com)**.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

import Foundation
import AlphaSubCore

// MARK: - DCP InterOp (DLP Cinema CineCanvas) Importer

/// DLP Cinema InterOp (CineCanvas v1.1) subtitle format importer.
/// Tick-based timecodes (1 tick = 4ms = 1/250s) with font and positioning.
public struct DCPInterOpImporter: FormatImporter {
    public static let formatID = FormatID.dcp_interop
    public static let formatName = String(localized: "DLP Cinema InterOp (CineCanvas)")
    public static let fileExtensions = ["xml"]

    public static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        return str.contains("DCSubtitle")
            && (str.contains("Version=\"1.0\"") || str.contains("Version=\"1.1\""))
            && !str.contains("SubtitleReel")
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw FormatError.unsupportedEncoding("Cannot decode DCP InterOp data")
        }

        let doc = try XMLDocument(xmlString: str, options: [])
        guard let root = doc.rootElement() else {
            throw FormatError.invalidData("No root element in DCP InterOp XML")
        }

        // CineCanvas declares its rate in <TimeCodeRate>; honour it when present
        // (real InterOp deliveries are 24 fps, but the element is authoritative)
        // and only fall back to 24 when the file omits it.
        let detectedRate = parseInteropRate(root)
        let frameRate = opts.targetFrameRate ?? detectedRate ?? .fps24

        let title = childString(root, localName: "MovieTitle") ?? "DCP InterOp Import"
        let rawLanguage = childString(root, localName: "Language") ?? ""

        // Resolve the <Language> value. DCP <Language> is the ISDCF DCNC tag
        // (uppercase, e.g. "FR", "EUS", "ZHS", "LAS"). Older or non-conformant
        // files may emit lowercase BCP-47 ("fr", "en-US"). Handle both.
        // Composite codes like "EN-FR" are preserved as raw and stored in
        // metadata; we only use the primary subtag for the model's language.
        let resolvedLanguage: String
        if let dash = rawLanguage.firstIndex(of: "-") {
            // Composite — preserve raw, use first segment for primary
            let primary = String(rawLanguage[..<dash])
            let language = importResolveLanguage(primary)
            resolvedLanguage = language
        } else {
            resolvedLanguage = importResolveLanguage(rawLanguage)
        }

        var metadata: FormatMetadata = [
            "dcp_namespace": "interop",
        ]
        if !rawLanguage.isEmpty {
            metadata["dcp_language_raw"] = rawLanguage
        }

        if let loadFont = findElement(root, localName: "LoadFont") {
            if let fontId = loadFont.attribute(forName: "Id")?.stringValue ?? loadFont.attribute(forName: "ID")?.stringValue {
                metadata["dcp_font_id"] = fontId
            }
            if let fontUri = loadFont.attribute(forName: "URI")?.stringValue {
                metadata["dcp_font_uri"] = fontUri
            }
        }

        if let fontElem = findElement(root, localName: "Font") {
            if let color = fontElem.attribute(forName: "Color")?.stringValue {
                metadata["dcp_font_color"] = color
            }
            if let size = fontElem.attribute(forName: "Size")?.stringValue {
                metadata["dcp_font_size"] = size
            }
            if let effect = fontElem.attribute(forName: "Effect")?.stringValue {
                metadata["dcp_font_effect"] = effect
            }
        }

        let subtitleElems = findElements(root: root, localName: "Subtitle")
        var subtitles: [Subtitle] = []

        for subElem in subtitleElems {
            guard let startStr = subElem.attribute(forName: "TimeIn")?.stringValue,
                  let endStr = subElem.attribute(forName: "TimeOut")?.stringValue,
                  let startTC = parseInteropTimecode(startStr, frameRate: frameRate),
                  let endTC = parseInteropTimecode(endStr, frameRate: frameRate)
            else { continue }

            // <Text> may be wrapped in <Font> elements inside <Subtitle> (the
            // standard way whole-cue italics are written) — walk the subtree
            // instead of only the direct children, inheriting the Font style.
            let textElems = DCPTextTree.texts(in: subElem)
            var textBlocks: [TextBlock] = []

            for (textElem, inheritedStyle, inheritedColor) in textElems {
                let segments = parseInteropTextSegments(textElem,
                                                        baseStyle: inheritedStyle,
                                                        baseColor: inheritedColor)
                textBlocks.append(TextBlock(segments: segments))
            }

            let position = parseInteropPosition(textElems.map(\.elem))

            subtitles.append(Subtitle(
                startTime: startTC,
                endTime: endTC,
                textBlocks: textBlocks,
                verticalPosition: position.vertical,
                horizontalPosition: position.horizontal,
                alignment: position.alignment,
                useCustomPosition: position.hasCustomPosition
            ))
        }

        return [Track(
            name: title,
            language: LanguageCode(resolvedLanguage),
            subtitles: subtitles,
            formatOrigin: "dcp_interop",
            metadata: metadata,
            frameRate: opts.targetFrameRate ?? detectedRate ?? .fps24
        )]
    }

    // MARK: - Parsing

    /// Read the CineCanvas <TimeCodeRate> (a single integer such as 24/25/30).
    /// Returns nil when the element is missing or unrecognised so the caller can
    /// fall back to 24.
    private static func parseInteropRate(_ root: XMLElement) -> FrameRate? {
        guard let raw = findElement(root, localName: "TimeCodeRate")?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let fps = Double(raw.split(separator: " ").first.map(String.init) ?? raw)
        else { return nil }
        for rate in FrameRate.allCases where abs(rate.value - fps) < 0.01 {
            return rate
        }
        return nil
    }

    private static func parseInteropTimecode(_ str: String, frameRate: FrameRate) -> Timecode? {
        let s = str.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.hasSuffix("s") {
            let numStr = String(s.dropLast())
            if let seconds = Double(numStr) {
                return Timecode.fromSeconds(seconds, frameRate: frameRate)
            }
        }

        let parts = s.components(separatedBy: ":")
        guard parts.count == 4 else { return nil }
        let ticksStr = parts[3].components(separatedBy: ".").first ?? parts[3]
        guard let h = Int(parts[0]), let m = Int(parts[1]),
              let sec = Int(parts[2]),
              let ticks = Int(ticksStr)
        else { return nil }

        // The 4th field is TICKS: 1 tick = 1/250 s = 4 ms (range 0–249).
        let totalMs = (h * 3600 + m * 60 + sec) * 1000 + ticks * 4
        let totalSeconds = Double(totalMs) / 1000.0
        return Timecode.fromSeconds(totalSeconds, frameRate: frameRate)
    }

    private struct InteropPosition {
        var vertical: VerticalPosition
        var horizontal: HorizontalPosition
        var alignment: TextAlignment
        var hasCustomPosition: Bool
    }

    private static func parseInteropPosition(_ textElems: [XMLElement]) -> InteropPosition {
        var vpos: VerticalPosition = .safeArea(.bottom)
        var hpos: HorizontalPosition = .centered
        var align: TextAlignment = .center
        var hasCustom = false

        // VPosition/HPosition are PERCENT offsets from the VAlign/HAlign
        // anchors (validated sample: VPosition="8.0" VAlign="bottom"). For
        // multi-line cues the LAST <Text> is the baseline line (lines stack
        // upward from the anchor), so iterate without breaking.
        for textElem in textElems {
            let va = textElem.attribute(forName: "VAlign")?.stringValue?.lowercased() ?? "bottom"
            let vp = textElem.attribute(forName: "VPosition")?.stringValue.flatMap(Double.init)
            let ha = textElem.attribute(forName: "HAlign")?.stringValue?.lowercased()
            let hp = textElem.attribute(forName: "HPosition")?.stringValue.flatMap(Double.init)

            // HPosition is an offset FROM the HAlign anchor, not an absolute
            // left-origin percent — compose the two so a centred cue
            // (HAlign="center" HPosition="0") stays centred instead of snapping
            // to the left edge.
            if ha != nil || hp != nil {
                let placement = DCPHorizontal.placement(halign: ha, hposition: hp)
                hpos = placement.0
                align = placement.1
            }

            switch va {
            case "top":
                vpos = vp.map { .percentage(min(100, max(0, $0))) } ?? .safeArea(.top)
            case "center":
                if let vp, vp != 0 {
                    vpos = .percentage(min(100, max(0, 50.0 - vp)))
                } else {
                    vpos = .safeArea(.center)
                }
            default: // bottom
                if let vp {
                    vpos = .percentage(min(100, max(0, 100.0 - vp)))
                }
            }

            // Only flag as custom when it deviates from the house default
            // (bottom-anchored at the standard 8 %, centered) — otherwise
            // every cue of a normal file would carry a custom position.
            let isDefaultV = (va == "bottom") && (vp == nil || abs(vp! - 8.0) < 0.05 || abs(vp! - 15.0) < 0.05)
            let isDefaultH = (ha == nil || ha == "center") && (hp == nil || hp == 0)
            if !(isDefaultV && isDefaultH) {
                hasCustom = true
            }
        }

        return InteropPosition(vertical: vpos, horizontal: hpos, alignment: align, hasCustomPosition: hasCustom)
    }

    private static func parseInteropTextSegments(_ textElem: XMLElement,
                                                 baseStyle: TextStyle = [],
                                                 baseColor: TextColor? = nil) -> [TextSegment] {
        var segments: [TextSegment] = []

        for child in (textElem.children ?? []).compactMap({ $0 as? XMLElement }) {
            let localName = resolveLocalName(child.name)
            if localName == "Font" {
                var style: TextStyle = baseStyle
                if child.attribute(forName: "Italic")?.stringValue == "yes" { style.insert(.italic) }
                if child.attribute(forName: "Weight")?.stringValue == "bold" { style.insert(.bold) }
                // Colour was being dropped here too (#50).
                let color = child.attribute(forName: "Color")?.stringValue
                    .flatMap(DCPColor.textColor(fromHex:)) ?? baseColor
                if let text = child.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !text.isEmpty {
                    segments.append(TextSegment(text: text, style: style, color: color))
                }
            }
        }

        if segments.isEmpty {
            if let text = textElem.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !text.isEmpty {
                segments.append(TextSegment(text: text, style: baseStyle, color: baseColor))
            }
        }

        return segments
    }

    private static func findElement(_ root: XMLElement, localName: String) -> XMLElement? {
        func walk(_ elem: XMLElement) -> XMLElement? {
            if resolveLocalName(elem.name) == localName { return elem }
            for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(root)
    }

    private static func findElements(root: XMLElement, localName: String) -> [XMLElement] {
        var results: [XMLElement] = []
        func walk(_ elem: XMLElement) {
            if resolveLocalName(elem.name) == localName {
                results.append(elem)
            }
            for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) {
                walk(child)
            }
        }
        walk(root)
        return results
    }

    private static func resolveLocalName(_ name: String?) -> String {
        guard let name = name else { return "" }
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    /// Read a child's text content by local name, working around a quirk
    /// in NSXMLDocument where `elements(forLocalName:uri:)` returns no
    /// matches for top-level children of a namespaceless root.
    private static func childString(_ parent: XMLElement, localName: String) -> String? {
        for child in (parent.children ?? []).compactMap({ $0 as? XMLElement }) {
            if resolveLocalName(child.name) == localName {
                return child.stringValue
            }
        }
        return nil
    }

    /// Convert a raw <Language> element value to canonical BCP-47.
    /// Handles DCNC tags (uppercase, e.g. "FR"), lowercase BCP-47 ("fr"),
    /// and DCNC composites' first segment. Empty string passes through.
    private static func importResolveLanguage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Try DCNC first (uppercase). If the string is all uppercase, it's
        // almost certainly a DCNC tag. If lowercase or mixed, it's BCP-47.
        if trimmed == trimmed.uppercased() {
            if let bcp47 = ISDCFDCNCTable.bcp47(forDCNCTag: trimmed) {
                return bcp47
            }
            // Unknown uppercase tag — pass through uppercase (round-trip safety)
            return trimmed
        }
        // Lowercase / mixed → treat as BCP-47, canonicalise
        return LanguageCode.canonicalize(trimmed)
    }
}

/// Minimal fallback DCNC lookup so this module does not need to depend on
/// AlphaSubLanguage. If Language is linked in, `LanguageBaliseProvider.dcnc`
/// (installed by `LanguageBaliseWiring.install()`) is used preferentially
/// elsewhere. This enum only covers the most common tags for safe round-trip.
private enum ISDCFDCNCTable {
    private static let map: [String: String] = [
        "AA": "aa", "AF": "af", "SQ": "sq", "AM": "am", "AR": "ar",
        "HY": "hy", "AS": "as", "AZ": "az", "BA": "ba", "BE": "be",
        "BN": "bn", "BS": "bs", "BG": "bg", "MY": "my", "CA": "ca",
        "ZH": "zh", "ZHS": "zh-Hans", "ZHT": "zh-Hant", "HR": "hr",
        "CS": "cs", "DA": "da", "DE": "de", "DV": "dv", "NL": "nl",
        "EN": "en", "EUS": "en-US", "EGB": "en-GB", "EAU": "en-AU",
        "ET": "et", "FI": "fi", "FR": "fr", "FRCA": "fr-CA", "KA": "ka",
        "DEA": "de-AT", "DCH": "de-CH", "EL": "el",
        "GU": "gu", "HE": "he", "HI": "hi", "HU": "hu", "IS": "is",
        "ID": "id", "IT": "it", "JA": "ja", "KK": "kk", "KM": "km",
        "KN": "kn", "KO": "ko", "KY": "ky", "LO": "lo", "LV": "lv",
        "LT": "lt", "MK": "mk", "MS": "ms", "ML": "ml", "MR": "mr",
        "MN": "mn", "NE": "ne", "NO": "no", "FA": "fa", "PL": "pl",
        "PT": "pt", "PA": "pa", "RO": "ro", "RU": "ru", "SR": "sr",
        "SI": "si", "SK": "sk", "SL": "sl", "ES": "es", "LAS": "es-419",
        "QSM": "es-MX", "SW": "sw", "SV": "sv", "TA": "ta", "TE": "te",
        "TG": "tg", "TH": "th", "TR": "tr", "TK": "tk", "UK": "uk",
        "UR": "ur", "UZ": "uz", "VI": "vi", "CY": "cy", "YI": "yi",
        "UND": "und", "XX": "",
    ]
    static func bcp47(forDCNCTag tag: String) -> String? {
        map[tag.uppercased()]
    }
}

// MARK: - DCP InterOp (DLP Cinema CineCanvas) Exporter

public struct DCPInterOpExporter: FormatExporter {
    public static let formatID = FormatID.dcp_interop
    public static let formatName = String(localized: "DLP Cinema InterOp (CineCanvas)")
    public static let fileExtension = "xml"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        let opts = options ?? ExportOptions()
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        // InterOp/CineCanvas timecodes are tick-based (1 tick = 1/250 s = 4 ms),
        // derived from wall-clock seconds — the tick format itself does not
        // depend on the source frame rate, so any project rate *exports*
        // correctly. However, real InterOp deliveries are 24 fps only:
        // `ConformanceValidator.frameRateIssue(formatID:...)` flags non-24
        // rates as an error so users know to retime or switch to DCP SMPTE.

        // Declare the reel's frame rate so importers (ours and others) can
        // recover it. Tick-based times stay rate-independent; this is metadata.
        let frameRate = opts.sourceFrameRate ?? track.subtitles.first?.startTime.frameRate ?? .fps24
        let fpsInt = Int(frameRate.value.rounded())

        let fontId = track.metadata["dcp_font_id"] ?? "FontID"
        let fontUri = interopFontURI(track: track, opts: opts)
        let fontColor = track.metadata["dcp_font_color"] ?? "FFF2F2F2"
        // Effect is optional — the validated sample carries none. Emit it only
        // when the user explicitly chose a border.
        let effectAttrs: String
        if let bw = opts.borderWidth, bw > 0 {
            let effect = track.metadata["dcp_font_effect"] ?? "border"
            let effectColor = track.metadata["dcp_font_effectColor"] ?? dcpInterOpColor(fromHex: opts.borderColor ?? "000000")
            effectAttrs = " Effect=\"\(effect)\" EffectColor=\"\(effectColor)\""
        } else {
            effectAttrs = ""
        }
        let fontWeight: String
        if opts.boldFont {
            fontWeight = "bold"
        } else if let metaWeight = track.metadata["dcp_font_weight"] {
            fontWeight = metaWeight
        } else {
            fontWeight = "normal"
        }
        let fontSize: String
        if let userSize = opts.fontSize {
            fontSize = String(Int(userSize.rounded()))
        } else if let userSize = track.metadata["dcp_font_size"] {
            fontSize = userSize
        } else {
            fontSize = "40"
        }

        let baseVPosition: Double = {
            if let v = opts.vPosition { return v }
            if case .percentage(let pct) = track.defaultVerticalPosition {
                return max(0.0, min(100.0, 100.0 - pct))
            }
            return 8.0
        }()
        let lineHeight: Double = opts.lineHeight ?? 7.0
        // AspectAdjust: prefer track metadata (set via the DCP Subtitle
        // Settings sheet), else 1.00. Previously hardcoded to "1.00".
        let fontAspect = track.metadata["dcp_font_aspect"] ?? "1.00"

        // The subtitle resource's Id and reel number. The package writer
        // passes the CPL asset UUID (dcp_resource_id) — CineCanvas requires
        // the XML's SubtitleID to match the CPL MainSubtitle/Id (ClairMeta's
        // "Subtitle UUID coherence") — and the reel's 1-based position
        // (dcp_reel_number) for multi-reel coherence. Standalone exports
        // fall back to a fresh UUID / reel 1.
        let subUUID = opts.extra["dcp_resource_id"] ?? UUID().uuidString.lowercased()
        let reelNumber = opts.extra["dcp_reel_number"] ?? "1"

        // Structure pinned to an EasyDCP-accepted InterOp sample
        // (ENGLISH FULL.xml): explicit LoadFont close, Weight/AspectAdjust on
        // Font, FadeUp/DownTime="0" on Subtitle, Text carries
        // VPosition/HAlign/Direction="horizontal"/HPosition/VAlign with
        // PERCENT values anchored by the align attributes (not 0–1 fractions).
        // Bilingual tracks emit "MUL" by default (see dcpLanguageBalise); the
        // export dialog can force the primary language instead.
        let bilingualUsesMul = (opts.extra["dcp_bilingual_lang"] ?? "mul") != "primary"
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DCSubtitle Version="1.1">
        <SubtitleID>\(subUUID)</SubtitleID>
        <MovieTitle>\(escapeXML(track.name))</MovieTitle>
        <!--DLP/Interop subtitle file-->
        <ReelNumber>\(reelNumber)</ReelNumber>
        <Language>\(track.dcpLanguageBalise(for: .dcp_interop, bilingualUsesMul: bilingualUsesMul))</Language>
        <TimeCodeRate>\(fpsInt)</TimeCodeRate>
        <!--Supply font with file name: \(fontUri)-->
        <LoadFont Id="\(fontId)" URI="\(fontUri)"></LoadFont>
        <Font Id="\(fontId)" Color="\(fontColor)" Weight="\(fontWeight)" Size="\(fontSize)" AspectAdjust="\(fontAspect)"\(effectAttrs)>
        """

        for (index, sub) in track.subtitles.enumerated() {
            let spotNum = index + 1
            let timeIn = formatInteropTime(sub.startTime)
            let timeOut = formatInteropTime(sub.endTime)
            let effective = track.effectivePosition(for: sub)

            xml += """

            <Subtitle SpotNumber="\(spotNum)" TimeIn="\(timeIn)" TimeOut="\(timeOut)" FadeUpTime="0" FadeDownTime="0">
            """

            for (blockIdx, block) in sub.textBlocks.enumerated() {
                let vpos = formatInteropVPosition(effective.vertical, blockIndex: blockIdx, totalBlocks: sub.textBlocks.count, baseVPosition: baseVPosition, lineHeight: lineHeight)
                let placement = DCPHorizontal.attributes(horizontal: effective.horizontal, alignment: effective.alignment)
                let hpos = String(format: "%.1f", placement.hposition)
                let halign = placement.halign
                let valign = formatInteropVAlign(effective.vertical)
                let plainText = block.segments.map { segment in
                    // Italics and per-run colour both ride on a wrapping <Font>;
                    // the colour only needs writing when it differs from the
                    // track default already set on the outer <Font> (#50).
                    var attrs = ""
                    if segment.style.contains(.italic) { attrs += " Italic=\"yes\"" }
                    if let c = segment.color, DCPColor.hex(from: c) != fontColor.uppercased() {
                        attrs += " Color=\"\(DCPColor.hex(from: c))\""
                    }
                    guard !attrs.isEmpty else { return escapeXML(segment.text) }
                    return "<Font\(attrs)>\(escapeXML(segment.text))</Font>"
                }.joined()

                xml += """

                <Text VPosition="\(vpos)" HAlign="\(halign)" Direction="horizontal" HPosition="\(hpos)" VAlign="\(valign)">\(plainText)</Text>
                """
            }

            xml += "\n      </Subtitle>"
        }

        xml += """

        </Font>
        </DCSubtitle>
        """

        guard let data = xml.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode DCP InterOp XML as UTF-8")
        }
        return data
    }

    /// InterOp time: HH:MM:SS:TTT where TTT is TICKS (1 tick = 1/250 s = 4 ms,
    /// range 000–249) — NOT milliseconds. Derived from wall-clock seconds, so
    /// the source frame rate is irrelevant.
    private static func formatInteropTime(_ tc: Timecode) -> String {
        let totalSeconds = max(0, tc.seconds)
        var whole = Int(totalSeconds)
        var ticks = Int(((totalSeconds - Double(whole)) * 250.0).rounded())
        if ticks >= 250 { ticks -= 250; whole += 1 }
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = whole % 60
        return String(format: "%02d:%02d:%02d:%03d", h, m, s, ticks)
    }

    private static func formatInteropVAlign(_ pos: VerticalPosition) -> String {
        switch pos {
        case .safeArea(.top): return "top"
        case .safeArea(.center): return "center"
        default: return "bottom"
        }
    }

    /// VPosition: PERCENT of screen height measured from the VAlign anchor
    /// (the validated sample uses VPosition="8.0" VAlign="bottom" = 8 % above
    /// the bottom edge) — not a 0–1 fraction from the top.
    private static func formatInteropVPosition(_ pos: VerticalPosition, blockIndex: Int, totalBlocks: Int, baseVPosition: Double = 8.0, lineHeight: Double = 7.0) -> String {
        switch pos {
        case .percentage(let pct):
            // Our model: 0 = top, 100 = bottom; anchored bottom ⇒ distance up
            // from the bottom edge. The stored percentage is the BASELINE
            // (bottom-most) line; earlier blocks stack upward by `lineHeight`
            // so a multi-line custom-positioned cue renders like a regular
            // bottom-anchored cue (top line higher).
            let base = 100.0 - pct
            let vpos = base + Double(totalBlocks - 1 - blockIndex) * lineHeight
            return String(format: "%.1f", max(0.0, min(100.0, vpos)))
        case .safeArea(.center):
            return "0.0"   // at the center anchor
        case .safeArea(.top):
            return String(format: "%.1f", baseVPosition)
        default: // bottom-anchored default, lines stacked upward
            if totalBlocks == 2 {
                return String(format: "%.1f", blockIndex == 0 ? (baseVPosition + lineHeight) : baseVPosition)
            }
            return String(format: "%.1f", baseVPosition)
        }
    }

    private static func escapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func exportToFiles(_ tracks: [Track], options: ExportOptions?) throws -> ExportResult {
        let opts = options ?? ExportOptions()
        let xmlData = try export(tracks, options: options)
        let trackName = tracks.first?.name ?? "exported"
        let sanitizedName = trackName
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let xmlFilename = sanitizedName.isEmpty ? "exported.xml" : "\(sanitizedName).xml"

        var files: [ExportResult.ExportFile] = [
            ExportResult.ExportFile(filename: xmlFilename, data: xmlData)
        ]

        if let fontData = opts.fontData {
            // CineCanvas caps the embedded font at 640 KB. Full fonts (Arial:
            // ~770 KB) exceed it, so subset to the glyphs the subtitles use —
            // the standard mastering-tool approach. Validated by re-loading
            // the subset with CoreText before shipping it.
            let limitedFontData = try FontSubsetter.limitForDCP(fontData: fontData, tracks: tracks)
            let fontURI = interopFontURI(track: tracks.first, opts: opts)
            files.append(ExportResult.ExportFile(filename: fontURI, data: limitedFontData))
        }

        return ExportResult(files: files)
    }

    /// Font filename for the XML's LoadFont URI and the bundled asset — named
    /// after the actual font ("Arial" → "Arial.ttf"), like the validated
    /// sample. The user's chosen export font wins; an imported file's original
    /// URI is kept on round-trip; "font.ttf" only as a last resort.
    static func interopFontURI(track: Track?, opts: ExportOptions) -> String {
        if let name = opts.fontName {
            let sanitized = name
                .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|"))
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sanitized.isEmpty { return "\(sanitized).ttf" }
        }
        return track?.metadata["dcp_font_uri"] ?? "font.ttf"
    }

    private static func dcpInterOpColor(fromHex hex: String) -> String {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let chars = Array(clean)
        if chars.count == 6 {
            return "FF" + String(chars[0]) + String(chars[1]) + String(chars[2]) + String(chars[3]) + String(chars[4]) + String(chars[5])
        } else if chars.count == 8 {
            return String(chars)
        }
        return "FF000000"
    }
}
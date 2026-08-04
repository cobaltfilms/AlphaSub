import Foundation
import AlphaSubCore

/// SMPTE 428-7 schema versions AlphaSub can export. Mirrors the enum in
/// `AlphaSubLanguage.DCPSchemaVersion` but lives in Formats so this module
/// does not need to depend on Language. `LanguageBaliseWiring.install()`
/// will register the same lookups in Core's `LanguageBaliseProvider`.
private enum SMPTESchemaVersion {
    case v2007
    case v2010
    case v2014
    case latest

    var namespaceURI: String {
        switch self {
        case .v2007:  return "http://www.smpte-ra.org/schemas/428-7/2007/DCST"
        case .v2010:  return "http://www.smpte-ra.org/schemas/428-7/2010/DCST"
        case .v2014:  return "http://www.smpte-ra.org/schemas/428-7/2014/DCST"
        case .latest: return "http://www.smpte-ra.org/schemas/428-7/2014/DCST"
        }
    }

    /// Whether `<Text>` should include `Direction` and `Hposition` attributes.
    var supportsTextDirection: Bool { self != .v2007 }

    /// Whether `<Subtitle>` should include `FadeUpTime` / `FadeDownTime`.
    var supportsFadeTimes: Bool { self != .v2007 }

    /// `<LoadFont>` attribute name, validated against an EasyDCP-accepted
    /// 2014 sample (Zejtune_EN CC): every version carries the attribute, with
    /// uppercase `ID` in 2007 AND 2014; only 2010 uses mixed-case `Id`.
    /// EasyDCP error 60003 ("attribute 'Id' is not allowed") on a 2014 file
    /// means the attribute NAME was wrong (`Id` vs `ID`), not that 2014
    /// forbids it — omitting it breaks the symbolic Font ID → LoadFont ID
    /// resolution ("Font ID invalid" / "UUID has invalid format").
    var loadFontAttributeCase: String { self == .v2010 ? "Id" : "ID" }
}

// MARK: - DCP SMPTE ST 428-7 Importer

/// SMPTE ST 428-7 DCDM Subtitle format importer.
/// Used for SMPTE DCP cinema subtitles with frame-based timecodes.
public struct DCPSMPTEImporter: FormatImporter {
    public static let formatID = FormatID.dcp_smpte
    public static let formatName = String(localized: "DCP SMPTE ST 428-7 (DCDM)")
    public static let fileExtensions = ["xml"]

    public static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        return str.contains("http://www.smpte-ra.org/schemas/428-7")
            || (str.contains("SubtitleReel") && str.contains("DCST"))
            || (str.contains("<SubtitleReel") && str.contains("<SubtitleList"))
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw FormatError.unsupportedEncoding("Cannot decode DCP SMPTE data")
        }

        let doc = try XMLDocument(xmlString: str, options: [])
        guard let root = doc.rootElement() else {
            throw FormatError.invalidData("No root element in DCP SMPTE XML")
        }

        let editRate = parseEditRate(root)
        let frameRate = opts.targetFrameRate ?? editRate ?? .fps25
        let title = root.elements(forLocalName: "ContentTitleText", uri: nil).first?.stringValue
            ?? root.elements(forLocalName: "AnnotationText", uri: nil).first?.stringValue
            ?? "DCP SMPTE Import"
        // Detect SMPTE schema version from the namespace URI
        let detectedSchema = detectSchemaVersion(root)
        var metadata: FormatMetadata = ["dcp_namespace": detectedSchema.uriSuffix]
        metadata["smpte_schema_version"] = detectedSchema.versionString
        let rawLanguage = findLanguageElement(in: root) ?? ""
        if !rawLanguage.isEmpty {
            metadata["dcp_language_raw"] = rawLanguage
        }
        let language = importResolveLanguage(rawLanguage)

        if let loadFont = findElement(root, localName: "LoadFont") {
            // 2007 uses ID, 2010 uses Id; 2014 has neither (URN-only reference).
            if let fontId = loadFont.attribute(forName: "ID")?.stringValue
                ?? loadFont.attribute(forName: "Id")?.stringValue {
                metadata["dcp_font_id"] = fontId
            }
            if let fontUrn = loadFont.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) {
                metadata["dcp_font_urn"] = fontUrn
            }
        }

        if let fontElem = findElement(root, localName: "Font") {
            if let color = fontElem.attribute(forName: "Color")?.stringValue {
                metadata["dcp_font_color"] = color
            }
            if let size = fontElem.attribute(forName: "Size")?.stringValue {
                metadata["dcp_font_size"] = size
            }
            if let weight = fontElem.attribute(forName: "Weight")?.stringValue {
                metadata["dcp_font_weight"] = weight
            }
            if let effect = fontElem.attribute(forName: "Effect")?.stringValue {
                metadata["dcp_font_effect"] = effect
            }
            if let effectColor = fontElem.attribute(forName: "EffectColor")?.stringValue {
                metadata["dcp_font_effectColor"] = effectColor
            }
            if let effectSize = fontElem.attribute(forName: "EffectSize")?.stringValue {
                metadata["dcp_font_effectSize"] = effectSize
            }
        }

        if let idElem = root.elements(forLocalName: "Id", uri: nil).first?.stringValue {
            metadata["dcp_reel_id"] = idElem.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let subtitleElems = findElements(root: root, localName: "Subtitle")
        var subtitles: [Subtitle] = []

        for subElem in subtitleElems {
            guard let startStr = subElem.attribute(forName: "TimeIn")?.stringValue,
                  let endStr = subElem.attribute(forName: "TimeOut")?.stringValue,
                  let startTC = parseSMPTE428Timecode(startStr, frameRate: frameRate),
                  let endTC = parseSMPTE428Timecode(endStr, frameRate: frameRate)
            else { continue }

            var textBlocks: [TextBlock] = []
            var vposSum: Double = 0
            var vposCount: Double = 0
            var parsedHpos: HorizontalPosition = .centered
            var parsedAlign: TextAlignment = .center
            var parsedVertical: VerticalPosition = .safeArea(.bottom)
            var hasPositionData = false
            var explicitValign: SafeAreaPosition? = nil

            // <Text> may be wrapped in <Font> elements inside <Subtitle> (the
            // standard way whole-cue italics are written) — walk the subtree
            // instead of only the direct children, inheriting the Font style.
            for (textElem, inheritedStyle, inheritedColor) in DCPTextTree.texts(in: subElem) {
                let vpos = parseVPosition(textElem)
                vposSum += vpos
                vposCount += 1

                let halignStr = textElem.attribute(forName: "Halign")?.stringValue
                let hposVal = textElem.attribute(forName: "Hposition")?.stringValue.flatMap(Double.init)
                if halignStr != nil || hposVal != nil {
                    // Hposition is an offset FROM the Halign anchor, not an
                    // absolute left-origin percent — compose the two so a
                    // centred cue (Halign="center" Hposition="0") stays centred
                    // instead of snapping to the left edge.
                    let placement = DCPHorizontal.placement(halign: halignStr, hposition: hposVal)
                    parsedHpos = placement.0
                    parsedAlign = placement.1
                    hasPositionData = true
                }
                if let va = textElem.attribute(forName: "Valign")?.stringValue {
                    switch va.lowercased() {
                    case "top": explicitValign = .top
                    case "center": explicitValign = .center
                    default: explicitValign = .bottom
                    }
                    hasPositionData = true
                }

                let segments = parseDCPTextSegments(textElem,
                                                    baseStyle: inheritedStyle,
                                                    baseColor: inheritedColor)
                textBlocks.append(TextBlock(segments: segments))
            }

            // Resolve vertical position:
            // - If an explicit Valign was provided, combine it with the average
            //   Vposition numeric to produce a precise percentage (our model:
            //   0 = top, 100 = bottom). SMPTE Vposition is the offset from the
            //   Valign anchor: Valign=bottom, Vposition=14 → 14% from bottom →
            //   86% from top → .percentage(86).
            // - If no Valign, fall back to the legacy heuristic (avgVpos>10 →
            //   percentage, else safeArea(.bottom)).
            let avgVpos = vposCount > 0 ? vposSum / vposCount : 8.0
            if let valign = explicitValign {
                let pct: Double
                switch valign {
                case .top:    pct = avgVpos
                case .center: pct = 50.0
                case .bottom: pct = max(0.0, min(100.0, 100.0 - avgVpos))
                }
                parsedVertical = .percentage(pct)
            } else if hasPositionData {
                // Has Hposition/Halign but no Valign — use safeArea default.
                parsedVertical = .safeArea(.bottom)
            } else if avgVpos > 10.0 {
                parsedVertical = .percentage(100.0 - avgVpos)
            } else {
                parsedVertical = .safeArea(.bottom)
            }

            subtitles.append(Subtitle(
                startTime: startTC,
                endTime: endTC,
                textBlocks: textBlocks,
                verticalPosition: parsedVertical,
                horizontalPosition: parsedHpos,
                alignment: parsedAlign,
                useCustomPosition: hasPositionData
            ))
        }

        // <StartTime> declares the reel's timeline origin — theatrical reels
        // commonly start at 01:00:00:00, with every TimeIn on that base. Keep
        // it as the track's timecode offset so the cues line up with a
        // zero-based video (the timeline/preview subtract the offset) instead
        // of sitting an hour off the right edge of the timeline.
        var startTimeOffset: Timecode? = nil
        if let startStr = findElement(root, localName: "StartTime")?.stringValue,
           let startTC = parseSMPTE428Timecode(startStr, frameRate: frameRate),
           startTC.totalFrames > 0 {
            startTimeOffset = startTC
            metadata["dcp_start_time"] = startStr.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return [Track(
            name: title,
            language: LanguageCode(language),
            subtitles: subtitles,
            formatOrigin: "dcp_smpte",
            timecodeOffset: startTimeOffset,
            metadata: metadata,
            frameRate: opts.targetFrameRate ?? editRate
        )]
    }

    // MARK: - Parsing Helpers

    private static func parseEditRate(_ root: XMLElement) -> FrameRate? {
        // <EditRate> is "num den" (e.g. "25 1"); <TimeCodeRate> is a single
        // integer. Both are namespaced children of <SubtitleReel>, so walk the
        // tree by local name — elements(forLocalName:uri:) with uri:nil does not
        // match elements that carry the document's default namespace, which is
        // why the frame rate went undetected on real DCP files.
        guard let editRateStr = findElement(root, localName: "EditRate")?.stringValue
            ?? findElement(root, localName: "TimeCodeRate")?.stringValue
            ?? root.attribute(forName: "EditRate")?.stringValue
        else { return nil }
        let parts = editRateStr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 1, let num = Double(parts[0]) else { return nil }
        let den = parts.count >= 2 ? (Double(parts[1]) ?? 1.0) : 1.0
        let fps = num / den
        for rate in FrameRate.allCases {
            if abs(rate.value - fps) < 0.01 { return rate }
        }
        return nil
    }

    /// Detect SMPTE 428-7 schema version from the namespace URI in the root element.
    private struct DetectedSchema {
        let uriSuffix: String
        let versionString: String
    }

    /// Walk the tree for any <Language> child of <SubtitleReel> regardless of
    /// namespace, because the namespace declaration in real DCP files is
    /// inconsistent and elements(forLocalName:uri:) requires the explicit URI.
    private static func findLanguageElement(in root: XMLElement) -> String? {
        for child in (root.children ?? []).compactMap({ $0 as? XMLElement }) {
            if resolveLocalName(child.name) == "Language" {
                return child.stringValue
            }
        }
        return nil
    }

    private static func detectSchemaVersion(_ root: XMLElement) -> DetectedSchema {
        // The default namespace is on the root element's `uri` property
        let uri = root.uri ?? ""
        if uri.contains("/428-7/2007/") {
            return DetectedSchema(uriSuffix: "428-7/2007/DCST", versionString: "2007")
        }
        if uri.contains("/428-7/2010/") {
            return DetectedSchema(uriSuffix: "428-7/2010/DCST", versionString: "2010")
        }
        if uri.contains("/428-7/2014/") {
            return DetectedSchema(uriSuffix: "428-7/2014/DCST", versionString: "2014")
        }
        return DetectedSchema(uriSuffix: "428-7/2014/DCST", versionString: "2014")
    }

    /// Convert a raw <Language> element value to canonical BCP-47. Mirrors
    /// the DCP InterOp importer's helper but lives here to keep modules decoupled.
    private static func importResolveLanguage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed == trimmed.uppercased() {
            if let bcp47 = ISDCFDCNCTableSMPTE.bcp47(forDCNCTag: trimmed) {
                return bcp47
            }
            return trimmed
        }
        return LanguageCode.canonicalize(trimmed)
    }

    private static func parseSMPTE428Timecode(_ str: String, frameRate: FrameRate) -> Timecode? {
        let s = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.components(separatedBy: ":")
        guard parts.count == 4,
              let h = Int(parts[0]), let m = Int(parts[1]),
              let sec = Int(parts[2]), let f = Int(parts[3])
        else { return nil }
        return Timecode(h: h, m: m, s: sec, f: f, frameRate: frameRate)
    }

    private static func parseVPosition(_ textElem: XMLElement) -> Double {
        if let vposStr = textElem.attribute(forName: "Vposition")?.stringValue,
           let vpos = Double(vposStr) { return vpos }
        return 8.0
    }

    private static func parseDCPTextSegments(_ textElem: XMLElement,
                                             baseStyle: TextStyle = [],
                                             baseColor: TextColor? = nil) -> [TextSegment] {
        var segments: [TextSegment] = []

        for child in (textElem.children ?? []).compactMap({ $0 as? XMLElement }) {
            let localName = resolveLocalName(child.name)
            if localName == "Font" {
                let isItalic = child.attribute(forName: "Italic")?.stringValue == "yes"
                let isBold = child.attribute(forName: "Weight")?.stringValue == "bold"
                var style: TextStyle = baseStyle
                if isItalic { style.insert(.italic) }
                if isBold { style.insert(.bold) }
                // A per-run Color overrides whatever the enclosing Font set —
                // this is how coloured speaker cues are written, and dropping it
                // was why imported colours never showed anywhere (#50).
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
}

// MARK: - DCP SMPTE ST 428-7 Exporter

public struct DCPSMPTEExporter: FormatExporter {
    public static let formatID = FormatID.dcp_smpte
    public static let formatName = String(localized: "DCP SMPTE ST 428-7 (DCDM)")
    public static let fileExtension = "xml"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        let opts = options ?? ExportOptions()
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        let frameRate = opts.sourceFrameRate ?? track.subtitles.first?.startTime.frameRate ?? .fps25
        let fpsInt = Int(frameRate.value.rounded())

        // SMPTE 428-7 schema version. 2007 = original (no Direction/Hposition
        // on <Text>, no FadeUp/FadeDown on <Subtitle>, LoadFont uses ID lowercase).
        // 2010+ adds both. 2014 is the current and is the default.
        let schemaVersion = schemaVersionFromOptions(opts)

        let fontID = track.metadata["dcp_font_id"] ?? "FontID"
        let fontURN = opts.extra["dcp_font_urn"]
            ?? track.metadata["dcp_font_urn"]
            ?? "urn:uuid:d86e5ebf-8697-4f0d-b44f-b78a64437d36"
        let fontColor = track.metadata["dcp_font_color"] ?? "FFF2F2F2"
        let fontEffect: String
        let fontEffectColor: String
        if let bw = opts.borderWidth, bw > 0 {
            fontEffect = track.metadata["dcp_font_effect"] ?? "border"
            fontEffectColor = track.metadata["dcp_font_effectColor"] ?? dcpColor(fromHex: opts.borderColor ?? "000000")
        } else if opts.borderWidth == 0 {
            fontEffect = track.metadata["dcp_font_effect"] ?? "none"
            fontEffectColor = track.metadata["dcp_font_effectColor"] ?? "FF000000"
        } else {
            fontEffect = track.metadata["dcp_font_effect"] ?? "border"
            fontEffectColor = track.metadata["dcp_font_effectColor"] ?? "FF000000"
        }
        let fontSize: String
        if let userSize = opts.fontSize {
            fontSize = String(Int(userSize.rounded()))
        } else if let userSize = track.metadata["dcp_font_size"] {
            fontSize = userSize
        } else {
            fontSize = "40"
        }
        // EffectSize scales the border/shadow thickness. Without it, EasyDCP
        // renders an oversized default border; 1.5 matches typical DCP masters.
        // Priority: explicit export option → track metadata → 1.5 default.
        let fontEffectSize: String
        if let optEffect = opts.effectSize {
            // Always emit a '.' decimal separator (e.g. "1.50"). `Double.formatted`
            // is locale-aware and would write "1,5" on a comma-locale (fr_BE/nl_BE),
            // producing an invalid EffectSize attribute rejected by DCP tooling.
            fontEffectSize = String(format: "%.2f", optEffect)
        } else {
            fontEffectSize = track.metadata["dcp_font_effectSize"] ?? "1.5"
        }
        let fontWeight: String
        if opts.boldFont {
            fontWeight = "bold"
        } else if let metaWeight = track.metadata["dcp_font_weight"] {
            fontWeight = metaWeight
        } else {
            fontWeight = "normal"
        }
        let fontAspect = track.metadata["dcp_font_aspect"] ?? "1.00"

        // Base V position (the baseline line for safeArea-bottom stacking,
        // measured as % up from the bottom edge): prefer the explicit export
        // option, then the track's default vertical position (set via the
        // DCP Subtitle Settings sheet — stored as .percentage with 0=top,
        // 100=bottom, so convert to "up from bottom" = 100 - pct), then 8.0.
        let baseVPosition: Double = {
            if let v = opts.vPosition { return v }
            if case .percentage(let pct) = track.defaultVerticalPosition {
                return max(0.0, min(100.0, 100.0 - pct))
            }
            return 8.0
        }()
        let lineHeight: Double = opts.lineHeight ?? 7.0

        // The subtitle resource's Id and reel number. The package writer
        // passes the MXF asset UUID (dcp_resource_id) so the XML's Id equals
        // the MXF track-file id — required by SMPTE ST 429-5 (ClairMeta's
        // "Subtitle UUID coherence") — and the reel's 1-based position
        // (dcp_reel_number) so multi-reel CPLs cross-check (ClairMeta's
        // "Subtitle reel number coherence with CPL"). Standalone exports
        // fall back to a fresh UUID / reel 1.
        let reelUUID = opts.extra["dcp_resource_id"] ?? UUID().uuidString.lowercased()
        let reelNumber = opts.extra["dcp_reel_number"] ?? "1"
        let issueDate = ISO8601DateFormatter().string(from: Date())

        let loadFontAttr = schemaVersion.loadFontAttributeCase
        // Bilingual tracks emit "mul" by default (see dcpLanguageBalise); the
        // export dialog can force the primary language instead.
        let bilingualUsesMul = (opts.extra["dcp_bilingual_lang"] ?? "mul") != "primary"
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <SubtitleReel xmlns="\(schemaVersion.namespaceURI)">
        <Id>urn:uuid:\(reelUUID)</Id>
        <ContentTitleText>\(escapeXML(track.name))</ContentTitleText>
        <AnnotationText>DCDM subtitle file</AnnotationText>
        <IssueDate>\(issueDate)</IssueDate>
        <ReelNumber>\(reelNumber)</ReelNumber>
        <Language>\(track.dcpLanguageBalise(for: .dcp_smpte, bilingualUsesMul: bilingualUsesMul))</Language>
        <EditRate>\(fpsInt) 1</EditRate>
        <TimeCodeRate>\(fpsInt)</TimeCodeRate>
        <StartTime>\(startTimeString(for: track))</StartTime>
        <!--Supply font with file name: \(fontURN.hasPrefix("urn:uuid:") ? String(fontURN.dropFirst("urn:uuid:".count)) : fontURN)-->
        <LoadFont \(loadFontAttr)="\(fontID)">\(fontURN)</LoadFont>
        <SubtitleList>
        <Font ID="\(fontID)" Color="\(fontColor)" Weight="\(fontWeight)" Size="\(fontSize)" Effect="\(fontEffect)" EffectColor="\(fontEffectColor)" EffectSize="\(fontEffectSize)" AspectAdjust="\(fontAspect)">
        """

        for (index, sub) in track.subtitles.enumerated() {
            let spotNum = index + 1
            let timeIn = formatSMPTE428Time(sub.startTime)
            let timeOut = formatSMPTE428Time(sub.endTime)
            let effective = track.effectivePosition(for: sub)

            if schemaVersion.supportsFadeTimes {
                xml += """

                    <Subtitle SpotNumber="\(spotNum)" TimeIn="\(timeIn)" TimeOut="\(timeOut)" FadeUpTime="00:00:00:00" FadeDownTime="00:00:00:00">
                """
            } else {
                xml += """

                    <Subtitle SpotNumber="\(spotNum)" TimeIn="\(timeIn)" TimeOut="\(timeOut)">
                """
            }

            for (blockIdx, block) in sub.textBlocks.enumerated() {
                let vpos = formatDCPVPosition(effective.vertical, blockIndex: blockIdx, totalBlocks: sub.textBlocks.count, baseVPosition: baseVPosition, lineHeight: lineHeight)
                let placement = DCPHorizontal.attributes(horizontal: effective.horizontal, alignment: effective.alignment)
                let hposStr = String(format: "%.1f", placement.hposition)
                let halignStr = placement.halign
                let valignStr = formatSMPTEVAlign(effective.vertical)
                let plainText = block.segments.map { segment in
                    // Wrap the run in a <Font> when it carries italics or a
                    // colour of its own; without the colour attribute a coloured
                    // cue came back white on the next round trip (#50). The
                    // enclosing <Font> already sets the track's default colour,
                    // so only a *different* colour needs writing here.
                    var attrs = ""
                    if segment.style.contains(.italic) { attrs += " Italic=\"yes\"" }
                    if let c = segment.color, DCPColor.hex(from: c) != fontColor.uppercased() {
                        attrs += " Color=\"\(DCPColor.hex(from: c))\""
                    }
                    guard !attrs.isEmpty else { return escapeXML(segment.text) }
                    return "<Font\(attrs)>\(escapeXML(segment.text))</Font>"
                }.joined()

                if schemaVersion.supportsTextDirection {
                    xml += """

                        <Text Vposition="\(vpos)" Halign="\(halignStr)" Direction="ltr" Valign="\(valignStr)" Hposition="\(hposStr)">\(plainText)</Text>
                    """
                } else {
                    xml += """

                        <Text Vposition="\(vpos)" Halign="\(halignStr)" Valign="\(valignStr)">\(plainText)</Text>
                    """
                }
            }

            xml += "\n      </Subtitle>"
        }

        xml += """

        </Font>
        </SubtitleList>
        </SubtitleReel>
        """

        guard let data = xml.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode DCP SMPTE XML as UTF-8")
        }
        return data
    }

    /// Round-trip the reel's `<StartTime>`: an imported hour-based reel keeps
    /// its declared origin (held as the track's timecode offset); everything
    /// else exports the standard zero start.
    private static func startTimeString(for track: Track) -> String {
        if let offset = track.timecodeOffset, offset.totalFrames > 0 {
            return formatSMPTE428Time(offset)
        }
        return "00:00:00:00"
    }

    /// Resolves the SMPTE 428-7 schema version from `ExportOptions.extra["smpte_schema_version"]`.
    /// Falls back to `.latest` (2014). Accepts both the enum raw values
    /// (`v2007`/`v2010`/`v2014`/`latest`) and bare year strings (`2007`/`2010`/`2014`).
    private static func schemaVersionFromOptions(_ opts: ExportOptions) -> SMPTESchemaVersion {
        guard let raw = opts.extra["smpte_schema_version"]?.lowercased(), !raw.isEmpty else {
            return .latest
        }
        switch raw {
        case "v2007", "2007": return .v2007
        case "v2010", "2010": return .v2010
        case "v2014", "2014": return .v2014
        case "latest", "vLatest": return .latest
        default: return .latest
        }
    }

    private static func formatSMPTE428Time(_ tc: Timecode) -> String {
        let (h, m, s, f) = tc.components
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    private static func formatSMPTEVAlign(_ pos: VerticalPosition) -> String {
        switch pos {
        case .safeArea(.top): return "top"
        case .safeArea(.center): return "center"
        default: return "bottom"
        }
    }

    private static func formatDCPVPosition(_ pos: VerticalPosition, blockIndex: Int, totalBlocks: Int, baseVPosition: Double = 8.0, lineHeight: Double = 7.0) -> String {
        switch pos {
        case .percentage(let pct):
            // Our model: 0 = top, 100 = bottom. SMPTE 428-7: 1 = bottom, 100 = top (inverted).
            // The stored percentage is the BASELINE (bottom-most) line; earlier
            // blocks stack upward by `lineHeight` so a multi-line custom-positioned
            // cue renders like a regular bottom-anchored cue (top line higher).
            let base = 100.0 - pct
            let vpos = base + Double(totalBlocks - 1 - blockIndex) * lineHeight
            return String(format: "%.1f", max(1.0, min(100.0, vpos)))
        case .row(let r):
            return String(r)
        case .safeArea(.bottom):
            if totalBlocks == 2 {
                return String(format: "%.1f", blockIndex == 0 ? (baseVPosition + lineHeight) : baseVPosition)
            }
            return String(format: "%.1f", baseVPosition)
        case .safeArea(.center):
            return "50.0"
        case .safeArea(.top):
            return String(format: "%.1f", 100.0 - baseVPosition)
        default:
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
            // ClairMeta applies the InterOp 640 KB font cap to SMPTE packages
            // too (dcp_check_subtitle.check_subtitle_cpl_font_size), so subset
            // oversized fonts here as well — smaller package, same rendering.
            let limitedFontData = try FontSubsetter.limitForDCP(fontData: fontData, tracks: tracks)
            let fontURN = opts.extra["dcp_font_urn"]
                ?? tracks.first?.metadata["dcp_font_urn"]
                ?? "urn:uuid:d86e5ebf-8697-4f0d-b44f-b78a64437d36"
            // The SMPTE font asset is named with the bare UUID referenced in the
            // XML's <LoadFont> URN — no "urn:uuid:" prefix, no file extension.
            var uuid = fontURN
            if uuid.hasPrefix("urn:uuid:") {
                uuid = String(uuid.dropFirst("urn:uuid:".count))
            }
            files.append(ExportResult.ExportFile(filename: uuid, data: limitedFontData))
        }

        return ExportResult(files: files)
    }

    private static func dcpColor(fromHex hex: String) -> String {
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

/// Minimal fallback DCNC lookup so this module does not need to depend on
/// AlphaSubLanguage. If Language is linked in, `LanguageBaliseProvider.dcnc`
/// (installed by `LanguageBaliseWiring.install()`) is used preferentially
/// via `Track.languageBalise(for: .dcp_smpte)`. This enum only covers the
/// most common tags for safe import-time round-trip.
private enum ISDCFDCNCTableSMPTE {
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
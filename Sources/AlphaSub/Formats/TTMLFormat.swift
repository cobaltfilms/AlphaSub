import Foundation
import AlphaSubCore

// MARK: - TTML/Netflix TTML1 Importer

/// W3C TTML / Netflix TTML1 / IMSC1 subtitle format importer.
/// Handles .ttml and .xml files with TTML namespaces.
///
/// Netflix TTAL (Timed Text Authoring Language) is also supported as a TTML variant.
public struct TTMLImporter: FormatImporter {
    public static let formatID = FormatID.ttml
    public static let formatName = String(localized: "TTML / Netflix TTML1 / IMSC")
    public static let fileExtensions = ["ttml", "dfxp", "itt", "xml"]

    public static func canImport(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        return str.contains("http://www.w3.org/ns/ttml")
            || str.contains("http://www.w3.org/2006/10/ttaf1")
            || str.contains("http://www.w3.org/ns/ttml#parameter")
            || str.contains(":tt=\"http://www.w3.org/ns/ttml\"")
            || (str.contains("<tt ") && str.contains("xml:lang"))
            || str.contains("ebuttm:documentEbuttVersion")
    }

    public static func `import`(_ data: Data, options: ImportOptions? = nil) throws -> [Track] {
        let opts = options ?? ImportOptions()
        let frameRate = opts.targetFrameRate ?? .fps25

        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw FormatError.unsupportedEncoding("Cannot decode TTML data")
        }

        let doc = try XMLDocument(xmlString: str, options: [])
        guard let root = doc.rootElement() else {
            throw FormatError.invalidData("No root element in TTML")
        }

        let ns = collectNamespaces(root)
        let ttNS = ns["tt"] ?? ns[""] ?? "http://www.w3.org/ns/ttml"
        let ttpNS = ns["ttp"] ?? "http://www.w3.org/ns/ttml#parameter"
        let ttsNS = ns["tts"] ?? "http://www.w3.org/ns/ttml#styling"

        let docFrameRate = parseFrameRateFromTTML(root, ttpNS: ttpNS) ?? frameRate
        // When the frame rate was read from the file's ttp:frameRate
        // attribute or explicitly passed via opts, record it on the track
        // so the UI knows it wasn't guessed. When both are nil and the
        // default (.fps25) was used, leave track.frameRate nil so the
        // view-model prompts the user.
        let explicitFrameRate = parseFrameRateFromTTML(root, ttpNS: ttpNS) ?? opts.targetFrameRate

        let title = root.attribute(forName: "tt:title")?.stringValue ?? root.elements(forLocalName: "title", uri: ttNS).first?.stringValue ?? "TTML Import"

        let lang = root.attribute(forName: "xml:lang")?.stringValue ?? opts.defaultLanguage?.rawValue ?? ""

        var metadata: FormatMetadata = [
            "ttml_namespace": ttNS,
        ]
        if let fr = root.attribute(forName: "ttp:frameRate")?.stringValue {
            metadata["ttp_frameRate"] = fr
        }
        if let frMul = root.attribute(forName: "ttp:frameRateMultiplier")?.stringValue {
            metadata["ttp_frameRateMultiplier"] = frMul
        }

        let bodyElements = findElements(root: root, localNames: ["body", "div", "p"], ttNS: ttNS)

        var subtitles: [Subtitle] = []
        for pElem in bodyElements where pElem.localName == "p" || pElem.name?.hasSuffix(":p") == true || resolveLocalName(pElem.name) == "p" {
            if let sub = parsePElement(pElem, frameRate: docFrameRate, ttsNS: ttsNS) {
                subtitles.append(sub)
            }
        }

        if subtitles.isEmpty {
            for divElem in bodyElements where resolveLocalName(divElem.name) == "div" {
                for pElem in (divElem.children ?? []).compactMap({ $0 as? XMLElement }) {
                    if resolveLocalName(pElem.name) == "p" {
                        if let sub = parsePElement(pElem, frameRate: docFrameRate, ttsNS: ttsNS) {
                            subtitles.append(sub)
                        }
                    }
                }
            }
        }

        var track = Track(
            name: extractTitle(root, ttNS: ttNS) ?? title,
            language: LanguageCode(lang),
            subtitles: subtitles,
            formatOrigin: "ttml",
            metadata: metadata,
            frameRate: explicitFrameRate
        )
        track.timecodeOffset = parseTimeOffset(root, frameRate: docFrameRate)
        return [track]
    }

    // MARK: - TTML Parsing Helpers

    private static func collectNamespaces(_ element: XMLElement) -> [String: String] {
        var ns: [String: String] = [:]
        if let attrs = element.attributes {
            for attr in attrs {
                if let name = attr.name {
                    if name.hasPrefix("xmlns:") {
                        let prefix = String(name.dropFirst(6))
                        ns[prefix] = attr.stringValue
                    } else if name == "xmlns" {
                        ns[""] = attr.stringValue
                    }
                }
            }
        }
        return ns
    }

    private static func resolveLocalName(_ name: String?) -> String {
        guard let name = name else { return "" }
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    private static func findElements(root: XMLElement, localNames: [String], ttNS: String) -> [XMLElement] {
        var results: [XMLElement] = []
        func walk(_ elem: XMLElement) {
            let local = resolveLocalName(elem.name)
            if localNames.contains(local) {
                results.append(elem)
            }
            for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) {
                walk(child)
            }
        }
        walk(root)
        return results
    }

    private static func extractTitle(_ root: XMLElement, ttNS: String) -> String? {
        let headElements = root.elements(forLocalName: "head", uri: ttNS)
        if let head = headElements.first {
            let titles = head.elements(forLocalName: "title", uri: ttNS)
            return titles.first?.stringValue
        }
        return nil
    }

    private static func parseFrameRateFromTTML(_ root: XMLElement, ttpNS: String) -> FrameRate? {
        guard let frStr = root.attribute(forName: "ttp:frameRate")?.stringValue,
              let fr = Int(frStr) else { return nil }

        let mulStr = root.attribute(forName: "ttp:frameRateMultiplier")?.stringValue ?? "1 1"
        let mulParts = mulStr.split(separator: " ")
        let num = Double(mulParts.first ?? "1") ?? 1.0
        let den = Double(mulParts.count > 1 ? mulParts[1] : "1") ?? 1.0
        let effectiveRate = Double(fr) * num / den

        for rate in FrameRate.allCases {
            if abs(rate.value - effectiveRate) < 0.01 { return rate }
        }
        return nil
    }

    private static func parsePElement(_ pElem: XMLElement, frameRate: FrameRate, ttsNS: String) -> Subtitle? {
        guard let beginStr = pElem.attribute(forName: "begin")?.stringValue ?? pElem.attribute(forName: "start")?.stringValue else { return nil }

        let endStr: String?
        if let end = pElem.attribute(forName: "end")?.stringValue {
            endStr = end
        } else if let durStr = pElem.attribute(forName: "dur")?.stringValue,
                  let begin = parseTTMLTime(beginStr, frameRate: frameRate),
                  let dur = parseTTMLTime(durStr, frameRate: frameRate) {
            endStr = formatSeconds(begin.seconds + dur.seconds)
        } else {
            endStr = nil
        }

        guard let endTimeStr = endStr,
              let startTime = parseTTMLTime(beginStr, frameRate: frameRate),
              let endTime = parseTTMLTime(endTimeStr, frameRate: frameRate)
        else { return nil }

        let textBlocks = parseTTMLTextContent(pElem, ttsNS: ttsNS)
        let vpos = parseTTMLPosition(pElem, ttsNS: ttsNS)

        // SDH: Read forced narrative role, music/offscreen from TTML attributes
        let isForced = pElem.attribute(forName: "ttm:role")?.stringValue == "forcedNarrative"
        let plainText = textBlocks.map { $0.plainText }.joined(separator: " ").lowercased()
        let isMusic = plainText.contains("♪") || plainText.hasPrefix("(music") || plainText.contains("music ")
        let isOffSpeech = plainText.hasPrefix("(off-screen)") || plainText.hasPrefix("(off screen)")
            || plainText.hasPrefix("(vo)") || plainText.hasPrefix("(voice")

        // SDH: Detect speaker prefix
        let fullText = textBlocks.map { $0.plainText }.joined(separator: " ")
        var speaker = ""
        if let colonRange = fullText.range(of: ": "), fullText.distance(from: fullText.startIndex, to: colonRange.lowerBound) <= 20 {
            let potentialSpeaker = String(fullText[..<colonRange.lowerBound])
            let stripped = potentialSpeaker.trimmingCharacters(in: .whitespaces)
            if stripped.count >= 2 && stripped.count <= 15 && stripped.allSatisfy({ $0.isLetter || $0.isWhitespace || $0 == "-" }) {
                speaker = stripped.uppercased()
            }
        }

        return Subtitle(
            startTime: startTime,
            endTime: endTime,
            textBlocks: textBlocks,
            verticalPosition: vpos.position,
            horizontalPosition: vpos.hposition,
            alignment: vpos.alignment,
            useCustomPosition: vpos.position != .safeArea(.bottom) || vpos.hposition != .centered
                || vpos.alignment != .center,
            isForced: isForced,
            isMusic: isMusic,
            isOffSpeech: isOffSpeech,
            isNewScene: plainText.hasPrefix("[new scene]") || plainText.hasPrefix("[scene change]"),
            speaker: speaker
        )
    }

    private static func formatSeconds(_ s: Double) -> String {
        let h = Int(s) / 3600
        let m = Int(s) % 3600 / 60
        let sec = Int(s) % 60
        let ms = Int((s * 1000).truncatingRemainder(dividingBy: 1000))
        return String(format: "%02d:%02d:%02d.%03d", h, m, sec, ms)
    }

    private static func parseTTMLTime(_ str: String, frameRate: FrameRate) -> Timecode? {
        let s = str.trimmingCharacters(in: .whitespaces)

        if s.hasSuffix("h") {
            guard let h = Double(s.dropLast()) else { return nil }
            return Timecode.fromSeconds(h * 3600, frameRate: frameRate)
        }
        if s.hasSuffix("ms") {
            guard let ms = Double(s.dropLast(2)) else { return nil }
            return Timecode.fromSeconds(ms / 1000.0, frameRate: frameRate)
        }
        if s.hasSuffix("s") && !s.hasSuffix("ms") {
            guard let sec = Double(s.dropLast()) else { return nil }
            return Timecode.fromSeconds(sec, frameRate: frameRate)
        }
        if s.hasSuffix("t") {
            guard let ticks = Double(s.dropLast()) else { return nil }
            let ticksPerSecond = frameRate.value * 100.0
            return Timecode.fromSeconds(ticks / ticksPerSecond, frameRate: frameRate)
        }

        let parts = s.components(separatedBy: CharacterSet(charactersIn: ":.,"))
        switch parts.count {
        case 4:
            guard let h = Int(parts[0]), let m = Int(parts[1]),
                  let sec = Int(parts[2]),
                  let framesOrMs = Int(parts[3]) else { return nil }
            if s.contains(",") || s.contains(".") {
                if parts[3].count == 2 {
                    let total = Double(h * 3600 + m * 60 + sec) + Double(framesOrMs) / Double(frameRate.value)
                    return Timecode.fromSeconds(total, frameRate: frameRate)
                } else {
                    let total = Double(h * 3600 + m * 60 + sec) + Double(framesOrMs) / 1000.0
                    return Timecode.fromSeconds(total, frameRate: frameRate)
                }
            } else {
                return Timecode(h: h, m: m, s: sec, f: framesOrMs, frameRate: frameRate)
            }
        case 3:
            guard let h = Int(parts[0]), let m = Int(parts[1]),
                  let secFrac = Double(parts[2]) else { return nil }
            let total = Double(h * 3600 + m * 60) + secFrac
            return Timecode.fromSeconds(total, frameRate: frameRate)
        default:
            return nil
        }
    }

    private static func parseTTMLTextContent(_ pElem: XMLElement, ttsNS: String) -> [TextBlock] {
        let blocks: [TextBlock] = collectTextBlocks(pElem, inheritedStyle: [], inheritedColor: nil, ttsNS: ttsNS)

        if blocks.isEmpty {
            if let text = pElem.stringValue, !text.isEmpty {
                return [TextBlock(segments: [TextSegment(text: text.trimmingCharacters(in: .whitespacesAndNewlines))])]
            }
        }

        return blocks.isEmpty ? [TextBlock(segments: [TextSegment(text: "")])] : blocks
    }

    private static func collectTextBlocks(_ element: XMLElement, inheritedStyle: TextStyle, inheritedColor: TextColor?, ttsNS: String) -> [TextBlock] {
        var blocks: [TextBlock] = []
        var currentLine: [TextSegment] = []

        let style = mergeTTMLStyle(element, inherited: inheritedStyle, ttsNS: ttsNS)
        let color = mergeTTMLColor(element, inherited: inheritedColor, ttsNS: ttsNS)

        for child in element.children ?? [] {
            if child.kind == .text {
                if let text = child.stringValue, !text.isEmpty {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        currentLine.append(TextSegment(text: trimmed, style: style, color: color))
                    }
                }
            } else if let childElem = child as? XMLElement {
                let childLocal = resolveLocalName(childElem.name)
                let childStyle = mergeTTMLStyle(childElem, inherited: style, ttsNS: ttsNS)
                let childColor = mergeTTMLColor(childElem, inherited: color, ttsNS: ttsNS)

                if childLocal == "br" {
                    if !currentLine.isEmpty {
                        blocks.append(TextBlock(segments: currentLine))
                        currentLine = []
                    }
                } else if childLocal == "span" || childLocal == "p" {
                    let childText = collectSpanText(childElem, style: childStyle, color: childColor, ttsNS: ttsNS)
                    currentLine.append(contentsOf: childText)
                } else if childLocal == "i" || childLocal == "b" || childLocal == "u" {
                    var childStyleMod = childStyle
                    if childLocal == "i" {
                        let isClosing = childElem.attribute(forName: "class")?.stringValue?.hasPrefix("/") == true
                        if isClosing { childStyleMod.remove(.italic) } else { childStyleMod.insert(.italic) }
                    }
                    if childLocal == "b" { childStyleMod.insert(.bold) }
                    if childLocal == "u" { childStyleMod.insert(.underline) }
                    let text = childElem.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                    if !text.isEmpty { currentLine.append(TextSegment(text: text, style: childStyleMod, color: childColor)) }
                } else {
                    let subBlocks = collectTextBlocks(childElem, inheritedStyle: style, inheritedColor: color, ttsNS: ttsNS)
                    blocks.append(contentsOf: subBlocks)
                }
            }
        }

        if !currentLine.isEmpty {
            blocks.append(TextBlock(segments: currentLine))
        }

        return blocks
    }

    private static func collectSpanText(_ elem: XMLElement, style: TextStyle, color: TextColor?, ttsNS: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        let mergedStyle = mergeTTMLStyle(elem, inherited: style, ttsNS: ttsNS)
        let mergedColor = mergeTTMLColor(elem, inherited: color, ttsNS: ttsNS)

        if let text = elem.stringValue, !text.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(TextSegment(text: trimmed, style: mergedStyle, color: mergedColor))
            }
        }

        for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) {
            let childStyle = mergeTTMLStyle(child, inherited: mergedStyle, ttsNS: ttsNS)
            let childColor = mergeTTMLColor(child, inherited: mergedColor, ttsNS: ttsNS)
            if let childText = child.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !childText.isEmpty {
                segments.append(TextSegment(text: childText, style: childStyle, color: childColor))
            }
        }

        return segments
    }

    /// Resolve `tts:color` (named or hex) on an element, inheriting from the
    /// parent. An explicit white is the format default and maps to nil.
    private static func mergeTTMLColor(_ element: XMLElement, inherited: TextColor?, ttsNS: String) -> TextColor? {
        guard let raw = element.attribute(forName: "tts:color")?.stringValue
            ?? element.attribute(forLocalName: "color", uri: ttsNS)?.stringValue
        else { return inherited }
        guard let color = TextColor(hex: raw) ?? TextColor(named: raw) else { return inherited }
        return color == .white ? nil : color
    }

    private static func mergeTTMLStyle(_ element: XMLElement, inherited: TextStyle, ttsNS: String) -> TextStyle {
        var style = inherited
        if let fontStyle = element.attribute(forName: "tts:fontStyle")?.stringValue
            ?? element.attribute(forLocalName: "fontStyle", uri: ttsNS)?.stringValue {
            if fontStyle == "italic" || fontStyle == "oblique" { style.insert(.italic) }
            else if fontStyle == "normal" { style.remove(.italic) }
        }
        if let fontWeight = element.attribute(forName: "tts:fontWeight")?.stringValue
            ?? element.attribute(forLocalName: "fontWeight", uri: ttsNS)?.stringValue {
            if fontWeight == "bold" { style.insert(.bold) }
            else if fontWeight == "normal" { style.remove(.bold) }
        }
        if let textDecoration = element.attribute(forName: "tts:textDecoration")?.stringValue
            ?? element.attribute(forLocalName: "textDecoration", uri: ttsNS)?.stringValue {
            if textDecoration.contains("underline") { style.insert(.underline) }
            if textDecoration.contains("noUnderline") { style.remove(.underline) }
        }
        let localName = resolveLocalName(element.name)
        if localName == "i" { style.insert(.italic) }
        if localName == "b" { style.insert(.bold) }
        if localName == "u" { style.insert(.underline) }
        return style
    }

    private struct TTMLPosition {
        var position: VerticalPosition
        var hposition: HorizontalPosition
        var alignment: TextAlignment
    }

    private static func parseTTMLPosition(_ pElem: XMLElement, ttsNS: String) -> TTMLPosition {
        var vpos: VerticalPosition = .safeArea(.bottom)
        var hpos: HorizontalPosition = .centered
        var align: TextAlignment = .center

        if let origin = pElem.attribute(forName: "tts:origin")?.stringValue
            ?? pElem.attribute(forLocalName: "origin", uri: ttsNS)?.stringValue {
            let parts = origin.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                if let yPct = parsePercentage(parts[1]) {
                    vpos = .percentage(yPct)
                }
            }
        }

        if let pos = pElem.attribute(forName: "tts:position")?.stringValue {
            if pos.contains("bottom") { vpos = .safeArea(.bottom) }
            else if pos.contains("center") { vpos = .safeArea(.center) }
            else if pos.contains("top") { vpos = .safeArea(.top) }
        }

        if let extent = pElem.attribute(forName: "tts:extent")?.stringValue {
            if extent.contains("70%") || extent.contains("80%") { hpos = .centered }
        }

        if let textAlign = pElem.attribute(forName: "tts:textAlign")?.stringValue
            ?? pElem.attribute(forLocalName: "textAlign", uri: ttsNS)?.stringValue {
            switch textAlign {
            case "left": align = .left
            case "right": align = .right
            case "center": align = .center
            case "start": align = .start
            case "end": align = .end
            default: break
            }
        }

        return TTMLPosition(position: vpos, hposition: hpos, alignment: align)
    }

    private static func parsePercentage(_ str: String) -> Double? {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix("%") {
            return Double(cleaned.dropLast())
        }
        if let val = Double(cleaned) { return val }
        return nil
    }

    private static func parseTimeOffset(_ root: XMLElement, frameRate: FrameRate) -> Timecode? {
        guard let offsetStr = root.attribute(forName: "ttp:timeOffset")?.stringValue
                ?? root.attribute(forName: "timeOffset")?.stringValue
        else { return nil }
        return parseTTMLTime(offsetStr, frameRate: frameRate)
    }
}

// MARK: - TTML/Netflix TTML1 Exporter

public struct TTMLExporter: FormatExporter {
    public static let formatID = FormatID.ttml
    public static let formatName = String(localized: "TTML (.ttml)")
    public static let fileExtension = "ttml"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        let opts = options ?? ExportOptions()
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        let frameRate = opts.sourceFrameRate ?? track.subtitles.first?.startTime.frameRate ?? .fps25
        let fps = ttmlFrameRate(frameRate)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:ttp="http://www.w3.org/ns/ttml#parameter"
            xmlns:tts="http://www.w3.org/ns/ttml#styling"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
            ttp:frameRate="\(fps.rate)"
            ttp:frameRateMultiplier="\(fps.multiplier)"
            xml:lang="\(resolveLanguage(opts, track: track, fallback: "en"))">
        """

        xml += "\n  <head>\n"
        xml += "    <metadata>\n"
        xml += "      <ttm:title>\(escapeXML(track.name))</ttm:title>\n"
        xml += "    </metadata>\n"

        let fontFamily   = opts.fontName ?? "proportionalSansSerif"
        let fontSizeAttr = opts.fontSize.map { " tts:fontSize=\"\(Int($0))px\"" } ?? ""
        let outlineAttr: String
        if let bw = opts.borderWidth, bw > 0 {
            let color = opts.borderColor ?? "black"
            outlineAttr = " tts:textOutline=\"\(color) \(String(format: "%.0f", bw))px\""
        } else {
            outlineAttr = ""
        }
        xml += "    <styling>\n"
        xml += "      <style xml:id=\"s1\" tts:fontFamily=\"\(fontFamily)\"\(fontSizeAttr)\(outlineAttr) tts:fontStyle=\"normal\" tts:fontWeight=\"normal\" tts:textAlign=\"center\"/>\n"
        xml += "    </styling>\n"
        xml += "    <layout>\n"
        xml += "      <region xml:id=\"bottom\"     tts:origin=\"0% 85%\" tts:extent=\"100% 15%\" tts:textAlign=\"center\"/>\n"
        xml += "      <region xml:id=\"top\"        tts:origin=\"0% 0%\"  tts:extent=\"100% 15%\" tts:textAlign=\"center\"/>\n"
        xml += "      <region xml:id=\"center\"     tts:origin=\"0% 42%\" tts:extent=\"100% 15%\" tts:textAlign=\"center\"/>\n"
        xml += "      <region xml:id=\"lineShift1\" tts:origin=\"0% 72%\" tts:extent=\"100% 15%\" tts:textAlign=\"center\"/>\n"

        // Generate a unique region per distinct (origin, align) pair for precise positioning.
        var customRegionKeys: [String: String] = [:]
        var customRegionCounter = 0
        for sub in track.subtitles {
            if case .percentage = sub.verticalPosition {
                let key = ttmlOriginAlignKey(vertical: sub.verticalPosition, horizontal: sub.horizontalPosition, align: sub.alignment)
                if customRegionKeys[key] == nil {
                    customRegionCounter += 1
                    let id = "custom\(customRegionCounter)"
                    customRegionKeys[key] = id
                    xml += "      <region xml:id=\"\(id)\" tts:origin=\"\(formatTTMLOrigin(vertical: sub.verticalPosition, horizontal: sub.horizontalPosition))\" tts:extent=\"100% 15%\" tts:textAlign=\"\(formatTTMLTextAlign(sub.alignment))\"/>\n"
                }
            }
        }
        xml += "    </layout>\n"
        xml += "  </head>\n"

        xml += "  <body>\n"
        xml += "    <div>\n"

        for sub in track.subtitles {
            let beginStr = formatTTMLTime(sub.startTime)
            let endStr = formatTTMLTime(sub.endTime)

            let region: String
            switch sub.verticalPosition {
            case .safeArea(.top):            region = "top"
            case .safeArea(.center):         region = "center"
            case .lineShift(let n) where n > 0: region = "lineShift1"
            case .percentage:
                let key = ttmlOriginAlignKey(vertical: sub.verticalPosition, horizontal: sub.horizontalPosition, align: sub.alignment)
                region = customRegionKeys[key] ?? "bottom"
            default:                         region = "bottom"
            }
            xml += "      <p begin=\"\(beginStr)\" end=\"\(endStr)\" region=\"\(region)\""

            if sub.isForced { xml += " ttm:role=\"forcedNarrative\"" }

            // For preset regions, we may still need to override textAlign inline.
            if case .percentage = sub.verticalPosition {
                // Already set on the region, don't duplicate.
            } else {
                switch sub.alignment {
                case .left, .start: xml += " tts:textAlign=\"left\""
                case .right, .end:  xml += " tts:textAlign=\"right\""
                default: break
                }
            }

            xml += ">"
            
            // SDH: Add speaker prefix if present
            if !sub.speaker.isEmpty {
                xml += "<span tts:fontWeight=\"bold\">\(escapeXML(sub.speaker)):</span> "
            }
            // SDH: Add music/offscreen indicators
            if sub.isMusic {
                xml += "<span tts:fontStyle=\"italic\">♪ </span>"
            }
            if sub.isOffSpeech {
                xml += "<span tts:fontStyle=\"italic\">(OFF-SCREEN) </span>"
            }
            if sub.isNewScene {
                xml += "<span tts:fontWeight=\"bold\">[NEW SCENE] </span>"
            }

            if sub.textBlocks.count == 1 {
                xml += formatTTMLTextBlocks(sub.textBlocks)
            } else {
                for (i, block) in sub.textBlocks.enumerated() {
                    xml += formatTTMLTextBlock(block)
                    if i < sub.textBlocks.count - 1 { xml += "<br/>" }
                }
            }

            xml += "</p>\n"
        }

        xml += "    </div>\n"
        xml += "  </body>\n"
        xml += "</tt>"

        guard let data = xml.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode TTML as UTF-8")
        }
        return data
    }

    static func formatTTMLTime(_ tc: Timecode) -> String {
        let (h, m, s, _) = tc.components
        let ms = tc.milliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    static func formatTTMLTextBlocks(_ blocks: [TextBlock]) -> String {
        return blocks.enumerated().map { (i, block) in
            let text = formatTTMLTextBlock(block)
            return i < blocks.count - 1 ? text + "<br/>" : text
        }.joined()
    }

    static func formatTTMLTextBlock(_ block: TextBlock) -> String {
        return block.segments.map { segment in
            var text = escapeXML(segment.text)
            if segment.style.contains(.italic) { text = "<span tts:fontStyle=\"italic\">\(text)</span>" }
            if segment.style.contains(.bold) { text = "<span tts:fontWeight=\"bold\">\(text)</span>" }
            if let color = segment.color { text = "<span tts:color=\"\(color.hexString)\">\(text)</span>" }
            return text
        }.joined()
    }

    static func escapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Element-content escape: only `&`, `<`, `>` require escaping inside text.
    /// Apostrophes/quotes are kept literal, matching professional TTML exporters.
    static func escapeText(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Integer `ttp:frameRate` + `ttp:frameRateMultiplier`. TTML/IMSC require an
    /// integer frame rate; NTSC-pulldown rates carry the 1000/1001 multiplier.
    /// (`frameRate="24.000"` is rejected by strict validators — this was the bug.)
    static func ttmlFrameRate(_ fr: FrameRate) -> (rate: String, multiplier: String) {
        switch fr {
        case .fps23_976:                  return ("24", "1000 1001")
        case .fps24:                      return ("24", "1 1")
        case .fps25:                      return ("25", "1 1")
        case .fps29_97_ndf, .fps29_97_df: return ("30", "1000 1001")
        case .fps30:                      return ("30", "1 1")
        case .fps47_952:                  return ("48", "1000 1001")
        case .fps48:                      return ("48", "1 1")
        case .fps50:                      return ("50", "1 1")
        case .fps59_94_ndf:               return ("60", "1000 1001")
        default:                          return ("25", "1 1")
        }
    }

    /// Export language: an explicit `extra["ttml_lang"]` override from the
    /// TTML/ITT/VTT export dialog wins, otherwise the track's own language.
    static func resolveLanguage(_ opts: ExportOptions, track: Track, fallback: String) -> String {
        if let l = opts.extra["ttml_lang"], !l.isEmpty { return l }
        return track.language.rawValue.isEmpty ? fallback : track.language.rawValue
    }

    /// Right-to-left scripts. Used to emit `tts:direction="rtl"` /
    /// `tts:unicodeBidi="embed"` per AWS MediaConvert's TTML guidance.
    static func isRTL(_ bcp47: String) -> Bool {
        let primary = bcp47.split(separator: "-").first.map(String.init)?.lowercased() ?? bcp47.lowercased()
        return ["ar", "he", "iw", "fa", "ur", "yi", "ps", "sd", "ug", "dv", "ckb"].contains(primary)
    }

    /// SMPTE timecode `HH:MM:SS:FF` for `ttp:timeBase="smpte"` (Apple iTunes ITT
    /// requires frame-based timecodes, not the media-time `HH:MM:SS.mmm` form).
    static func formatTTMLSMPTE(_ tc: Timecode) -> String {
        let (h, m, s, f) = tc.components
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    /// Render text blocks to inline TTML, wrapping italic runs in
    /// `<span tts:fontStyle="italic">` and coloured runs in
    /// `<span tts:color="#rrggbb">`. Uses element-content escaping.
    static func inlineSpanItalic(_ blocks: [TextBlock], separator: String = "<br/>") -> String {
        blocks.map { block in
            block.segments.map { seg in
                var t = escapeText(seg.text)
                if seg.style.contains(.italic) { t = "<span tts:fontStyle=\"italic\">\(t)</span>" }
                if let color = seg.color { t = "<span tts:color=\"\(color.hexString)\">\(t)</span>" }
                return t
            }.joined()
        }.joined(separator: separator)
    }

    /// Build a `tts:origin` string from the subtitle's vertical/horizontal position
    /// as a percentage of the active pixel area. Our model uses 0=top, 0=left, 0–100.
    /// TTML uses the same convention.
    static func formatTTMLOrigin(vertical: VerticalPosition, horizontal: HorizontalPosition) -> String {
        let h = horizontalPercent(horizontal)
        let v = verticalPercent(vertical)
        return String(format: "%.1f%% %.1f%%", h, v)
    }

    static func horizontalPercent(_ pos: HorizontalPosition) -> Double {
        switch pos {
        case .centered:          return 50.0
        case .leftAligned:       return 0.0
        case .rightAligned:      return 100.0
        case .percentage(let v):  return v
        }
    }

    static func verticalPercent(_ pos: VerticalPosition) -> Double {
        switch pos {
        case .safeArea(.top):    return 0.0
        case .safeArea(.center): return 50.0
        case .safeArea(.bottom): return 85.0  // near bottom (matches "bottom" region origin)
        case .percentage(let v):  return v
        case .row, .lineShift:   return 85.0
        }
    }

    static func formatTTMLTextAlign(_ alignment: TextAlignment) -> String {
        switch alignment {
        case .left, .start: return "left"
        case .right, .end:  return "right"
        case .center:      return "center"
        }
    }

    /// Deduplication key for per-cue custom regions: (H%, V%, align).
    static func ttmlOriginAlignKey(vertical: VerticalPosition, horizontal: HorizontalPosition, align: TextAlignment) -> String {
        let h = String(format: "%.1f", horizontalPercent(horizontal))
        let v = String(format: "%.1f", verticalPercent(vertical))
        return "\(h)x\(v)x\(align.rawValue)"
    }
}


// MARK: - DaVinci Resolve TTML Exporter

/// DaVinci Resolve TTML profile exporter.
/// Simple TTML with DaVinci-compatible regions and styling.
public struct DaVinciTTMLExporter: FormatExporter {
    public static let formatID = FormatID.ttml_davinci
    public static let formatName = String(localized: "TTML DaVinci Resolve")
    public static let fileExtension = "ttml"

    public static func export(_ tracks: [Track], options: ExportOptions? = nil) throws -> Data {
        let opts = options ?? ExportOptions()
        guard let track = tracks.first else {
            throw FormatError.invalidData("No tracks to export")
        }

        let frameRate = opts.sourceFrameRate ?? track.subtitles.first?.startTime.frameRate ?? .fps25
        let fps = TTMLExporter.ttmlFrameRate(frameRate)
        let lang = TTMLExporter.resolveLanguage(opts, track: track, fallback: "en")
        let fontSize = opts.fontSize.map { Int($0) } ?? 55

        var xml = "<?xml version='1.0' encoding='UTF-8'?>\n"
        xml += "<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttp=\"http://www.w3.org/ns/ttml#parameter\" xmlns:tts=\"http://www.w3.org/ns/ttml#styling\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" xmlns:ittp=\"http://www.w3.org/ns/ttml/profile/imsc1#parameter\" xmlns:itts=\"http://www.w3.org/ns/ttml/profile/imsc1#styling\" xmlns:xml=\"http://www.w3.org/XML/1998/namespace\" ttp:profile=\"http://www.w3.org/ns/ttml/profile/imsc1/text\" ttp:frameRate=\"\(fps.rate)\" ttp:frameRateMultiplier=\"\(fps.multiplier)\" ttp:timeBase=\"media\" xml:lang=\"\(lang)\">\n"
        xml += "  <head>\n"
        xml += "    <styling>\n"
        xml += "      <style xml:id=\"r0_style\" tts:color=\"#ffffff\" tts:opacity=\"1\" tts:fontFamily=\"proportionalSansSerif\" tts:textOutline=\"#000000 1px\" />\n"
        xml += "    </styling>\n"
        xml += "    <layout>\n"
        xml += "      <region xml:id=\"bottom_left\" tts:origin=\"5.0% 95.2%\" tts:extent=\"90.0% 0%\" tts:textAlign=\"start\" tts:displayAlign=\"after\" />\n"
        xml += "      <region xml:id=\"bottom_center\" tts:origin=\"5.0% 95.2%\" tts:extent=\"90.0% 0%\" tts:textAlign=\"center\" tts:displayAlign=\"after\" />\n"
        xml += "    </layout>\n"
        xml += "  </head>\n"
        xml += "  <body>\n"

        // DaVinci groups cues into per-alignment divs (left vs. centre).
        let leftCues = track.subtitles.filter { isLeftAligned($0.alignment) }
        let centerCues = track.subtitles.filter { !isLeftAligned($0.alignment) }

        func emitDiv(_ cues: [Subtitle], region: String) {
            guard !cues.isEmpty else { return }
            xml += "    <div region=\"\(region)\" style=\"r0_style\">\n"
            for sub in cues {
                let beginStr = TTMLExporter.formatTTMLTime(sub.startTime)
                let endStr = TTMLExporter.formatTTMLTime(sub.endTime)
                // Coloured cues take the span path so per-segment colours survive.
                let allItalic = !sub.textBlocks.isEmpty && !sub.hasColor && sub.textBlocks.allSatisfy { block in
                    !block.segments.isEmpty && block.segments.allSatisfy { $0.style.contains(.italic) }
                }
                let italicAttr = allItalic ? " tts:fontStyle=\"italic\"" : ""
                xml += "      <p begin=\"\(beginStr)\" end=\"\(endStr)\" tts:color=\"#ffffff\" tts:fontSize=\"\(fontSize)px\"\(italicAttr)>"
                // Whole-cue italic is on the <p>; mixed runs still use spans.
                xml += allItalic ? TTMLExporter.escapeText(sub.textBlocks.map(\.plainText).joined(separator: "\n")).replacingOccurrences(of: "\n", with: "<br />")
                                  : TTMLExporter.inlineSpanItalic(sub.textBlocks, separator: "<br />")
                xml += "</p>\n"
            }
            xml += "    </div>\n"
        }
        emitDiv(leftCues, region: "bottom_left")
        emitDiv(centerCues, region: "bottom_center")

        xml += "  </body>\n"
        xml += "</tt>"

        guard let data = xml.data(using: .utf8) else {
            throw FormatError.fileWriteFailed("Cannot encode DaVinci TTML as UTF-8")
        }
        return data
    }

    private static func isLeftAligned(_ alignment: TextAlignment) -> Bool {
        alignment == .left || alignment == .start
    }
}
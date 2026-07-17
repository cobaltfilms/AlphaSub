import Foundation

// MARK: - Frame Rate

/// Video frame rates with drop-frame support.
public enum FrameRate: String, Codable, CaseIterable {
    case fps23_976 = "23.976"
    case fps24     = "24"
    case fps25     = "25"
    case fps29_97_ndf = "29.97ndf"
    case fps29_97_df  = "29.97df"
    case fps30     = "30"
    case fps47_952 = "47.952"
    case fps48     = "48"
    case fps50     = "50"
    case fps59_94_ndf = "59.94ndf"
    case fps59_94_df  = "59.94df"
    case fps60     = "60"

    public var value: Double {
        switch self {
        case .fps23_976:   return 24000.0 / 1001.0
        case .fps24:       return 24.0
        case .fps25:       return 25.0
        case .fps29_97_ndf, .fps29_97_df: return 30000.0 / 1001.0
        case .fps30:       return 30.0
        case .fps47_952:   return 48000.0 / 1001.0
        case .fps48:       return 48.0
        case .fps50:       return 50.0
        case .fps59_94_ndf, .fps59_94_df: return 60000.0 / 1001.0
        case .fps60:       return 60.0
        }
    }

    public var isDropFrame: Bool {
        switch self {
        case .fps29_97_df, .fps59_94_df: return true
        default: return false
        }
    }

    /// Nominal (integer) frame count used for SMPTE component labeling,
    /// e.g. 30 for 29.97, 60 for 59.94.
    public var nominalFPS: Int {
        Int(value.rounded())
    }

    /// Frame numbers skipped at the start of each minute (except every 10th)
    /// in SMPTE drop-frame counting: 2 for 29.97DF, 4 for 59.94DF.
    public var droppedFramesPerMinute: Int {
        switch self {
        case .fps29_97_df: return 2
        case .fps59_94_df: return 4
        default: return 0
        }
    }

    public var isNTSC: Bool {
        switch self {
        case .fps29_97_ndf, .fps29_97_df, .fps59_94_ndf, .fps59_94_df, .fps23_976, .fps47_952:
            return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .fps23_976:    return String(localized: "23.976 fps (NTSC film)")
        case .fps24:        return String(localized: "24 fps (film)")
        case .fps25:        return String(localized: "25 fps (PAL)")
        case .fps29_97_ndf: return String(localized: "29.97 fps NDF (NTSC)")
        case .fps29_97_df:  return String(localized: "29.97 fps DF (NTSC)")
        case .fps30:        return String(localized: "30 fps")
        case .fps47_952:    return String(localized: "47.952 fps")
        case .fps48:        return String(localized: "48 fps")
        case .fps50:        return String(localized: "50 fps")
        case .fps59_94_ndf: return String(localized: "59.94 fps NDF")
        case .fps59_94_df:  return String(localized: "59.94 fps DF")
        case .fps60:        return String(localized: "60 fps")
        }
    }

    /// Compact tag for naming duplicated tracks, e.g. "25fps" → "My Subtitle (25fps)".
    public var shortLabel: String {
        switch self {
        case .fps23_976:    return "23.976fps"
        case .fps24:        return "24fps"
        case .fps25:        return "25fps"
        case .fps29_97_ndf: return "29.97fps"
        case .fps29_97_df:  return "29.97DF"
        case .fps30:        return "30fps"
        case .fps47_952:    return "47.952fps"
        case .fps48:        return "48fps"
        case .fps50:        return "50fps"
        case .fps59_94_ndf: return "59.94fps"
        case .fps59_94_df:  return "59.94DF"
        case .fps60:        return "60fps"
        }
    }
}

// MARK: - Timecode

/// Frame-accurate timecode with SMPTE string conversion.
public struct Timecode: Codable, Equatable, Comparable, Hashable {
    public var totalFrames: Int64
    public var frameRate: FrameRate

    public init(totalFrames: Int64, frameRate: FrameRate) {
        self.totalFrames = totalFrames
        self.frameRate = frameRate
    }

    /// Create from hours, minutes, seconds, frames.
    /// For drop-frame rates the components are SMPTE labels: the dropped frame
    /// numbers (;00/;01 at 29.97DF) don't exist at the start of most minutes,
    /// so labels are converted to a true frame count. Non-existent labels
    /// (e.g. 00:01:00;00) are snapped forward to the first valid frame.
    public init(h: Int, m: Int, s: Int, f: Int, frameRate: FrameRate) {
        let fps = frameRate.nominalFPS
        let d = frameRate.droppedFramesPerMinute
        var f = f
        if d > 0, s == 0, m % 10 != 0, f < d { f = d }
        let totalMinutes = h * 60 + m
        let dropped = d * (totalMinutes - totalMinutes / 10)
        self.totalFrames = Int64(h * 3600 + m * 60 + s) * Int64(fps) + Int64(f) - Int64(dropped)
        self.frameRate = frameRate
    }

    public var seconds: Double {
        Double(totalFrames) / frameRate.value
    }

    public var milliseconds: Int {
        Int((seconds * 1000).rounded())
    }

    public var components: (h: Int, m: Int, s: Int, f: Int) {
        let fps = Int64(frameRate.nominalFPS)
        let d = Int64(frameRate.droppedFramesPerMinute)
        var frameNumber = totalFrames
        if d > 0, frameNumber > 0 {
            // Re-insert the dropped frame numbers so the labels come out in
            // SMPTE drop-frame counting (2 labels skipped per minute except
            // every 10th minute at 29.97DF; 4 at 59.94DF).
            let framesPerMinute = fps * 60 - d           // 1798 @ 29.97DF
            let framesPer10Minutes = framesPerMinute * 10 + d  // 17982 @ 29.97DF
            let tenMinChunks = frameNumber / framesPer10Minutes
            let rem = frameNumber % framesPer10Minutes
            frameNumber += d * 9 * tenMinChunks
            if rem > d {
                frameNumber += d * ((rem - d) / framesPerMinute)
            }
        }
        let frames = Int(frameNumber % fps)
        let totalSeconds = Int(frameNumber / fps)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return (h, m, s, frames)
    }

    /// "HH:MM:SS:FF" or "HH:MM:SS;FF" for drop-frame.
    public var smpteString: String {
        let (h, m, s, f) = components
        let sep = frameRate.isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", h, m, s, sep, f)
    }

    /// Parse "HH:MM:SS:FF", "HH:MM:SS;FF", or "HH:MM:SS,mmm".
    public static func parse(_ string: String, frameRate: FrameRate) throws -> Timecode {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try HH:MM:SS:FF or HH:MM:SS;FF
        let smptePattern = #/^(\d{1,2}):(\d{2}):(\d{2})[:;](\d{2})$/#  // requires Swift 5.7+ regex
        if #available(macOS 13.0, *) {
            if let match = try? smptePattern.wholeMatch(in: trimmed) {
                let h = Int(match.1)!, m = Int(match.2)!, s = Int(match.3)!, f = Int(match.4)!
                return Timecode(h: h, m: m, s: s, f: f, frameRate: frameRate)
            }
        }

        // Try HH:MM:SS,mmm (milliseconds)
        let msPattern = #/^(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})$/#
        if #available(macOS 13.0, *) {
            if let match = try? msPattern.wholeMatch(in: trimmed) {
                let h = Int(match.1)!, m = Int(match.2)!, s = Int(match.3)!, ms = Int(match.4)!
                let total = Double(h * 3600 + m * 60 + s) + Double(ms) / 1000.0
                return Timecode.fromSeconds(total, frameRate: frameRate)
            }
        }

        throw TimecodeError.invalidFormat(string)
    }

    /// Parse a timecode that may be negative ("-HH:MM:SS:FF" or "-HH:MM:SS,mmm").
    /// Used by the "offset by" sheet so users can shift subs *backwards* in time.
    /// The returned `totalFrames` may be negative; offsets that push subtitles
    /// below frame 0 are clamped when the caller applies them to the document.
    public static func parseSigned(_ string: String, frameRate: FrameRate) throws -> Timecode {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TimecodeError.invalidFormat(string) }
        let sign: Int64 = trimmed.hasPrefix("-") ? -1 : 1
        let body = sign == -1 ? String(trimmed.dropFirst()) : trimmed
        let base = try parse(body, frameRate: frameRate)
        return Timecode(totalFrames: sign * base.totalFrames, frameRate: frameRate)
    }

    public static func fromSeconds(_ seconds: Double, frameRate: FrameRate) -> Timecode {
        let frames = Int64(seconds * frameRate.value)
        return Timecode(totalFrames: frames, frameRate: frameRate)
    }

    /// Duration as string "00:00:03:12" or millisecond variant.
    public var durationString: String { smpteString }

    // Comparable — mixed frame rates are compared by wall-clock time.
    public static func < (lhs: Timecode, rhs: Timecode) -> Bool {
        if lhs.frameRate == rhs.frameRate { return lhs.totalFrames < rhs.totalFrames }
        return lhs.seconds < rhs.seconds
    }

    public static let zero = Timecode(totalFrames: 0, frameRate: .fps25)

    /// Mixed frame rates are converted to the left operand's rate (wall-clock)
    /// instead of trapping, matching `offset(by:)`.
    public static func + (lhs: Timecode, rhs: Timecode) -> Timecode {
        let r = rhs.frameRate == lhs.frameRate ? rhs : rhs.converted(to: lhs.frameRate)
        return Timecode(totalFrames: lhs.totalFrames + r.totalFrames, frameRate: lhs.frameRate)
    }

    public static func - (lhs: Timecode, rhs: Timecode) -> Timecode {
        let r = rhs.frameRate == lhs.frameRate ? rhs : rhs.converted(to: lhs.frameRate)
        return Timecode(totalFrames: lhs.totalFrames - r.totalFrames, frameRate: lhs.frameRate)
    }

    public func offset(by other: Timecode) -> Timecode {
        let converted = other.converted(to: frameRate)
        return Timecode(totalFrames: totalFrames + converted.totalFrames, frameRate: frameRate)
    }

    public func converted(to newFrameRate: FrameRate) -> Timecode {
        return Timecode.fromSeconds(seconds, frameRate: newFrameRate)
    }

    /// Re-express this timecode at a new frame rate while KEEPING the on-screen
    /// HH:MM:SS:FF components — so `10:00:00:00@24` stays `10:00:00:00@25`.
    /// Frames are recomputed from the components, not from wall-clock seconds.
    /// Used to hold a programme-start base fixed during a frame-for-frame
    /// (film↔PAL) conversion.
    public func relabeled(to newFrameRate: FrameRate) -> Timecode {
        let c = components
        let fps = max(1, newFrameRate.nominalFPS)
        let f = min(c.f, fps - 1)
        return Timecode(h: c.h, m: c.m, s: c.s, f: f, frameRate: newFrameRate)
    }
}

public enum TimecodeError: LocalizedError {
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let s): return s
        }
    }
}

// MARK: - Subtitle

public struct Subtitle: Codable, Identifiable, Equatable {
    public var id: UUID
    public var startTime: Timecode
    public var endTime: Timecode
    public var textBlocks: [TextBlock]

    // Positioning
    public var verticalPosition: VerticalPosition
    public var horizontalPosition: HorizontalPosition
    public var alignment: TextAlignment

    // Position override — when false the subtitle follows the track default
    public var useCustomPosition: Bool

    // Flags (matching Annotation Edit's TextBoxEntry)
    public var isForced: Bool
    public var isMusic: Bool
    public var isOffSpeech: Bool
    public var isNewScene: Bool
    public var hasRevision: Bool

    /// True if this cue's content was created or materially changed by an
    /// AI/beta feature. This flag is inert for core interpretation: stable
    /// builds preserve it on save but do not act on it, so projects using
    /// beta AI features remain openable in stable releases.
    public var isAI: Bool

    // SDH: Speaker identification for deaf/hard-of-hearing captions
    public var speaker: String

    /// On-screen time in wall-clock seconds.
    public var durationSeconds: Double {
        endTime.seconds - startTime.seconds
    }

    public var cps: Double {
        let chars = textBlocks.reduce(0) { $0 + $1.characterCount }
        let dur = endTime.seconds - startTime.seconds
        return dur > 0 ? Double(chars) / dur : 0
    }

    public var maxCPL: Int {
        let lines = plainText.components(separatedBy: "\n")
        return lines.map(\.count).max() ?? 0
    }

    public init(
        id: UUID = UUID(),
        startTime: Timecode,
        endTime: Timecode,
        textBlocks: [TextBlock] = [],
        verticalPosition: VerticalPosition = .safeArea(.bottom),
        horizontalPosition: HorizontalPosition = .centered,
        alignment: TextAlignment = .center,
        useCustomPosition: Bool = false,
        isForced: Bool = false,
        isMusic: Bool = false,
        isOffSpeech: Bool = false,
        isNewScene: Bool = false,
        hasRevision: Bool = false,
        isAI: Bool = false,
        speaker: String = ""
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.textBlocks = textBlocks
        self.verticalPosition = verticalPosition
        self.horizontalPosition = horizontalPosition
        self.alignment = alignment
        self.useCustomPosition = useCustomPosition
        self.isForced = isForced
        self.isMusic = isMusic
        self.isOffSpeech = isOffSpeech
        self.isNewScene = isNewScene
        self.hasRevision = hasRevision
        self.isAI = isAI
        self.speaker = speaker
    }

    /// Backward-compatible overload for code compiled before `isAI` was added.
    @available(*, deprecated, message: "Use the initializer that includes isAI.")
    public init(
        id: UUID = UUID(),
        startTime: Timecode,
        endTime: Timecode,
        textBlocks: [TextBlock] = [],
        verticalPosition: VerticalPosition = .safeArea(.bottom),
        horizontalPosition: HorizontalPosition = .centered,
        alignment: TextAlignment = .center,
        useCustomPosition: Bool = false,
        isForced: Bool = false,
        isMusic: Bool = false,
        isOffSpeech: Bool = false,
        isNewScene: Bool = false,
        hasRevision: Bool = false,
        speaker: String = ""
    ) {
        self.init(
            id: id,
            startTime: startTime,
            endTime: endTime,
            textBlocks: textBlocks,
            verticalPosition: verticalPosition,
            horizontalPosition: horizontalPosition,
            alignment: alignment,
            useCustomPosition: useCustomPosition,
            isForced: isForced,
            isMusic: isMusic,
            isOffSpeech: isOffSpeech,
            isNewScene: isNewScene,
            hasRevision: hasRevision,
            isAI: false,
            speaker: speaker
        )
    }

    public var plainText: String {
        textBlocks.map { $0.plainText }.joined(separator: "\n")
    }

    /// True when any segment carries an explicit (non-default) colour.
    public var hasColor: Bool {
        textBlocks.contains { $0.segments.contains { $0.color != nil } }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, textBlocks
        case verticalPosition, horizontalPosition, alignment, useCustomPosition
        case isForced, isMusic, isOffSpeech, isNewScene, hasRevision, isAI, speaker
    }

    /// Tolerant decoder for forward/backward project compatibility.
    ///
    /// Every flag and metadata field is decoded with `decodeIfPresent` and a
    /// default, so projects written by older builds (which lack newer keys such
    /// as `isAI`, added in 1.0.0) still open, and projects written by beta
    /// builds (which carry beta-only keys) open in stable. Only `startTime` and
    /// `endTime` are required — a cue without timing is not a valid subtitle.
    ///
    /// `encode(to:)` stays synthesized from `CodingKeys`, so every field is
    /// still written out and round-trips losslessly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startTime = try c.decode(Timecode.self, forKey: .startTime)
        endTime = try c.decode(Timecode.self, forKey: .endTime)
        textBlocks = try c.decodeIfPresent([TextBlock].self, forKey: .textBlocks) ?? []
        verticalPosition = try c.decodeIfPresent(VerticalPosition.self, forKey: .verticalPosition) ?? .safeArea(.bottom)
        horizontalPosition = try c.decodeIfPresent(HorizontalPosition.self, forKey: .horizontalPosition) ?? .centered
        alignment = try c.decodeIfPresent(TextAlignment.self, forKey: .alignment) ?? .center
        useCustomPosition = try c.decodeIfPresent(Bool.self, forKey: .useCustomPosition) ?? false
        isForced = try c.decodeIfPresent(Bool.self, forKey: .isForced) ?? false
        isMusic = try c.decodeIfPresent(Bool.self, forKey: .isMusic) ?? false
        isOffSpeech = try c.decodeIfPresent(Bool.self, forKey: .isOffSpeech) ?? false
        isNewScene = try c.decodeIfPresent(Bool.self, forKey: .isNewScene) ?? false
        hasRevision = try c.decodeIfPresent(Bool.self, forKey: .hasRevision) ?? false
        isAI = try c.decodeIfPresent(Bool.self, forKey: .isAI) ?? false
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? ""
    }
}

// MARK: - SDH Flags

/// SDH (Subtitles for the Deaf or Hard-of-Hearing) classification flags
/// with standardized color coding used in professional subtitling workflows.
///
/// Color codes follow industry conventions:
/// - **White**: Regular dialogue (default, no flag)
/// - **Green**: Music / musical content (`isMusic`)
/// - **Yellow**: Off-screen / voice-over speech (`isOffSpeech`)
/// - **Blue**: Scene change / new scene indicator (`isNewScene`)
/// - **Red / Italic**: Forced narrative — foreign-language dialogue (`isForced`)
/// - **Cyan**: Speaker identification label (`speaker` is non-empty)
public enum SDHFlag: String, Codable, CaseIterable {
    case music     = "music"
    case offSpeech = "offSpeech"
    case newScene  = "newScene"
    case forced    = "forced"
    case speaker   = "speaker"

    public var label: String {
        switch self {
        case .music:     return String(localized: "Music")
        case .offSpeech: return String(localized: "Off-Screen")
        case .newScene:  return String(localized: "New Scene")
        case .forced:    return String(localized: "Forced")
        case .speaker:   return String(localized: "Speaker")
        }
    }

    public var symbol: String {
        switch self {
        case .music:     return "♪"
        case .offSpeech: return "OS"
        case .newScene:  return "NS"
        case .forced:    return "F"
        case .speaker:   return "🗣"
        }
    }

    /// Human-readable description of the SDH flag meaning
    public var description: String {
        switch self {
        case .music:     return String(localized: "Musical content — lyrics, song titles, or music indicators")
        case .offSpeech: return String(localized: "Off-screen dialogue — speaker is not visible in the scene")
        case .newScene:  return String(localized: "New scene — marks a scene transition for the viewer")
        case .forced:    return String(localized: "Forced narrative — essential foreign-language dialogue that must always display")
        case .speaker:   return String(localized: "Speaker identification — identifies who is speaking")
        }
    }

    /// Example of how this flag appears in subtitle text
    public var example: String {
        switch self {
        case .music:     return String(localized: "♪ gentle piano music ♪")
        case .offSpeech: return String(localized: "(OFF-SCREEN): I'll be right there.")
        case .newScene:  return String(localized: "[NEW SCENE]")
        case .forced:    return String(localized: "(speaking French): Je ne comprends pas.")
        case .speaker:   return String(localized: "JOHN:\nI can't believe it.")
        }
    }
}

extension Subtitle {
    /// Returns the first active SDH flag, or nil if none are set.
    /// Priority: music > offSpeech > forced > newScene > speaker
    public var primarySDHFlag: SDHFlag? {
        if isMusic     { return .music }
        if isOffSpeech { return .offSpeech }
        if isForced    { return .forced }
        if isNewScene  { return .newScene }
        if !speaker.isEmpty { return .speaker }
        return nil
    }
}

// MARK: - Text Styling

public struct TextBlock: Codable, Equatable {
    public var segments: [TextSegment]

    public init(segments: [TextSegment]) { self.segments = segments }

    public init(plainText: String) {
        self.segments = [TextSegment(text: plainText, style: [])]
    }

    public var characterCount: Int {
        segments.reduce(0) { $0 + $1.text.count }
    }

    public var plainText: String {
        segments.map(\.text).joined()
    }

    /// Splits this block at every embedded "\n" into one block per display line,
    /// preserving each segment's styling. A block with no newline returns itself
    /// unchanged. Restores the "one block per line" invariant for cues that were
    /// stored with embedded newlines by an older Subtitle Editor.
    public func splitOnNewlines() -> [TextBlock] {
        guard segments.contains(where: { $0.text.contains("\n") }) else { return [self] }
        var lines: [[TextSegment]] = [[]]
        for seg in segments {
            let parts = seg.text.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 { lines.append([]) }   // a newline opens the next line
                if !part.isEmpty {
                    lines[lines.count - 1].append(TextSegment(text: part, style: seg.style))
                }
            }
        }
        return lines.map { TextBlock(segments: $0.isEmpty ? [TextSegment(text: "", style: [])] : $0) }
    }
}

/// An RGB text colour carried by a `TextSegment`. `nil` on the segment means
/// "format default" (white in every subtitle format AlphaSub handles).
public struct TextColor: Codable, Equatable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// "#RRGGBB", lowercase hex digits.
    public var hexString: String {
        String(format: "#%02x%02x%02x", r, g, b)
    }

    /// Parse "#RGB", "#RRGGBB", or "#RRGGBBAA" (alpha ignored). The leading
    /// "#" is optional.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch s.count {
        case 3:
            let chars = Array(s)
            guard let r = UInt8(String([chars[0], chars[0]]), radix: 16),
                  let g = UInt8(String([chars[1], chars[1]]), radix: 16),
                  let b = UInt8(String([chars[2], chars[2]]), radix: 16)
            else { return nil }
            self.init(r: r, g: g, b: b)
        case 6, 8:
            guard let r = UInt8(s.prefix(2), radix: 16),
                  let g = UInt8(s.dropFirst(2).prefix(2), radix: 16),
                  let b = UInt8(s.dropFirst(4).prefix(2), radix: 16)
            else { return nil }
            self.init(r: r, g: g, b: b)
        default:
            return nil
        }
    }

    // The 8 teletext/EBU alpha colours.
    public static let black   = TextColor(r: 0x00, g: 0x00, b: 0x00)
    public static let red     = TextColor(r: 0xFF, g: 0x00, b: 0x00)
    public static let green   = TextColor(r: 0x00, g: 0xFF, b: 0x00)
    public static let yellow  = TextColor(r: 0xFF, g: 0xFF, b: 0x00)
    public static let blue    = TextColor(r: 0x00, g: 0x00, b: 0xFF)
    public static let magenta = TextColor(r: 0xFF, g: 0x00, b: 0xFF)
    public static let cyan    = TextColor(r: 0x00, g: 0xFF, b: 0xFF)
    public static let white   = TextColor(r: 0xFF, g: 0xFF, b: 0xFF)

    /// The 8 teletext colours in EBU control-code order (0x00 AlphaBlack …
    /// 0x07 AlphaWhite).
    public static let teletextColors: [TextColor] = [
        .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white,
    ]

    /// The nearest of the 8 teletext colours by RGB distance. Used by formats
    /// (EBU STL) that can only carry the teletext palette.
    public var closestTeletextColor: TextColor {
        func dist(_ c: TextColor) -> Int {
            let dr = Int(r) - Int(c.r), dg = Int(g) - Int(c.g), db = Int(b) - Int(c.b)
            return dr * dr + dg * dg + db * db
        }
        return TextColor.teletextColors.min { dist($0) < dist($1) } ?? .white
    }

    /// CSS/HTML colour names: the 8 teletext names plus common aliases.
    /// Case-insensitive. Used by SRT `<font color>` and TTML `tts:color`.
    public init?(named name: String) {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "white":              self = .white
        case "yellow":             self = .yellow
        case "cyan", "aqua":       self = .cyan
        case "green":              self = TextColor(r: 0x00, g: 0x80, b: 0x00)
        case "lime":               self = .green
        case "magenta", "fuchsia": self = .magenta
        case "red":                self = .red
        case "blue":               self = .blue
        case "black":              self = .black
        case "gray", "grey":       self = TextColor(r: 0x80, g: 0x80, b: 0x80)
        case "silver":             self = TextColor(r: 0xC0, g: 0xC0, b: 0xC0)
        case "orange":             self = TextColor(r: 0xFF, g: 0xA5, b: 0x00)
        case "purple":             self = TextColor(r: 0x80, g: 0x00, b: 0x80)
        case "pink":               self = TextColor(r: 0xFF, g: 0xC0, b: 0xCB)
        case "brown":              self = TextColor(r: 0xA5, g: 0x2A, b: 0x2A)
        default:                   return nil
        }
    }
}

public struct TextSegment: Codable, Equatable {
    public var text: String
    public var style: TextStyle
    /// `nil` = format default colour (white).
    public var color: TextColor?

    public init(text: String, style: TextStyle = [], color: TextColor? = nil) {
        self.text = text
        self.style = style
        self.color = color
    }

    // MARK: Codable
    //
    // `color` is decoded tolerantly and only written when non-nil, so projects
    // saved without colours stay byte-compatible with older app versions, and
    // old projects (no `color` key) still open.

    private enum CodingKeys: String, CodingKey {
        case text, style, color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        style = try c.decodeIfPresent(TextStyle.self, forKey: .style) ?? []
        color = try c.decodeIfPresent(TextColor.self, forKey: .color)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(style, forKey: .style)
        try c.encodeIfPresent(color, forKey: .color)
    }
}

public struct TextStyle: Codable, OptionSet, Equatable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let italic    = TextStyle(rawValue: 1 << 0)
    public static let bold      = TextStyle(rawValue: 1 << 1)
    public static let underline = TextStyle(rawValue: 1 << 2)
    public static let ruby      = TextStyle(rawValue: 1 << 3)   // SDH
    public static let strikethrough = TextStyle(rawValue: 1 << 4)
}

// MARK: - Positioning

public enum VerticalPosition: Codable, Equatable {
    case row(Int)                   // Teletext row 1-23
    case lineShift(Int)            // Lines shifted from safe area
    case percentage(Double)        // 0-100 percent from top of active pixel area (DCP/TTML/InterOp standard)
    case safeArea(SafeAreaPosition)

    public static let bottom: VerticalPosition = .safeArea(.bottom)
    public static let center: VerticalPosition = .safeArea(.center)
    public static let top: VerticalPosition    = .safeArea(.top)
}

public enum SafeAreaPosition: String, Codable {
    case top, center, bottom
}

public enum HorizontalPosition: Codable, Equatable {
    case centered                  // 50% (center of active pixel area width)
    case leftAligned               // 0% (left edge)
    case rightAligned              // 100% (right edge)
    case percentage(Double)        // 0-100 percent from left of active pixel area (DCP/TTML/InterOp standard)
}

public enum TextAlignment: String, Codable {
    case left, center, right, start, end
}

// MARK: - Track

public struct Track: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var language: LanguageCode
    public var subtitles: [Subtitle]
    public var formatOrigin: String?     // "srt", "stl", "scc", etc.
    public var timecodeOffset: Timecode? // Offset from program start
    public var metadata: FormatMetadata  // Preserved format-specific metadata

    /// The track's frame rate. When the track has cues, the cues' timecodes
    /// are authoritative and this field is kept in sync with them (see
    /// `effectiveFrameRate`). When the track is empty, this field holds the
    /// intended rate for new cues (e.g. the rate chosen in the New Project
    /// sheet). `nil` on old projects that predate the field; resolved via
    /// `effectiveFrameRate(videoFrameRate:)`.
    public var frameRate: FrameRate?

    /// Track-level default positioning (used when subtitle.useCustomPosition is false).
    /// Stored in metadata so existing documents remain compatible.
    public var defaultHorizontalPosition: HorizontalPosition {
        get {
            if let pct = metadata["track_default_hpos_pct"], let v = Double(pct) {
                return .percentage(v)
            }
            if metadata["track_default_hpos"] == "left" { return .leftAligned }
            if metadata["track_default_hpos"] == "right" { return .rightAligned }
            return .centered
        }
        set {
            switch newValue {
            case .centered: metadata["track_default_hpos"] = "center"
                metadata.removeValue(forKey: "track_default_hpos_pct")
            case .leftAligned: metadata["track_default_hpos"] = "left"
                metadata.removeValue(forKey: "track_default_hpos_pct")
            case .rightAligned: metadata["track_default_hpos"] = "right"
                metadata.removeValue(forKey: "track_default_hpos_pct")
            case .percentage(let v):
                metadata["track_default_hpos_pct"] = String(format: "%.1f", v)
                metadata["track_default_hpos"] = "percentage"
            }
        }
    }

    public var defaultVerticalPosition: VerticalPosition {
        get {
            if let pct = metadata["track_default_vpos_pct"], let v = Double(pct) {
                return .percentage(v)
            }
            if let row = metadata["track_default_vpos_row"], let v = Int(row) {
                return .row(v)
            }
            if metadata["track_default_vpos"] == "top" { return .safeArea(.top) }
            if metadata["track_default_vpos"] == "center" { return .safeArea(.center) }
            return .safeArea(.bottom)
        }
        set {
            switch newValue {
            case .safeArea(.top): metadata["track_default_vpos"] = "top"
                metadata.removeValue(forKey: "track_default_vpos_pct")
                metadata.removeValue(forKey: "track_default_vpos_row")
            case .safeArea(.center): metadata["track_default_vpos"] = "center"
                metadata.removeValue(forKey: "track_default_vpos_pct")
                metadata.removeValue(forKey: "track_default_vpos_row")
            case .safeArea(.bottom): metadata["track_default_vpos"] = "bottom"
                metadata.removeValue(forKey: "track_default_vpos_pct")
                metadata.removeValue(forKey: "track_default_vpos_row")
            case .percentage(let v):
                metadata["track_default_vpos_pct"] = String(format: "%.1f", v)
                metadata["track_default_vpos"] = "percentage"
                metadata.removeValue(forKey: "track_default_vpos_row")
            case .row(let v):
                metadata["track_default_vpos_row"] = String(v)
                metadata["track_default_vpos"] = "row"
                metadata.removeValue(forKey: "track_default_vpos_pct")
            case .lineShift(let v):
                metadata["track_default_vpos_row"] = String(v)
                metadata["track_default_vpos"] = "lineShift"
                metadata.removeValue(forKey: "track_default_vpos_pct")
            }
        }
    }

    public var defaultAlignment: TextAlignment {
        get {
            TextAlignment(rawValue: metadata["track_default_align"] ?? "center") ?? .center
        }
        set { metadata["track_default_align"] = newValue.rawValue }
    }

    /// Resolve the effective position for a given subtitle, falling back to track defaults
    /// when `subtitle.useCustomPosition` is false.
    public func effectivePosition(for subtitle: Subtitle) -> (vertical: VerticalPosition, horizontal: HorizontalPosition, alignment: TextAlignment) {
        if subtitle.useCustomPosition {
            return (subtitle.verticalPosition, subtitle.horizontalPosition, subtitle.alignment)
        }
        return (defaultVerticalPosition, defaultHorizontalPosition, defaultAlignment)
    }

    /// The track's effective frame rate. The cues' timecodes are
    /// authoritative when the track has cues; otherwise fall back to the
    /// stored `frameRate` field; otherwise to the detected video frame rate
    /// (if any); otherwise to the document default.
    public func effectiveFrameRate(videoFrameRate: FrameRate? = nil, default: FrameRate = .fps25) -> FrameRate {
        if let cueFR = subtitles.first?.startTime.frameRate {
            return cueFR
        }
        return frameRate ?? videoFrameRate ?? `default`
    }

    public init(
        id: UUID = UUID(),
        name: String = "New Track",
        language: LanguageCode = "",
        subtitles: [Subtitle] = [],
        formatOrigin: String? = nil,
        timecodeOffset: Timecode? = nil,
        metadata: FormatMetadata = [:],
        frameRate: FrameRate? = nil
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.subtitles = subtitles
        self.formatOrigin = formatOrigin
        self.timecodeOffset = timecodeOffset
        self.metadata = metadata
        self.frameRate = frameRate
    }

    // MARK: Codable (tolerant of older projects that lack `frameRate`)

    private enum CodingKeys: String, CodingKey {
        case id, name, language, subtitles, formatOrigin, timecodeOffset, metadata
        case frameRate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Track"
        self.language = try c.decodeIfPresent(LanguageCode.self, forKey: .language) ?? ""
        self.subtitles = try c.decodeIfPresent([Subtitle].self, forKey: .subtitles) ?? []
        self.formatOrigin = try c.decodeIfPresent(String.self, forKey: .formatOrigin)
        self.timecodeOffset = try c.decodeIfPresent(Timecode.self, forKey: .timecodeOffset)
        self.metadata = try c.decodeIfPresent(FormatMetadata.self, forKey: .metadata) ?? [:]
        self.frameRate = try c.decodeIfPresent(FrameRate.self, forKey: .frameRate)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(language, forKey: .language)
        try c.encode(subtitles, forKey: .subtitles)
        try c.encodeIfPresent(formatOrigin, forKey: .formatOrigin)
        try c.encodeIfPresent(timecodeOffset, forKey: .timecodeOffset)
        try c.encode(metadata, forKey: .metadata)
        try c.encodeIfPresent(frameRate, forKey: .frameRate)
    }

    public var duration: Timecode? {
        guard let first = subtitles.first?.startTime,
              let last = subtitles.last?.endTime,
              first.frameRate == last.frameRate
        else { return nil }
        return Timecode(totalFrames: last.totalFrames - first.totalFrames, frameRate: first.frameRate)
    }

    /// Limit a (possibly negative) offset so no affected cue's start time is
    /// pushed below 00:00:00:00. Forward or zero offsets pass through unchanged.
    /// A backward shift is honoured up to the earliest affected cue; a larger
    /// backward shift is capped so that earliest cue lands exactly at zero,
    /// which preserves every inter-cue gap instead of collapsing cues onto the
    /// floor. This is the clamp promised by `Timecode.parseSigned`'s contract.
    static func clampBackward(_ offset: Timecode, notBelowZeroFor subs: [Subtitle]) -> Timecode {
        guard offset.totalFrames < 0,
              let earliest = subs.map(\.startTime).min(by: { $0.seconds < $1.seconds })
        else { return offset }
        let maxBackward = earliest.converted(to: offset.frameRate).totalFrames  // >= 0
        if offset.totalFrames < -maxBackward {
            return Timecode(totalFrames: -maxBackward, frameRate: offset.frameRate)
        }
        return offset
    }

    /// Apply `offset` to a single cue while guaranteeing a non-negative result.
    /// The per-cue `max(0, …)` is a rounding backstop only — `clampBackward`
    /// already prevents any meaningful negative, so this never collapses cues.
    private static func offsetFloored(_ tc: Timecode, by offset: Timecode) -> Timecode {
        let shifted = tc.offset(by: offset)
        return Timecode(totalFrames: max(0, shifted.totalFrames), frameRate: shifted.frameRate)
    }

    public func offsetAll(by offset: Timecode) -> Track {
        let clamped = Track.clampBackward(offset, notBelowZeroFor: subtitles)
        var track = self
        track.subtitles = subtitles.map { sub in
            var s = sub
            s.startTime = Track.offsetFloored(sub.startTime, by: clamped)
            s.endTime = Track.offsetFloored(sub.endTime, by: clamped)
            return s
        }
        if let existingOffset = timecodeOffset {
            track.timecodeOffset = existingOffset.offset(by: clamped)
        } else {
            track.timecodeOffset = clamped
        }
        return track
    }

    public func offset(ids: Set<UUID>, by offset: Timecode) -> Track {
        let clamped = Track.clampBackward(offset, notBelowZeroFor: subtitles.filter { ids.contains($0.id) })
        var track = self
        track.subtitles = subtitles.map { sub in
            guard ids.contains(sub.id) else { return sub }
            var s = sub
            s.startTime = Track.offsetFloored(sub.startTime, by: clamped)
            s.endTime = Track.offsetFloored(sub.endTime, by: clamped)
            return s
        }
        return track
    }

    public func offsetAll(to targetStart: Timecode) -> Track {
        guard let first = subtitles.first else { return self }
        let offsetTC = Timecode(totalFrames: targetStart.totalFrames - first.startTime.totalFrames, frameRate: targetStart.frameRate)
        return offsetAll(by: offsetTC)
    }

    public func offset(ids: Set<UUID>, to targetStart: Timecode) -> Track {
        guard let firstInRange = subtitles.first(where: { ids.contains($0.id) }) else { return self }
        let offsetTC = Timecode(totalFrames: targetStart.totalFrames - firstInRange.startTime.totalFrames, frameRate: targetStart.frameRate)
        return offset(ids: ids, by: offsetTC)
    }

    public func babySync(firstTarget: Timecode, lastTarget: Timecode) -> Track {
        guard subtitles.count >= 2 else {
            return offsetAll(to: firstTarget)
        }
        let oldFirst = subtitles.first!.startTime
        let oldLast  = subtitles.last!.startTime
        let oldRange = oldLast.totalFrames - oldFirst.totalFrames
        guard oldRange > 0 else {
            return offsetAll(to: firstTarget)
        }
        let ratio = Double(lastTarget.totalFrames - firstTarget.totalFrames) / Double(oldRange)
        var track = self
        track.subtitles = subtitles.map { sub in
            var s = sub
            let newStart = firstTarget.totalFrames + Int64(Double(sub.startTime.totalFrames - oldFirst.totalFrames) * ratio)
            let newEnd   = firstTarget.totalFrames + Int64(Double(sub.endTime.totalFrames   - oldFirst.totalFrames) * ratio)
            s.startTime = Timecode(totalFrames: max(0, newStart), frameRate: firstTarget.frameRate)
            s.endTime   = Timecode(totalFrames: max(newStart, newEnd), frameRate: firstTarget.frameRate)
            return s
        }
        track.timecodeOffset = firstTarget
        return track
    }

    public func convertFrameRate(to newFrameRate: FrameRate) -> Track {
        var track = self
        track.subtitles = subtitles.map { sub in
            var s = sub
            s.startTime = sub.startTime.converted(to: newFrameRate)
            s.endTime = sub.endTime.converted(to: newFrameRate)
            return s
        }
        track.timecodeOffset = timecodeOffset?.converted(to: newFrameRate)
        track.frameRate = newFrameRate
        return track
    }

    /// Convert this track's frame rate frame-for-frame while holding a `base`
    /// timecode fixed (e.g. a 10:00:00:00 programme start). The base keeps its
    /// on-screen value; only the portion *after* the base is re-stamped at the
    /// new rate, so the same frame count maps to its new real duration. This is
    /// the classic film↔PAL "pull" conversion and, unlike
    /// `convertFrameRate(to:)`, it never scales the base into a huge offset:
    /// `10:00:20:16@24` → `10:00:19:21@25`, not `09:36:…`.
    public func convertFrameRateHoldingBase(to newFrameRate: FrameRate, base: Timecode) -> Track {
        let oldBaseFrames = base.totalFrames
        let newBaseFrames = base.relabeled(to: newFrameRate).totalFrames
        func remap(_ t: Timecode) -> Timecode {
            // Frames relative to the base are preserved exactly (frame-for-frame),
            // then re-anchored on the base re-expressed at the new rate.
            let rel = max(0, t.totalFrames - oldBaseFrames)
            return Timecode(totalFrames: newBaseFrames + rel, frameRate: newFrameRate)
        }
        var track = self
        track.subtitles = subtitles.map { sub in
            var s = sub
            s.startTime = remap(sub.startTime)
            s.endTime = remap(sub.endTime)
            return s
        }
        track.timecodeOffset = timecodeOffset.map { remap($0) }
        track.frameRate = newFrameRate
        return track
    }
}

/// BCP-47 language tag.
public struct LanguageCode: Codable, Equatable, ExpressibleByStringLiteral, Hashable {
    public var rawValue: String

    public init(stringLiteral value: String) { self.rawValue = LanguageCode.canonicalize(value) }
    public init(_ value: String) { self.rawValue = LanguageCode.canonicalize(value) }

    /// Lowercase the language subtag and uppercase any 2- or 3-letter region
    /// subtag. Mirrors the rules in `LanguageCodeNormalizer.normalize` but lives
    /// here so Core stays independent of the Language target.
    public static func canonicalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split(separator: "-").map(String.init)
        guard let first = parts.first, !first.isEmpty else { return "" }
        var out: [String] = [first.lowercased()]
        for sub in parts.dropFirst() {
            if sub.count == 4 {
                out.append(sub.prefix(1).uppercased() + sub.dropFirst().lowercased())
            } else if sub.count == 2 || sub.count == 3 {
                out.append(sub.uppercased())
            } else {
                out.append(sub)
            }
        }
        return out.joined(separator: "-")
    }

    /// A canonicalised copy. Currently a no-op (init already canonicalises),
    /// exposed so callers can re-derive after manual mutation of `rawValue`.
    public var canonical: LanguageCode { LanguageCode(rawValue) }

    public var displayName: String {
        // Prefer the ISDCF display name when present; fall back to the system
        // Locale. The ISDCF table is bundled in the Language target, so this
        // lookup is indirect via the Language module when imported.
        Locale(identifier: rawValue).localizedString(forLanguageCode: rawValue) ?? rawValue
    }
}

/// Format-specific metadata preserved for lossless round-tripping.
public typealias FormatMetadata = [String: String]

// MARK: - Document

public struct SubtitleDocument: Codable {
    public var version: Int
    public var metadata: DocumentMetadata
    public var tracks: [Track]
    public var mediaReference: MediaReference?

    /// Opaque metadata reserved for beta/in-development features. Core never
    /// interprets this dictionary; it is preserved on decode/encode so that
    /// stable releases can open projects touched by beta features without
    /// losing data they do not yet understand.
    public var featureMetadata: [String: Data]?

    public init(
        version: Int = 1,
        metadata: DocumentMetadata = .init(),
        tracks: [Track] = [],
        mediaReference: MediaReference? = nil,
        featureMetadata: [String: Data]? = nil
    ) {
        self.version = version
        self.metadata = metadata
        self.tracks = tracks
        self.mediaReference = mediaReference
        self.featureMetadata = featureMetadata
    }

    // MARK: Codable (tolerant of older projects that stored `frameRate` on the document)

    private enum CodingKeys: String, CodingKey {
        case version, metadata, tracks, mediaReference, featureMetadata
        case frameRate   // legacy — read on decode to migrate, never written
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.metadata = try c.decodeIfPresent(DocumentMetadata.self, forKey: .metadata) ?? .init()
        self.tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        self.mediaReference = try c.decodeIfPresent(MediaReference.self, forKey: .mediaReference)
        self.featureMetadata = try c.decodeIfPresent([String: Data].self, forKey: .featureMetadata)
        // Migration: pre-1.0.8 projects stored the frame rate on the document.
        // Apply it to any tracks that have no cues (and thus no cue-derived
        // rate) and no explicit `frameRate` field, so empty tracks keep their
        // intended rate. Tracks with cues already carry the rate via timecodes.
        if let legacyFR = try c.decodeIfPresent(FrameRate.self, forKey: .frameRate) {
            for i in tracks.indices {
                if tracks[i].subtitles.isEmpty && tracks[i].frameRate == nil {
                    tracks[i].frameRate = legacyFR
                }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(tracks, forKey: .tracks)
        try c.encodeIfPresent(mediaReference, forKey: .mediaReference)
        try c.encodeIfPresent(featureMetadata, forKey: .featureMetadata)
        // `frameRate` is intentionally NOT encoded — projects have no frame
        // rate; only the video and the tracks do.
    }

    /// Restores the "one TextBlock per display line" invariant across every cue
    /// by splitting any block that holds embedded "\n". Older projects (and cues
    /// edited before the editor stored lines as separate blocks) could keep all
    /// lines in a single block, which corrupts the line break on export and hides
    /// the cue from per-line conformance checks. Run once on load. Returns the
    /// number of cues repaired.
    @discardableResult
    public mutating func normalizeTextBlockLineBreaks() -> Int {
        var repaired = 0
        for ti in tracks.indices {
            for si in tracks[ti].subtitles.indices {
                let blocks = tracks[ti].subtitles[si].textBlocks
                guard blocks.contains(where: { $0.segments.contains { $0.text.contains("\n") } }) else { continue }
                tracks[ti].subtitles[si].textBlocks = blocks.flatMap { $0.splitOnNewlines() }
                repaired += 1
            }
        }
        return repaired
    }

    public mutating func offsetAll(by offset: Timecode) {
        tracks = tracks.map { $0.offsetAll(by: offset) }
    }

    public mutating func offset(ids: Set<UUID>, by offset: Timecode) {
        tracks = tracks.map { $0.offset(ids: ids, by: offset) }
    }

    public mutating func offsetAll(to targetStart: Timecode) {
        tracks = tracks.enumerated().map { index, track in
            guard track.subtitles.first != nil else { return track }
            let first = track.subtitles.first!
            let offsetTC = Timecode(totalFrames: targetStart.totalFrames - first.startTime.totalFrames, frameRate: targetStart.frameRate)
            return track.offsetAll(by: offsetTC)
        }
    }

    public mutating func offset(ids: Set<UUID>, to targetStart: Timecode) {
        tracks = tracks.map { track in
            guard let firstInRange = track.subtitles.first(where: { ids.contains($0.id) }) else { return track }
            let offsetTC = Timecode(totalFrames: targetStart.totalFrames - firstInRange.startTime.totalFrames, frameRate: targetStart.frameRate)
            return track.offset(ids: ids, by: offsetTC)
        }
    }

    public mutating func babySync(firstTarget: Timecode, lastTarget: Timecode) {
        tracks = tracks.map { $0.babySync(firstTarget: firstTarget, lastTarget: lastTarget) }
    }

    public mutating func convertFrameRate(to newFrameRate: FrameRate) {
        tracks = tracks.map { $0.convertFrameRate(to: newFrameRate) }
    }

    public mutating func findReplaceAll(search: String, replacement: String, matchCase: Bool) -> Int {
        guard !search.isEmpty else { return 0 }
        var totalReplacements = 0
        for ti in tracks.indices {
            for si in tracks[ti].subtitles.indices {
                let sub = tracks[ti].subtitles[si]
                var newBlocks: [TextBlock] = []
                var changed = false
                for block in sub.textBlocks {
                    let original = block.plainText
                    let replaced: String
                    if matchCase {
                        replaced = original.replacingOccurrences(of: search, with: replacement)
                    } else {
                        replaced = original.replacingOccurrences(of: search, with: replacement, options: .caseInsensitive)
                    }
                    if replaced != original {
                        totalReplacements += 1
                        changed = true
                        newBlocks.append(TextBlock(plainText: replaced))
                    } else {
                        newBlocks.append(block)
                    }
                }
                if changed {
                    tracks[ti].subtitles[si].textBlocks = newBlocks
                }
            }
        }
        return totalReplacements
    }

    /// Iterator for find-and-replace one-by-one.  Created from a document
    /// snapshot so it operates on a stable set of tracks / subtitles.
    public struct FindReplaceIterator {
        public let document: SubtitleDocument
        public let search: String
        public let replacement: String
        public let matchCase: Bool
        public var currentTrackIndex: Int = 0
        public var currentSubtitleIndex: Int = 0
        public var currentBlockIndex: Int = 0

        public init(document: SubtitleDocument, search: String, replacement: String, matchCase: Bool) {
            self.document = document
            self.search = search
            self.replacement = replacement
            self.matchCase = matchCase
        }

        private var compareOptions: String.CompareOptions {
            matchCase ? [] : .caseInsensitive
        }

        /// Returns `true` if `text` contains at least one match.
        private func containsMatch(_ text: String) -> Bool {
            text.range(of: search, options: compareOptions) != nil
        }

        /// Advance to the next occurrence and return its coordinates.
        /// Returns `nil` when there are no more matches.
        public mutating func next() -> (trackIdx: Int, subIdx: Int, blockIdx: Int)? {
            while currentTrackIndex < document.tracks.count {
                let track = document.tracks[currentTrackIndex]
                while currentSubtitleIndex < track.subtitles.count {
                    let sub = track.subtitles[currentSubtitleIndex]
                    while currentBlockIndex < sub.textBlocks.count {
                        let block = sub.textBlocks[currentBlockIndex]
                        if containsMatch(block.plainText) {
                            let result = (currentTrackIndex, currentSubtitleIndex, currentBlockIndex)
                            advanceCursor()
                            return result
                        }
                        advanceCursor()
                    }
                }
            }
            return nil
        }

        public mutating func advanceCursor() {
            currentBlockIndex += 1
            if currentBlockIndex >= document.tracks[currentTrackIndex].subtitles[currentSubtitleIndex].textBlocks.count {
                currentBlockIndex = 0
                currentSubtitleIndex += 1
                if currentSubtitleIndex >= document.tracks[currentTrackIndex].subtitles.count {
                    currentSubtitleIndex = 0
                    currentTrackIndex += 1
                }
            }
        }

        /// Peek at the next match without consuming it.
        public func peek() -> (trackIdx: Int, subIdx: Int, blockIdx: Int)? {
            var copy = self
            return copy.next()
        }

        /// How many matches remain starting from the current cursor position?
        public func remainingMatches() -> Int {
            var copy = self
            var count = 0
            while copy.next() != nil { count += 1 }
            return count
        }

        /// Perform replacement at the given coordinates and return the new plain text.
        public func apply(at trackIdx: Int, subIdx: Int, blockIdx: Int) -> String {
            let original = document.tracks[trackIdx].subtitles[subIdx].textBlocks[blockIdx].plainText
            return original.replacingOccurrences(of: search, with: replacement, options: compareOptions)
        }
    }
}

public struct DocumentMetadata: Codable {
    public var title: String
    public var originator: String?
    public var originatorReference: String?
    public var creationDate: Date
    public var revisionDate: Date?
    public var revisionNumber: Int?
    public var countryOrigin: String?
    public var publisher: String?

    public init(
        title: String = "Untitled",
        originator: String? = nil,
        originatorReference: String? = nil,
        creationDate: Date = Date(),
        revisionDate: Date? = nil,
        revisionNumber: Int? = nil,
        countryOrigin: String? = nil,
        publisher: String? = nil
    ) {
        self.title = title
        self.originator = originator
        self.originatorReference = originatorReference
        self.creationDate = creationDate
        self.revisionDate = revisionDate
        self.revisionNumber = revisionNumber
        self.countryOrigin = countryOrigin
        self.publisher = publisher
    }
}

// MARK: - Speech Region

/// Represents a range in time where speech has been detected.
/// Used to highlight the waveform in yellow.
public struct SpeechRegion: Codable, Equatable, Hashable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = max(endSeconds, startSeconds)
    }

    public var durationSeconds: Double { endSeconds - startSeconds }
}

// MARK: - Spectrogram

/// A precomputed, quantized time–frequency representation of the program audio,
/// ready to be turned into an image and blended under the timeline waveform
/// (iZotope-RX-style). The grid is stored column-major: one column per STFT
/// frame, `bins` rows per column on a *log-frequency* axis (row 0 = `minFrequency`,
/// row `bins-1` = `maxFrequency`). Magnitudes are dB-normalized to `UInt8`.
///
/// `voiceness` carries one 0…1 score per frame — a cheap spectral estimate of
/// how speech-like that instant is — used to refine ML VAD output. It is *not*
/// part of the visual grid but shares the same frame axis.
public struct SpectrogramData: Codable, Equatable, Sendable {
    /// Number of time columns (STFT frames).
    public var frames: Int
    /// Number of frequency rows per column.
    public var bins: Int
    /// Sample rate of the analyzed audio (Hz).
    public var sampleRate: Double
    /// Seconds advanced per column (STFT hop / sample rate).
    public var hopSeconds: Double
    /// Lowest frequency represented by row 0 (Hz).
    public var minFrequency: Double
    /// Highest frequency represented by the top row (Hz).
    public var maxFrequency: Double
    /// `frames × bins` magnitudes, column-major: `magnitudes[frame * bins + bin]`.
    public var magnitudes: [UInt8]
    /// One speech-likeness score per frame (0…1). `count == frames` or empty.
    public var voiceness: [Float]

    public init(
        frames: Int,
        bins: Int,
        sampleRate: Double,
        hopSeconds: Double,
        minFrequency: Double,
        maxFrequency: Double,
        magnitudes: [UInt8],
        voiceness: [Float]
    ) {
        self.frames = frames
        self.bins = bins
        self.sampleRate = sampleRate
        self.hopSeconds = hopSeconds
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.magnitudes = magnitudes
        self.voiceness = voiceness
    }

    /// Total analyzed duration covered by the columns (seconds).
    public var durationSeconds: Double { Double(frames) * hopSeconds }

    /// The frame index covering `time` (seconds), clamped to valid range.
    public func frameIndex(at time: Double) -> Int {
        guard hopSeconds > 0, frames > 0 else { return 0 }
        return min(frames - 1, max(0, Int(time / hopSeconds)))
    }
}

public struct MediaReference: Codable {
    public var url: URL
    public var timecodeOffset: Timecode?
    public var programStartTime: Timecode?
    public var videoProfile: VideoProfile?
    public var videoCodec: VideoCodec?
    public var container: VideoContainer?
    public var audioCodec: String?
    public var durationSeconds: Double?
    /// Detected shot changes (hard cuts) in seconds from media start,
    /// ascending. Optional so projects saved before this field existed
    /// decode unchanged, and `nil` is not encoded (synthesized Codable
    /// uses decodeIfPresent/encodeIfPresent for optionals) so older app
    /// versions can still open newer projects.
    public var shotChanges: [Double]?
    /// Length in seconds of a detected counting leader (first frame → the
    /// round-hour programme start), i.e. the end of the leader region in
    /// media-time seconds from file start. `nil` when no leader was detected.
    /// Optional so older projects decode unchanged and it's omitted when nil.
    public var leaderSeconds: Double?

    public init(
        url: URL,
        timecodeOffset: Timecode? = nil,
        programStartTime: Timecode? = nil,
        videoProfile: VideoProfile? = nil,
        videoCodec: VideoCodec? = nil,
        container: VideoContainer? = nil,
        audioCodec: String? = nil,
        durationSeconds: Double? = nil,
        shotChanges: [Double]? = nil,
        leaderSeconds: Double? = nil
    ) {
        self.url = url
        self.timecodeOffset = timecodeOffset
        self.programStartTime = programStartTime
        self.videoProfile = videoProfile
        self.videoCodec = videoCodec
        self.container = container
        self.audioCodec = audioCodec
        self.durationSeconds = durationSeconds
        self.shotChanges = shotChanges
        self.leaderSeconds = leaderSeconds
    }

    public var fileExtension: String {
        url.pathExtension.lowercased()
    }

    public var detectedContainer: VideoContainer? {
        container ?? VideoContainer.from(fileExtension: fileExtension)
    }

    public var displayCodecName: String {
        videoCodec?.shortName ?? "Unknown"
    }
}

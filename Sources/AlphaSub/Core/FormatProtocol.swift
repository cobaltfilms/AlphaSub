import Foundation

// MARK: - Format Identifiers

public struct FormatID: RawRepresentable, Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    // Subtitle formats
    public static let srt    = FormatID(rawValue: "srt")
    public static let stl    = FormatID(rawValue: "stl")
    public static let scc    = FormatID(rawValue: "scc")
    public static let webvtt = FormatID(rawValue: "webvtt")
    public static let ttml   = FormatID(rawValue: "ttml")
    public static let fcpxml = FormatID(rawValue: "fcpxml")
    public static let dcp_smpte  = FormatID(rawValue: "dcp_smpte")
    public static let dcp_interop = FormatID(rawValue: "dcp_interop")
    public static let ass   = FormatID(rawValue: "ass")
    public static let txt   = FormatID(rawValue: "txt")
    public static let avid  = FormatID(rawValue: "avid")
    public static let xlsx  = FormatID(rawValue: "xlsx")
    public static let docx  = FormatID(rawValue: "docx")
    public static let premiere = FormatID(rawValue: "premiere")
    public static let ttml_netflix  = FormatID(rawValue: "ttml_netflix")
    public static let ttml_amazon   = FormatID(rawValue: "ttml_amazon")
    public static let ttml_itunes  = FormatID(rawValue: "ttml_itunes")
    public static let ttml_davinci = FormatID(rawValue: "ttml_davinci")

    // Video containers
    public static let mov = FormatID(rawValue: "mov")
    public static let mp4 = FormatID(rawValue: "mp4")
    public static let mxf = FormatID(rawValue: "mxf")

    // Video codecs
    public static let proRes4444XQ  = FormatID(rawValue: "prores_4444_xq")
    public static let proRes4444    = FormatID(rawValue: "prores_4444")
    public static let proRes422HQ   = FormatID(rawValue: "prores_422_hq")
    public static let proRes422     = FormatID(rawValue: "prores_422")
    public static let proRes422LT   = FormatID(rawValue: "prores_422_lt")
    public static let proRes422Proxy = FormatID(rawValue: "prores_422_proxy")
    public static let h264          = FormatID(rawValue: "h264")
    public static let h265           = FormatID(rawValue: "h265")
    public static let dnxHD          = FormatID(rawValue: "dnxhd")
    public static let dnxHR          = FormatID(rawValue: "dnxhr")
}

// MARK: - Export Result

/// Represents a multi-file export result.
/// For single-file exports, use ``singleFile``.
/// For DCP and other multi-file exports, use ``init(files:)``.
public struct ExportResult {
    /// A named file in the export result.
    public struct ExportFile {
        /// Relative filename (e.g. "font.otf", "subtitle.xml").
        /// For the primary file this should match the format's file extension.
        public var filename: String
        /// The file data.
        public var data: Data

        public init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
        }
    }

    /// All files in the export result.
    public var files: [ExportFile]

    /// The primary file (first file) — used for simple single-file exports.
    public var primaryData: Data? {
        files.first?.data
    }

    /// Create a single-file export result.
    public static func singleFile(filename: String, data: Data) -> ExportResult {
        ExportResult(files: [ExportFile(filename: filename, data: data)])
    }

    /// Create a multi-file export result.
    public init(files: [ExportFile]) {
        self.files = files
    }
}

// MARK: - Format Importer Protocol

public protocol FormatImporter {
    static var formatID: FormatID { get }
    static var formatName: String { get }
    static var fileExtensions: [String] { get }

    /// Quick check: does the data look like this format?
    static func canImport(_ data: Data) -> Bool

    /// Parse data into one or more tracks.
    static func `import`(_ data: Data, options: ImportOptions?) throws -> [Track]
}

// MARK: - Format Exporter Protocol

public protocol FormatExporter {
    static var formatID: FormatID { get }
    static var formatName: String { get }
    static var fileExtension: String { get }

    /// Export tracks to format-specific data.
    static func export(_ tracks: [Track], options: ExportOptions?) throws -> Data

    /// Export tracks to a multi-file result. Default implementation wraps single-file Data.
    static func exportToFiles(_ tracks: [Track], options: ExportOptions?) throws -> ExportResult
}

public extension FormatExporter {
    /// Default implementation: wraps single-file export into an ExportResult.
    static func exportToFiles(_ tracks: [Track], options: ExportOptions?) throws -> ExportResult {
        let data = try export(tracks, options: options)
        let trackName = tracks.first?.name ?? "exported"
        let sanitizedName = trackName
            .components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = sanitizedName.isEmpty ? "exported.\(fileExtension)" : "\(sanitizedName).\(fileExtension)"
        return .singleFile(filename: filename, data: data)
    }
}

// MARK: - Options

public struct ImportOptions {
    /// Target frame rate for timecode conversion.
    public var targetFrameRate: FrameRate?
    /// Language to assign to imported tracks.
    public var defaultLanguage: LanguageCode?
    /// Character encoding override (e.g., "ISO-8859-1").
    public var encoding: String.Encoding?
    /// Timecode offset to add to all imported subtitles.
    public var timecodeOffset: Timecode?

    public init(
        targetFrameRate: FrameRate? = nil,
        defaultLanguage: LanguageCode? = nil,
        encoding: String.Encoding? = nil,
        timecodeOffset: Timecode? = nil
    ) {
        self.targetFrameRate = targetFrameRate
        self.defaultLanguage = defaultLanguage
        self.encoding = encoding
        self.timecodeOffset = timecodeOffset
    }
}

public struct ExportOptions {
    /// Source frame rate used for timecode rendering.
    public var sourceFrameRate: FrameRate?
    /// Include BOM in text output.
    public var includeBOM: Bool
    /// Output directory for multi-file exports (DCP font bundling).
    public var outputDirectory: URL?
    /// Font family for formats that embed font metadata (TTML, WebVTT, ASS, DCP).
    public var fontName: String?
    /// Font size in points for formats that embed font metadata.
    public var fontSize: Double?
    /// Border/outline width in points (0 = disabled, default 1).
    public var borderWidth: Double?
    /// Border/outline color as hex string (e.g. "000000" for black, default).
    public var borderColor: String?
    /// DCP SMPTE `EffectSize` — the thickness of the border/shadow effect in
    /// the rendered subtitle, independent of the on/off `borderWidth` toggle.
    /// Written to the `<Font EffectSize="…">` attribute; default 1.5.
    public var effectSize: Double?
    /// Font file data for embedding in multi-file exports (e.g. DCP font bundling).
    /// When provided, DCP exporters will write this as a separate file alongside the XML.
    public var fontData: Data?
    /// V position (vertical position) as a percentage of the safe area (DCP only).
    /// For DLP formats, default is 8.0.
    public var vPosition: Double?
    /// Line height in percent of font size (DLP only).
    /// Controls spacing between multi-line subtitles; default is 7.0.
    public var lineHeight: Double?
    /// Whether to use bold font weight for the track-level style.
    /// Supported by DCP SMPTE (Weight="bold"), TTML (tts:fontWeight="bold"),
    /// ASS (-1 in Bold field), WebVTT (font-weight: bold in ::cue).
    /// Inline bold via TextSegment styles is always preserved regardless.
    public var boldFont: Bool
    /// Additional format-specific options.
    public var extra: [String: String]

    public init(
        sourceFrameRate: FrameRate? = nil,
        includeBOM: Bool = true,
        outputDirectory: URL? = nil,
        fontName: String? = nil,
        fontSize: Double? = nil,
        borderWidth: Double? = nil,
        borderColor: String? = nil,
        effectSize: Double? = nil,
        fontData: Data? = nil,
        vPosition: Double? = nil,
        lineHeight: Double? = nil,
        boldFont: Bool = false,
        extra: [String: String] = [:]
    ) {
        self.sourceFrameRate = sourceFrameRate
        self.includeBOM = includeBOM
        self.outputDirectory = outputDirectory
        self.fontName = fontName
        self.fontSize = fontSize
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.effectSize = effectSize
        self.fontData = fontData
        self.vPosition = vPosition
        self.lineHeight = lineHeight
        self.boldFont = boldFont
        self.extra = extra
    }
}

// MARK: - Format Registry

public final class FormatRegistry {
    public static let shared = FormatRegistry()

    private var importers: [FormatID: any FormatImporter.Type] = [:]
    private var exporters: [FormatID: any FormatExporter.Type] = [:]
    /// Registration order determines detection priority: formats registered first
    /// are tried first in `detectFormat`. This prevents non-deterministic Dictionary
    /// iteration from causing SRT files to be mis-detected as TXT, etc.
    private var importerOrder: [FormatID] = []

    private init() {}

    public func registerImporter(_ importer: any FormatImporter.Type) {
        if importers[importer.formatID] == nil {
            importerOrder.append(importer.formatID)
        }
        importers[importer.formatID] = importer
    }

    public func registerExporter(_ exporter: any FormatExporter.Type) {
        exporters[exporter.formatID] = exporter
    }

    public func importer(for formatID: FormatID) -> (any FormatImporter.Type)? {
        importers[formatID]
    }

    public func exporter(for formatID: FormatID) -> (any FormatExporter.Type)? {
        exporters[formatID]
    }

    public func importer(forFileExtension ext: String) -> (any FormatImporter.Type)? {
        let lowered = ext.lowercased()
        for id in importerOrder {
            if let imp = importers[id], imp.fileExtensions.contains(lowered) {
                return imp
            }
        }
        return nil
    }

    public func detectFormat(from data: Data) -> (any FormatImporter.Type)? {
        for id in importerOrder {
            if let importer = importers[id], importer.canImport(data) { return importer }
        }
        return nil
    }

    public var allImporters: [any FormatImporter.Type] { importerOrder.compactMap { importers[$0] } }
    public var allExporters: [any FormatExporter.Type] { Array(exporters.values) }
}

// MARK: - Format Import/Export Errors

public enum FormatError: LocalizedError {
    case invalidData(String)
    case unsupportedEncoding(String)
    case missingRequiredField(String)
    case timecodeParseError(String)
    case fileWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidData(let s):           return s
        case .unsupportedEncoding(let s):   return s
        case .missingRequiredField(let s):  return s
        case .timecodeParseError(let s):   return s
        case .fileWriteFailed(let s):       return s
        }
    }
}

// MARK: - Language balise resolution

public extension Track {
    /// Resolve this track's language to the code form required by `formatID`.
    ///
    /// - DCP SMPTE 428-7 and DLP InterOp CineCanvas: ISDCF DCNC tag
    ///   (uppercase 2-4 chars, e.g. `EN`, `EUS`, `ZHS`). Falls back to `und`
    ///   per ISDCF Doc 7.
    /// - EBU STL (Tech 3264) and ASS/SSA: ISO 639-2/B 3-letter code
    ///   (e.g. `eng`, `fre`, `ger`). Falls back to `und`.
    /// - TTML / IMSC / Netflix / Amazon / iTunes / DaVinci TTML / WebVTT:
    ///   BCP-47 lowercase (e.g. `en`, `en-US`, `pt-BR`).
    /// - Formats without a native language balise (SCC, SRT, Premiere, FCPXML,
    ///   AVID, DOCX, XLSX, TXT): BCP-47, empty string when unset.
    ///
    /// This indirection lets every exporter write the conformant code without
    /// having to reimplement the BCP-47 ↔ DCNC conversion logic.
    func languageBalise(for formatID: FormatID) -> String {
        let raw = language.rawValue
        guard !raw.isEmpty else {
            switch formatID {
            case .dcp_smpte, .dcp_interop: return "und"
            case .stl, .ass, .avid: return "und"
            default: return ""
            }
        }

        switch formatID {
        case .dcp_smpte:
            if let dcnc = LanguageBaliseProvider.dcnc?(raw) { return dcnc.lowercased() }
            return raw.lowercased()
        case .dcp_interop:
            if let dcnc = LanguageBaliseProvider.dcnc?(raw) { return dcnc }
            return raw.uppercased()
        case .stl, .ass, .avid:
            if let b = LanguageBaliseProvider.iso639_2B?(raw) { return b }
            return "und"
        case .ttml, .ttml_netflix, .ttml_amazon, .ttml_itunes, .ttml_davinci, .webvtt:
            return LanguageBaliseProvider.bcp47(raw) ?? raw
        default:
            return LanguageBaliseProvider.bcp47(raw) ?? raw
        }
    }

    /// The DCP `<Language>` value, honoring bilingual tracks. A bilingual track
    /// (two languages stacked in one subtitle asset, e.g. Belgian FR-over-NL)
    /// can't be expressed by a single RFC 5646 tag, so with `bilingualUsesMul`
    /// (the default) it emits `mul` — ISO 639-2 "Multiple languages", the only
    /// RFC-5646-valid way to say a file carries more than one language (SMPTE
    /// lowercase, InterOp uppercase). When `bilingualUsesMul` is false, or the
    /// track is monolingual, the primary language is used via `languageBalise`.
    /// The two actual languages are still carried downstream by the DCP package
    /// name and the CPL's MainSubtitleLanguageList (set by the mastering tool).
    func dcpLanguageBalise(for formatID: FormatID, bilingualUsesMul: Bool) -> String {
        if isBilingual && bilingualUsesMul {
            return formatID == .dcp_smpte ? "mul" : "MUL"
        }
        return languageBalise(for: formatID)
    }
}

/// Pluggable indirection so the Core target stays free of an
/// AlphaSubLanguage dependency. The Language target provides a default
/// implementation that consults the ISDCF table; Core-only builds get a
/// best-effort fallback that uses system Locale + a tiny internal table.
public enum LanguageBaliseProvider {
    public static var dcnc: ((String) -> String?)? = nil
    public static var bcp47: ((String) -> String?) = { input in
        // Strip whitespace and return canonicalised form (lowercase primary,
        // uppercase region). Mirrors LanguageCode.canonicalize.
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "-").map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }
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
    public static var iso639_2B: ((String) -> String?)? = nil
    /// Returns the lowercase full language name for DLP InterOp CineCanvas
    /// (e.g. "french", "english", "spanish"). Installed by LanguageBaliseWiring.
    public static var interOpName: ((String) -> String?)? = nil
}
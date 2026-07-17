import Foundation

// MARK: - Season Bible
//
// A persistent, per-series consistency glossary that lives OUTSIDE any single
// project: character names, recurring term choices, formality decisions
// (tu/vous), song titles, speaker labels. One `.alphabible` file serves every
// episode project of a series, so a term settled in episode 1 is enforced in
// episode 9.
//
// The bible itself is a stable feature: `check(track:)` is pure string
// matching (word-boundary, case- and diacritic-insensitive by default) with
// no AI involved. Only the auto-extract step (see `BibleExtractor` in the AI
// target) uses the loaded LLM and is beta-gated.

/// One consistency decision in a Season Bible.
public struct BibleEntry: Codable, Identifiable, Equatable {
    /// What kind of thing this entry pins down.
    public enum Kind: String, Codable, CaseIterable {
        case character   // recurring character / speaker name
        case term        // recurring term or catchphrase
        case place       // location name
        case song        // song / episode title
        case formality   // formality decision (tu/vous, du/Sie, …)

        public var label: String {
            switch self {
            case .character: return String(localized: "Character")
            case .term:      return String(localized: "Term")
            case .place:     return String(localized: "Place")
            case .song:      return String(localized: "Song")
            case .formality: return String(localized: "Formality")
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// The term as it appears in the source language (e.g. "Sarge").
    public var source: String
    /// The settled rendering in the target language (e.g. "Chef").
    public var target: String
    /// Free-form translator note ("established in ep 1x03", "always vous").
    public var note: String?
    /// Known WRONG alternatives to flag (e.g. ["Sergent", "le Sarge"]).
    public var variants: [String]
    /// When false (default), matching ignores letter case.
    public var caseSensitive: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind = .term,
        source: String,
        target: String,
        note: String? = nil,
        variants: [String] = [],
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.target = target
        self.note = note
        self.variants = variants
        self.caseSensitive = caseSensitive
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, source, target, note, variants, caseSensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .term
        self.source = try c.decode(String.self, forKey: .source)
        self.target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
        self.variants = try c.decodeIfPresent([String].self, forKey: .variants) ?? []
        self.caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }
}

/// One drift hit found by `SeasonBible.check(track:)`.
public struct BibleFinding: Identifiable, Equatable {
    public let id: UUID
    /// The offending cue.
    public let cueID: UUID
    /// 1-based position of the cue in the track, for display.
    public let cueNumber: Int
    /// The bible entry that flagged the cue.
    public let entryID: UUID
    /// The exact text found in the cue (as written in the cue).
    public let matchedText: String
    /// What the bible says it should be.
    public let expected: String
    /// Human-readable explanation for the Issues panel.
    public let message: String
    /// Location of `matchedText` in the cue's `plainText`, so replacing the
    /// range with `expected` is a mechanical auto-fix.
    public let range: NSRange

    public init(
        id: UUID = UUID(),
        cueID: UUID,
        cueNumber: Int,
        entryID: UUID,
        matchedText: String,
        expected: String,
        message: String,
        range: NSRange
    ) {
        self.id = id
        self.cueID = cueID
        self.cueNumber = cueNumber
        self.entryID = entryID
        self.matchedText = matchedText
        self.expected = expected
        self.message = message
        self.range = range
    }
}

/// A per-series consistency glossary, stored as a standalone JSON document
/// (`.alphabible`) so one bible serves many episode projects.
public struct SeasonBible: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// Original-dialogue language of the series (nil = unknown / same-language).
    public var sourceLanguage: LanguageCode?
    /// Subtitle language the renderings in `target` are settled for.
    public var targetLanguage: LanguageCode?
    public var entries: [BibleEntry]
    public var modifiedAt: Date

    /// File extension of the standalone bible document.
    public static let fileExtension = "alphabible"

    public init(
        id: UUID = UUID(),
        name: String,
        sourceLanguage: LanguageCode? = nil,
        targetLanguage: LanguageCode? = nil,
        entries: [BibleEntry] = [],
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.entries = entries
        self.modifiedAt = modifiedAt
    }

    // MARK: - Persistence

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> SeasonBible {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SeasonBible.self, from: data)
    }

    public static func load(from url: URL) throws -> SeasonBible {
        try decode(from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    // MARK: - Matching primitives

    /// Case/diacritic-folded key used to compare terms for equality
    /// ("Sérgent" == "sergent").
    public static func foldKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All word-boundary occurrences of `needle` in `text`. Matching is
    /// diacritic-insensitive, and case-insensitive unless `caseSensitive`.
    /// Word-boundary means the match may not be flanked by a letter or digit,
    /// so entry "Chef" does NOT match inside "Chefs".
    public static func occurrences(
        of needle: String,
        in text: String,
        caseSensitive: Bool = false
    ) -> [Range<String.Index>] {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        var options: String.CompareOptions = [.diacriticInsensitive]
        if !caseSensitive { options.insert(.caseInsensitive) }

        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let r = text.range(of: needle, options: options,
                                 range: searchStart..<text.endIndex) {
            if isWordBoundary(r, in: text) { result.append(r) }
            searchStart = r.upperBound > r.lowerBound
                ? r.upperBound
                : text.index(after: r.lowerBound)
        }
        return result
    }

    /// How many times `needle` occurs (word-boundary, case-insensitive) in
    /// the plain text of `track`'s cues. Used by the extractor's ≥2 filter.
    public static func occurrenceCount(of needle: String, in track: Track) -> Int {
        track.subtitles.reduce(0) {
            $0 + occurrences(of: needle, in: $1.plainText).count
        }
    }

    private static func isWordBoundary(_ r: Range<String.Index>, in text: String) -> Bool {
        if r.lowerBound > text.startIndex {
            let before = text[text.index(before: r.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if r.upperBound < text.endIndex {
            let after = text[r.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

    /// True when both codes share the same primary language subtag
    /// ("fr" matches "fr-FR"). nil / empty codes never match.
    public static func languagesMatch(_ a: LanguageCode?, _ b: LanguageCode?) -> Bool {
        guard let pa = primarySubtag(a), let pb = primarySubtag(b) else { return false }
        return pa == pb
    }

    private static func primarySubtag(_ code: LanguageCode?) -> String? {
        guard let raw = code?.rawValue.split(separator: "-").first else { return nil }
        let s = String(raw).lowercased()
        return s.isEmpty ? nil : s
    }

    // MARK: - QC check

    /// Pure string-matching QC pass over one track. Two simple, predictable
    /// rules:
    ///
    /// 1. **Wrong variant** — any cue containing a known-wrong `variants`
    ///    string of any entry is flagged, with the entry's `target` (or
    ///    `source` when no target is set) as the expected replacement.
    /// 2. **Untranslated source** — when the track's language matches the
    ///    bible's `targetLanguage` (and the bible actually translates, i.e.
    ///    source and target languages differ), any cue still containing an
    ///    entry's source-language term is flagged as untranslated.
    ///
    /// Matching is word-boundary, diacritic-insensitive, and
    /// case-insensitive unless the entry says otherwise. Every occurrence
    /// yields its own finding, so one cue can carry several.
    public func check(track: Track) -> [BibleFinding] {
        let untranslatedRuleActive =
            Self.languagesMatch(track.language, targetLanguage)
            && !Self.languagesMatch(sourceLanguage, targetLanguage)

        var findings: [BibleFinding] = []
        for (idx, sub) in track.subtitles.enumerated() {
            let text = sub.plainText
            guard !text.isEmpty else { continue }
            for entry in entries {
                findings.append(contentsOf: findingsForEntry(
                    entry, in: text, cueID: sub.id, cueNumber: idx + 1,
                    untranslatedRuleActive: untranslatedRuleActive))
            }
        }
        return findings
    }

    private func findingsForEntry(
        _ entry: BibleEntry,
        in text: String,
        cueID: UUID,
        cueNumber: Int,
        untranslatedRuleActive: Bool
    ) -> [BibleFinding] {
        let expected = entry.target.isEmpty ? entry.source : entry.target
        guard !Self.foldKey(expected).isEmpty else { return [] }
        var findings: [BibleFinding] = []

        // Rule 1: known-wrong variants.
        for variant in entry.variants {
            // Never flag text that already equals the expected rendering.
            guard Self.foldKey(variant) != Self.foldKey(expected) else { continue }
            for r in Self.occurrences(of: variant, in: text,
                                      caseSensitive: entry.caseSensitive) {
                let matched = String(text[r])
                findings.append(BibleFinding(
                    cueID: cueID, cueNumber: cueNumber, entryID: entry.id,
                    matchedText: matched, expected: expected,
                    message: String(localized: "\u{201C}\(matched)\u{201D} drifts from the Season Bible — \u{201C}\(entry.source)\u{201D} is rendered \u{201C}\(expected)\u{201D} in this series."),
                    range: NSRange(r, in: text)))
            }
        }

        // Rule 2: source-language term left untranslated in a target-language
        // track. Skipped when the settled rendering itself contains the
        // source term (e.g. names that stay unchanged).
        if untranslatedRuleActive,
           !entry.target.isEmpty,
           Self.foldKey(entry.source) != Self.foldKey(entry.target),
           !Self.foldKey(entry.target).contains(Self.foldKey(entry.source)) {
            for r in Self.occurrences(of: entry.source, in: text,
                                      caseSensitive: entry.caseSensitive) {
                let matched = String(text[r])
                findings.append(BibleFinding(
                    cueID: cueID, cueNumber: cueNumber, entryID: entry.id,
                    matchedText: matched, expected: entry.target,
                    message: String(localized: "\u{201C}\(matched)\u{201D} appears untranslated — the Season Bible renders it \u{201C}\(entry.target)\u{201D}."),
                    range: NSRange(r, in: text)))
            }
        }

        return findings
    }

    // MARK: - Auto-fix

    /// Returns `text` with every drift hit replaced by the expected
    /// rendering. Used by "Fix on Copy" to correct a whole track at once.
    /// Replacements are applied back-to-front so earlier ranges stay valid;
    /// overlapping hits keep the first (leftmost) replacement.
    public func fixedText(for text: String, trackLanguage: LanguageCode?) -> String {
        let probe = Track(name: "", language: trackLanguage ?? LanguageCode(""),
                          subtitles: [Subtitle(
                            startTime: Timecode(totalFrames: 0, frameRate: .fps25),
                            endTime: Timecode(totalFrames: 0, frameRate: .fps25),
                            textBlocks: [TextBlock(plainText: text)])])
        let hits = check(track: probe)
            .sorted { $0.range.location > $1.range.location }
        guard !hits.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        var lastStart = mutable.length
        for hit in hits where hit.range.location + hit.range.length <= lastStart {
            mutable.replaceCharacters(in: hit.range, with: hit.expected)
            lastStart = hit.range.location
        }
        return mutable as String
    }

    /// Merge `newEntries` into the bible, skipping any whose source term is
    /// already present (fold-compared). Returns the entries actually added.
    @discardableResult
    public mutating func merge(_ newEntries: [BibleEntry]) -> [BibleEntry] {
        var known = Set(entries.map { Self.foldKey($0.source) })
        var added: [BibleEntry] = []
        for entry in newEntries {
            let key = Self.foldKey(entry.source)
            guard !key.isEmpty, !known.contains(key) else { continue }
            known.insert(key)
            entries.append(entry)
            added.append(entry)
        }
        if !added.isEmpty { modifiedAt = Date() }
        return added
    }
}

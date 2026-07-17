import Foundation

// Review Sessions — screening-room note capture.
//
// While the film plays out (main window, second-display fullscreen, or
// DeckLink), the operator hits single keys to log timecoded notes without
// stopping playback; afterwards the notes are a work list. The model lives in
// Core so it can be tested without the app target; persistence goes through
// `SubtitleDocument.featureMetadata` so projects carry their review notes and
// older app versions preserve them unchanged (Core never interprets that
// dictionary beyond the "reviewSessions" key used here).

/// A single timecoded note captured during a review session.
public struct ReviewNote: Codable, Identifiable, Equatable, Sendable {
    /// How the note was captured: a bare flag, a star (emphasis), or a
    /// typed text note.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case flag, star, text
    }

    public var id: UUID
    /// Position of the note in the track's timecode domain (seconds) —
    /// playback seconds plus the timeline timecode offset, so the value
    /// matches the SMPTE timecodes shown for the cues.
    public var timecodeSeconds: Double
    public var kind: Kind
    /// Typed note body (`kind == .text`); nil for flag/star notes.
    public var text: String?
    /// The subtitle under the playhead when the note was taken, if any.
    public var cueID: UUID?
    /// Ticked off in the Issues panel once the note has been dealt with.
    public var resolved: Bool

    public init(id: UUID = UUID(),
                timecodeSeconds: Double,
                kind: Kind,
                text: String? = nil,
                cueID: UUID? = nil,
                resolved: Bool = false) {
        self.id = id
        self.timecodeSeconds = timecodeSeconds
        self.kind = kind
        self.text = text
        self.cueID = cueID
        self.resolved = resolved
    }
}

/// One screening's worth of notes. A document can accumulate several
/// sessions (e.g. successive review passes); all of them are listed in the
/// Issues panel's Review tab.
public struct ReviewSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var name: String
    public var notes: [ReviewNote]

    public init(id: UUID = UUID(),
                startedAt: Date,
                name: String,
                notes: [ReviewNote] = []) {
        self.id = id
        self.startedAt = startedAt
        self.name = name
        self.notes = notes
    }
}

/// Serializes review sessions into `SubtitleDocument.featureMetadata` and
/// resolves the cue under the playhead when a note is captured.
public enum ReviewSessionStore {

    /// Key inside `SubtitleDocument.featureMetadata`. The payload is a
    /// JSON-encoded `[ReviewSession]`.
    public static let featureMetadataKey = "reviewSessions"

    /// The document's review sessions (empty when none were ever taken or
    /// the payload can't be decoded).
    public static func sessions(in document: SubtitleDocument) -> [ReviewSession] {
        guard let data = document.featureMetadata?[featureMetadataKey] else { return [] }
        return (try? JSONDecoder().decode([ReviewSession].self, from: data)) ?? []
    }

    /// Write `sessions` back into the document's feature metadata. Other
    /// keys in the dictionary are left untouched. Writing an empty list
    /// removes the key (so untouched projects stay byte-identical).
    public static func write(_ sessions: [ReviewSession], to document: inout SubtitleDocument) {
        if sessions.isEmpty {
            document.featureMetadata?[featureMetadataKey] = nil
            if document.featureMetadata?.isEmpty == true { document.featureMetadata = nil }
            return
        }
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        if document.featureMetadata == nil { document.featureMetadata = [:] }
        document.featureMetadata?[featureMetadataKey] = data
    }

    /// The cue under the playhead at `timecodeSeconds` (track-domain
    /// seconds), if any. A cue "contains" the playhead from its in-point
    /// (inclusive) to its out-point (exclusive), matching what is on screen.
    public static func cueID(atTimecodeSeconds t: Double, in track: Track?) -> UUID? {
        guard let track else { return nil }
        return track.subtitles.first {
            $0.startTime.seconds <= t && t < $0.endTime.seconds
        }?.id
    }
}

/// Builds the change-list rows/CSV for "Export Review Notes…". The HTML/PDF
/// rendering reuses the app-side `IssueReport` styling; the row content and
/// the CSV live here so they are testable without AppKit.
public enum ReviewNotesReport {

    public static let header = ["Session", "Timecode", "Kind", "Cue text", "Note", "Resolved"]

    public static func kindLabel(_ kind: ReviewNote.Kind) -> String {
        switch kind {
        case .flag: return "Flag"
        case .star: return "Star"
        case .text: return "Note"
        }
    }

    /// One row per note, sessions in stored order, notes sorted by timecode.
    /// `track` (usually the active track) resolves each note's `cueID` to the
    /// cue's current text; notes whose cue was deleted get an empty cue cell.
    public static func rows(sessions: [ReviewSession],
                            track: Track?,
                            frameRate: FrameRate) -> [[String]] {
        sessions.flatMap { session in
            session.notes
                .sorted { $0.timecodeSeconds < $1.timecodeSeconds }
                .map { note -> [String] in
                    let cueText = note.cueID
                        .flatMap { id in track?.subtitles.first { $0.id == id }?.plainText }
                        ?? ""
                    return [
                        session.name,
                        Timecode.fromSeconds(note.timecodeSeconds, frameRate: frameRate).smpteString,
                        kindLabel(note.kind),
                        cueText.replacingOccurrences(of: "\n", with: " "),
                        note.text ?? "",
                        note.resolved ? "yes" : "no",
                    ]
                }
        }
    }

    /// RFC-4180-style CSV (same quoting/CRLF conventions as the QC reports).
    public static func csv(sessions: [ReviewSession],
                           track: Track?,
                           frameRate: FrameRate) -> String {
        func esc(_ s: String) -> String {
            let needsQuote = s.contains(",") || s.contains("\"") || s.contains("\n")
            let body = s.replacingOccurrences(of: "\"", with: "\"\"")
            return needsQuote ? "\"\(body)\"" : body
        }
        var lines = [header.map(esc).joined(separator: ",")]
        for row in rows(sessions: sessions, track: track, frameRate: frameRate) {
            lines.append(row.map(esc).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

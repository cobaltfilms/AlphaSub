import Foundation

// MARK: - Where a DCP cue's placement comes from
//
// A DCP export has two candidate layouts and no way, until now, of saying which
// one it meant. The cue carries its own position — set in the editor, or read
// out of the file it was imported from — and the export dialog carries one too.
// The exporters preferred the cue, silently, and the dialog's V position had no
// effect on any cue that had a position of its own.
//
// That is more cues than it sounds. Every importer that finds placement data
// marks the cue with it, and the DCP Subtitle Settings sheet writes the TRACK
// default as an explicit percentage — so once that sheet had been opened, the
// dialog's V position was dead for the whole track, with nothing on screen to
// explain why the number would not take.

public enum DCPPositionSource: String, CaseIterable, Sendable {
    /// The cue's own position wins, falling back to the track default. Right
    /// for a track that has been spotted by hand.
    case authored
    /// The export dialog's layout replaces every cue's placement. Right for a
    /// lab that asked for one line height at one height, whatever the file says.
    case settings

    public static let optionKey = "dcp_position_source"

    /// Reads the choice out of an export request, defaulting to `authored` —
    /// the behaviour every existing export already has, so an older project or
    /// a caller that never sets it is not silently re-laid-out.
    public init(_ options: ExportOptions?) {
        self = options?.extra[DCPPositionSource.optionKey]
            .flatMap(DCPPositionSource.init(rawValue:)) ?? .authored
    }
}

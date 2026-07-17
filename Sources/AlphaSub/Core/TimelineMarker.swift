import Foundation

// Timeline markers — user-placed, commentable cue points on the waveform
// timeline, independent of subtitles. Stored in `SubtitleDocument.featureMetadata`
// (key "timelineMarkers") so a project carries its markers and older app
// versions preserve them unchanged. Designed to round-trip out to the NLEs as
// timeline markers (DaVinci EDL, Premiere CSV, FCP X FCPXML) for a
// comment/review hand-off — see `MarkerExport`.

/// A single user marker on the timeline.
public struct TimelineMarker: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    /// Position in the waveform's media/playback-seconds domain (from file
    /// start), the same domain as the playhead and `shotChanges`. The timeline
    /// timecode offset is applied only when exporting to an NLE.
    public var time: Double
    /// Short marker name/title (shows on the pin and as the NLE marker name).
    public var name: String
    /// Longer free-text comment/note (the review body).
    public var comment: String
    /// Marker colour, stored as a DaVinci-style colour name (Blue, Cyan,
    /// Green, Yellow, Red, Pink, Purple, Fuchsia, Rose, Lavender, Sky, Mint,
    /// Lemon, Sand, Cocoa, Cream). Defaults to Blue.
    public var color: String

    public init(id: UUID = UUID(),
                time: Double,
                name: String = "",
                comment: String = "",
                color: String = "Blue") {
        self.id = id
        self.time = time
        self.name = name
        self.comment = comment
        self.color = color
    }

    /// Colours offered in the UI and mappable to each NLE.
    public static let colorNames = [
        "Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple",
        "Fuchsia", "Rose", "Lavender", "Sky", "Mint", "Lemon", "Sand",
        "Cocoa", "Cream",
    ]
}

/// Serializes timeline markers into `SubtitleDocument.featureMetadata`,
/// mirroring `ReviewSessionStore`.
public enum TimelineMarkerStore {

    /// Key inside `SubtitleDocument.featureMetadata`. Payload is a JSON-encoded
    /// `[TimelineMarker]`.
    public static let featureMetadataKey = "timelineMarkers"

    /// The document's markers, sorted by time (empty when none / undecodable).
    public static func markers(in document: SubtitleDocument) -> [TimelineMarker] {
        guard let data = document.featureMetadata?[featureMetadataKey] else { return [] }
        let decoded = (try? JSONDecoder().decode([TimelineMarker].self, from: data)) ?? []
        return decoded.sorted { $0.time < $1.time }
    }

    /// Write `markers` back into the document's feature metadata, leaving other
    /// keys untouched. Writing an empty list removes the key so untouched
    /// projects stay byte-identical.
    public static func write(_ markers: [TimelineMarker], to document: inout SubtitleDocument) {
        if markers.isEmpty {
            document.featureMetadata?[featureMetadataKey] = nil
            if document.featureMetadata?.isEmpty == true { document.featureMetadata = nil }
            return
        }
        guard let data = try? JSONEncoder().encode(markers.sorted { $0.time < $1.time }) else { return }
        if document.featureMetadata == nil { document.featureMetadata = [:] }
        document.featureMetadata?[featureMetadataKey] = data
    }
}

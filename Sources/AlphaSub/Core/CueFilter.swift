import Foundation

/// Narrowing the subtitle list to the cues that depart from the project.
///
/// Once a DCP import stops marking every cue custom (`LayoutConsensus`), the
/// exceptions are the interesting cues — the line raised over a burned-in
/// credit, the italicised aside, the cue in a speaker colour. On a 2000-cue
/// feature they are also unfindable by scrolling, which is what this is for.
///
/// Pure and testable: the view asks for the row indices to show and nothing
/// more. Indices rather than a filtered array on purpose — the list still shows
/// each cue's real number and measures its gap against the cue that genuinely
/// precedes it in the track.
public enum CueFilter: String, CaseIterable, Identifiable {
    /// Every cue.
    case all
    /// Cues whose position overrides the track default.
    case customPosition
    /// Cues carrying their own italic/bold/underline/colour.
    case customFormatting
    /// Either kind of exception.
    case anyCustom

    public var id: String { rawValue }

    public func matches(_ subtitle: Subtitle) -> Bool {
        switch self {
        case .all:              return true
        case .customPosition:   return subtitle.useCustomPosition
        case .customFormatting: return subtitle.hasCustomFormatting
        case .anyCustom:        return subtitle.useCustomPosition || subtitle.hasCustomFormatting
        }
    }

    /// The indices of the matching cues, in track order.
    public func rows(in subtitles: [Subtitle]) -> [Int] {
        guard self != .all else { return Array(subtitles.indices) }
        return subtitles.indices.filter { matches(subtitles[$0]) }
    }

    /// How many cues each filter would show — for the menu, so the user can
    /// see there are 12 custom-position cues without switching to find out.
    public static func counts(in subtitles: [Subtitle]) -> [CueFilter: Int] {
        var result: [CueFilter: Int] = [:]
        for filter in CueFilter.allCases {
            result[filter] = filter == .all
                ? subtitles.count
                : subtitles.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) }
        }
        return result
    }
}

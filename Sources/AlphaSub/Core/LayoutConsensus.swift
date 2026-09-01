import Foundation

/// Deciding what a track's *default* layout is, from the cues themselves.
///
/// A DCP states position on every single `<Text>` element — that is how the
/// format works, not a sign that the author positioned each cue by hand. Taking
/// it literally, as the importers did, marked every imported cue
/// `useCustomPosition = true`: the Custom Position switch was on for all 2000
/// cues of a feature, the track defaults meant nothing, and changing the film's
/// subtitle position meant editing every cue instead of one setting.
///
/// The fix is to read the file the way a human does: whatever layout most cues
/// share IS the track's layout, and only the cues that depart from it are
/// genuinely custom — the raised line over a burned-in credit, the cue moved up
/// off a lower third.
///
/// Nothing about how a cue *draws* changes. A cue matching the consensus
/// resolves through `Track.effectivePosition(for:)` to the track default, which
/// this sets to exactly the value that cue carried; per-line positions on the
/// text blocks are untouched, so multi-line DCP cues still draw each line where
/// the file puts it.
public enum LayoutConsensus {

    /// A cue's layout: the three values `useCustomPosition` switches between
    /// the cue's own and the track's.
    public struct Layout: Equatable {
        public var vertical: VerticalPosition
        public var horizontal: HorizontalPosition
        public var alignment: TextAlignment

        public init(vertical: VerticalPosition, horizontal: HorizontalPosition, alignment: TextAlignment) {
            self.vertical = vertical
            self.horizontal = horizontal
            self.alignment = alignment
        }

        public init(_ subtitle: Subtitle) {
            self.init(vertical: subtitle.verticalPosition,
                      horizontal: subtitle.horizontalPosition,
                      alignment: subtitle.alignment)
        }
    }

    /// The layout the greatest number of cues share, or `nil` for no cues.
    ///
    /// Ties go to the layout seen first, so the result is stable for a given
    /// file rather than depending on dictionary ordering. A subtitle file has a
    /// handful of distinct layouts at most, so the linear scan per distinct
    /// layout costs nothing even on a feature-length track — and it avoids
    /// making the position types `Hashable` purely to be counted.
    public static func majority(of subtitles: [Subtitle]) -> Layout? {
        var tally: [(layout: Layout, count: Int)] = []
        for subtitle in subtitles {
            let layout = Layout(subtitle)
            if let i = tally.firstIndex(where: { $0.layout == layout }) {
                tally[i].count += 1
            } else {
                tally.append((layout, 1))
            }
        }
        return tally.max(by: { $0.count < $1.count })?.layout
    }

    /// The positions a project should be set to after importing this track:
    /// the ones most of its cues actually use.
    ///
    /// `nil` on a field means "the file says nothing usable about it, leave the
    /// project's own setting alone" — an SRT states no position at all, and a
    /// DCP whose cues resolve to the safe-area default states no percentage.
    public struct ProjectPositions: Equatable {
        /// Percent up from the bottom of the active picture — the same
        /// convention `SubtitleDisplaySettings.vPosition` uses, so it is
        /// carried across as-is rather than converted.
        public var verticalPercent: Double?
        /// Horizontal offset in percent of picture width, −50…+50, 0 centred.
        /// `HorizontalPosition.percentage` runs 0…100 across the picture, so
        /// the two differ by the 50 that means "centre".
        public var horizontalOffsetPercent: Double?
        /// The gap between two stacked display lines, in percent of picture
        /// height — the file's own line height, not a guess.
        public var lineSpacingPercent: Double?

        public var isEmpty: Bool {
            verticalPercent == nil && horizontalOffsetPercent == nil && lineSpacingPercent == nil
        }
    }

    public static func projectPositions(of subtitles: [Subtitle]) -> ProjectPositions {
        var result = ProjectPositions()
        if let consensus = majority(of: subtitles) {
            if case .percentage(let v) = consensus.vertical {
                result.verticalPercent = v
            }
            switch consensus.horizontal {
            case .centered:
                result.horizontalOffsetPercent = 0
            case .percentage(let p):
                // Only meaningful for centred text; a flush-left or flush-right
                // cue is placed by its alignment, and folding that into a
                // global offset would shift every cue in the project.
                if consensus.alignment == .center { result.horizontalOffsetPercent = p - 50 }
            case .leftAligned, .rightAligned:
                break
            }
        }
        result.lineSpacingPercent = lineSpacing(of: subtitles)
        return result
    }

    /// The gap most often found between two stacked lines of the same cue.
    ///
    /// A DCP writes each line's own `Vposition` — 15 and 9, say — so the line
    /// height is in the file rather than something to assume. Only cues whose
    /// lines carry percentages contribute; `nil` when none do.
    public static func lineSpacing(of subtitles: [Subtitle]) -> Double? {
        var tally: [(gap: Double, count: Int)] = []
        for subtitle in subtitles {
            let percents: [Double] = subtitle.textBlocks.compactMap {
                if case .percentage(let v) = $0.verticalPosition { return v }
                return nil
            }
            guard percents.count >= 2 else { continue }
            for (a, b) in zip(percents, percents.dropFirst()) {
                // Lines are written top-down, so consecutive values descend;
                // the sign is not the point, the distance is.
                let gap = (a - b).magnitude
                guard gap > 0.01 else { continue }
                let rounded = (gap * 10).rounded() / 10
                if let i = tally.firstIndex(where: { $0.gap == rounded }) { tally[i].count += 1 }
                else { tally.append((rounded, 1)) }
            }
        }
        return tally.max(by: { $0.count < $1.count })?.gap
    }

    /// Adopt the consensus layout as the track's default and clear
    /// `useCustomPosition` on every cue that matches it.
    ///
    /// Cues that differ keep their own layout and stay custom — they are the
    /// ones a subtitler wants flagged. Returns the layout adopted, or `nil`
    /// when the track has no cues (in which case nothing is touched).
    @discardableResult
    public static func adoptMajorityAsTrackDefault(_ track: inout Track) -> Layout? {
        guard let consensus = majority(of: track.subtitles) else { return nil }
        track.defaultVerticalPosition = consensus.vertical
        track.defaultHorizontalPosition = consensus.horizontal
        track.defaultAlignment = consensus.alignment
        for i in track.subtitles.indices {
            track.subtitles[i].useCustomPosition = Layout(track.subtitles[i]) != consensus
        }
        return consensus
    }
}

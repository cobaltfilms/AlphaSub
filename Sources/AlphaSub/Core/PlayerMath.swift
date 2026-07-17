import CoreGraphics

/// Pure geometry/time math for the video player. No AppKit/SwiftUI imports —
/// everything here must stay unit-testable without a UI.
public enum PlayerMath {

    // MARK: Progress bar (guide 06)

    /// 0…1 playback fraction. 0 when duration is not positive. Clamped.
    public static func fraction(time: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    /// Inverse of `fraction`: time for a click/drag at x in a bar of `width`.
    /// Clamped to 0…duration. 0 when width or duration is not positive.
    public static func time(atX x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(Double(x / width) * duration, 0), duration)
    }

    // MARK: Subtitle position (guide 03)

    /// Bottom padding in points for a vertical position given in percent of
    /// the picture height (SMPTE-style: 8 → 8 % above the bottom edge).
    public static func bottomPadding(vPositionPercent: Double, pictureHeight: CGFloat) -> CGFloat {
        guard pictureHeight > 0 else { return 0 }
        return pictureHeight * CGFloat(vPositionPercent) / 100.0
    }

    /// Horizontal offset in points for a global horizontal position given in
    /// percent of picture width. 0 = centered, −50 = left edge, +50 = right edge.
    public static func horizontalOffset(hPositionPercent: Double, pictureWidth: CGFloat) -> CGFloat {
        guard pictureWidth > 0 else { return 0 }
        return pictureWidth * CGFloat(hPositionPercent) / 100.0
    }

    // MARK: Custom positions within available space

    /// Inset from the top/leading edge for a 0–100 percent position within the
    /// space actually available to the label (picture extent minus label
    /// extent). 0 = flush start, 50 = centered, 100 = flush end — the label
    /// stays fully inside the picture at both extremes. Percent clamped.
    public static func percentInset(percent: Double, available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0 }
        return available * CGFloat(min(max(percent, 0), 100)) / 100.0
    }

    /// Offset from center for a 0–100 percent position within `available`
    /// space: 0 → −available/2 (flush start), 50 → 0, 100 → +available/2
    /// (flush end). The global H Pos (−50…+50, 0 = centered) maps onto this
    /// via `percent: hPosition + 50`.
    public static func centeredPercentOffset(percent: Double, available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0 }
        return available * CGFloat(min(max(percent, 0), 100) - 50) / 100.0
    }

    // MARK: Integer-pixel outline (guide 04)

    /// Converts an outline width given in whole video-content pixels into
    /// points that land exactly on the device-pixel grid (no subpixel
    /// rendering) — but only while the width spans at least one device pixel.
    /// In heavily minified previews (small video pane), forcing a 1-device-px
    /// floor makes the outline up to 3× heavier than requested relative to the
    /// scaled-down font; below one device pixel the exact proportional width
    /// is returned instead, which antialiases to the faint hairline a shrunken
    /// 1 px outline should look like.
    public static func pixelAlignedBorderWidth(contentPixels: Int, scaleFactor: CGFloat, displayScale: CGFloat) -> CGFloat {
        guard contentPixels > 0, scaleFactor > 0, displayScale > 0 else { return 0 }
        let points = CGFloat(contentPixels) * scaleFactor
        let devicePixels = points * displayScale
        guard devicePixels >= 1 else { return points }
        return devicePixels.rounded() / displayScale
    }

    // MARK: Active picture (guide 10)

    /// Insets, in video-content pixels, marking the active picture area
    /// inside the full video frame (letterbox/pillarbox bars excluded).
    public struct ActivePictureInsets: Equatable, Codable {
        public var top: Int
        public var bottom: Int
        public var left: Int
        public var right: Int
        public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
            self.top = top; self.bottom = bottom; self.left = left; self.right = right
        }
        public var isZero: Bool { top == 0 && bottom == 0 && left == 0 && right == 0 }
    }

    /// The centred, aspect-preserving rect (top-down, output pixels) that a source
    /// raster of `sourceNatural` occupies when fitted into an `outputSize` frame
    /// with square pixels — i.e. the real picture area, with pill/letterbox bars
    /// around it. Mirrors the bridge's `composeScaled` fit math so burned-in
    /// subtitles land inside the picture the card actually outputs, never on a bar.
    public static func outputPictureRect(sourceNatural: CGSize, outputSize: CGSize) -> CGRect {
        guard sourceNatural.width > 0, sourceNatural.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            return CGRect(origin: .zero, size: outputSize)
        }
        let scale = min(outputSize.width / sourceNatural.width,
                        outputSize.height / sourceNatural.height)
        let fitW = min((sourceNatural.width * scale).rounded(), outputSize.width)
        let fitH = min((sourceNatural.height * scale).rounded(), outputSize.height)
        let ox = ((outputSize.width - fitW) / 2).rounded()
        let oy = ((outputSize.height - fitH) / 2).rounded()
        return CGRect(x: ox, y: oy, width: fitW, height: fitH)
    }

    /// Shrinks an on-screen picture rect by insets expressed in video-content
    /// pixels. `videoNaturalSize` is the video's pixel dimensions; insets are
    /// scaled by the on-screen/native ratio. Degenerate inputs return `picture`
    /// unchanged; an over-inset rect is clamped to zero size at its center.
    public static func activeRect(picture: CGRect, insets: ActivePictureInsets, videoNaturalSize: CGSize) -> CGRect {
        guard !insets.isZero, videoNaturalSize.width > 0, videoNaturalSize.height > 0,
              picture.width > 0, picture.height > 0 else { return picture }
        let sx = picture.width / videoNaturalSize.width
        let sy = picture.height / videoNaturalSize.height
        var r = picture
        r.origin.x += CGFloat(insets.left) * sx
        r.origin.y += CGFloat(insets.top) * sy
        r.size.width  -= CGFloat(insets.left + insets.right) * sx
        r.size.height -= CGFloat(insets.top + insets.bottom) * sy
        if r.size.width < 0 { r.origin.x += r.size.width / 2; r.size.width = 0 }
        if r.size.height < 0 { r.origin.y += r.size.height / 2; r.size.height = 0 }
        return r
    }

    // MARK: Preview scale (guide 09)

    /// Subtitle-preview scale for the in-app video player: the ratio between
    /// the on-screen picture height and the video's natural (pixel) height.
    ///
    /// This mirrors how subtitles are actually composited into the video raster
    /// and then scaled with the picture, so a 42 px font on a 1080p video is
    /// drawn at 42 points when the video is displayed at 1080p and shrinks
    /// proportionally when the window is smaller — independent of the display
    /// or window size itself (SMPTE-safe-area preview behaviour).
    public static func pictureScaleFactor(pictureHeight: CGFloat, naturalHeight: CGFloat) -> CGFloat {
        guard naturalHeight > 0, pictureHeight > 0 else { return 1 }
        return pictureHeight / naturalHeight
    }

    /// Deprecated preview scale based on the full container height. Kept for
    /// backwards compatibility with external callers, but the overlay now uses
    /// `pictureScaleFactor(pictureHeight:naturalHeight:)` so text scales with
    /// the active picture rather than the player view.
    public static func previewScaleFactor(displayedHeight: CGFloat, naturalHeight: CGFloat) -> CGFloat {
        let reference = naturalHeight > 0 ? naturalHeight : 1080
        guard displayedHeight > 0 else { return 0.3 }
        return max(displayedHeight / reference, 0.3)
    }

    // MARK: Subtitle lookup (guide 02)

    /// Finds the subtitle covering `playerTime + timecodeOffset`.
    /// `intervals` are (startSeconds, endSeconds) in absolute (offset) time.
    public static func subtitleIndex(at playerTime: Double, timecodeOffset: Double,
                                     intervals: [(start: Double, end: Double)]) -> Int? {
        let t = playerTime + timecodeOffset
        return intervals.firstIndex { t >= $0.start && t <= $0.end }
    }
}

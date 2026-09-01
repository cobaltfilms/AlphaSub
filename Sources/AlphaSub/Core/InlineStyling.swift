import Foundation

/// Inline (part-of-a-line) styling: italicising one word, not the whole cue.
///
/// The model has always been able to hold it — a `TextBlock` is a list of
/// `TextSegment`s, each with its own `TextStyle` and colour, and both DCP
/// formats carry it on the wire (`<Text>` is mixed content in ST 428-7 and
/// InterOp alike, so a nested `<Font Italic="yes">` may wrap a single word).
/// What was missing was any way to *address* part of a cue: the toggles walked
/// every segment, and the editor rebuilt the cue from a plain `String` on every
/// keystroke, which flattened imported styling back to nothing.
///
/// These are pure functions over a cue's blocks, addressed by character offsets
/// into the cue's plain text (its lines joined with `\n`) — the same coordinate
/// space `CueEditing.splitTextBlocks(_:atPlainTextIndex:)` already uses. Offsets
/// are in `Character`s, not UTF-16 units; AppKit hands out UTF-16 `NSRange`s, so
/// the UI converts at the boundary rather than letting two coordinate systems
/// loose in the model.
///
/// The implementation expands a cue to one attribute per character, mutates
/// that, and coalesces back into segments. A cue is a couple of hundred
/// characters at most, and the alternative — segment-boundary surgery for every
/// operation — is where this kind of code goes wrong.
public enum InlineStyling {

    /// A stretch of the cue's plain text that shares one style and colour.
    public struct Run: Equatable {
        /// Character offsets into the cue's plain text (lines joined with `\n`).
        public var range: Range<Int>
        public var style: TextStyle
        public var color: TextColor?

        public init(range: Range<Int>, style: TextStyle, color: TextColor? = nil) {
            self.range = range
            self.style = style
            self.color = color
        }
    }

    /// One character's styling. Private: the public currency is `Run`.
    private struct Attr: Equatable {
        var style: TextStyle = []
        var color: TextColor?
    }

    // MARK: - Reading

    /// The cue's plain text: its lines joined with `\n`.
    public static func plainText(_ blocks: [TextBlock]) -> String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    /// The styled runs over that plain text, in order, merged so that adjacent
    /// runs never share the same style *and* colour. Unstyled stretches are
    /// included (with an empty style) so the runs tile the whole string.
    public static func runs(of blocks: [TextBlock]) -> [Run] {
        let attrs = flatten(blocks).map(\.attr)
        var result: [Run] = []
        var start = 0
        var i = 0
        while i < attrs.count {
            if attrs[i] != attrs[start] {
                result.append(Run(range: start..<i, style: attrs[start].style, color: attrs[start].color))
                start = i
            }
            i += 1
        }
        if start < attrs.count {
            result.append(Run(range: start..<attrs.count, style: attrs[start].style, color: attrs[start].color))
        }
        return result
    }

    /// The cue's text with its inline styling shown as tags — `<i>`, `<b>`,
    /// `<u>` — for places that can only display a plain string, such as a
    /// table row. Not a file format: it is how the styling is *read out*, so
    /// that a cue carrying one italic word is distinguishable at a glance from
    /// one that does not.
    public static func markup(of blocks: [TextBlock]) -> String {
        blocks.map { block in
            block.segments.map { segment -> String in
                var text = segment.text
                // Innermost first, so the tags nest in a stable order.
                if segment.style.contains(.underline) { text = "<u>\(text)</u>" }
                if segment.style.contains(.bold)      { text = "<b>\(text)</b>" }
                if segment.style.contains(.italic)    { text = "<i>\(text)</i>" }
                return text
            }.joined()
        }.joined(separator: "\n")
    }

    /// Whether every character in `range` already carries `flag` — what decides
    /// which way a toggle goes. An empty or out-of-range selection is `false`,
    /// so a toggle over nothing turns the style *on*.
    public static func styleIsUniform(_ flag: TextStyle, in range: Range<Int>,
                                      of blocks: [TextBlock]) -> Bool {
        let attrs = flatten(blocks).map(\.attr)
        let r = clamp(range, to: attrs.count)
        guard !r.isEmpty else { return false }
        return attrs[r].allSatisfy { $0.style.contains(flag) }
    }

    /// The colour shared by every character in `range`, or `nil` when they
    /// differ, when the range is empty, or when the characters carry no colour
    /// of their own. Companion to `styleIsUniform` for the formatting bar's
    /// colour swatch, which must report the run under the caret rather than
    /// the first run of the cue.
    public static func uniformColor(in range: Range<Int>, of blocks: [TextBlock]) -> TextColor? {
        let attrs = flatten(blocks).map(\.attr)
        let r = clamp(range, to: attrs.count)
        guard let first = attrs[r].first else { return nil }
        return attrs[r].allSatisfy({ $0.color == first.color }) ? first.color : nil
    }

    /// The range a caret-or-selection should be *read* through.
    ///
    /// A selection reads as itself. A bare caret reads as the character BEFORE
    /// it — the one whose styling typing would inherit (`applyPlainText`), so
    /// the Italic button lights up exactly when the next character typed would
    /// come out italic. At offset 0 there is nothing before, so it reads the
    /// character after. `nil` selection means the whole cue, which is also the
    /// scope a toggle then applies to.
    public static func probeRange(for selection: Range<Int>?, in blocks: [TextBlock]) -> Range<Int> {
        let length = plainText(blocks).count
        guard let selection else { return 0..<length }
        guard selection.isEmpty else { return selection }
        let caret = min(max(selection.lowerBound, 0), length)
        if caret > 0 { return (caret - 1)..<caret }
        return 0..<min(1, length)
    }

    // MARK: - Writing

    /// Toggle `flag` over a character range: on unless every character in the
    /// range already has it, in which case off. Blocks outside the range — and
    /// every block's language and per-line position — are untouched.
    public static func toggleStyle(_ flag: TextStyle, in range: Range<Int>,
                                   of blocks: [TextBlock]) -> [TextBlock] {
        var chars = flatten(blocks)
        let r = clamp(range, to: chars.count)
        guard !r.isEmpty else { return blocks }
        let allHave = chars[r].allSatisfy { $0.attr.style.contains(flag) }
        for i in r {
            if allHave { chars[i].attr.style.subtract(flag) }
            else       { chars[i].attr.style.formUnion(flag) }
        }
        return rebuild(chars, like: blocks)
    }

    /// Set (or clear, with `nil`) the colour over a character range.
    public static func setColor(_ color: TextColor?, in range: Range<Int>,
                                of blocks: [TextBlock]) -> [TextBlock] {
        var chars = flatten(blocks)
        let r = clamp(range, to: chars.count)
        guard !r.isEmpty else { return blocks }
        for i in r { chars[i].attr.color = color }
        return rebuild(chars, like: blocks)
    }

    /// Replace the cue's text with `newText`, carrying the existing styling
    /// across the edit.
    ///
    /// The editor is a plain-text view: it hands back a whole `String`, not a
    /// description of what changed. Comparing the common prefix and suffix
    /// recovers the edit — which is exact for the one-insertion-or-deletion
    /// shape typing actually produces, and degrades gracefully for a paste.
    /// Text that survived keeps its own styling; inserted text inherits the
    /// character before it (the rule a text view itself uses for typing
    /// attributes), or the character after it when inserting at the very start.
    ///
    /// One `TextBlock` per display line is preserved — the invariant every
    /// exporter relies on — and each line keeps the language and per-line
    /// position of the line that was at that index before the edit.
    public static func applyPlainText(_ newText: String, to blocks: [TextBlock]) -> [TextBlock] {
        let old = flatten(blocks)
        let new = Array(newText)
        guard old.map(\.ch) != new else { return blocks }

        // Longest common prefix, then longest common suffix of what is left.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].ch == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix].ch == new[new.count - 1 - suffix] { suffix += 1 }

        // What inserted characters inherit: the surviving character before the
        // insertion point, else the one after it, else nothing.
        let inherited: Attr
        if prefix > 0 { inherited = old[prefix - 1].attr }
        else if old.count - suffix < old.count { inherited = old[old.count - suffix].attr }
        else { inherited = Attr() }

        var chars: [(ch: Character, attr: Attr)] = []
        chars.reserveCapacity(new.count)
        for (i, ch) in new.enumerated() {
            if i < prefix {
                chars.append((ch, old[i].attr))
            } else if i >= new.count - suffix {
                chars.append((ch, old[old.count - (new.count - i)].attr))
            } else {
                chars.append((ch, inherited))
            }
        }
        return rebuild(chars, like: blocks)
    }

    // MARK: - Flatten / rebuild

    private static func flatten(_ blocks: [TextBlock]) -> [(ch: Character, attr: Attr)] {
        var chars: [(ch: Character, attr: Attr)] = []
        for (bi, block) in blocks.enumerated() {
            if bi > 0 { chars.append(("\n", Attr())) }
            for seg in block.segments {
                let attr = Attr(style: seg.style, color: seg.color)
                for ch in seg.text { chars.append((ch, attr)) }
            }
        }
        return chars
    }

    /// Coalesce characters back into one block per line, taking each line's
    /// language and per-line position from the block that was at that index.
    /// Lines beyond the original count carry none — the same as a cue whose
    /// text was typed from scratch.
    private static func rebuild(_ chars: [(ch: Character, attr: Attr)],
                                like template: [TextBlock]) -> [TextBlock] {
        var lines: [[(ch: Character, attr: Attr)]] = [[]]
        for c in chars {
            if c.ch == "\n" { lines.append([]) } else { lines[lines.count - 1].append(c) }
        }
        return lines.enumerated().map { (index, line) in
            var segments: [TextSegment] = []
            for c in line {
                if var last = segments.last, last.style == c.attr.style, last.color == c.attr.color {
                    last.text.append(c.ch)
                    segments[segments.count - 1] = last
                } else {
                    segments.append(TextSegment(text: String(c.ch), style: c.attr.style, color: c.attr.color))
                }
            }
            if segments.isEmpty { segments = [TextSegment(text: "", style: [])] }
            let source = index < template.count ? template[index] : nil
            return TextBlock(segments: segments,
                             language: source?.language,
                             verticalPosition: source?.verticalPosition,
                             horizontalPosition: source?.horizontalPosition)
        }
    }

    private static func clamp(_ range: Range<Int>, to count: Int) -> Range<Int> {
        let lower = max(0, min(range.lowerBound, count))
        let upper = max(lower, min(range.upperBound, count))
        return lower..<upper
    }
}

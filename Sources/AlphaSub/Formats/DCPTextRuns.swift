import Foundation
import AlphaSubCore

/// Reading the styled runs out of a DCP `<Text>` element.
///
/// `<Text>` is *mixed content* in both DCP subtitle schemas — ST 428-7's
/// DCDMSubtitle and InterOp's DCSubtitle — meaning it holds text and `<Font>`
/// elements side by side:
///
/// ```xml
/// <Text ...>Il a dit <Font Italic="yes">non</Font> hier.</Text>
/// ```
///
/// This is how a projector is told to italicise one word. Both importers used
/// to walk only the child *elements*, so the bare text either side of a nested
/// `<Font>` — "Il a dit " and " hier." — was not merely unstyled, it was
/// **dropped**: a partially italicised line imported as the italic word alone.
/// Walking the nodes in document order is the whole fix.
///
/// The two schemas differ on one attribute name — ST 428-7 has `Underline`,
/// InterOp has `Underlined` — so the caller passes its own spelling.
enum DCPTextRuns {

    /// Collect the styled runs of a `<Text>` (or of a `<Font>` wrapping one),
    /// in document order, inheriting `baseStyle` and `baseColor` from whatever
    /// encloses it.
    static func segments(in element: XMLElement,
                         baseStyle: TextStyle = [],
                         baseColor: TextColor? = nil,
                         underlineAttribute: String) -> [TextSegment] {
        let raw = collect(element, style: baseStyle, color: baseColor,
                          underlineAttribute: underlineAttribute)
        return tidy(raw)
    }

    private static func collect(_ element: XMLElement,
                                style: TextStyle,
                                color: TextColor?,
                                underlineAttribute: String) -> [TextSegment] {
        var runs: [TextSegment] = []
        for node in element.children ?? [] {
            if node.kind == .text {
                if let text = node.stringValue, !text.isEmpty {
                    runs.append(TextSegment(text: text, style: style, color: color))
                }
                continue
            }
            guard let child = node as? XMLElement else { continue }
            if localName(child.name) == "Font" {
                var childStyle = style
                if child.attribute(forName: "Italic")?.stringValue == "yes" { childStyle.insert(.italic) }
                if child.attribute(forName: "Weight")?.stringValue == "bold" { childStyle.insert(.bold) }
                if child.attribute(forName: underlineAttribute)?.stringValue == "yes" { childStyle.insert(.underline) }
                // A run's own Color overrides whatever the enclosing Font set —
                // how coloured speaker cues are written, and dropping it was why
                // imported colours never showed anywhere (#50).
                let childColor = child.attribute(forName: "Color")?.stringValue
                    .flatMap(DCPColor.textColor(fromHex:)) ?? color
                runs.append(contentsOf: collect(child, style: childStyle, color: childColor,
                                                underlineAttribute: underlineAttribute))
            } else {
                // Anything else the schema allows inside a Text — Ruby, Space,
                // a vendor extension. Its text is still the cue's text; only
                // the styling it might imply is beyond us.
                runs.append(contentsOf: collect(child, style: style, color: color,
                                                underlineAttribute: underlineAttribute))
            }
        }
        return runs
    }

    /// Whitespace *inside* a `<Text>` is XML formatting, not content: a DCP
    /// carries one display line per `<Text>`, so a newline and its indentation
    /// is at most a word space. The indentation a pretty-printed file puts
    /// around the runs is trimmed off the outside; spaces *between* runs are
    /// the author's and are kept — losing them is how "Il a dit non hier."
    /// becomes "Il a ditnonhier."
    private static func tidy(_ runs: [TextSegment]) -> [TextSegment] {
        var runs = runs.map { run -> TextSegment in
            var copy = run
            copy.text = collapseLineBreaks(run.text)
            return copy
        }
        guard !runs.isEmpty else { return [] }
        runs[0].text = String(runs[0].text.drop(while: { $0.isWhitespace }))
        let last = runs.count - 1
        while let final = runs[last].text.last, final.isWhitespace {
            runs[last].text.removeLast()
        }
        return runs.filter { !$0.text.isEmpty }
    }

    /// Collapse any whitespace run that contains a line break to a single
    /// space, leaving ordinary spaces alone.
    private static func collapseLineBreaks(_ text: String) -> String {
        var out = ""
        var pending = ""
        var pendingHasBreak = false
        func flush() {
            guard !pending.isEmpty else { return }
            out += pendingHasBreak ? " " : pending
            pending = ""
            pendingHasBreak = false
        }
        for ch in text {
            if ch.isWhitespace {
                pending.append(ch)
                if ch.isNewline { pendingHasBreak = true }
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }

    private static func localName(_ name: String?) -> String {
        guard let name else { return "" }
        if let colon = name.lastIndex(of: ":") { return String(name[name.index(after: colon)...]) }
        return name
    }
}

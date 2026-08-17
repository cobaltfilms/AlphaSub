import Foundation

// MARK: - The one spelling of a DCP timestamp
//
// `IssueDate` is `xs:dateTime` in every D-Cinema schema (ST 428-7 subtitles,
// ST 429-7 CPL, ST 429-8 PKL, ST 429-9 ASSETMAP), so `2026-08-17T10:20:11Z`,
// `…+02:00` and the naive `…T10:20:11` are all schema-valid. Interoperability
// is a narrower target than the schema, and two real rejections bracket it:
//
//   * A lab rejected a package for carrying a numeric offset (`+02:00`) in
//     CPL/PKL/ASSETMAP — it wanted the instant expressed in UTC.
//   * A cinema server rejected our subtitle XML for the `Z` designator —
//     `strptime("%z")` on older libc, and Python's `%z` before 3.7, both
//     parse a numeric offset and refuse `Z`.
//
// `+00:00` is the one form that answers both: the value *is* UTC, and the
// zone is written numerically. It is also what asdcplib, OpenDCP and our own
// KDM path already emit, so it makes the product self-consistent.
//
// Fractional seconds are deliberately never written. They are legal, but
// plenty of parsers in the chain cap at three digits and choke on the six
// that a Python `datetime.isoformat()` produces.

/// Formats and parses the `IssueDate` of every DCP XML document we write.
public enum DCPIssueDate {

    /// `2026-08-17T10:20:11+00:00` — UTC, seconds precision, numeric zone.
    ///
    /// Built by hand rather than with `ISO8601DateFormatter`: no combination
    /// of its `formatOptions` yields `+00:00` instead of `Z`.
    ///
    /// The result is always exactly 25 characters. SMPTE 430-1 packs this
    /// string into a fixed-width cipher block and `ASDCPSigning.mm` hard
    /// checks the length before copying, so the width is load-bearing.
    public static func string(from date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                   from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d+00:00",
                      c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Reads any `xs:dateTime` another tool might have written: `Z`, `+HH:MM`,
    /// `+HHMM`, or no zone at all, with or without fractional seconds.
    ///
    /// Deliberately lenient. `ISO8601DateFormatter` has to be told about
    /// fractional seconds up front and returns nil for the shape it was not
    /// configured for, which is how a Rouge-gorge timestamp
    /// (`2026-08-17T12:16:24.389278`) silently failed to parse.
    ///
    /// A value with no zone designator is read as UTC. That is a guess — the
    /// form is ambiguous by construction — but it is the guess that keeps a
    /// freshly written file from reading as post-dated.
    public static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // ISO8601DateFormatter always requires a zone designator, so a naive
        // value gets one appended before the attempts below.
        let candidate = hasZoneDesignator(trimmed) ? trimmed : trimmed + "Z"
        for options in parseOptions {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let date = f.date(from: candidate) { return date }
        }
        return nil
    }

    private static let parseOptions: [ISO8601DateFormatter.Options] = [
        [.withInternetDateTime],
        [.withInternetDateTime, .withFractionalSeconds],
    ]

    /// True if the value ends in `Z`, `+HH:MM`, `+HHMM` or the `-` equivalents.
    private static func hasZoneDesignator(_ value: String) -> Bool {
        if value.hasSuffix("Z") || value.hasSuffix("z") { return true }
        return value.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
    }
}

import Foundation

/// Compares AlphaSub marketing versions, including prerelease builds such as
/// "1.0.0b1".
public enum VersionComparator {

    /// True if `candidate` is strictly newer than `current`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let (candidateBase, candidatePre) = splitVersion(candidate)
        let (currentBase, currentPre) = splitVersion(current)

        for i in 0..<max(candidateBase.count, currentBase.count) {
            let a = i < candidateBase.count ? candidateBase[i] : 0
            let b = i < currentBase.count ? currentBase[i] : 0
            if a != b { return a > b }
        }

        // Base versions are equal: a release without a prerelease tag wins.
        switch (candidatePre, currentPre) {
        case (nil, nil): return false
        case (_, nil):   return false          // current is stable, candidate is prerelease
        case (nil, _):   return true           // candidate is stable, current is prerelease
        case let (c?, r?):
            return comparePrerelease(c, r) > 0
        }
    }

    /// Decide whether `candidate` (the latest build on the appcast being
    /// checked) should be offered to a user running `current`.
    ///
    /// A routine update check only offers strictly-newer builds. A deliberate
    /// channel switch (`crossChannel == true`) offers the target channel's
    /// current build whenever it simply *differs* from what is running — so
    /// switching to the beta channel installs e.g. "1.0.1b1" even though it is
    /// not "newer" than the installed stable "1.0.1". Without this, switching
    /// stable → beta silently reports "up to date" and appears to do nothing.
    public static func shouldOfferUpdate(candidate: String,
                                         current: String,
                                         crossChannel: Bool) -> Bool {
        crossChannel ? (candidate != current) : isNewer(candidate, than: current)
    }

    /// Splits "1.0.0b1" into base [1,0,0] and prerelease "b1".
    /// Splits "1.0.0" into base [1,0,0] and no prerelease.
    private static func splitVersion(_ s: String) -> (base: [Int], prerelease: String?) {
        let digitsAndDots = s.prefix { $0.isNumber || $0 == "." }
        let base = digitsAndDots
            .split(separator: ".", omittingEmptySubsequences: true)
            .compactMap { Int($0) }

        let suffixStart = digitsAndDots.endIndex
        let suffix = String(s[suffixStart...])
        return (base, suffix.isEmpty ? nil : suffix)
    }

    /// Compare two prerelease tags. Returns a positive value if `lhs` is newer.
    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> Int {
        var l = lhs[...]
        var r = rhs[...]

        func nextToken(_ s: inout Substring) -> (String, Bool)? {
            guard !s.isEmpty else { return nil }
            let firstIsNumber = s.first?.isNumber ?? false
            let token = s.prefix { char in
                if firstIsNumber { return char.isNumber }
                return char.isLetter
            }
            let tokenStr = String(token)
            s = s[token.endIndex...]
            return (tokenStr, firstIsNumber)
        }

        while true {
            guard let lt = nextToken(&l) else {
                return nextToken(&r) == nil ? 0 : -1
            }
            guard let rt = nextToken(&r) else {
                return 1
            }

            if lt.1 && rt.1 {
                let ln = Int(lt.0) ?? 0
                let rn = Int(rt.0) ?? 0
                if ln != rn { return ln - rn }
            } else {
                let cmp = lt.0.compare(rt.0)
                if cmp != .orderedSame { return cmp == .orderedAscending ? -1 : 1 }
            }
        }
    }
}

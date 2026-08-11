import Foundation

/// Decides which bundle inside an unpacked update archive may replace the
/// running application — and, crucially, whether any of them may at all.
///
/// This is the pure decision half of `Updater.locateApp`. It lives in Core
/// rather than the app target because the app target has no tests, and the
/// property it enforces is a security property that should be verified rather
/// than assumed: whatever the updater selects gets copied over
/// `Bundle.main.bundleURL`, so selecting on file name alone would let any
/// archive containing a plausibly-named bundle overwrite the running app.
///
/// The rule is deliberately strict — the candidate's bundle identifier must
/// equal the running application's. A mismatch is a hard rejection, never a
/// fall-through to the next candidate, because a wrong-feed or tampered payload
/// should surface as a visible failure rather than quietly installing something
/// else.
public enum UpdateBundleSelector {

    /// A `.app` found inside the unpacked archive.
    public struct Candidate: Equatable, Sendable {
        /// Last path component, e.g. `AlphaSub.app`.
        public let name: String
        /// `CFBundleIdentifier`, or `nil` if the bundle could not be read.
        public let bundleIdentifier: String?

        public init(name: String, bundleIdentifier: String?) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// Why an update was refused. Distinguishing these matters: "no app in the
    /// archive" is a broken download, whereas "wrong identity" may mean the
    /// updater is pointed at another product's release feed.
    public enum Rejection: Error, Equatable, Sendable {
        /// The archive contained no `.app` bundle at all.
        case noBundleFound
        /// A bundle was found but it is not this application.
        case identityMismatch(found: String?)
        /// The running app has no readable bundle identifier, so identity
        /// cannot be established. Refuse rather than guess.
        case unknownRunningIdentity
    }

    /// Choose the index of the candidate that may replace the running app.
    ///
    /// Candidates whose name matches `expectedName` are considered first, but
    /// every candidate is identity-checked — a legitimately renamed bundle is
    /// still validated rather than silently skipped, and a same-named impostor
    /// is still rejected.
    ///
    /// - Returns: the index into `candidates`, or the reason for refusal.
    public static func select(
        from candidates: [Candidate],
        expectedName: String,
        runningIdentifier: String?
    ) -> Result<Int, Rejection> {
        guard !candidates.isEmpty else { return .failure(.noBundleFound) }
        guard let runningIdentifier, !runningIdentifier.isEmpty else {
            return .failure(.unknownRunningIdentity)
        }

        // Exact-name matches first, original order preserved within each group.
        let order = candidates.indices.sorted { lhs, rhs in
            let l = candidates[lhs].name == expectedName ? 0 : 1
            let r = candidates[rhs].name == expectedName ? 0 : 1
            return l == r ? lhs < rhs : l < r
        }

        for index in order where candidates[index].bundleIdentifier == runningIdentifier {
            return .success(index)
        }

        // Report the identity we actually saw, preferring the preferred-name
        // candidate, so the error message points at the real problem.
        let reported = order.first.map { candidates[$0].bundleIdentifier } ?? nil
        return .failure(.identityMismatch(found: reported))
    }
}

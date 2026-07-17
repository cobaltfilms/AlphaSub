import Foundation
import ObjectiveC

// MARK: - SecureModeBlockingProtocol

/// Defense-in-depth network kill switch for Secure Mode.
///
/// While ``SecureMode/isEnabled`` is true, this `URLProtocol` claims every
/// http/https load and immediately fails it with a descriptive
/// `NSURLErrorDomain` error (so existing `catch let error as URLError`
/// handling keeps working), recording a `network_blocked` audit entry.
///
/// ``installGlobally()`` registers the class for `URLSession.shared` /
/// `NSURLConnection` **and** swizzles `URLSessionConfiguration.protocolClasses`
/// so that every session configuration created anywhere in the process —
/// including sessions built by third-party packages (swift-transformers Hub,
/// WhisperKit, FluidAudio) — carries the blocker. Because `canInit` consults
/// `SecureMode.isEnabled` dynamically, sessions created while the mode is off
/// are still blocked the moment it is turned on.
///
/// Non-HTTP schemes (`file:` for the bundled WKWebView user guide, `data:`)
/// are never intercepted.
public final class SecureModeBlockingProtocol: URLProtocol {

    // MARK: URLProtocol

    public override class func canInit(with request: URLRequest) -> Bool {
        guard SecureMode.isEnabled,
              let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest ?? task.originalRequest else { return false }
        return canInit(with: request)
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        let url = request.url
        AuditLog.shared.record(.networkBlocked,
                               detail: url?.absoluteString ?? "(unknown URL)")
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: SecureMode.blockedMessage(
                feature: String(localized: "Network access to “\(url?.host ?? "unknown host")”"))
        ]
        if let url {
            userInfo[NSURLErrorFailingURLErrorKey] = url
            userInfo[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
        }
        let error = NSError(domain: NSURLErrorDomain,
                            code: NSURLErrorNotConnectedToInternet,
                            userInfo: userInfo)
        client?.urlProtocol(self, didFailWithError: error)
    }

    public override func stopLoading() {}

    // MARK: Installation

    private static var installed = false

    /// Call once at app start. Registers the protocol globally and injects it
    /// into every `URLSessionConfiguration` created from then on.
    public static func installGlobally() {
        guard !installed else { return }
        installed = true
        URLProtocol.registerClass(SecureModeBlockingProtocol.self)

        // Swizzle the `protocolClasses` getter so ALL configurations —
        // .default, .ephemeral, and ones built by dependencies — return this
        // class first. The blocker is inert while Secure Mode is off (canInit
        // returns false), so this has no effect on normal operation.
        if let original = class_getInstanceMethod(
                URLSessionConfiguration.self,
                #selector(getter: URLSessionConfiguration.protocolClasses)),
           let swizzled = class_getInstanceMethod(
                URLSessionConfiguration.self,
                #selector(getter: URLSessionConfiguration.alphaSub_protocolClasses)) {
            method_exchangeImplementations(original, swizzled)
        }
    }

    /// Explicitly prepend the blocker to a configuration the app builds
    /// itself (belt-and-suspenders on top of the global swizzle).
    @discardableResult
    public static func harden(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        var classes = configuration.protocolClasses ?? []
        if !classes.contains(where: { $0 == SecureModeBlockingProtocol.self }) {
            classes.insert(SecureModeBlockingProtocol.self, at: 0)
            configuration.protocolClasses = classes
        }
        return configuration
    }
}

extension URLSessionConfiguration {
    /// Swizzled replacement for the `protocolClasses` getter. After
    /// `method_exchangeImplementations`, calling this selector inside the
    /// body invokes the ORIGINAL getter.
    @objc fileprivate var alphaSub_protocolClasses: [AnyClass]? {
        var classes = self.alphaSub_protocolClasses ?? []
        if !classes.contains(where: { $0 == SecureModeBlockingProtocol.self }) {
            classes.insert(SecureModeBlockingProtocol.self, at: 0)
        }
        return classes
    }
}

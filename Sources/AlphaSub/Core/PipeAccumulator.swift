import Foundation

/// Thread-safe accumulator for draining a child process's stdout/stderr
/// `Pipe` from a `readabilityHandler` while `Process.waitUntilExit()` runs
/// concurrently.
///
/// The alternative — `waitUntilExit()` and only *then* `readDataToEndOfFile()`
/// — deadlocks whenever the child writes more than the OS pipe buffer (as
/// little as ~16 KB on macOS): the child blocks in `write()` waiting for the
/// buffer to be read, while the parent blocks in `waitUntilExit()` waiting for
/// the child to finish. Every long-running tool the installers invoke (pip,
/// `whisperx --help`, model conversion) can exceed that, so they must drain
/// live. This box collects the streamed chunks safely across the handler's
/// background queue and the caller.
public final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    public init() {}

    public func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    /// UTF-8 decoding of everything accumulated so far.
    public var string: String? {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)
    }
}

import XCTest
@testable import AlphaSubCore

/// Guards the pipe-draining pattern the installers use. The failure it locks
/// out is the one that stalled the WhisperX installer at "Verifying
/// installation…": calling `Process.waitUntilExit()` before reading a pipe
/// deadlocks once the child writes more than the OS pipe buffer (~16 KB on
/// macOS). `whisperx --help` emits ~13 KB on each of stdout AND stderr.
final class PipeAccumulatorTests: XCTestCase {

    func testAppendIsThreadSafe() {
        let acc = PipeAccumulator()
        let group = DispatchGroup()
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<1000 { acc.append(Data([UInt8(i)])) }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(acc.string?.utf8.count, 8000)
    }

    /// A child that floods BOTH stdout and stderr with far more than one pipe
    /// buffer, drained concurrently with waitUntilExit — must complete quickly
    /// and capture every byte. The pre-fix pattern (wait, then read) hangs here.
    func testDrainingBothPipesDoesNotDeadlockOnLargeOutput() {
        // 512 KB per stream — dozens of pipe buffers' worth.
        let bytesPerStream = 512 * 1024
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c",
            "yes A | head -c \(bytesPerStream); yes B | head -c \(bytesPerStream) 1>&2"]
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outBuf = PipeAccumulator(), errBuf = PipeAccumulator()
        let group = DispatchGroup()
        for (pipe, buf) in [(outPipe, outBuf), (errPipe, errBuf)] {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty { fh.readabilityHandler = nil; group.leave(); return }
                buf.append(chunk)
            }
        }

        XCTAssertNoThrow(try proc.run())
        proc.waitUntilExit()
        // If draining worked, both EOFs have arrived (or arrive momentarily).
        let waited = group.wait(timeout: .now() + 30)
        XCTAssertEqual(waited, .success, "pipe draining deadlocked / did not reach EOF")
        XCTAssertEqual(proc.terminationStatus, 0)
        XCTAssertEqual(outBuf.string?.utf8.count, bytesPerStream)
        XCTAssertEqual(errBuf.string?.utf8.count, bytesPerStream)
    }
}

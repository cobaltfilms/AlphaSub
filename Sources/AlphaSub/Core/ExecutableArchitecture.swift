import Foundation

/// Whether a Mach-O executable can actually run on this Mac.
///
/// `FileManager.isExecutableFile` answers a different question than the one
/// callers think they are asking: it tests the `+x` permission bit, which is
/// set on an arm64-only binary sitting on an Intel Mac just as it is anywhere
/// else. Resolving a bundled tool that way finds it, hands it to
/// `posix_spawn`, and gets `EBADARCH` — surfaced to the user as "Bad CPU type
/// in executable", which names neither the tool nor the reason.
///
/// Worse, it makes a fallback unreachable. The asdcp resolvers list
/// `/usr/local/bin` after the bundled copy, and `/usr/local` is the *Intel*
/// Homebrew prefix — that entry exists for precisely this case. The bundled
/// arm64 binary always won, so an Intel user with asdcplib installed still
/// failed.
public enum ExecutableArchitecture {

    /// Architectures this Mac can execute.
    ///
    /// An arm64 Mac also runs x86_64 through Rosetta; an Intel Mac runs x86_64
    /// only. The asymmetry is the whole point — it is why an arm64-only tool
    /// is fine to bundle for one and useless for the other.
    static var host: Set<CPUType> {
        #if arch(arm64)
        return [.arm64, .x86_64]
        #elseif arch(x86_64)
        return [.x86_64]
        #else
        return []
        #endif
    }

    public enum CPUType: UInt32 {
        case x86_64 = 0x0100_0007
        case arm64  = 0x0100_000c
    }

    /// The architectures `path` provides, empty if it is not a Mach-O file.
    public static func architectures(atPath path: String) -> Set<CPUType> {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return [] }

        func bytes(_ d: Data, _ offset: Int) -> [UInt8] {
            let start = d.index(d.startIndex, offsetBy: offset)
            guard offset + 4 <= d.count else { return [] }
            return Array(d[start..<d.index(start, offsetBy: 4)])
        }
        func be32(_ d: Data, _ offset: Int) -> UInt32 {
            bytes(d, offset).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func le32(_ d: Data, _ offset: Int) -> UInt32 {
            bytes(d, offset).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        let magic = be32(header, 0)
        switch magic {
        // Universal ("fat") binary. Its header is always big-endian, and each
        // entry is 20 bytes (32-bit) or 32 bytes (64-bit offsets).
        case 0xcafe_babe, 0xcafe_babf:
            let is64 = (magic == 0xcafe_babf)
            let count = be32(header, 4)
            guard count > 0, count < 64 else { return [] }   // sanity, not spec
            let entry = is64 ? 32 : 20
            guard let table = try? handle.read(upToCount: Int(count) * entry),
                  table.count == Int(count) * entry else { return [] }
            var found: Set<CPUType> = []
            for i in 0..<Int(count) {
                if let cpu = CPUType(rawValue: be32(table, i * entry)) { found.insert(cpu) }
            }
            return found

        // Thin Mach-O. `cputype` follows the magic; endianness is whichever
        // form the magic arrived in.
        case 0xfeed_face, 0xfeed_facf:
            return CPUType(rawValue: be32(header, 4)).map { [$0] } ?? []
        default:
            let swapped = le32(header, 0)
            if swapped == 0xfeed_face || swapped == 0xfeed_facf {
                return CPUType(rawValue: le32(header, 4)).map { [$0] } ?? []
            }
            return []
        }
    }

    /// True when `path` is executable **and** carries a slice this Mac can run.
    ///
    /// A file that is not Mach-O at all — a shell script with a shebang, say —
    /// is accepted on the permission bit alone, because the kernel can run it
    /// and reading its architecture is meaningless.
    public static func canExecute(atPath path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        return canRun(architectures(atPath: path), on: host)
    }

    /// The decision itself, separated from the machine it is asked on so the
    /// Intel case can be tested from an Apple Silicon build — otherwise the
    /// only way to exercise the bug this fixes would be to own the hardware
    /// that has it.
    static func canRun(_ architectures: Set<CPUType>, on host: Set<CPUType>) -> Bool {
        if architectures.isEmpty { return true }  // not Mach-O: script, or unreadable header
        return !architectures.isDisjoint(with: host)
    }
}

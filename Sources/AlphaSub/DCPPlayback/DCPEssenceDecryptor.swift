import Foundation
import CommonCrypto

// MARK: - SMPTE 429-6 encrypted-essence decryption (open-core)
//
// A KDM-encrypted DCP wraps each essence frame in a "Cryptographic Framework"
// triplet (SMPTE 429-6): the plaintext essence element is replaced by an
// Encrypted KLV whose value is
//
//   BER + ContextID(16)  BER + PlaintextOffset(8)  BER + SourceKey(16)
//   BER + SourceLength(8) BER + ESV
//
// where SourceKey is the ORIGINAL essence element UL (byte[12] = 0x15 picture,
// 0x16 sound, 0x17 data/subtitle) and ESV = IV(16) ‖ AES-128-CBC( CheckValue(16)
// ‖ source ‖ padding ). CheckValue is the constant "CHUKCHUKCHUKCHUK". Cinema
// content uses PlaintextOffset = 0 (the whole frame is encrypted).
//
// Given the 16-byte AES content key (from a .keys.json / .dcpdig, or a KDM
// decrypted with our signer key), this recovers the original codestream/XML.
// Validated byte-for-byte against a real AlphaSub-authored encrypted DCP.

public enum DCPEssenceDecryptor {

    /// The 16-byte EKLV check value: ASCII "CHUKCHUKCHUKCHUK".
    static let checkValue = Data([0x43, 0x48, 0x55, 0x4b, 0x43, 0x48, 0x55, 0x4b,
                                  0x43, 0x48, 0x55, 0x4b, 0x43, 0x48, 0x55, 0x4b])

    public enum EssenceKind: UInt8 { case picture = 0x15, sound = 0x16, data = 0x17 }

    public enum DecryptError: LocalizedError {
        case malformedTriplet
        case checkValueMismatch
        case aesFailed(Int32)
        case badKey
        public var errorDescription: String? {
            switch self {
            case .malformedTriplet:  return "Malformed SMPTE 429-6 encrypted triplet."
            case .checkValueMismatch: return "Decryption failed — wrong content key (check value mismatch)."
            case .aesFailed(let s):  return "AES decryption failed (\(s))."
            case .badKey:            return "The content key is not a valid AES-128 key."
            }
        }
    }

    /// A parsed 429-6 encrypted triplet (header fields + the ESV blob).
    public struct Triplet: Sendable {
        public let plaintextOffset: Int
        public let sourceKey: Data       // 16-byte original essence element UL
        public let sourceLength: Int
        public let esv: Data
        /// Essence kind from SourceKey byte 12 (0x15 picture, 0x16 sound, …).
        public var kind: UInt8 { sourceKey.count > 12 ? sourceKey[sourceKey.startIndex + 12] : 0 }
    }

    /// True if `value` (a KLV essence-element value) is an encrypted triplet
    /// whose source is the given essence kind (peek is enough).
    public static func isEncryptedFrame(_ value: Data, kind: EssenceKind) -> Bool {
        guard let t = parseTriplet(value, headerOnly: true) else { return false }
        return t.kind == kind.rawValue
    }

    /// Parses the triplet header (and, unless `headerOnly`, the ESV).
    public static func parseTriplet(_ value: Data, headerOnly: Bool = false) -> Triplet? {
        var o = value.startIndex
        let end = value.endIndex
        func ber() -> Int? {
            guard o < end else { return nil }
            let first = value[o]; o = value.index(after: o)
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 8, value.distance(from: o, to: end) >= count else { return nil }
            var v = 0
            for _ in 0..<count { v = (v << 8) | Int(value[o]); o = value.index(after: o) }
            return v
        }
        func bytes(_ n: Int) -> Data? {
            guard value.distance(from: o, to: end) >= n else { return nil }
            let sub = value.subdata(in: o..<value.index(o, offsetBy: n))
            o = value.index(o, offsetBy: n)
            return sub
        }
        func beUInt(_ n: Int) -> Int? { bytes(n).map { $0.reduce(0) { ($0 << 8) | Int($1) } } }

        guard let cidLen = ber(), cidLen == 16, bytes(16) != nil else { return nil }
        guard let poLen = ber(), let po = beUInt(poLen) else { return nil }
        guard let skLen = ber(), skLen == 16, let sk = bytes(16) else { return nil }
        guard let slLen = ber(), let sl = beUInt(slLen) else { return nil }
        guard let esvLen = ber() else { return nil }
        let esv: Data
        if headerOnly {
            esv = Data()
        } else {
            guard let e = bytes(esvLen) else { return nil }
            esv = e
        }
        return Triplet(plaintextOffset: po, sourceKey: sk, sourceLength: sl, esv: esv)
    }

    /// Decrypts a triplet's ESV with the 16-byte AES content key → the original
    /// source essence bytes.
    public static func decrypt(triplet: Triplet, key: Data) throws -> Data {
        guard key.count == 16 else { throw DecryptError.badKey }
        guard triplet.plaintextOffset == 0, triplet.esv.count >= 32,
              (triplet.esv.count - 16) % 16 == 0 else { throw DecryptError.malformedTriplet }
        let iv = triplet.esv.prefix(16)
        let ct = triplet.esv.suffix(from: triplet.esv.index(triplet.esv.startIndex, offsetBy: 16))
        let plain = try aesCBCDecryptNoPadding(Data(ct), key: key, iv: Data(iv))
        guard plain.count >= 16 + triplet.sourceLength,
              plain.prefix(16) == checkValue else { throw DecryptError.checkValueMismatch }
        let start = plain.index(plain.startIndex, offsetBy: 16)
        return plain.subdata(in: start..<plain.index(start, offsetBy: triplet.sourceLength))
    }

    /// Convenience: parse + decrypt an encrypted essence-element value.
    public static func decryptFrame(_ value: Data, key: Data) throws -> Data {
        guard let t = parseTriplet(value) else { throw DecryptError.malformedTriplet }
        return try decrypt(triplet: t, key: key)
    }

    // MARK: AES-128-CBC (no padding; asdcplib uses a custom zero-marker pad)

    static func aesCBCDecryptNoPadding(_ data: Data, key: Data, iv: Data) throws -> Data {
        let outCapacity = data.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var moved = 0
        let status: Int32 = out.withUnsafeMutableBytes { op in
            data.withUnsafeBytes { ip in
                key.withUnsafeBytes { kp in
                    iv.withUnsafeBytes { vp in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                0,   // CBC, NO PKCS7 padding
                                kp.baseAddress, key.count,
                                vp.baseAddress,
                                ip.baseAddress, data.count,
                                op.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DecryptError.aesFailed(status) }
        out.removeSubrange(moved..<out.count)
        return out
    }
}

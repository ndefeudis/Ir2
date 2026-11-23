import CryptoKit
import Foundation

/// The protocol's crypto (docs/PROTOCOL.md). Same results as tools/fakecar/ir2proto.py and the car's Proto.java.
public enum Ir2Crypto {
    public static let port = 47115
    static let salt = Data("ir2-companion/v1".utf8)
    static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Uppercase, no dashes or spaces, O→0, I→1, L→1.
    public static func normalizeCode(_ text: String) -> String {
        var s = text.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        s = s.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "L", with: "1")
        return s
    }

    /// True for 16 Crockford base32 characters (after normalizing).
    public static func isValidCode(_ text: String) -> Bool {
        let s = normalizeCode(text)
        return s.count == 16 && s.allSatisfy { crockford.contains($0) }
    }

    /// "0123456789ABCDEF" → "0123-4567-89AB-CDEF", for showing what was typed.
    public static func groupCode(_ text: String) -> String {
        let s = Array(normalizeCode(text).prefix(16))
        return stride(from: 0, to: s.count, by: 4).map { String(s[$0..<min($0 + 4, s.count)]) }.joined(separator: "-")
    }

    public static func newDeviceID() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    public static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func deviceKey(code: String, deviceID: String) -> Data {
        hkdf(ikm: Data(normalizeCode(code).utf8), salt: salt, info: Data(("device-key:" + deviceID).utf8), length: 32)
    }

    public static func signRequest(key: Data, method: String, path: String, deviceID: String, counter: UInt64, body: Data) -> String {
        let canonical = [method.uppercased(), path, deviceID, String(counter), hex(Data(SHA256.hash(data: body)))].joined(separator: "\n")
        return hmac(key: key, Data(canonical.utf8))
    }

    public static func signResponse(key: Data, counter: UInt64, status: Int, body: Data) -> String {
        let canonical = ["response", String(counter), String(status), hex(Data(SHA256.hash(data: body)))].joined(separator: "\n")
        return hmac(key: key, Data(canonical.utf8))
    }

    static func hmac(key: Data, _ data: Data) -> String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))))
    }

    /// Constant-time compare.
    public static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }

    public static func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    public static func unhex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}

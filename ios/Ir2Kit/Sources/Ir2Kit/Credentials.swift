import Foundation
#if canImport(Security)
import Security
#endif

/// What pairing leaves on the phone: which car, this phone's id there, the key and the counter.
public struct Pairing: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var deviceID: String
    public var keyHex: String
    public var counter: UInt64
    public var carName: String

    public init(host: String, port: Int, deviceID: String, keyHex: String, counter: UInt64, carName: String) {
        self.host = host
        self.port = port
        self.deviceID = deviceID
        self.keyHex = keyHex
        self.counter = counter
        self.carName = carName
    }
}

/// Where the pairing lives. Counters only ever go up, and are saved before each request.
public protocol PairingStore: Sendable {
    func load() -> Pairing?
    func save(_ p: Pairing) throws
    func clear()
}

public final class MemoryPairingStore: PairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Pairing?

    public init(_ p: Pairing? = nil) { value = p }

    public func load() -> Pairing? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ p: Pairing) throws { lock.lock(); value = p; lock.unlock() }
    public func clear() { lock.lock(); value = nil; lock.unlock() }
}

#if canImport(Security)
/// The pairing in the Keychain, this device only (it never syncs to iCloud or other devices).
public final class KeychainPairingStore: PairingStore, @unchecked Sendable {
    let service: String
    let account = "car"

    public init(service: String = "dev.ir2.companion") { self.service = service }

    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> Pairing? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    public func save(_ p: Pairing) throws {
        let data = try JSONEncoder().encode(p)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q.merge(attrs) { $1 }
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Ir2Error.transport("Keychain error \(status)") }
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}
#endif

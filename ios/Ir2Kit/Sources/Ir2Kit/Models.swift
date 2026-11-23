import Foundation

/// GET /v1/info
public struct CarInfo: Codable, Sendable, Equatable {
    public var `protocol`: Int
    public var service: String
    public var version: String
    public var name: String
    public var pairingOpen: Bool

    enum CodingKeys: String, CodingKey {
        case `protocol`, service, version, name
        case pairingOpen = "pairing_open"
    }
}

/// GET /v1/status
public struct CarStatus: Codable, Sendable, Equatable {
    public struct Ambient: Codable, Sendable, Equatable {
        public var holding: Bool
        public var color: String?
        public var brightness: Int?
    }

    public struct Guard: Codable, Sendable, Equatable {
        public var onlyInPark: Bool
        enum CodingKeys: String, CodingKey { case onlyInPark = "only_in_park" }
    }

    /// nil: the car didn't answer
    public var parked: Bool?
    public var ambient: Ambient
    public var `guard`: Guard
}

/// POST /v1/ambient's answer
public struct AmbientResult: Codable, Sendable, Equatable {
    public var color: String?
    public var brightness: Int?
    public var nearest: Bool
    public var message: String
}

/// A setting's value: JSON true/false, a whole number or text.
public enum SettingValue: Codable, Sendable, Hashable {
    case bool(Bool)
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "a setting is true/false, a whole number or text")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }

    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var int: Int? { if case .int(let i) = self { return i }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
}

/// One entry of the mod's settings.json, as HMG-API's app draws it.
public struct SettingSpec: Codable, Sendable, Identifiable, Equatable {
    public struct Option: Codable, Sendable, Equatable, Hashable {
        public var value: SettingValue
        public var title: String?
    }

    public enum Kind: String, Sendable {
        case toggle, choice, number, text
    }

    public var key: String
    public var type: String?
    public var `default`: SettingValue?
    public var title: String?
    public var description: String?
    public var warning: String?
    public var options: [Option]?
    public var min: Int?
    public var max: Int?
    public var maxLength: Int?
    public var pattern: String?

    public var id: String { key }
    public var kind: Kind { Kind(rawValue: type ?? "text") ?? .text }

    enum CodingKeys: String, CodingKey {
        case key, type, `default`, title, description, warning, options, min, max, pattern
        case maxLength = "max_length"
    }

    /// The same checks the car makes; nil when the value is fine.
    public func problem(with value: SettingValue) -> String? {
        switch kind {
        case .toggle:
            return value.bool == nil ? "On or off" : nil
        case .number:
            guard let n = value.int else { return "A whole number" }
            if let lo = min, n < lo { return "At least \(lo)" }
            if let hi = max, n > hi { return "At most \(hi)" }
            return nil
        case .choice:
            return (options ?? []).contains { $0.value == value } ? nil : "Pick one of the choices"
        case .text:
            guard let s = value.string else { return "Text" }
            let limit = maxLength ?? 200
            if s.count > limit { return "Up to \(limit) characters" }
            if let p = pattern, s.range(of: "^(?:" + p + ")$", options: .regularExpression) == nil { return "Not in the expected form" }
            return nil
        }
    }
}

/// GET/PUT /v1/settings
public struct SettingsPayload: Codable, Sendable, Equatable {
    public var schema: [SettingSpec]
    public var values: [String: SettingValue]
}

struct ErrorBody: Codable {
    var error: String
    var message: String?
}

public enum Ir2Error: Error, Equatable, LocalizedError {
    /// the car answered with an error (docs/PROTOCOL.md, Errors)
    case car(status: Int, code: String, message: String)
    /// an answer that isn't signed by the paired car
    case badSignature
    case notPaired
    case invalidCode
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .car(_, let code, let message):
            switch code {
            case "not_parked": return "Put the car in P first. (\(message))"
            case "unauthorized": return "The car doesn't know this phone any more. Pair it again."
            case "no_pairing": return "There's no pairing code on the car's screen, or it ran out. Tap Pair a phone on the car."
            case "pairing_locked": return "Too many wrong codes. Show a new code on the car."
            case "too_many_devices": return "Four phones are paired already. Remove one on the car's screen."
            case "slow_down": return "Changing too fast; trying again."
            case "refused": return message
            case "car_unavailable": return "HMG-API on the car isn't answering. (\(message))"
            default: return message.isEmpty ? code : message
            }
        case .badSignature: return "An answer didn't come from the paired car, so it was ignored."
        case .notPaired: return "This phone isn't paired with a car yet."
        case .invalidCode: return "The code is 16 letters and digits, as on the car's screen."
        case .transport(let m): return "Can't reach the car: \(m). Is the iPhone on the car's Wi-Fi?"
        }
    }

    public var code: String? {
        if case .car(_, let c, _) = self { return c }
        return nil
    }
}

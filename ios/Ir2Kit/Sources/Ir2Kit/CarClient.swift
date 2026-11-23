import Foundation

/// Talks to the Ir2 Companion mod on the car (docs/PROTOCOL.md). Every request is signed;
/// every answer must be signed by the car, or it's dropped.
public actor CarClient {
    /// errors the car sends before it knows the phone: never signed, only ever taken as "that failed"
    static let unsignedErrors: Set<String> = ["unauthorized", "no_pairing", "pairing_locked", "too_large"]

    let store: PairingStore
    let session: URLSession

    public init(store: PairingStore, timeout: TimeInterval = 8) {
        self.store = store
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.waitsForConnectivity = false
        cfg.httpShouldUsePipelining = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    public var pairing: Pairing? { store.load() }

    // MARK: - before pairing

    public func info(host: String, port: Int = Ir2Crypto.port) async throws -> CarInfo {
        var req = URLRequest(url: try url(host, port, "/v1/info"))
        req.httpMethod = "GET"
        let (data, status, _) = try await send(req)
        guard status == 200 else { throw Ir2Error.transport("HTTP \(status)") }
        do {
            return try JSONDecoder().decode(CarInfo.self, from: data)
        } catch {
            throw Ir2Error.transport("that isn't an Ir2 Companion car")
        }
    }

    /// Pairs with the code on the car's screen. Replaces any earlier pairing on this phone.
    @discardableResult
    public func pair(host: String, port: Int = Ir2Crypto.port, code: String, deviceName: String) async throws -> Pairing {
        guard Ir2Crypto.isValidCode(code) else { throw Ir2Error.invalidCode }
        let deviceID = Ir2Crypto.newDeviceID()
        let key = Ir2Crypto.deviceKey(code: code, deviceID: deviceID)
        struct Body: Encodable { let device_id: String; let device_name: String }
        let name = String(deviceName.prefix(40)).isEmpty ? "iPhone" : String(deviceName.prefix(40))
        let body = try JSONEncoder().encode(Body(device_id: deviceID, device_name: name))
        let data = try await signed("POST", "/v1/pair", body: body, host: host, port: port, deviceID: deviceID, key: key, counter: 1)
        struct Paired: Decodable { let paired: Bool; let name: String }
        let r = try JSONDecoder().decode(Paired.self, from: data)
        let p = Pairing(host: host, port: port, deviceID: deviceID, keyHex: Ir2Crypto.hex(key), counter: 1, carName: r.name)
        try store.save(p)
        return p
    }

    // MARK: - paired

    public func status() async throws -> CarStatus {
        let data = try await call("GET", "/v1/status")
        return try decode(CarStatus.self, data)
    }

    public func settings() async throws -> SettingsPayload {
        let data = try await call("GET", "/v1/settings")
        return try decode(SettingsPayload.self, data)
    }

    public func saveSettings(_ values: [String: SettingValue]) async throws -> SettingsPayload {
        struct Body: Encodable { let values: [String: SettingValue] }
        let body = try JSONEncoder().encode(Body(values: values))
        let data = try await call("PUT", "/v1/settings", body: body)
        let payload = try decode(SettingsPayload.self, data)
        if let name = payload.values["car_name"]?.string, var p = store.load(), p.carName != name {
            p.carName = name
            try? store.save(p)
        }
        return payload
    }

    /// Sets the ambient light. save: also keep it as the mod's saved colour (put back at each start if asked).
    public func ambient(color: UInt32? = nil, brightness: Int? = nil, save: Bool = false) async throws -> AmbientResult {
        struct Body: Encodable { let color: String?; let brightness: Int?; let save: Bool }
        let body = try JSONEncoder().encode(Body(color: color.map(AmbientPalette.hex), brightness: brightness, save: save))
        let data = try await call("POST", "/v1/ambient", body: body)
        return try decode(AmbientResult.self, data)
    }

    /// Gives the light back to the car's own colour and brightness.
    public func releaseAmbient() async throws {
        _ = try await call("POST", "/v1/ambient/release")
    }

    /// Tells the car to forget this phone, and forgets the car. The local pairing goes even if the car can't be reached.
    public func unpair() async {
        _ = try? await call("POST", "/v1/unpair")
        store.clear()
    }

    public func forget() { store.clear() }

    // MARK: - plumbing

    func call(_ method: String, _ path: String, body: Data = Data()) async throws -> Data {
        guard var p = store.load(), let key = Ir2Crypto.unhex(p.keyHex) else { throw Ir2Error.notPaired }
        p.counter += 1
        try store.save(p)  // before sending: a counter is never used twice
        return try await signed(method, path, body: body, host: p.host, port: p.port, deviceID: p.deviceID, key: key, counter: p.counter)
    }

    func signed(_ method: String, _ path: String, body: Data, host: String, port: Int,
                deviceID: String, key: Data, counter: UInt64) async throws -> Data {
        var req = URLRequest(url: try url(host, port, path))
        req.httpMethod = method
        if !body.isEmpty {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.setValue(deviceID, forHTTPHeaderField: "X-Ir2-Device")
        req.setValue(String(counter), forHTTPHeaderField: "X-Ir2-Counter")
        req.setValue(Ir2Crypto.signRequest(key: key, method: method, path: path, deviceID: deviceID, counter: counter, body: body),
                     forHTTPHeaderField: "X-Ir2-Signature")
        let (data, status, sig) = try await send(req)
        let err = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let unsignedOK = status != 200 && sig == nil && err.map { Self.unsignedErrors.contains($0.error) } == true
        if !unsignedOK {
            let want = Ir2Crypto.signResponse(key: key, counter: counter, status: status, body: data)
            guard let sig, Ir2Crypto.same(sig, want) else { throw Ir2Error.badSignature }
        }
        guard status == 200 else {
            throw Ir2Error.car(status: status, code: err?.error ?? "http_\(status)", message: err?.message ?? "")
        }
        return data
    }

    func send(_ req: URLRequest) async throws -> (Data, Int, String?) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw Ir2Error.transport("no HTTP answer") }
            return (data, http.statusCode, http.value(forHTTPHeaderField: "X-Ir2-Signature"))
        } catch let e as Ir2Error {
            throw e
        } catch {
            throw Ir2Error.transport(error.localizedDescription)
        }
    }

    func url(_ host: String, _ port: Int, _ path: String) throws -> URL {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = port
        c.path = path
        guard let u = c.url else { throw Ir2Error.transport("bad address \(host)") }
        return u
    }

    func decode<T: Decodable>(_ t: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(t, from: data)
        } catch {
            throw Ir2Error.transport("unexpected answer from the car")
        }
    }
}

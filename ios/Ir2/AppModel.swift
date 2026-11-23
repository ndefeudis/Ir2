import Foundation
import Ir2Kit
import Observation

/// A saved look the phone can put on the car with one tap. Kept on the phone only.
struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var color: UInt32
    var brightness: Int
}

@MainActor
@Observable
final class AppModel {
    let client: CarClient
    private(set) var pairing: Pairing?
    private(set) var status: CarStatus?
    private(set) var settings: SettingsPayload?
    private(set) var lastResult: AmbientResult?
    var lastError: String?
    private(set) var busy = false

    // the look being edited
    var draftColor: UInt32 = 0xffffff
    var draftBrightness: Int = 6
    var livePreview = true

    var presets: [Preset] = [] {
        didSet { savePresets() }
    }

    private var sending = false
    private var pending: (color: UInt32?, brightness: Int?)?

    init(store: PairingStore = KeychainPairingStore()) {
        client = CarClient(store: store)
        pairing = store.load()
        presets = Self.loadPresets()
    }

    var carName: String { pairing?.carName ?? "Car" }

    // MARK: pairing

    func checkCar(host: String) async -> CarInfo? {
        do {
            lastError = nil
            return try await client.info(host: host)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func pair(host: String, code: String, deviceName: String) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            lastError = nil
            pairing = try await client.pair(host: host, code: code, deviceName: deviceName)
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func unpair() async {
        await client.unpair()
        pairing = nil
        status = nil
        settings = nil
        lastResult = nil
    }

    // MARK: reading the car

    func refresh() async {
        guard pairing != nil else { return }
        do {
            lastError = nil
            let st = try await client.status()
            status = st
            settings = try await client.settings()
            if !sending, let c = st.ambient.color.flatMap(AmbientPalette.parse) { draftColor = c }
            if !sending, let b = st.ambient.brightness { draftBrightness = b }
            pairing = await client.pairing
        } catch {
            handle(error)
        }
    }

    // MARK: the ambient light

    /// Called as the colour or brightness changes: sends the latest look, at most 4 times a second.
    func lookChanged() {
        guard livePreview, pairing != nil else { return }
        pending = (draftColor, draftBrightness)
        if !sending { Task { await drain() } }
    }

    private func drain() async {
        sending = true
        defer { sending = false }
        while let next = pending {
            pending = nil
            do {
                lastResult = try await client.ambient(color: next.color, brightness: next.brightness)
                lastError = nil
            } catch Ir2Error.car(_, "slow_down", _) {
                if pending == nil { pending = next }
            } catch {
                handle(error)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if let st = try? await client.status() { status = st }
    }

    /// Puts the look on the car and keeps it as the mod's saved look.
    func saveLook() async {
        busy = true
        defer { busy = false }
        do {
            lastResult = try await client.ambient(color: draftColor, brightness: draftBrightness, save: true)
            lastError = nil
            await refresh()
        } catch {
            handle(error)
        }
    }

    /// Gives the light back to the car's own colour.
    func release() async {
        busy = true
        defer { busy = false }
        do {
            try await client.releaseAmbient()
            lastResult = nil
            await refresh()
        } catch {
            handle(error)
        }
    }

    func apply(_ p: Preset) {
        draftColor = p.color
        draftBrightness = p.brightness
        pending = (p.color, p.brightness)
        if !sending { Task { await drain() } }
    }

    // MARK: settings

    func saveSettings(_ values: [String: SettingValue]) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            settings = try await client.saveSettings(values)
            pairing = await client.pairing
            lastError = nil
            if let st = try? await client.status() { status = st }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: -

    private func handle(_ error: Error) {
        lastError = error.localizedDescription
        if case Ir2Error.car(_, "unauthorized", _) = error {
            // the car forgot this phone (removed on its screen): start over
            Task {
                await client.forget()
                pairing = nil
            }
        }
    }

    private static let presetsKey = "presets.v1"

    private static func loadPresets() -> [Preset] {
        if let d = UserDefaults.standard.data(forKey: presetsKey), let p = try? JSONDecoder().decode([Preset].self, from: d) {
            return p
        }
        return [
            Preset(name: "Ice", color: 0x10f4fc, brightness: 6),
            Preset(name: "Ember", color: 0xff321d, brightness: 5),
            Preset(name: "Violet", color: 0x781cef, brightness: 6),
            Preset(name: "White", color: 0xffffff, brightness: 4),
        ]
    }

    private func savePresets() {
        if let d = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(d, forKey: Self.presetsKey) }
    }
}

#if os(macOS)
import XCTest
@testable import Ir2Kit

/// The client against tools/fakecar/fake_headunit.py (needs python3): pairing, signing,
/// settings and the ambient light, end to end over HTTP.
final class FakeHeadUnitTests: XCTestCase {
    static let code = "0123-4567-89AB-CDEF"
    var proc: Process!
    var input: Pipe!
    var port = 0

    override func setUpWithError() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../").standardizedFileURL
        let fake = repo.appendingPathComponent("tools/fakecar/fake_headunit.py").path
        guard FileManager.default.fileExists(atPath: fake) else { throw XCTSkip("no fake head unit at \(fake)") }
        proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", fake, "--host", "127.0.0.1", "--port", "0", "--pair-code", Self.code]
        let out = Pipe()
        input = Pipe()
        proc.standardOutput = out
        proc.standardInput = input
        try proc.run()
        var buf = Data()
        let deadline = Date().addingTimeInterval(15)
        while port == 0 && Date() < deadline {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buf.append(chunk)
            for line in String(decoding: buf, as: UTF8.self).split(separator: "\n") where line.hasPrefix("LISTENING ") {
                port = Int(line.split(separator: " ")[1]) ?? 0
            }
        }
        if port == 0 { throw XCTSkip("the fake head unit didn't start (python3 missing?)") }
    }

    override func tearDown() {
        proc?.terminate()
        proc?.waitUntilExit()
    }

    func command(_ s: String) {
        input.fileHandleForWriting.write(Data((s + "\n").utf8))
        Thread.sleep(forTimeInterval: 0.3)
    }

    func testEndToEnd() async throws {
        let store = MemoryPairingStore()
        let c = CarClient(store: store)

        let info = try await c.info(host: "127.0.0.1", port: port)
        XCTAssertEqual(info.service, "ir2-companion")
        XCTAssertTrue(info.pairingOpen)

        do {
            try await c.pair(host: "127.0.0.1", port: port, code: "AAAA-AAAA-AAAA-AAAA", deviceName: "Test")
            XCTFail("a wrong code paired")
        } catch let e as Ir2Error {
            XCTAssertEqual(e.code, "unauthorized")
        }
        let p = try await c.pair(host: "127.0.0.1", port: port, code: Self.code.lowercased(), deviceName: "Test")
        XCTAssertEqual(p.carName, "Ioniq 5")

        let st = try await c.status()
        XCTAssertEqual(st.parked, true)
        XCTAssertFalse(st.ambient.holding)

        let r = try await c.ambient(color: 0xff3300, brightness: 4, save: true)
        XCTAssertEqual(r.color, "ff321d")
        XCTAssertTrue(r.nearest)
        let s = try await c.settings()
        XCTAssertEqual(s.values["ambient_color"], .string("ff321d"))
        XCTAssertEqual(s.values["ambient_brightness"], .int(4))

        let s2 = try await c.saveSettings(["car_name": .string("Blue Ioniq")])
        XCTAssertEqual(s2.values["car_name"], .string("Blue Ioniq"))
        XCTAssertEqual(store.load()?.carName, "Blue Ioniq")

        command("park no")
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            _ = try await c.ambient(brightness: 2)
            XCTFail("changed the light outside P")
        } catch let e as Ir2Error {
            XCTAssertEqual(e.code, "not_parked")
        }
        try await c.releaseAmbient()

        // a replayed counter is refused, and the answer is still signed
        var old = store.load()!
        old.counter = 2
        try store.save(old)
        do {
            _ = try await c.status()
            XCTFail("replay accepted")
        } catch let e as Ir2Error {
            XCTAssertEqual(e.code, "replay")
        }

        await c.unpair()
        XCTAssertNil(store.load())
    }

    func testWrongKeyIsRefused() async throws {
        let store = MemoryPairingStore()
        let c = CarClient(store: store)
        try await c.pair(host: "127.0.0.1", port: port, code: Self.code, deviceName: "Test")
        // the phone now holds a key the car never made: the car refuses it, unsigned
        var p = store.load()!
        p.keyHex = String(repeating: "ab", count: 32)
        try store.save(p)
        do {
            _ = try await c.settings()
            XCTFail("an answer signed with another key was accepted")
        } catch let e as Ir2Error {
            XCTAssertEqual(e.code, "unauthorized")  // the car doesn't know that key either: unsigned 401
        }
    }
}
#endif

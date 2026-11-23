import XCTest
@testable import Ir2Kit

/// Vectors from tools/fakecar/ir2proto.py: the phone, the fake and the car must agree byte for byte.
final class CryptoTests: XCTestCase {
    let dev = "00112233445566778899aabbccddeeff"

    func testHKDFRFC5869Case1() {
        let okm = Ir2Crypto.hkdf(ikm: Data(repeating: 0x0b, count: 22), salt: Data(0...12), info: Data(0xf0...0xf9), length: 42)
        XCTAssertEqual(Ir2Crypto.hex(okm), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }

    func testDeviceKey() {
        let k = Ir2Crypto.deviceKey(code: "0123-4567-89ab-cdef", deviceID: dev)
        XCTAssertEqual(Ir2Crypto.hex(k), "faf346982120d5eb6027e474e76ad859cf99fd978f63f9c29737c70ea520c6b8")
        XCTAssertEqual(k, Ir2Crypto.deviceKey(code: "o123 4567 89AB CDEF", deviceID: dev))
    }

    func testSignatures() {
        let k = Ir2Crypto.deviceKey(code: "0123456789ABCDEF", deviceID: dev)
        let body = Data(#"{"device_id":"00112233445566778899aabbccddeeff","device_name":"Test"}"#.utf8)
        XCTAssertEqual(Ir2Crypto.signRequest(key: k, method: "POST", path: "/v1/pair", deviceID: dev, counter: 1, body: body),
                       "5a520567be85fbda21ec888e3cef770d24221090dfac45cb00db749006b289c0")
        XCTAssertEqual(Ir2Crypto.signRequest(key: k, method: "get", path: "/v1/status", deviceID: dev, counter: 42, body: Data()),
                       "90ffb857bd848df019bf4aaba137d37e51982616a368f44b62f627d8bfeeceec")
        XCTAssertEqual(Ir2Crypto.signResponse(key: k, counter: 42, status: 200, body: Data(#"{"ok":true}"#.utf8)),
                       "c10f343fc56dd38d811bd852a321f55b725fc857c32075496e1ec0e66a815641")
    }

    func testCodes() {
        XCTAssertTrue(Ir2Crypto.isValidCode("0123-4567-89ab-cdef"))
        XCTAssertFalse(Ir2Crypto.isValidCode("0123-4567-89ab-cde"))
        XCTAssertFalse(Ir2Crypto.isValidCode("0123-4567-89ab-cdeU"))
        XCTAssertEqual(Ir2Crypto.groupCode("0123456789abcdef"), "0123-4567-89AB-CDEF")
        XCTAssertEqual(Ir2Crypto.groupCode("012345"), "0123-45")
        XCTAssertEqual(Ir2Crypto.newDeviceID().count, 32)
        XCTAssertTrue(Ir2Crypto.same("abc", "abc"))
        XCTAssertFalse(Ir2Crypto.same("abc", "abd"))
        XCTAssertEqual(Ir2Crypto.unhex("00ff10"), Data([0, 255, 16]))
    }

    func testPalette() {
        XCTAssertEqual(AmbientPalette.colors.count, 64)
        XCTAssertEqual(AmbientPalette.hex(AmbientPalette.nearest(0xff3300)), "ff321d")
        XCTAssertEqual(AmbientPalette.hex(AmbientPalette.nearest(0x00ff00)), "5dde69")
        XCTAssertEqual(AmbientPalette.hex(AmbientPalette.nearest(0x000000)), "1020ef")
    }
}

final class SettingsTests: XCTestCase {
    func testSchemaDecodesAndChecks() throws {
        let json = #"""
        {"schema":[
          {"key":"car_name","type":"text","default":"Ioniq 5","max_length":24,"title":"Car name"},
          {"key":"only_in_park","type":"toggle","default":true},
          {"key":"ambient_color","type":"text","default":"","pattern":"([0-9a-f]{6})?"},
          {"key":"ambient_brightness","type":"number","default":6,"min":0,"max":10},
          {"key":"mode","type":"choice","default":"a","options":[{"value":"a","title":"A"},{"value":"b"}]}
        ],"values":{"car_name":"Ioniq 5","only_in_park":true,"ambient_color":"","ambient_brightness":6,"mode":"a"}}
        """#
        let p = try JSONDecoder().decode(SettingsPayload.self, from: Data(json.utf8))
        XCTAssertEqual(p.values["ambient_brightness"], .int(6))
        XCTAssertEqual(p.values["only_in_park"], .bool(true))
        let s = Dictionary(uniqueKeysWithValues: p.schema.map { ($0.key, $0) })
        XCTAssertNil(s["car_name"]!.problem(with: .string("Blue")))
        XCTAssertNotNil(s["car_name"]!.problem(with: .string(String(repeating: "x", count: 25))))
        XCTAssertNil(s["ambient_color"]!.problem(with: .string("")))
        XCTAssertNil(s["ambient_color"]!.problem(with: .string("ff321d")))
        XCTAssertNotNil(s["ambient_color"]!.problem(with: .string("FF321D")))
        XCTAssertNotNil(s["ambient_brightness"]!.problem(with: .int(11)))
        XCTAssertNotNil(s["ambient_brightness"]!.problem(with: .bool(true)))
        XCTAssertNil(s["mode"]!.problem(with: .string("b")))
        XCTAssertNotNil(s["mode"]!.problem(with: .string("c")))
        XCTAssertEqual(s["mode"]!.kind, .choice)
    }
}

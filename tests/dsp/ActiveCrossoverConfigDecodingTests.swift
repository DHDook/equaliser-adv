import XCTest
@testable import Equaliser

final class ActiveCrossoverConfigDecodingTests: XCTestCase {

    func testActiveCrossoverConfigDecodesWithoutLegacyKeys() throws {
        // The exact scenario that crashed: a JSON blob with NO legacy flat keys
        // present at all (the current, non-legacy format).
        let json = """
        {"isEnabled": true, "bandCount": 2,
         "lowerPoint": {"lpHz": 300, "hpHz": 300}, "upperPoint": {"lpHz": 3000, "hpHz": 3000}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ActiveCrossoverConfig.self, from: json)
        XCTAssertEqual(decoded.lowerCrossoverHz, 300)
        XCTAssertEqual(decoded.upperCrossoverHz, 3000)
    }

    func testActiveCrossoverConfigDecodesWithLegacyKeysPresent() throws {
        // Simulates an actual pre-V5 saved file using the old flat format.
        let json = """
        {"isEnabled": true, "bandCount": 2,
         "lowerCrossoverHz": 250, "upperCrossoverHz": 2500,
         "slope": 1, "filterType": 0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ActiveCrossoverConfig.self, from: json)
        XCTAssertEqual(decoded.lowerCrossoverHz, 250)
        XCTAssertEqual(decoded.upperCrossoverHz, 2500)
    }

    func testActiveCrossoverConfigEncodeDecodeRoundTrip() throws {
        let original = ActiveCrossoverConfig(isEnabled: true, bandCount: .triAmp)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActiveCrossoverConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}

import XCTest
@testable import Equaliser

final class FilterSlopeTests: XCTestCase {

    // MARK: - Raw Values

    func testRawValues() {
        XCTAssertEqual(FilterSlope.db6.rawValue, 6)
        XCTAssertEqual(FilterSlope.db12.rawValue, 12)
        XCTAssertEqual(FilterSlope.db18.rawValue, 18)
        XCTAssertEqual(FilterSlope.db24.rawValue, 24)
        XCTAssertEqual(FilterSlope.db36.rawValue, 36)
        XCTAssertEqual(FilterSlope.db48.rawValue, 48)
        XCTAssertEqual(FilterSlope.db60.rawValue, 60)
        XCTAssertEqual(FilterSlope.db72.rawValue, 72)
        XCTAssertEqual(FilterSlope.db84.rawValue, 84)
        XCTAssertEqual(FilterSlope.db96.rawValue, 96)
    }

    // MARK: - CaseIterable

    func testCaseIterable_allCasesCount() {
        XCTAssertEqual(FilterSlope.allCases.count, 10)
    }

    func testCaseIterable_orderedBySlope() {
        let rawValues = FilterSlope.allCases.map { $0.rawValue }
        XCTAssertEqual(rawValues, rawValues.sorted())
    }

    // MARK: - Section Count

    func testSectionCount_db6() {
        XCTAssertEqual(FilterSlope.db6.sectionCount, 1)
    }

    func testSectionCount_db12() {
        XCTAssertEqual(FilterSlope.db12.sectionCount, 1)
    }

    func testSectionCount_db18() {
        XCTAssertEqual(FilterSlope.db18.sectionCount, 2)
    }

    func testSectionCount_db24() {
        XCTAssertEqual(FilterSlope.db24.sectionCount, 2)
    }

    func testSectionCount_db36() {
        XCTAssertEqual(FilterSlope.db36.sectionCount, 3)
    }

    func testSectionCount_db48() {
        XCTAssertEqual(FilterSlope.db48.sectionCount, 4)
    }

    func testSectionCount_db60() {
        XCTAssertEqual(FilterSlope.db60.sectionCount, 5)
    }

    func testSectionCount_db72() {
        XCTAssertEqual(FilterSlope.db72.sectionCount, 6)
    }

    func testSectionCount_db84() {
        XCTAssertEqual(FilterSlope.db84.sectionCount, 7)
    }

    func testSectionCount_db96() {
        XCTAssertEqual(FilterSlope.db96.sectionCount, 8)
    }

    // MARK: - First-Order Section

    func testHasFirstOrderSection_onlyDb18() {
        for slope in FilterSlope.allCases {
            if slope == .db18 {
                XCTAssertTrue(slope.hasFirstOrderSection)
            } else {
                XCTAssertFalse(slope.hasFirstOrderSection, "\(slope) should not have first-order section")
            }
        }
    }

    // MARK: - Butterworth Q Values

    func testButterworthQValues_db6_isEmpty() {
        XCTAssertTrue(FilterSlope.db6.butterworthQValues.isEmpty)
    }

    func testButterworthQValues_db12_singleValue() {
        let qValues = FilterSlope.db12.butterworthQValues
        XCTAssertEqual(qValues.count, 1)
        XCTAssertEqual(qValues[0], 1.0 / sqrt(2.0), accuracy: 1e-10)
    }

    func testButterworthQValues_db18_singleValue() {
        let qValues = FilterSlope.db18.butterworthQValues
        XCTAssertEqual(qValues.count, 1)
        XCTAssertEqual(qValues[0], 1.0, accuracy: 1e-10)
    }

    func testButterworthQValues_db24_twoValues() {
        let qValues = FilterSlope.db24.butterworthQValues
        XCTAssertEqual(qValues.count, 2)
        XCTAssertGreaterThan(qValues[0], 1.0)
        XCTAssertLessThan(qValues[1], 1.0)
    }

    func testButterworthQValues_countMatchesSectionCountForEvenOrders() {
        // For even-order slopes (not db6, db18), Q value count should equal section count
        let evenSlopes: [FilterSlope] = [.db12, .db24, .db36, .db48, .db60, .db72, .db84, .db96]
        for slope in evenSlopes {
            XCTAssertEqual(
                slope.butterworthQValues.count,
                slope.sectionCount,
                "\(slope) Q value count should match section count"
            )
        }
    }

    func testButterworthQValues_allPositive() {
        for slope in FilterSlope.allCases {
            for q in slope.butterworthQValues {
                XCTAssertGreaterThan(q, 0, "\(slope) has non-positive Q value")
            }
        }
    }

    // MARK: - Display Names

    func testDisplayName_format() {
        for slope in FilterSlope.allCases {
            let name = slope.displayName
            XCTAssertTrue(name.hasSuffix("dB/oct"), "\(slope) display name should end with dB/oct")
            XCTAssertTrue(name.contains("\(slope.rawValue)"), "\(slope) display name should contain raw value")
        }
    }

    // MARK: - Codable

    func testCodable_roundTrip() throws {
        for slope in FilterSlope.allCases {
            let data = try JSONEncoder().encode(slope)
            let decoded = try JSONDecoder().decode(FilterSlope.self, from: data)
            XCTAssertEqual(decoded, slope)
        }
    }

    // MARK: - isSupported

    func testIsSupported_lowPass() {
        XCTAssertTrue(FilterSlope.isSupported(for: .lowPass))
    }

    func testIsSupported_highPass() {
        XCTAssertTrue(FilterSlope.isSupported(for: .highPass))
    }

    func testIsSupported_lowShelf() {
        XCTAssertTrue(FilterSlope.isSupported(for: .lowShelf))
    }

    func testIsSupported_highShelf() {
        XCTAssertTrue(FilterSlope.isSupported(for: .highShelf))
    }

    func testIsSupported_parametric_notSupported() {
        XCTAssertFalse(FilterSlope.isSupported(for: .parametric))
    }

    func testIsSupported_bandPass_notSupported() {
        XCTAssertFalse(FilterSlope.isSupported(for: .bandPass))
    }

    func testIsSupported_notch_notSupported() {
        XCTAssertFalse(FilterSlope.isSupported(for: .notch))
    }
}

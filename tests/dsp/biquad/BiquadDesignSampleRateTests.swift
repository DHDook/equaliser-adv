import XCTest
@testable import Equaliser

final class BiquadDesignSampleRateTests: XCTestCase {

    func testDesignSampleRateUsesReferenceAbove96kWhenEnabled() {
        let rate = BiquadMath.designSampleRate(actualRate: 192_000, coefficientDecouplingEnabled: true)
        XCTAssertEqual(rate, BiquadMath.highResReferenceSampleRateHz)
    }

    func testDesignSampleRatePassesThroughAt48k() {
        let rate = BiquadMath.designSampleRate(actualRate: 48_000, coefficientDecouplingEnabled: true)
        XCTAssertEqual(rate, 48_000)
    }

    func testDesignSampleRateBypassedAbove96k() {
        let rate = BiquadMath.designSampleRate(actualRate: 192_000, coefficientDecouplingEnabled: false)
        XCTAssertEqual(rate, 192_000)
    }
}

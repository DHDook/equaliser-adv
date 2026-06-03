import XCTest
@testable import Equaliser

final class RoutingStatusTests: XCTestCase {

    // MARK: - isActive

    func testIsActive_active_returnsTrue() {
        let status = RoutingStatus.active(inputName: "Mic", outputName: "Speakers")
        XCTAssertTrue(status.isActive)
    }

    func testIsActive_idle_returnsFalse() {
        XCTAssertFalse(RoutingStatus.idle.isActive)
    }

    func testIsActive_starting_returnsFalse() {
        XCTAssertFalse(RoutingStatus.starting.isActive)
    }

    func testIsActive_driverNotInstalled_returnsFalse() {
        XCTAssertFalse(RoutingStatus.driverNotInstalled.isActive)
    }

    func testIsActive_error_returnsFalse() {
        XCTAssertFalse(RoutingStatus.error("something failed").isActive)
    }

    // MARK: - Equatable

    func testEquatable_sameCase_equal() {
        XCTAssertEqual(RoutingStatus.idle, RoutingStatus.idle)
        XCTAssertEqual(RoutingStatus.starting, RoutingStatus.starting)
        XCTAssertEqual(RoutingStatus.driverNotInstalled, RoutingStatus.driverNotInstalled)
        XCTAssertEqual(
            RoutingStatus.active(inputName: "A", outputName: "B"),
            RoutingStatus.active(inputName: "A", outputName: "B")
        )
        XCTAssertEqual(RoutingStatus.error("x"), RoutingStatus.error("x"))
    }

    func testEquatable_differentCase_notEqual() {
        XCTAssertNotEqual(RoutingStatus.idle, RoutingStatus.starting)
        XCTAssertNotEqual(RoutingStatus.idle, RoutingStatus.driverNotInstalled)
        XCTAssertNotEqual(
            RoutingStatus.active(inputName: "A", outputName: "B"),
            RoutingStatus.active(inputName: "A", outputName: "C")
        )
        XCTAssertNotEqual(RoutingStatus.error("x"), RoutingStatus.error("y"))
    }
}

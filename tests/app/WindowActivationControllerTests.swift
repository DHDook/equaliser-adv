import AppKit
import XCTest
@testable import Equaliser

@MainActor
final class WindowActivationControllerTests: XCTestCase {
    func testPrepareToShowWindow_requestsRegularActivation() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.prepareToShowWindow()

        XCTAssertEqual(policyApplier.policies, [.regular])
    }

    func testWindowBecameVisible_requestsRegularActivation() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.windowBecameVisible(.equaliser)

        XCTAssertEqual(policyApplier.policies, [.regular])
    }

    func testWindowBecameHidden_requestsAccessoryWhenLastWindowCloses() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.windowBecameVisible(.equaliser)
        controller.windowBecameHidden(.equaliser)

        XCTAssertEqual(policyApplier.policies, [.regular, .accessory])
    }

    func testWindowBecameHidden_keepsRegularWhenAnotherWindowIsVisible() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.windowBecameVisible(.equaliser)
        controller.windowBecameVisible(.settings)
        controller.windowBecameHidden(.equaliser)

        XCTAssertEqual(policyApplier.policies, [.regular])
    }

    func testWindowVisibilityChanges_areIdempotent() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.windowBecameVisible(.equaliser)
        controller.windowBecameVisible(.equaliser)
        controller.windowBecameHidden(.equaliser)
        controller.windowBecameHidden(.equaliser)

        XCTAssertEqual(policyApplier.policies, [.regular, .accessory])
    }

    func testLaunchAsMenuBarApp_requestsAccessoryActivation() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.launchAsMenuBarApp()

        XCTAssertEqual(policyApplier.policies, [.accessory])
    }

    func testLaunchAsMenuBarApp_keepsRegularWhenWindowIsVisible() {
        let policyApplier = RecordingActivationPolicyApplier()
        let controller = WindowActivationController(policyApplier: policyApplier)

        controller.windowBecameVisible(.equaliser)
        controller.launchAsMenuBarApp()

        XCTAssertEqual(policyApplier.policies, [.regular])
    }
}

private final class RecordingActivationPolicyApplier: ActivationPolicyApplying {
    private(set) var policies: [NSApplication.ActivationPolicy] = []

    func apply(_ policy: NSApplication.ActivationPolicy) {
        policies.append(policy)
    }
}

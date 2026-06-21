import XCTest
@testable import Equaliser
import SwiftUI

/// Tests for the Single Amp template in OutputChannelMatrixView.
final class SingleAmpTemplateTests: XCTestCase {

    func testApplySingleAmpTemplateSetsFullRangeBandCount() throws {
        let store = EqualiserStore()
        let view = OutputChannelMatrixView(store: store, meterStore: MeterStore())

        // Apply the Single Amp template
        view.applySingleAmpTemplate()

        // Verify bandCount is set to fullRange
        XCTAssertEqual(store.activeCrossoverConfig.bandCount, .fullRange)
    }

    func testApplySingleAmpTemplateCreatesExactlyTwoChannels() throws {
        let store = EqualiserStore()
        let view = OutputChannelMatrixView(store: store, meterStore: MeterStore())

        // Apply the Single Amp template
        view.applySingleAmpTemplate()

        // Verify exactly two channels are created
        XCTAssertEqual(store.outputChannelMatrix.channels.count, 2)
    }

    func testApplySingleAmpTemplateUsesMainsLeftAndMainsRightSources() throws {
        let store = EqualiserStore()
        let view = OutputChannelMatrixView(store: store, meterStore: MeterStore())

        // Apply the Single Amp template
        view.applySingleAmpTemplate()

        // Verify the sources are mainsLeft and mainsRight
        XCTAssertEqual(store.outputChannelMatrix.channels[0].source, .mainsLeft)
        XCTAssertEqual(store.outputChannelMatrix.channels[1].source, .mainsRight)
    }

    func testApplySingleAmpTemplateBothChannelsEnabledByDefault() throws {
        let store = EqualiserStore()
        let view = OutputChannelMatrixView(store: store, meterStore: MeterStore())

        // Apply the Single Amp template
        view.applySingleAmpTemplate()

        // Verify both channels are enabled
        XCTAssertTrue(store.outputChannelMatrix.channels[0].isEnabled)
        XCTAssertTrue(store.outputChannelMatrix.channels[1].isEnabled)
    }

    func testApplySingleAmpTemplateReplacesExistingChannelsEntirely() throws {
        let store = EqualiserStore()
        let view = OutputChannelMatrixView(store: store, meterStore: MeterStore())

        // Pre-populate channels via applyVerticalTriAmpTemplate()
        view.applyVerticalTriAmpTemplate()
        XCTAssertEqual(store.outputChannelMatrix.channels.count, 6)

        // Apply the Single Amp template
        view.applySingleAmpTemplate()

        // Verify channels are replaced entirely (now exactly 2)
        XCTAssertEqual(store.outputChannelMatrix.channels.count, 2)
        XCTAssertEqual(store.outputChannelMatrix.channels[0].label, "Left")
        XCTAssertEqual(store.outputChannelMatrix.channels[1].label, "Right")
        XCTAssertEqual(store.outputChannelMatrix.channels[0].source, .mainsLeft)
        XCTAssertEqual(store.outputChannelMatrix.channels[1].source, .mainsRight)
    }
}

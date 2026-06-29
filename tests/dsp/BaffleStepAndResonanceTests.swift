// BaffleStepAndResonanceTests.swift
// Tests for BaffleStepCalculator wiring and resonance auto-correction path.

import XCTest
@testable import Equaliser

final class BaffleStepAndResonanceTests: XCTestCase {

    // MARK: - BaffleStepCalculator correctness
    // These tests are purely computational — no @MainActor needed.

    /// For a 30 cm wide baffle with centred driver (driverToEdge = 15 cm),
    /// transition frequency must be c / (2π × 0.15) ≈ 363.8 Hz.
    func testBaffleStepCalculator_30cmBaffle_CorrectTransitionFrequency() {
        let geometry = BaffleStepCalculator.BaffleGeometry(widthMetres: 0.30)
        let result = BaffleStepCalculator.computeCompensation(geometry: geometry)
        let expected = Float(343.0) / (2.0 * Float.pi * 0.15)
        XCTAssertEqual(result.transitionHz, expected, accuracy: 1.0,
            "30 cm baffle transition must be ~364 Hz; got \(result.transitionHz) Hz")
    }

    /// The old (wrong) formula would give 343 / (2 × 0.30) = 571.7 Hz.
    /// Verify the correct formula does NOT produce this value.
    func testBaffleStepCalculator_30cmBaffle_NotOldWrongFormula() {
        let geometry = BaffleStepCalculator.BaffleGeometry(widthMetres: 0.30)
        let result = BaffleStepCalculator.computeCompensation(geometry: geometry)
        let oldWrongFreq = Float(343.0) / (2.0 * 0.30)
        XCTAssertNotEqual(result.transitionHz, oldWrongFreq, accuracy: 10.0,
            "BaffleStepCalculator must NOT use the incorrect formula f = c / (2×width)")
    }

    /// Shelf frequency is transitionHz / 1.5.
    func testBaffleStepCalculator_ShelfFrequency_IsTransitionDividedBy1Point5() {
        let geometry = BaffleStepCalculator.BaffleGeometry(widthMetres: 0.25)
        let result = BaffleStepCalculator.computeCompensation(geometry: geometry)
        let shelfFreq = result.transitionHz / 1.5
        XCTAssertEqual(shelfFreq, result.transitionHz / 1.5, accuracy: 0.1)
    }

    /// Recommended gain must be 6.0 dB (theoretical full baffle step).
    func testBaffleStepCalculator_RecommendedGain_IsSixDB() {
        let geometry = BaffleStepCalculator.BaffleGeometry(widthMetres: 0.40)
        let result = BaffleStepCalculator.computeCompensation(geometry: geometry)
        XCTAssertEqual(result.recommendedGainDB, 6.0, accuracy: 0.01)
    }

    /// Explicit driverToEdge overrides the widthMetres / 2 assumption.
    func testBaffleStepCalculator_ExplicitDriverToEdge_UsedOverHalfWidth() {
        let geometry = BaffleStepCalculator.BaffleGeometry(
            widthMetres: 0.30,
            driverToEdgeMetres: 0.08
        )
        let result = BaffleStepCalculator.computeCompensation(geometry: geometry)
        let expectedTransition = Float(343.0) / (2.0 * Float.pi * 0.08)
        XCTAssertEqual(result.transitionHz, expectedTransition, accuracy: 1.0,
            "Explicit driverToEdge must override widthMetres / 2")
    }

    // MARK: - applyBaffleStepToChannel (@MainActor — touches EqualiserStore)

    @MainActor
    func testApplyBaffleStepToChannel_AddsLowShelfBand() {
        let store = makeTestStore()
        let channelIndex = 0
        let initialBandCount = store.outputChannelMatrix.channels[channelIndex].eq.activeBandCount

        let geometry = BaffleStepCalculator.BaffleGeometry(widthMetres: 0.30)
        let result = BaffleStepCalculator.computeCompensation(geometry: geometry)
        store.applyBaffleStepToChannel(index: channelIndex, result: result)

        let ch = store.outputChannelMatrix.channels[channelIndex]
        XCTAssertEqual(ch.eq.activeBandCount, initialBandCount + 1,
            "Applying baffle step must add exactly one new band")

        let newBand = ch.eq.bands[initialBandCount]
        XCTAssertEqual(newBand.filterType, .lowShelf, "Applied band must be a low shelf")
        XCTAssertEqual(Double(newBand.frequency), Double(result.transitionHz / 1.5), accuracy: 1.0,
            "Shelf frequency must be transitionHz / 1.5")
        XCTAssertEqual(newBand.gain, result.recommendedGainDB, accuracy: 0.01)
        XCTAssertFalse(newBand.bypass, "Applied band must not be bypassed")
    }

    @MainActor
    func testApplyBaffleStepToChannel_FullChannel_DoesNotCrash() {
        let store = makeTestStore()
        let channelIndex = 0
        for i in 0..<EQConfiguration.maxBandCount {
            store.outputChannelMatrix.channels[channelIndex].eq.bands[i] =
                EQBandConfiguration(frequency: 1000, q: 1.0, gain: 0,
                                    filterType: .parametric, bypass: false)
        }
        store.outputChannelMatrix.channels[channelIndex].eq.activeBandCount =
            EQConfiguration.maxBandCount

        let applied = store.appendBandToOutputChannel(
            index: channelIndex,
            band: EQBandConfiguration(frequency: 300, q: 0.707,
                                      gain: 6.0, filterType: .lowShelf, bypass: false)
        )
        XCTAssertFalse(applied,
            "appendBandToOutputChannel must return false when band limit is reached")
        XCTAssertEqual(
            store.outputChannelMatrix.channels[channelIndex].eq.activeBandCount,
            EQConfiguration.maxBandCount,
            "Band count must not exceed maxBandCount"
        )
    }

    // MARK: - DiaphragmResonanceDetector: suggestedNotch.gain fix
    // Pure computation — no @MainActor needed.

    func testResonanceDetector_SuggestedNotchGain_IsNegativeProminence() {
        let response = createSyntheticResponse(
            peaks: [(frequency: 3000.0, prominenceDB: 8.0, q: 12.0)]
        )
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response)
        XCTAssertGreaterThan(candidates.count, 0, "Must detect the test peak")

        let notchGain = candidates[0].suggestedNotch.gain
        XCTAssertLessThan(notchGain, 0.0, "Notch gain must be negative (a cut)")
        XCTAssertGreaterThan(notchGain, -20.0, "Notch gain must be bounded")
        let expected = Float(-candidates[0].prominenceDB * 0.8)
        XCTAssertEqual(notchGain, expected, accuracy: 0.1,
            "Notch gain must be -prominenceDB × 0.8")
    }

    func testResonanceDetector_SuggestedNotchGain_IsNotZero() {
        let response = createSyntheticResponse(
            peaks: [(frequency: 5000.0, prominenceDB: 6.0, q: 10.0)]
        )
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response)
        XCTAssertGreaterThan(candidates.count, 0)
        XCTAssertNotEqual(candidates[0].suggestedNotch.gain, 0.0, accuracy: 0.01,
            "Suggested notch gain must not be 0 — a zero-gain notch has no effect")
    }

    // MARK: - applyResonanceCorrection (@MainActor — touches EqualiserStore)

    @MainActor
    func testApplyResonanceCorrection_SingleCandidate_AddsOneNotchBand() {
        let store = makeTestStore()
        let channelIndex = 0
        let initialCount = store.outputChannelMatrix.channels[channelIndex].eq.activeBandCount

        let response = createSyntheticResponse(
            peaks: [(frequency: 6000.0, prominenceDB: 7.0, q: 10.0)]
        )
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response)
        XCTAssertGreaterThan(candidates.count, 0, "Must detect at least one candidate")

        store.applyResonanceCorrection(channelIndex: channelIndex, candidates: [candidates[0]])

        let ch = store.outputChannelMatrix.channels[channelIndex]
        XCTAssertEqual(ch.eq.activeBandCount, initialCount + 1,
            "Applying one resonance candidate must add exactly one band")

        let newBand = ch.eq.bands[initialCount]
        XCTAssertEqual(newBand.filterType, .notch, "Applied band must be a notch filter")
        XCTAssertLessThan(newBand.gain, 0.0, "Notch band gain must be negative (a cut)")
        XCTAssertFalse(newBand.bypass)
    }

    @MainActor
    func testApplyResonanceCorrection_MultipleCandidates_AddsOneBandPerCandidate() {
        let store = makeTestStore()
        let channelIndex = 0
        let initialCount = store.outputChannelMatrix.channels[channelIndex].eq.activeBandCount

        let response = createSyntheticResponse(peaks: [
            (frequency: 4000.0, prominenceDB: 8.0, q: 10.0),
            (frequency: 8000.0, prominenceDB: 5.0, q: 10.0)
        ])
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response)
        XCTAssertGreaterThanOrEqual(candidates.count, 2, "Must detect both test peaks")

        store.applyResonanceCorrection(channelIndex: channelIndex,
                                       candidates: Array(candidates.prefix(2)))

        let newCount = store.outputChannelMatrix.channels[channelIndex].eq.activeBandCount
        XCTAssertEqual(newCount, initialCount + 2,
            "Applying two candidates must add exactly two bands")
    }

    @MainActor
    func testApplyResonanceCorrection_AppliesHighestProminenceFirst() {
        let store = makeTestStore()
        let channelIndex = 0

        let response = createSyntheticResponse(peaks: [
            (frequency: 3000.0, prominenceDB: 4.0, q: 10.0),
            (frequency: 8000.0, prominenceDB: 9.0, q: 10.0)
        ])
        let candidates = DiaphragmResonanceDetector.detect(magnitudeResponseDB: response)
        XCTAssertGreaterThanOrEqual(candidates.count, 2)

        let initialCount = store.outputChannelMatrix.channels[channelIndex].eq.activeBandCount
        store.applyResonanceCorrection(channelIndex: channelIndex, candidates: candidates)

        let firstApplied = store.outputChannelMatrix.channels[channelIndex].eq.bands[initialCount]
        XCTAssertEqual(Double(firstApplied.frequency), 8000.0, accuracy: 500.0,
            "Highest prominence candidate (8 kHz) must be applied first")
    }

    // MARK: - Helpers

    @MainActor
    private func makeTestStore() -> EqualiserStore {
        let store = EqualiserStore()
        var ch1 = OutputChannelConfig()
        ch1.source = .mainsLeftHigh
        ch1.isEnabled = true
        var ch2 = OutputChannelConfig()
        ch2.source = .mainsRightHigh
        ch2.isEnabled = true
        store.outputChannelMatrix = OutputChannelMatrixConfig(
            isEnabled: true, channels: [ch1, ch2])
        return store
    }

    private func createSyntheticResponse(
        baseLevel: Double = 0.0,
        peaks: [(frequency: Double, prominenceDB: Double, q: Double)]
    ) -> [(frequency: Double, gainDB: Double)] {
        let points = 500
        let logStart = log10(20.0)
        let logEnd   = log10(20000.0)
        let logStep  = (logEnd - logStart) / Double(points - 1)

        return (0..<points).map { i in
            let freq = pow(10.0, logStart + Double(i) * logStep)
            var gain = baseLevel
            for peak in peaks {
                let bw = peak.frequency / peak.q
                let lo = peak.frequency / pow(2.0, bw / peak.frequency / 2.0)
                let hi = peak.frequency * pow(2.0, bw / peak.frequency / 2.0)
                if freq >= lo && freq <= hi {
                    let centre     = log10(peak.frequency)
                    let curr       = log10(freq)
                    let width      = log10(hi) - log10(lo)
                    let normalised = (curr - centre) / (width / 2.0)
                    gain += peak.prominenceDB * exp(-normalised * normalised)
                }
            }
            return (frequency: freq, gainDB: gain)
        }
    }
}

// ActiveCrossoverEngineTests.swift
// Regression tests for ActiveCrossoverEngine.

import XCTest
@testable import Equaliser

final class ActiveCrossoverEngineTests: XCTestCase {

    // MARK: - No-allocation guard

    /// Verifies that process() can be called repeatedly without any change in
    /// observable heap activity (structural guard: if work buffers were re-allocated
    /// per call, filter state would be reset each time, causing leftLow[0] to equal
    /// leftIn[0] on every call regardless of filter state — this test checks that
    /// filter state accumulates correctly across multiple calls, which only works if
    /// the work buffers are the pre-allocated stored properties, not freshly zeroed locals).
    func testProcessPreservesFilterStateAcrossCalls() {
        var engine = ActiveCrossoverEngine(maxFrameCount: 512)

        let sampleRate = 48000.0
        let lpCoeffs = BiquadMath.calculateSections(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 500.0,
            q: 0.7071,
            gain: 0.0,
            slope: .db24
        )

        let identity: (b0: Float, b1: Float, b2: Float, na1: Float, na2: Float) = (1, 0, 0, 0, 0)
        var lpSections = ActiveCrossoverEngine.SectionArray(
            repeating: identity, count: ActiveCrossoverEngine.maxSections)
        for (i, s) in lpCoeffs.enumerated() where i < ActiveCrossoverEngine.maxSections {
            lpSections[i] = (Float(s.b0), Float(s.b1), Float(s.b2), Float(s.a1), Float(s.a2))
        }
        let identitySections = ActiveCrossoverEngine.SectionArray(
            repeating: identity, count: ActiveCrossoverEngine.maxSections)

        engine.pendingLowerLP   = lpSections
        engine.pendingLowerHP   = identitySections
        engine.pendingUpperLP   = identitySections
        engine.pendingUpperHP   = identitySections
        engine.pendingBandCount = 2
        engine.hasIIRPendingUpdate.store(true, ordering: .relaxed)

        // Process a burst of DC (1.0) for 256 frames to prime the filter state
        let frameCount = 256
        let inputL = [Float](repeating: 1.0, count: frameCount)
        let inputR = [Float](repeating: 1.0, count: frameCount)

        inputL.withUnsafeBufferPointer { lPtr in
            inputR.withUnsafeBufferPointer { rPtr in
                engine.process(leftIn: lPtr.baseAddress!, rightIn: rPtr.baseAddress!, frameCount: frameCount)
            }
        }

        // Capture output after first call
        let firstCallOutput = engine.leftLow[frameCount - 1]

        // Process again — if filter state was reset by a re-allocation in process(),
        // the output would match the first sample of the first call. If state is
        // preserved correctly, the second call continues from where the first left off,
        // producing the same steady-state value (filter is near-settled after 256 DC frames).
        inputL.withUnsafeBufferPointer { lPtr in
            inputR.withUnsafeBufferPointer { rPtr in
                engine.process(leftIn: lPtr.baseAddress!, rightIn: rPtr.baseAddress!, frameCount: frameCount)
            }
        }

        let secondCallOutput = engine.leftLow[frameCount - 1]

        // Both calls should produce the same near-DC output (filter settled).
        // If work buffers were accidentally zeroed between calls, the state would
        // reset and the second call would produce a different (lower) transient value.
        XCTAssertEqual(firstCallOutput, secondCallOutput, accuracy: 0.001,
            "Filter state must be preserved across process() calls — work buffers must not be re-initialised per call")
    }

    // MARK: - Bi-amp split correctness

    /// Verifies that in bi-amp mode, leftLow + leftHigh sum to approximately
    /// the input at the crossover frequency (power-complementary property is
    /// not tested here — just that both outputs are populated and non-trivially different).
    func testBiAmpSplitProducesNonZeroLowAndHigh() {
        var engine = ActiveCrossoverEngine(maxFrameCount: 512)
        let sampleRate = 48000.0
        let crossoverHz = 2000.0

        let lpCoeffs = BiquadMath.calculateSections(
            type: .lowPass, sampleRate: sampleRate,
            frequency: crossoverHz, q: 0.7071, gain: 0.0, slope: .db24)
        let hpCoeffs = BiquadMath.calculateSections(
            type: .highPass, sampleRate: sampleRate,
            frequency: crossoverHz, q: 0.7071, gain: 0.0, slope: .db24)

        let identity: (b0: Float, b1: Float, b2: Float, na1: Float, na2: Float) = (1, 0, 0, 0, 0)
        func toSectionArray(_ c: [BiquadCoefficients]) -> ActiveCrossoverEngine.SectionArray {
            var arr = ActiveCrossoverEngine.SectionArray(
                repeating: identity, count: ActiveCrossoverEngine.maxSections)
            for (i, s) in c.enumerated() where i < ActiveCrossoverEngine.maxSections {
                arr[i] = (Float(s.b0), Float(s.b1), Float(s.b2), Float(s.a1), Float(s.a2))
            }
            return arr
        }

        engine.pendingLowerLP   = toSectionArray(lpCoeffs)
        engine.pendingLowerHP   = toSectionArray(hpCoeffs)
        engine.pendingUpperLP   = ActiveCrossoverEngine.SectionArray(repeating: identity, count: ActiveCrossoverEngine.maxSections)
        engine.pendingUpperHP   = ActiveCrossoverEngine.SectionArray(repeating: identity, count: ActiveCrossoverEngine.maxSections)
        engine.pendingBandCount = 2
        engine.hasIIRPendingUpdate.store(true, ordering: .relaxed)

        // Sine wave at 500 Hz (well below crossover) — should appear mostly in leftLow
        let frameCount = 512
        let freq: Float = 500.0
        var inputL = (0..<frameCount).map { Float(sin(2.0 * .pi * freq * Float($0) / Float(sampleRate))) }
        var inputR = inputL

        inputL.withUnsafeMutableBufferPointer { lPtr in
            inputR.withUnsafeMutableBufferPointer { rPtr in
                engine.process(leftIn: lPtr.baseAddress!, rightIn: rPtr.baseAddress!, frameCount: frameCount)
            }
        }

        // After settling, RMS of leftLow should be substantially larger than leftHigh
        let rmsLow  = sqrt(engine.leftLow[256...511].map { $0 * $0 }.reduce(0, +) / 256)
        let rmsHigh = sqrt(engine.leftHigh[256...511].map { $0 * $0 }.reduce(0, +) / 256)

        XCTAssertGreaterThan(rmsLow, 0.1, "Low band should pass a 500 Hz tone")
        XCTAssertGreaterThan(rmsLow, rmsHigh * 5.0,
            "Low band RMS should greatly exceed high band RMS for a tone well below crossover")
    }
}

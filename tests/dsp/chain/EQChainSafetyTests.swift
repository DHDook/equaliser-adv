// EQChainSafetyTests.swift
// Tests for EQChain's defense-in-depth NaN/Inf coefficient rejection (S-07, R-04).
// Verifies that malformed coefficients staged by any code path are silently replaced
// with identity passthrough before reaching the audio thread.

import XCTest
@testable import Equaliser

final class EQChainSafetyTests: XCTestCase {

    private let frameCount: UInt32 = 512

    func testStageBandUpdateRejectsNaNCoefficients() {
        let chain = EQChain(maxFrameCount: frameCount)
        let malformed = BiquadCoefficients(b0: .nan, b1: 0, b2: 0, a1: 0, a2: 0)
        chain.stageBandUpdate(index: 0, sections: [malformed], bypass: false)
        chain.applyPendingUpdates()

        // Feed a unit impulse — output must remain finite (identity passthrough behaviour)
        var buffer = [Float](repeating: 0.0, count: 16)
        buffer[0] = 1.0
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(buffer: ptr.baseAddress!, frameCount: 16)
        }
        for (i, sample) in buffer.enumerated() {
            XCTAssertTrue(sample.isFinite,
                "Sample[\(i)] is non-finite after staging NaN b0 coefficient")
        }
    }

    func testStageBandUpdateRejectsInfCoefficients() {
        let chain = EQChain(maxFrameCount: frameCount)
        let malformed = BiquadCoefficients(b0: 1, b1: .infinity, b2: 0, a1: 0, a2: 0)
        chain.stageBandUpdate(index: 0, sections: [malformed], bypass: false)
        chain.applyPendingUpdates()

        var buffer = [Float](repeating: 0.0, count: 16)
        buffer[0] = 1.0
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(buffer: ptr.baseAddress!, frameCount: 16)
        }
        for (i, sample) in buffer.enumerated() {
            XCTAssertTrue(sample.isFinite,
                "Sample[\(i)] is non-finite after staging Inf b1 coefficient")
        }
    }

    func testStageFullUpdateRejectsNaNInOneBand() {
        let chain = EQChain(maxFrameCount: frameCount)
        // Place NaN in band 3 — all other bands are identity
        var sections = [[BiquadCoefficients]](repeating: [.identity], count: EQConfiguration.maxBandCount)
        sections[3] = [BiquadCoefficients(b0: .nan, b1: 0, b2: 0, a1: 0, a2: 0)]

        chain.stageFullUpdate(
            sections: sections,
            bypassFlags: [Bool](repeating: false, count: EQConfiguration.maxBandCount),
            activeBandCount: 10,
            layerBypass: false
        )
        chain.applyPendingUpdates()

        var buffer = [Float](repeating: 0.0, count: 16)
        buffer[0] = 1.0
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(buffer: ptr.baseAddress!, frameCount: 16)
        }
        for (i, sample) in buffer.enumerated() {
            XCTAssertTrue(sample.isFinite,
                "Sample[\(i)] is non-finite after stageFullUpdate with NaN in band 3")
        }
    }

    func testStageFullUpdateRejectsInfInOneBand() {
        let chain = EQChain(maxFrameCount: frameCount)
        var sections = [[BiquadCoefficients]](repeating: [.identity], count: EQConfiguration.maxBandCount)
        sections[5] = [BiquadCoefficients(b0: 1, b1: .infinity, b2: 0, a1: 0, a2: 0)]

        chain.stageFullUpdate(
            sections: sections,
            bypassFlags: [Bool](repeating: false, count: EQConfiguration.maxBandCount),
            activeBandCount: 10,
            layerBypass: false
        )
        chain.applyPendingUpdates()

        var buffer = [Float](repeating: 0.0, count: 16)
        buffer[0] = 1.0
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(buffer: ptr.baseAddress!, frameCount: 16)
        }
        for (i, sample) in buffer.enumerated() {
            XCTAssertTrue(sample.isFinite,
                "Sample[\(i)] is non-finite after stageFullUpdate with Inf in band 5")
        }
    }

    func testValidCoefficientsPassThrough() {
        // Sanity check: a valid peaking EQ band at 1 kHz should not produce identity output.
        let chain = EQChain(maxFrameCount: frameCount)
        let coeffs = BiquadMath.peakingEQ(sampleRate: 48000, frequency: 1000, q: 1.0, gain: 6.0)
        chain.stageBandUpdate(index: 0, sections: [coeffs], bypass: false)
        chain.applyPendingUpdates()

        // Feed white-ish signal — output should differ from input (filter is active)
        var buffer: [Float] = (0..<16).map { Float($0 % 4 == 0 ? 1.0 : 0.0) }
        let inputSum = buffer.reduce(0, +)
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(buffer: ptr.baseAddress!, frameCount: 16)
        }
        let outputSum = buffer.reduce(0, +)
        // A +6 dB peaking filter at 1 kHz will modify the signal — sums should differ
        XCTAssertNotEqual(inputSum, outputSum, accuracy: 0.001,
            "Valid +6 dB peaking filter must modify the signal, not act as identity")
        for sample in buffer {
            XCTAssertTrue(sample.isFinite, "Valid filter must produce finite output")
        }
    }
}

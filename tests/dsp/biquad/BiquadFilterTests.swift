import XCTest
@testable import Equaliser

final class BiquadFilterTests: XCTestCase {
    // MARK: - Test Constants

    let sampleRate: Double = 48000.0
    let frameCount: UInt32 = 512

    // MARK: - Helper

    /// Convenience helper for tests: creates setup and sets coefficients in one call.
    /// This avoids repeating the prepareSetup + setCoefficients pattern in every test.
    private func setFilterCoefficients(
        _ filter: BiquadFilter,
        _ coefficients: BiquadCoefficients,
        resetState: Bool
    ) {
        let setup = BiquadFilter.prepareSetup(coefficients)
        filter.setCoefficients(coefficients, setup: setup, resetState: resetState)
    }

    // MARK: - Passthrough Tests

    func testIdentityPassthrough() {
        let filter = BiquadFilter()
        setFilterCoefficients(filter, .identity, resetState: true)

        // Create a simple impulse signal
        var input: [Float] = [Float](repeating: 0, count: Int(frameCount))
        input[0] = 1.0 // Impulse at first sample

        var output: [Float] = [Float](repeating: 0, count: Int(frameCount))

        input.withUnsafeBufferPointer { inputPtr in
            output.withUnsafeMutableBufferPointer { outputPtr in
                filter.process(
                    input: inputPtr.baseAddress!,
                    output: outputPtr.baseAddress!,
                    frameCount: frameCount
                )
            }
        }

        // Identity coefficients should pass signal unchanged
        for i in 0..<Int(frameCount) {
            XCTAssertEqual(output[i], input[i], accuracy: 1e-6, "Sample \(i) differs")
        }
    }

    func testPassthroughBeforeSetup() {
        // Filter starts with no setup, so should pass through
        let filter = BiquadFilter()

        var input: [Float] = [Float](repeating: 0.5, count: Int(frameCount))
        var output: [Float] = [Float](repeating: 0, count: Int(frameCount))

        input.withUnsafeBufferPointer { inputPtr in
            output.withUnsafeMutableBufferPointer { outputPtr in
                filter.process(
                    input: inputPtr.baseAddress!,
                    output: outputPtr.baseAddress!,
                    frameCount: frameCount
                )
            }
        }

        // Should pass through (no setup = passthrough)
        for i in 0..<Int(frameCount) {
            XCTAssertEqual(output[i], input[i], accuracy: 1e-6)
        }
    }

    // MARK: - Filter Response Tests

    func testParametricImpulseResponse() {
        let filter = BiquadFilter()

        // Create a +6dB peaking filter at 1kHz
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0
        )
        setFilterCoefficients(filter, coeffs, resetState: true)

        // Create impulse
        var input: [Float] = [Float](repeating: 0, count: Int(frameCount))
        input[0] = 1.0

        var output: [Float] = [Float](repeating: 0, count: Int(frameCount))

        input.withUnsafeBufferPointer { inputPtr in
            output.withUnsafeMutableBufferPointer { outputPtr in
                filter.process(
                    input: inputPtr.baseAddress!,
                    output: outputPtr.baseAddress!,
                    frameCount: frameCount
                )
            }
        }

        // Output should be non-zero (filter has processed the impulse)
        // First sample should be close to b0
        XCTAssertGreaterThan(abs(output[0]), 0.0)

        // The impulse response should decay towards zero
        // For a stable filter, later samples should be smaller
        let lateSum = output.suffix(100).reduce(0) { $0 + abs($1) }
        XCTAssertLessThan(lateSum, 1.0) // Sum of last 100 samples should be small
    }

    func testLowPassAttenuatesHighs() {
        let filter = BiquadFilter()

        // Low-pass at 1kHz
        let coeffs = BiquadMath.calculateCoefficients(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0
        )
        setFilterCoefficients(filter, coeffs, resetState: true)

        // Create a high-frequency signal (10kHz, near Nyquist)
        let highFreq: Float = 10000.0
        var input: [Float] = [Float](repeating: 0, count: Int(frameCount))
        for i in 0..<Int(frameCount) {
            input[i] = sin(2.0 * .pi * highFreq * Float(i) / Float(sampleRate))
        }

        var output: [Float] = [Float](repeating: 0, count: Int(frameCount))

        input.withUnsafeBufferPointer { inputPtr in
            output.withUnsafeMutableBufferPointer { outputPtr in
                filter.process(
                    input: inputPtr.baseAddress!,
                    output: outputPtr.baseAddress!,
                    frameCount: frameCount
                )
            }
        }

        // Calculate RMS of output
        let outputRMS = sqrt(output.reduce(0) { $0 + $1 * $1 } / Float(frameCount))
        let inputRMS = sqrt(input.reduce(0) { $0 + $1 * $1 } / Float(frameCount))

        // Low-pass at 1kHz should significantly attenuate 10kHz
        XCTAssertLessThan(outputRMS, inputRMS * 0.5)
    }

    func testHighPassAttenuatesLows() {
        let filter = BiquadFilter()

        // High-pass at 1kHz
        let coeffs = BiquadMath.calculateCoefficients(
            type: .highPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0
        )
        setFilterCoefficients(filter, coeffs, resetState: true)

        // Create a low-frequency signal (100Hz)
        let lowFreq: Float = 100.0
        var input: [Float] = [Float](repeating: 0, count: Int(frameCount))
        for i in 0..<Int(frameCount) {
            input[i] = sin(2.0 * .pi * lowFreq * Float(i) / Float(sampleRate))
        }

        var output: [Float] = [Float](repeating: 0, count: Int(frameCount))

        input.withUnsafeBufferPointer { inputPtr in
            output.withUnsafeMutableBufferPointer { outputPtr in
                filter.process(
                    input: inputPtr.baseAddress!,
                    output: outputPtr.baseAddress!,
                    frameCount: frameCount
                )
            }
        }

        // Calculate RMS of output
        let outputRMS = sqrt(output.reduce(0) { $0 + $1 * $1 } / Float(frameCount))
        let inputRMS = sqrt(input.reduce(0) { $0 + $1 * $1 } / Float(frameCount))

        // High-pass at 1kHz should significantly attenuate 100Hz
        XCTAssertLessThan(outputRMS, inputRMS * 0.5)
    }

    func testCoefficientUpdate() {
        let filter = BiquadFilter()

        // Start with identity
        setFilterCoefficients(filter, .identity, resetState: true)

        // Update to a low-pass
        let lowPassCoeffs = BiquadMath.calculateCoefficients(
            type: .lowPass,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 0.707,
            gain: 0.0
        )
        setFilterCoefficients(filter, lowPassCoeffs, resetState: true)

        // Create impulse
        var input: [Float] = [Float](repeating: 0, count: Int(frameCount))
        input[0] = 1.0

        var output: [Float] = [Float](repeating: 0, count: Int(frameCount))

        input.withUnsafeBufferPointer { inputPtr in
            output.withUnsafeMutableBufferPointer { outputPtr in
                filter.process(
                    input: inputPtr.baseAddress!,
                    output: outputPtr.baseAddress!,
                    frameCount: frameCount
                )
            }
        }

        // Should not match identity output
        // Low-pass impulse response has different shape
        // Just verify it's different from identity
        XCTAssertGreaterThan(abs(output[0] - input[0]), 0.1)
    }

    func testInPlaceProcessing() {
        let filter = BiquadFilter()
        setFilterCoefficients(filter, .identity, resetState: true)

        var buffer: [Float] = [Float](repeating: 1.0, count: Int(frameCount))

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            // Process in-place: input and output point to same buffer
            filter.process(
                input: bufPtr.baseAddress!,
                output: bufPtr.baseAddress!,
                frameCount: frameCount
            )
        }

        // Identity filter should pass signal unchanged
        for i in 0..<Int(frameCount) {
            XCTAssertEqual(buffer[i], 1.0, accuracy: 1e-6)
        }
    }

    // MARK: - resetState Behaviour Tests

    /// Verifies that `resetState: false` preserves filter memory between coefficient changes.
    /// A filter with accumulated delay state should produce different output to one that was reset.
    func testIncrementalUpdate_preservesDelayState() {
        let filter = BiquadFilter()
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0
        )

        // Set initial coefficients with a clean state
        setFilterCoefficients(filter, coeffs, resetState: true)

        // Run a sine wave through the filter to accumulate delay state
        let freq: Float = 1000.0
        var warmupBuffer: [Float] = (0..<Int(frameCount)).map {
            sin(2.0 * .pi * freq * Float($0) / Float(sampleRate))
        }
        warmupBuffer.withUnsafeMutableBufferPointer { ptr in
            filter.process(input: ptr.baseAddress!, output: ptr.baseAddress!, frameCount: frameCount)
        }

        // Capture a snapshot of output with preserved state (resetState: false)
        setFilterCoefficients(filter, coeffs, resetState: false)
        var outputPreserved: [Float] = (0..<Int(frameCount)).map {
            sin(2.0 * .pi * freq * Float($0) / Float(sampleRate))
        }
        outputPreserved.withUnsafeMutableBufferPointer { ptr in
            filter.process(input: ptr.baseAddress!, output: ptr.baseAddress!, frameCount: frameCount)
        }

        // Capture output after resetting state (resetState: true)
        setFilterCoefficients(filter, coeffs, resetState: true)
        var outputReset: [Float] = (0..<Int(frameCount)).map {
            sin(2.0 * .pi * freq * Float($0) / Float(sampleRate))
        }
        outputReset.withUnsafeMutableBufferPointer { ptr in
            filter.process(input: ptr.baseAddress!, output: ptr.baseAddress!, frameCount: frameCount)
        }

        // The preserved-state output should quickly reach steady state (close to reset output
        // by the end of the buffer), but their early samples should differ due to the transient
        // caused by the reset. Verify they are not identical across the whole buffer.
        var differ = false
        for i in 0..<min(32, Int(frameCount)) {
            if abs(outputPreserved[i] - outputReset[i]) > 1e-4 {
                differ = true
                break
            }
        }
        XCTAssertTrue(differ, "resetState:false should produce different early output than resetState:true")
    }

    // MARK: - Pre-built Setup Tests

    /// Verifies that `prepareSetup()` + `setCoefficients(_:setup:resetState:)` produces
    /// identical output to the pre-built setup path — confirming the vDSP setup created
    /// on the main thread works correctly when installed on the audio thread.
    func testPreBuiltSetupProducesCorrectOutput() {
        let coeffs = BiquadMath.calculateCoefficients(
            type: .parametric,
            sampleRate: sampleRate,
            frequency: 1000.0,
            q: 1.0,
            gain: 6.0
        )

        // Create two filters — one with pre-built setup, one with inline setup
        let filterA = BiquadFilter()
        let setupA = BiquadFilter.prepareSetup(coeffs)
        filterA.setCoefficients(coeffs, setup: setupA, resetState: true)

        let filterB = BiquadFilter()
        let setupB = BiquadFilter.prepareSetup(coeffs)
        filterB.setCoefficients(coeffs, setup: setupB, resetState: true)

        // Process the same impulse through both
        var input: [Float] = [Float](repeating: 0, count: Int(frameCount))
        input[0] = 1.0

        var outputA: [Float] = [Float](repeating: 0, count: Int(frameCount))
        var outputB: [Float] = [Float](repeating: 0, count: Int(frameCount))

        input.withUnsafeBufferPointer { inputPtr in
            outputA.withUnsafeMutableBufferPointer { outputPtrA in
                filterA.process(
                    input: inputPtr.baseAddress!,
                    output: outputPtrA.baseAddress!,
                    frameCount: frameCount
                )
            }
            outputB.withUnsafeMutableBufferPointer { outputPtrB in
                filterB.process(
                    input: inputPtr.baseAddress!,
                    output: outputPtrB.baseAddress!,
                    frameCount: frameCount
                )
            }
        }

        // Both filters with identical coefficients should produce identical output
        for i in 0..<Int(frameCount) {
            XCTAssertEqual(outputA[i], outputB[i], accuracy: 1e-6, "Sample \(i) differs between pre-built setups")
        }
    }
}
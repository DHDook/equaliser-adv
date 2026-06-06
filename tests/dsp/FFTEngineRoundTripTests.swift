// FFTEngineRoundTripTests.swift
// Tests for FFT round-trip normalization

import XCTest
@testable import Equaliser

final class FFTEngineRoundTripTests: XCTestCase {

    func testFFTRoundTripNormalization() {
        // Generate 1 kHz sine at fftSize samples
        let fftSize: Int = 2048
        let sampleRate: Double = 48000.0
        let frequency: Double = 1000.0
        let amplitude: Float = 1.0

        let fftEngine = FFTEngine(fftSize: fftSize)

        // Generate input sine wave
        var input = [Float](repeating: 0.0, count: fftSize)
        for i in 0..<fftSize {
            let t = Double(i) / sampleRate
            input[i] = Float(sin(2.0 * Double.pi * frequency * t)) * amplitude
        }

        // Perform round-trip FFT
        let fftResult = fftEngine.forwardFFT(input: input)
        let output = fftEngine.inverseFFT(real: fftResult.real, imag: fftResult.imag)

        // Verify round-trip recovery with error < 1e-5 per sample
        var maxError: Float = 0.0
        for i in 0..<fftSize {
            let error = abs(output[i] - input[i])
            maxError = max(maxError, error)
            XCTAssertLessThan(error, 1e-5,
                              "Round-trip error at index \(i) should be < 1e-5, got \(error)")
        }

        print("FFT round-trip max error: \(maxError)")
        XCTAssertLessThan(maxError, 1e-5, "Max round-trip error should be < 1e-5")
    }

    func testFFTRoundTripWithDCInput() {
        // Test with DC input to verify normalization
        let fftSize: Int = 2048
        let fftEngine = FFTEngine(fftSize: fftSize)

        var input = [Float](repeating: 0.5, count: fftSize)

        // Perform round-trip FFT
        let fftResult = fftEngine.forwardFFT(input: input)
        let output = fftEngine.inverseFFT(real: fftResult.real, imag: fftResult.imag)

        // Verify DC passes through with minimal error
        var maxError: Float = 0.0
        for i in 0..<fftSize {
            let error = abs(output[i] - input[i])
            maxError = max(maxError, error)
        }

        print("DC round-trip max error: \(maxError)")
        XCTAssertLessThan(maxError, 1e-5, "DC round-trip error should be < 1e-5")
    }

    func testFFTRoundTripWithRandomNoise() {
        // Test with random noise to verify normalization across spectrum
        let fftSize: Int = 2048
        let fftEngine = FFTEngine(fftSize: fftSize)

        var input = [Float](repeating: 0.0, count: fftSize)
        for i in 0..<fftSize {
            input[i] = Float.random(in: -1...1)
        }

        // Perform round-trip FFT
        let fftResult = fftEngine.forwardFFT(input: input)
        let output = fftEngine.inverseFFT(real: fftResult.real, imag: fftResult.imag)

        // Verify round-trip recovery with error < 1e-5 per sample
        var maxError: Float = 0.0
        for i in 0..<fftSize {
            let error = abs(output[i] - input[i])
            maxError = max(maxError, error)
        }

        print("Random noise round-trip max error: \(maxError)")
        XCTAssertLessThan(maxError, 1e-5, "Random noise round-trip error should be < 1e-5")
    }
}

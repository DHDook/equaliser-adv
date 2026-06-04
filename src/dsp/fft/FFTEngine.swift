// FFTEngine.swift
// FFT engine for linear-phase EQ and room correction

import Foundation
import Accelerate

/// FFT engine using Accelerate framework for efficient frequency-domain processing.
final class FFTEngine {

    // MARK: - Constants

    private let fftSize: Int
    private let halfSize: Int

    // MARK: - State

    /// FFT setup from Accelerate.
    private var fftSetup: FFTSetup

    /// Real input buffer.
    private var realInput: [Float]

    /// Imaginary input buffer.
    private var imagInput: [Float]

    /// Real output buffer.
    private var realOutput: [Float]

    /// Imaginary output buffer.
    private var imagOutput: [Float]

    /// Split complex buffer for Accelerate.
    private var splitComplex: DSPSplitComplex

    // MARK: - Initialization

    init(fftSize: Int) {
        precondition(fftSize > 0 && fftSize & (fftSize - 1) == 0, "FFT size must be power of 2")

        self.fftSize = fftSize
        self.halfSize = fftSize / 2

        // Create FFT setup
        var log2n = vDSP_Length(0)
        var n = 1
        while n < fftSize {
            n *= 2
            log2n += 1
        }

        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // Allocate buffers
        self.realInput = Array(repeating: 0.0, count: fftSize)
        self.imagInput = Array(repeating: 0.0, count: fftSize)
        self.realOutput = Array(repeating: 0.0, count: fftSize)
        self.imagOutput = Array(repeating: 0.0, count: fftSize)

        // Setup split complex
        self.splitComplex = DSPSplitComplex(
            realp: &realOutput,
            imagp: &imagOutput
        )
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - FFT Operations

    /// Performs forward FFT on real input data.
    /// - Parameter input: Real input samples (must be fftSize long)
    /// - Returns: Complex frequency-domain data (real and imaginary parts)
    func forwardFFT(input: [Float]) -> (real: [Float], imag: [Float]) {
        precondition(input.count == fftSize, "Input must be exactly fftSize samples")

        // Copy input to real part
        realInput.withUnsafeMutableBufferPointer { realPtr in
            input.withUnsafeBufferPointer { inputPtr in
                vDSP_vcpy(inputPtr.baseAddress!, 1, realPtr.baseAddress!, 1, vDSP_Length(fftSize))
            }
        }

        // Zero imaginary part
        imagInput.withUnsafeMutableBufferPointer { imagPtr in
            vDSP_vclr(imagPtr.baseAddress!, 1, vDSP_Length(fftSize))
        }

        // Perform FFT
        var splitComplex = DSPSplitComplex(
            realp: &realInput,
            imagp: &imagInput
        )

        var log2n = vDSP_Length(0)
        var n = 1
        while n < fftSize {
            n *= 2
            log2n += 1
        }

        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // Scale by 2 for real FFT
        var scale: Float = 0.5
        vDSP_vsmul(splitComplex.realp, 1, &scale, splitComplex.realp, 1, vDSP_Length(halfSize))
        vDSP_vsmul(splitComplex.imagp, 1, &scale, splitComplex.imagp, 1, vDSP_Length(halfSize))

        return (realInput, imagInput)
    }

    /// Performs inverse FFT on complex frequency-domain data.
    /// - Parameters:
    ///   - real: Real part of frequency data
    ///   - imag: Imaginary part of frequency data
    /// - Returns: Real time-domain samples
    func inverseFFT(real: [Float], imag: [Float]) -> [Float] {
        precondition(real.count == halfSize, "Real part must be halfSize")
        precondition(imag.count == halfSize, "Imag part must be halfSize")

        // Copy to split complex
        var splitComplex = DSPSplitComplex(
            realp: UnsafeMutablePointer<Float>(mutating: real),
            imagp: UnsafeMutablePointer<Float>(mutating: imag)
        )

        var log2n = vDSP_Length(0)
        var n = 1
        while n < fftSize {
            n *= 2
            log2n += 1
        }

        // Perform inverse FFT
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Inverse))

        // Scale by 2 for real FFT
        var scale: Float = 2.0
        vDSP_vsmul(splitComplex.realp, 1, &scale, splitComplex.realp, 1, vDSP_Length(halfSize))
        vDSP_vsmul(splitComplex.imagp, 1, &scale, splitComplex.imagp, 1, vDSP_Length(halfSize))

        // Copy real part to output
        var output = Array(repeating: 0.0, count: fftSize)
        output.withUnsafeMutableBufferPointer { outPtr in
            vDSP_vcpy(splitComplex.realp, 1, outPtr.baseAddress!, 1, vDSP_Length(fftSize))
        }

        return output
    }

    /// Performs convolution in frequency domain using overlap-add method.
    /// - Parameters:
    ///   - signal: Input signal
    ///   - impulse: Impulse response (kernel)
    /// - Returns: Convolved signal
    func convolve(signal: [Float], impulse: [Float]) -> [Float] {
        let signalLen = signal.count
        let impulseLen = impulse.count
        let outputLen = signalLen + impulseLen - 1

        // Zero-pad both to next power of 2
        let paddedSize = nextPowerOfTwo(outputLen)

        var paddedSignal = Array(repeating: 0.0, count: paddedSize)
        var paddedImpulse = Array(repeating: 0.0, count: paddedSize)

        for i in 0..<signalLen {
            paddedSignal[i] = signal[i]
        }
        for i in 0..<impulseLen {
            paddedImpulse[i] = impulse[i]
        }

        // FFT both
        let signalFFT = forwardFFT(input: paddedSignal)
        let impulseFFT = forwardFFT(input: paddedImpulse)

        // Complex multiplication
        var realResult = Array(repeating: 0.0, count: paddedSize / 2)
        var imagResult = Array(repeating: 0.0, count: paddedSize / 2)

        for i in 0..<(paddedSize / 2) {
            let ar = signalFFT.real[i]
            let ai = signalFFT.imag[i]
            let br = impulseFFT.real[i]
            let bi = impulseFFT.imag[i]

            realResult[i] = ar * br - ai * bi
            imagResult[i] = ar * bi + ai * br
        }

        // Inverse FFT
        let result = inverseFFT(real: realResult, imag: imagResult)

        // Trim to output length
        return Array(result[0..<outputLen])
    }

    // MARK: - Helpers

    private func nextPowerOfTwo(_ n: Int) -> Int {
        var v = n
        v -= 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v += 1
        return v
    }
}

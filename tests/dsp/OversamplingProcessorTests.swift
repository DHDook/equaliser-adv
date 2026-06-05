// OversamplingProcessorTests.swift
// Tests for oversampling processor unity gain and numerical stability

import XCTest
@testable import Equaliser

final class OversamplingProcessorTests: XCTestCase {

    func testUnityGainThroughOversamplingChain() {
        // Generate 1 kHz sine at -12 dBFS
        let sampleRate: Double = 48000.0
        let frequency: Double = 1000.0
        let amplitude: Float = pow(10.0, -12.0 / 20.0) // -12 dBFS
        let frameCount: Int = 512

        let oversampler = OversamplingProcessor(maxFrameCount: frameCount)

        // Generate input sine wave
        var inputL = [Float](repeating: 0.0, count: frameCount)
        var inputR = [Float](repeating: 0.0, count: frameCount)

        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let sample = Float(sin(2.0 * Double.pi * frequency * t)) * amplitude
            inputL[i] = sample
            inputR[i] = sample
        }

        // Calculate input RMS
        let inputRMS = sqrt(inputL.map { $0 * $0 }.reduce(0, +) / Float(frameCount))
        let inputDB = 20.0 * log10(inputRMS)

        // Process through oversampling chain
        inputL.withUnsafeMutableBufferPointer { inputPtr in
            inputR.withUnsafeMutableBufferPointer { inputPtrR in
                oversampler.upsample(ablL: inputPtr.baseAddress!,
                                   ablR: inputPtrR.baseAddress!,
                                   frameCount: frameCount)

                // Simulate processing at upsampled rate (passthrough for unity gain test)
                // In real use, this would be the clipper/limiter

                oversampler.downsample(ablL: inputPtr.baseAddress!,
                                      ablR: inputPtrR.baseAddress!,
                                      frameCount: frameCount)
            }
        }

        // Calculate output RMS
        let outputRMS = sqrt(inputL.map { $0 * $0 }.reduce(0, +) / Float(frameCount))
        let outputDB = 20.0 * log10(outputRMS)

        // Verify unity gain within ±0.1 dB
        let levelDifference = abs(outputDB - inputDB)
        XCTAssertLessThan(levelDifference, 0.1,
                          "Oversampling chain level difference should be < 0.1 dB, got \(levelDifference) dB")

        // Verify output is finite
        for sample in inputL {
            XCTAssertTrue(sample.isFinite, "Output should be finite, got \(sample)")
        }
    }

    func testOversamplingNumericalStability() {
        // Test with various input levels including extreme values
        let sampleRate: Double = 48000.0
        let frameCount: Int = 512
        let oversampler = OversamplingProcessor(maxFrameCount: frameCount)

        let testLevels: [Float] = [0.0, 1e-6, 0.001, 0.1, 0.5, 0.9, 1.0]

        for amplitude in testLevels {
            var input = [Float](repeating: amplitude, count: frameCount)

            input.withUnsafeMutableBufferPointer { inputPtr in
                oversampler.upsample(ablL: inputPtr.baseAddress!,
                                   ablR: nil,
                                   frameCount: frameCount)
                oversampler.downsample(ablL: inputPtr.baseAddress!,
                                      ablR: nil,
                                      frameCount: frameCount)
            }

            // Verify all samples are finite
            for (index, sample) in input.enumerated() {
                XCTAssertTrue(sample.isFinite,
                              "Output should be finite for amplitude \(amplitude) at index \(index), got \(sample)")
            }
        }
    }

    func testOversamplingReset() {
        // Test that reset clears state properly
        let frameCount: Int = 512
        let oversampler = OversamplingProcessor(maxFrameCount: frameCount)

        var input = [Float](repeating: 1.0, count: frameCount)

        // Process some audio
        input.withUnsafeMutableBufferPointer { inputPtr in
            oversampler.upsample(ablL: inputPtr.baseAddress!,
                               ablR: nil,
                               frameCount: frameCount)
            oversampler.downsample(ablL: inputPtr.baseAddress!,
                                  ablR: nil,
                                  frameCount: frameCount)
        }

        // Reset
        oversampler.reset()

        // Process silence
        input = [Float](repeating: 0.0, count: frameCount)
        input.withUnsafeMutableBufferPointer { inputPtr in
            oversampler.upsample(ablL: inputPtr.baseAddress!,
                               ablR: nil,
                               frameCount: frameCount)
            oversampler.downsample(ablL: inputPtr.baseAddress!,
                                  ablR: nil,
                                  frameCount: frameCount)
        }

        // Verify output is near zero (state was cleared)
        let maxOutput = input.max()!
        XCTAssertLessThan(maxOutput, 1e-6,
                          "After reset, output should be near zero, got \(maxOutput)")
    }
}

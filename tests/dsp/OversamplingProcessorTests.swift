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

    func testOversamplingWithDCInput() {
        // Test with DC input to verify gain compensation
        let frameCount: Int = 512
        let oversampler = OversamplingProcessor(maxFrameCount: frameCount)

        var inputL = [Float](repeating: 0.5, count: frameCount)
        var inputR = [Float](repeating: 0.5, count: frameCount)

        let inputLevel = inputL[0]

        inputL.withUnsafeMutableBufferPointer { inputPtr in
            inputR.withUnsafeMutableBufferPointer { inputPtrR in
                oversampler.upsample(ablL: inputPtr.baseAddress!,
                                   ablR: inputPtrR.baseAddress!,
                                   frameCount: frameCount)
                oversampler.downsample(ablL: inputPtr.baseAddress!,
                                      ablR: inputPtrR.baseAddress!,
                                      frameCount: frameCount)
            }
        }

        // Skip first few samples to account for filter startup
        let startIndex = 100
        let outputLevel = inputL[startIndex]

        // DC should pass through with minimal attenuation
        let levelDifference = abs(outputLevel - inputLevel)
        XCTAssertLessThan(levelDifference, 0.01,
                          "DC level difference should be < 0.01, got \(levelDifference)")
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

    func testOversampling10SecondSineValidation() {
        // Generate 1 kHz sine at -12 dBFS for 10 seconds
        let sampleRate: Double = 48000.0
        let frequency: Double = 1000.0
        let amplitude: Float = pow(10.0, -12.0 / 20.0) // -12 dBFS
        let duration: Double = 10.0
        let frameCount: Int = Int(sampleRate * duration)

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

        // Calculate input RMS and Peak
        let inputRMS = sqrt(inputL.map { $0 * $0 }.reduce(0, +) / Float(frameCount))
        let inputPeak = inputL.map { abs($0) }.max()!
        let inputRMSDB = 20.0 * log10(inputRMS)
        let inputPeakDB = 20.0 * log10(inputPeak)

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

        // Calculate output RMS and Peak
        let outputRMS = sqrt(inputL.map { $0 * $0 }.reduce(0, +) / Float(frameCount))
        let outputPeak = inputL.map { abs($0) }.max()!
        let outputRMSDB = 20.0 * log10(outputRMS)
        let outputPeakDB = 20.0 * log10(outputPeak)

        // Verify unity gain within ±0.1 dB
        let rmsDifference = abs(outputRMSDB - inputRMSDB)
        let peakDifference = abs(outputPeakDB - inputPeakDB)

        print("Input RMS: \(inputRMSDB) dB, Output RMS: \(outputRMSDB) dB, Difference: \(rmsDifference) dB")
        print("Input Peak: \(inputPeakDB) dB, Output Peak: \(outputPeakDB) dB, Difference: \(peakDifference) dB")

        XCTAssertLessThan(rmsDifference, 0.1,
                          "Oversampling chain RMS level difference should be < 0.1 dB, got \(rmsDifference) dB")
        XCTAssertLessThan(peakDifference, 0.1,
                          "Oversampling chain Peak level difference should be < 0.1 dB, got \(peakDifference) dB")

        // Verify output is finite
        for sample in inputL {
            XCTAssertTrue(sample.isFinite, "Output should be finite, got \(sample)")
        }
    }

    func testOversamplingImpulseResponse() {
        // Test with single impulse to verify unity gain
        let frameCount: Int = 1024
        let oversampler = OversamplingProcessor(maxFrameCount: frameCount)

        var inputL = [Float](repeating: 0.0, count: frameCount)
        var inputR = [Float](repeating: 0.0, count: frameCount)

        // Place impulse at center
        inputL[frameCount / 2] = 1.0
        inputR[frameCount / 2] = 1.0

        let inputPeak = inputL.max()!
        let inputEnergy = inputL.map { $0 * $0 }.reduce(0, +)

        inputL.withUnsafeMutableBufferPointer { inputPtr in
            inputR.withUnsafeMutableBufferPointer { inputPtrR in
                oversampler.upsample(ablL: inputPtr.baseAddress!,
                                   ablR: inputPtrR.baseAddress!,
                                   frameCount: frameCount)
                oversampler.downsample(ablL: inputPtr.baseAddress!,
                                      ablR: inputPtrR.baseAddress!,
                                      frameCount: frameCount)
            }
        }

        // Calculate output peak and energy
        let outputPeak = inputL.map { abs($0) }.max()!
        let outputEnergy = inputL.map { $0 * $0 }.reduce(0, +)

        print("Input Peak: \(inputPeak), Output Peak: \(outputPeak)")
        print("Input Energy: \(inputEnergy), Output Energy: \(outputEnergy)")

        // Peak should be close to 1.0 (unity gain)
        let peakDifference = abs(outputPeak - 1.0)
        XCTAssertLessThan(peakDifference, 0.01,
                          "Impulse peak should be close to 1.0, got \(outputPeak), difference: \(peakDifference)")

        // Energy should be preserved within tolerance
        let energyRatio = outputEnergy / inputEnergy
        XCTAssertGreaterThan(energyRatio, 0.9,
                            "Energy should be preserved, ratio: \(energyRatio)")
        XCTAssertLessThan(energyRatio, 1.1,
                          "Energy should be preserved, ratio: \(energyRatio)")
    }

    func testOversamplingWhiteNoise() {
        // Test with broadband noise
        let frameCount: Int = 48000 // 1 second at 48 kHz
        let oversampler = OversamplingProcessor(maxFrameCount: frameCount)

        var inputL = [Float](repeating: 0.0, count: frameCount)
        var inputR = [Float](repeating: 0.0, count: frameCount)

        // Generate white noise
        for i in 0..<frameCount {
            inputL[i] = Float.random(in: -1...1)
            inputR[i] = Float.random(in: -1...1)
        }

        // Calculate input RMS
        let inputRMS = sqrt(inputL.map { $0 * $0 }.reduce(0, +) / Float(frameCount))
        let inputRMSDB = 20.0 * log10(inputRMS)

        inputL.withUnsafeMutableBufferPointer { inputPtr in
            inputR.withUnsafeMutableBufferPointer { inputPtrR in
                oversampler.upsample(ablL: inputPtr.baseAddress!,
                                   ablR: inputPtrR.baseAddress!,
                                   frameCount: frameCount)
                oversampler.downsample(ablL: inputPtr.baseAddress!,
                                      ablR: inputPtrR.baseAddress!,
                                      frameCount: frameCount)
            }
        }

        // Calculate output RMS
        let outputRMS = sqrt(inputL.map { $0 * $0 }.reduce(0, +) / Float(frameCount))
        let outputRMSDB = 20.0 * log10(outputRMS)

        // Verify unity gain within ±0.1 dB
        let rmsDifference = abs(outputRMSDB - inputRMSDB)

        print("Input RMS: \(inputRMSDB) dB, Output RMS: \(outputRMSDB) dB, Difference: \(rmsDifference) dB")

        XCTAssertLessThan(rmsDifference, 0.1,
                          "Oversampling chain RMS level difference for white noise should be < 0.1 dB, got \(rmsDifference) dB")
    }
}

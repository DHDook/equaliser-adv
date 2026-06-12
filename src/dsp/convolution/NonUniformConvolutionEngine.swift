// NonUniformConvolutionEngine.swift
// Non-uniform partitioned convolution engine (Part 7)
//
// Implements Gardner-style partitioning with growing block sizes for efficient
// long-IR convolution. Partitions double in size at each stage (512, 1024, 2048...).
// This reduces per-block overhead for long IRs while maintaining low latency.

import Foundation
import Accelerate

/// Configuration for non-uniform partitioned convolution.
struct NonUniformConvolutionConfig: Sendable {
    let basePartitionSize: Int  // Base partition size (default 512)
    let maxStages: Int          // Maximum number of stages
}

/// Stage in the non-uniform partitioned convolution.
struct ConvolutionStage: Sendable {
    let blockSize: Int
    let fftSize: Int
    let irFFTReal: [Float]  // Real part of pre-computed FFT of IR segment
    let irFFTImag: [Float] // Imaginary part of pre-computed FFT of IR segment
    var phaseCounter: Int = 0  // Tracks when to process this stage
    var inputBuffer: [Float] = []  // Circular input buffer for this stage
    var outputBuffer: [Float] = []  // Output accumulation buffer
    var inputBufferPos: Int = 0  // Current position in circular buffer
}

/// Non-uniform partitioned convolution engine (Part 7).
/// Uses Gardner-style partitioning with growing block sizes for efficient long-IR convolution.
enum NonUniformConvolutionEngine {

    /// Partitions an IR into non-uniform blocks (Gardner-style).
    /// - Parameters:
    ///   - ir: Impulse response
    ///   - config: Configuration for partitioning
    /// - Returns: Array of convolution stages
    static func partitionIR(_ ir: [Float], config: NonUniformConvolutionConfig) -> [ConvolutionStage] {
        var stages: [ConvolutionStage] = []
        var offset = 0
        var blockSize = config.basePartitionSize

        while offset < ir.count && stages.count < config.maxStages {
            let segmentSize = min(blockSize, ir.count - offset)
            guard segmentSize > 0 else { break }

            let segment = Array(ir[offset..<(offset + segmentSize)])

            // Compute FFT of this segment
            let fftSize = nextPowerOfTwo(segmentSize * 2)  // Zero-pad for convolution
            let fftEngine = FFTEngine(fftSize: fftSize)
            let paddedIR = padToFFTSize(segment, fftSize: fftSize)
            let irFFT = fftEngine.forwardFFT(input: paddedIR)

            // Initialize circular buffers for this stage
            let inputBuffer = Array(repeating: Float(0.0), count: blockSize)
            let outputBuffer = Array(repeating: Float(0.0), count: blockSize)

            let stage = ConvolutionStage(
                blockSize: blockSize,
                fftSize: fftSize,
                irFFTReal: irFFT.real,
                irFFTImag: irFFT.imag,
                phaseCounter: 0,
                inputBuffer: inputBuffer,
                outputBuffer: outputBuffer,
                inputBufferPos: 0
            )

            stages.append(stage)
            offset += segmentSize
            blockSize *= 2  // Double block size for next stage
        }

        return stages
    }

    /// Loads an IR from a file and partitions it for non-uniform convolution.
    /// - Parameters:
    ///   - url: The file URL to load from
    ///   - targetSampleRate: The target sample rate for resampling if needed
    ///   - config: Configuration for partitioning
    /// - Returns: Tuple of (left stages, right stages, display name)
    /// - Throws: An error if the file cannot be loaded or parsed
    static func loadAndPartitionIR(
        url: URL,
        targetSampleRate: Double,
        config: NonUniformConvolutionConfig
    ) throws -> (leftStages: [ConvolutionStage], rightStages: [ConvolutionStage], displayName: String) {
        let loadResult = try IRFileLoader.load(url: url, targetSampleRate: targetSampleRate)

        let leftStages = partitionIR(loadResult.leftSamples, config: config)
        let rightStages = partitionIR(loadResult.rightSamples, config: config)

        return (leftStages, rightStages, loadResult.displayName)
    }

    /// Processes audio through the non-uniform convolution engine.
    /// - Parameters:
    ///   - input: Input audio buffer
    ///   - stages: Convolution stages
    ///   - sampleRate: Sample rate
    /// - Returns: Convolved output buffer
    static func process(
        input: [Float],
        stages: inout [ConvolutionStage],
        sampleRate: Double
    ) -> [Float] {
        var output = Array(repeating: Float(0.0), count: input.count)

        // Process each input sample
        for (i, sample) in input.enumerated() {
            // Feed sample into all stage input buffers
            for stageIndex in 0..<stages.count {
                var stage = stages[stageIndex]
                stage.inputBuffer[stage.inputBufferPos] = sample
                stages[stageIndex] = stage
            }

            // Increment phase counters
            for stageIndex in 0..<stages.count {
                var stage = stages[stageIndex]
                stage.phaseCounter += 1
                stages[stageIndex] = stage
            }

            // Check if any stage needs processing (phase counter reached block size)
            for stageIndex in 0..<stages.count {
                var stage = stages[stageIndex]
                if stage.phaseCounter >= stage.blockSize {
                    // Time to process this stage
                    stage.phaseCounter = 0

                    // Extract block from circular buffer
                    var block = Array(repeating: Float(0.0), count: stage.blockSize)
                    for j in 0..<stage.blockSize {
                        let pos = (stage.inputBufferPos - j + stage.blockSize) % stage.blockSize
                        block[stage.blockSize - 1 - j] = stage.inputBuffer[pos]
                    }

                    // Zero-pad to FFT size
                    let paddedBlock = padToFFTSize(block, fftSize: stage.fftSize)

                    // Compute FFT of input block
                    let fftEngine = FFTEngine(fftSize: stage.fftSize)
                    let inputFFT = fftEngine.forwardFFT(input: paddedBlock)

                    // Complex multiplication in frequency domain
                    var outputReal = Array(repeating: Float(0.0), count: stage.fftSize / 2)
                    var outputImag = Array(repeating: Float(0.0), count: stage.fftSize / 2)

                    for j in 0..<(stage.fftSize / 2) {
                        let ar = inputFFT.real[j]
                        let ai = inputFFT.imag[j]
                        let br = stage.irFFTReal[j]
                        let bi = stage.irFFTImag[j]

                        outputReal[j] = ar * br - ai * bi
                        outputImag[j] = ar * bi + ai * br
                    }

                    // Inverse FFT to get time-domain output
                    let timeOutput = fftEngine.inverseFFT(real: outputReal, imag: outputImag)

                    // Add to output buffer (overlap-add)
                    for j in 0..<stage.blockSize {
                        stage.outputBuffer[j] += timeOutput[j]
                    }

                    stages[stageIndex] = stage
                }
            }

            // Sum outputs from all stages and advance buffer positions
            var sampleOutput: Float = 0.0
            for stageIndex in 0..<stages.count {
                var stage = stages[stageIndex]
                sampleOutput += stage.outputBuffer[stage.inputBufferPos]
                stage.outputBuffer[stage.inputBufferPos] = 0.0  // Clear after reading
                stages[stageIndex] = stage
            }

            output[i] = sampleOutput

            // Advance buffer positions
            for stageIndex in 0..<stages.count {
                var stage = stages[stageIndex]
                stage.inputBufferPos = (stage.inputBufferPos + 1) % stage.blockSize
                stages[stageIndex] = stage
            }
        }

        return output
    }

    /// Estimates the algorithmic latency of the non-uniform engine.
    /// - Parameter basePartitionSize: Base partition size
    /// - Returns: Latency in samples (always equal to basePartitionSize)
    static func estimateLatency(basePartitionSize: Int) -> Int {
        // Algorithmic latency is always the smallest partition size
        return basePartitionSize
    }

    /// Finds the next power of two >= n.
    private static func nextPowerOfTwo(_ n: Int) -> Int {
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

    /// Pads an array to the specified FFT size.
    private static func padToFFTSize(_ array: [Float], fftSize: Int) -> [Float] {
        var result = Array(repeating: Float(0.0), count: fftSize)
        for (i, value) in array.enumerated() {
            if i < fftSize {
                result[i] = value
            }
        }
        return result
    }
}

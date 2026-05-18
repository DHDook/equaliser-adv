import Atomics
import XCTest
@testable import Equaliser

final class EQChainConcurrencyTests: XCTestCase {

    // MARK: - Test Constants

    let sampleRate: Double = 48000.0
    let frameCount: UInt32 = 512
    let maxFrameCount: UInt32 = 4096

    // MARK: - Lock-Free Update Path Test

    /// Verifies that the lock-free coefficient update path works correctly when
    /// staging and applying happen on different threads. Matches the real-world
    /// pattern: main thread stages, audio thread applies and processes.
    ///
    /// Uses a semaphore to ensure staging and applying are interleaved correctly
    /// (staging completes before applying reads), which matches the real app's
    /// main-thread-serial execution model.
    func testLockFreeCoefficientUpdatePath() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        // Pre-compute coefficient sets
        let coefficients: [BiquadCoefficients] = (0..<10).map { i in
            BiquadMath.calculateCoefficients(
                type: .parametric,
                sampleRate: sampleRate,
                frequency: 100.0 + Double(i) * 100.0,
                q: 1.0,
                gain: Double(i) * 2.0 - 10.0
            )
        }

        // Set up initial state
        var initialCoeffs = [BiquadCoefficients](repeating: .identity, count: EQChain.maxBandCount)
        initialCoeffs[0] = coefficients[0]
        chain.stageFullUpdate(
            coefficients: initialCoeffs,
            bypassFlags: [Bool](repeating: false, count: EQChain.maxBandCount),
            activeBandCount: 10,
            layerBypass: false
        )
        chain.applyPendingUpdates()

        let iterations = 5_000
        let stagingSemaphore = DispatchSemaphore(value: 0)
        let processingSemaphore = DispatchSemaphore(value: 0)
        let stagingDone = XCTestExpectation(description: "Staging complete")
        let processingDone = XCTestExpectation(description: "Processing complete")

        // Thread A: Stage coefficient updates (simulates main thread — serial)
        DispatchQueue.global(qos: .userInteractive).async {
            for i in 0..<iterations {
                // Wait for previous processing to complete
                stagingSemaphore.wait()

                let coeffIndex = i % coefficients.count
                let bandIndex = i % 10
                chain.stageBandUpdate(
                    index: bandIndex,
                    coefficients: coefficients[coeffIndex],
                    bypass: i % 7 == 0
                )

                // Periodically stage full updates (simulates preset loads)
                if i % 100 == 0 {
                    var fullCoeffs = [BiquadCoefficients](repeating: .identity, count: EQChain.maxBandCount)
                    for j in 0..<10 {
                        fullCoeffs[j] = coefficients[j % coefficients.count]
                    }
                    chain.stageFullUpdate(
                        coefficients: fullCoeffs,
                        bypassFlags: [Bool](repeating: false, count: EQChain.maxBandCount),
                        activeBandCount: 10,
                        layerBypass: i % 5 == 0
                    )
                }

                // Signal Thread B to process
                processingSemaphore.signal()
            }
            stagingDone.fulfill()
        }

        // Thread B: Apply updates and process (simulates audio thread — serial)
        DispatchQueue.global(qos: .userInteractive).async {
            var buffer: [Float] = [Float](repeating: 0.5, count: Int(self.frameCount))
            for i in 0..<iterations {
                // Wait for staging to complete
                processingSemaphore.wait()

                buffer.withUnsafeMutableBufferPointer { bufPtr in
                    chain.applyPendingUpdates()
                    chain.process(buffer: bufPtr.baseAddress!, frameCount: self.frameCount)
                }

                // Verify output is finite
                for sample in buffer.prefix(10) {
                    XCTAssertTrue(sample.isFinite,
                        "Non-finite sample at iteration \(i): \(sample)")
                }

                // Signal Thread A to stage next update
                stagingSemaphore.signal()

                // Reset buffer
                for j in 0..<Int(self.frameCount) {
                    buffer[j] = 0.5
                }
            }
            processingDone.fulfill()
        }

        // Kick off the first staging
        stagingSemaphore.signal()

        wait(for: [stagingDone, processingDone], timeout: 120.0)
    }

    // MARK: - Rapid Staging Without Applying

    /// Verifies that staging multiple updates before applying is safe.
    /// This simulates the user rapidly adjusting multiple bands before the
    /// next audio render cycle applies them.
    func testRapidStagingThenApply() {
        let chain = EQChain(maxFrameCount: maxFrameCount)

        let coefficients: [BiquadCoefficients] = (0..<10).map { i in
            BiquadMath.calculateCoefficients(
                type: .parametric,
                sampleRate: sampleRate,
                frequency: 200.0 + Double(i) * 200.0,
                q: 1.0,
                gain: Double(i) - 5.0
            )
        }

        // Set up initial state
        var initialCoeffs = [BiquadCoefficients](repeating: .identity, count: EQChain.maxBandCount)
        chain.stageFullUpdate(
            coefficients: initialCoeffs,
            bypassFlags: [Bool](repeating: false, count: EQChain.maxBandCount),
            activeBandCount: 10,
            layerBypass: false
        )
        chain.applyPendingUpdates()

        // Stage many updates rapidly (simulates rapid slider drags)
        for i in 0..<1000 {
            let bandIndex = i % 10
            chain.stageBandUpdate(
                index: bandIndex,
                coefficients: coefficients[bandIndex],
                bypass: false
            )
        }

        // Apply once (simulates next audio render cycle)
        chain.applyPendingUpdates()

        // Process and verify output is valid
        var buffer = [Float](repeating: 0.5, count: Int(frameCount))
        buffer.withUnsafeMutableBufferPointer { bufPtr in
            chain.process(buffer: bufPtr.baseAddress!, frameCount: frameCount)
        }

        for sample in buffer.prefix(10) {
            XCTAssertTrue(sample.isFinite, "Non-finite sample after rapid staging: \(sample)")
        }
    }
}
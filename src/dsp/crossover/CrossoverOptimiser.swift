// CrossoverOptimiser.swift
//
// Iterative crossover and per-output EQ optimisation against measured driver responses.
// Minimises deviation of predicted acoustic summation from a target curve using
// gradient-free iterative descent.

import Accelerate
import Foundation

enum CrossoverOptimiser {

    struct OptimisationParameters: Sendable {
        /// Which parameters the optimiser may adjust.
        var optimiseCrossoverFrequencies: Bool = true
        var optimiseCrossoverSlopes: Bool = false      // Slope changes are large steps; off by default
        var optimisePerOutputEQ: Bool = true
        var optimiseDelay: Bool = false                // Handled by Task V; off by default here

        /// Frequency range over which to minimise error (Hz).
        var optimisationRangeHz: (low: Double, high: Double) = (20.0, 20000.0)

        /// Target curve to optimise toward.
        var targetCurve: [(frequency: Double, gainDB: Double)] = TargetCurveLibrary.harmanRoom

        /// Maximum number of optimisation iterations. Default: 200.
        var maxIterations: Int = 200

        /// Convergence threshold: stop when total weighted RMS error
        /// changes by less than this amount between iterations (dB). Default: 0.05 dB.
        var convergenceThresholdDB: Double = 0.05

        /// Maximum crossover frequency adjustment per step (Hz). Default: 50 Hz.
        var maxCrossoverFrequencyStepHz: Float = 50.0

        /// Maximum per-output EQ adjustment per band per step (dB). Default: 1.0 dB.
        var maxEQStepDB: Float = 1.0

        /// Maximum total per-output EQ correction (dB). Prevents over-correction.
        var maxTotalEQCorrectionDB: Float = 12.0

        /// Smoothing octaves applied to residual before computing EQ corrections.
        var smoothingOctaves: Double = 1.0 / 3.0
    }

    struct OptimisationResult: Sendable {
        /// Suggested crossover configuration after optimisation.
        var suggestedCrossoverConfig: ActiveCrossoverConfig
        /// Suggested per-output EQ adjustments (delta from current config).
        var suggestedEQAdjustments: [Int: [EQBandConfiguration]]
        /// Predicted residual RMS error after optimisation (dB).
        var residualRMSErrorDB: Double
        /// Initial residual RMS error before optimisation (dB).
        var initialRMSErrorDB: Double
        /// Number of iterations taken.
        var iterationCount: Int
        /// Whether optimisation converged within maxIterations.
        var converged: Bool
        /// Predicted summation response after suggested adjustments.
        var predictedSummationDB: [(frequency: Double, gainDB: Double)]
    }

    /// Runs the optimisation.
    ///
    /// Algorithm (gradient-free iterative descent):
    ///
    ///   1. Compute initial predicted summation using AcousticSummationEngine
    ///      with measured driver responses and current crossover/EQ settings.
    ///   2. Compute residual = predictedSummation − targetCurve at each frequency.
    ///   3. Apply 1/3-octave smoothing to residual.
    ///   4. For each parameter that is enabled for optimisation:
    ///      a. Crossover frequency: if residual shows consistent sign across
    ///         the crossover transition region (indicating the crossover is
    ///         too high or too low), nudge the frequency by ±maxFrequencyStepHz.
    ///      b. Per-output EQ: compute the negative of the smoothed residual
    ///         as a correction curve, fit parametric EQ bands (using
    ///         RoomCorrectionEngine.fitBands), apply as delta to current EQ.
    ///   5. Recompute predicted summation with updated parameters.
    ///   6. If RMS error < convergenceThreshold or iteration > maxIterations, stop.
    ///   7. Otherwise, go to step 2.
    ///
    /// The optimiser operates on a COPY of the current parameters and returns
    /// suggestions. It does NOT modify live DSP state. The user reviews and
    /// applies the suggestions explicitly.
    ///
    /// - Parameters:
    ///   - measurements: Per-driver measured transfer functions (from TransferFunctionDataset).
    ///   - currentCrossoverConfig: Starting point for optimisation.
    ///   - currentEQConfigs: Current per-output EQ configurations, keyed by channel index.
    ///   - params: Optimisation parameters.
    ///   - sampleRate: System sample rate.
    ///   - progressHandler: Called after each iteration with (iteration, currentRMSError).
    ///     Return false to cancel optimisation.
    static func optimise(
        measurements: [Int: ChannelTransferFunctionData],
        currentCrossoverConfig: ActiveCrossoverConfig,
        currentEQConfigs: [Int: OutputChannelEQConfig],
        params: OptimisationParameters,
        sampleRate: Double,
        progressHandler: @escaping (Int, Double) -> Bool
    ) async -> OptimisationResult {
        var crossoverConfig = currentCrossoverConfig
        var eqConfigs = currentEQConfigs

        // Generate frequency points for analysis
        let frequencies = generateLogFrequencies(
            low: params.optimisationRangeHz.low,
            high: params.optimisationRangeHz.high,
            pointsPerOctave: 12
        )

        // Step 1: Compute initial predicted summation
        let initialSummation = computePredictedSummation(
            measurements: measurements,
            crossoverConfig: crossoverConfig,
            eqConfigs: eqConfigs,
            frequencies: frequencies,
            sampleRate: sampleRate
        )

        let initialRMSError = computeRMSError(
            predicted: initialSummation,
            target: params.targetCurve,
            frequencies: frequencies
        )

        var currentRMSError = initialRMSError
        var iteration = 0
        var converged = false

        while iteration < params.maxIterations {
            // Check cancellation
            let shouldContinue = progressHandler(iteration, currentRMSError)
            if !shouldContinue {
                break
            }

            // Step 2: Compute residual
            let currentSummation = computePredictedSummation(
                measurements: measurements,
                crossoverConfig: crossoverConfig,
                eqConfigs: eqConfigs,
                frequencies: frequencies,
                sampleRate: sampleRate
            )

            let residual = computeResidual(
                predicted: currentSummation,
                target: params.targetCurve,
                frequencies: frequencies
            )

            // Step 3: Apply smoothing
            let smoothedResidual = RoomCorrectionEngine.applyOctaveSmoothing(
                response: residual,
                octaves: params.smoothingOctaves
            )

            // Step 4: Adjust parameters
            if params.optimiseCrossoverFrequencies {
                adjustCrossoverFrequencies(
                    crossoverConfig: &crossoverConfig,
                    residual: smoothedResidual,
                    frequencies: frequencies,
                    maxStepHz: params.maxCrossoverFrequencyStepHz
                )
            }

            if params.optimisePerOutputEQ {
                adjustPerOutputEQ(
                    eqConfigs: &eqConfigs,
                    residual: smoothedResidual,
                    frequencies: frequencies,
                    sampleRate: sampleRate,
                    maxStepDB: params.maxEQStepDB,
                    maxTotalCorrectionDB: params.maxTotalEQCorrectionDB
                )
            }

            // Step 5: Recompute error
            let newSummation = computePredictedSummation(
                measurements: measurements,
                crossoverConfig: crossoverConfig,
                eqConfigs: eqConfigs,
                frequencies: frequencies,
                sampleRate: sampleRate
            )

            let newRMSError = computeRMSError(
                predicted: newSummation,
                target: params.targetCurve,
                frequencies: frequencies
            )

            // Step 6: Check convergence
            let errorChange = abs(newRMSError - currentRMSError)
            if errorChange < params.convergenceThresholdDB {
                converged = true
                break
            }

            currentRMSError = newRMSError
            iteration += 1

            // Small delay to allow UI updates
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }

        // Compute final predicted summation
        let finalSummation = computePredictedSummation(
            measurements: measurements,
            crossoverConfig: crossoverConfig,
            eqConfigs: eqConfigs,
            frequencies: frequencies,
            sampleRate: sampleRate
        )

        // Compute EQ adjustments (delta from original)
        var eqAdjustments: [Int: [EQBandConfiguration]] = [:]
        for (channelIndex, newConfig) in eqConfigs {
            if let originalConfig = currentEQConfigs[channelIndex] {
                // Compute delta by comparing bands
                var adjustments: [EQBandConfiguration] = []
                for (newBand, originalBand) in zip(newConfig.bands, originalConfig.bands) {
                    let deltaGain = newBand.gain - originalBand.gain
                    if abs(deltaGain) > 0.1 {
                        var adjustedBand = newBand
                        adjustedBand.gain = deltaGain  // Store only the delta
                        adjustments.append(adjustedBand)
                    }
                }
                if !adjustments.isEmpty {
                    eqAdjustments[channelIndex] = adjustments
                }
            }
        }

        return OptimisationResult(
            suggestedCrossoverConfig: crossoverConfig,
            suggestedEQAdjustments: eqAdjustments,
            residualRMSErrorDB: currentRMSError,
            initialRMSErrorDB: initialRMSError,
            iterationCount: iteration,
            converged: converged,
            predictedSummationDB: finalSummation
        )
    }

    // MARK: - Helper Functions

    private static func generateLogFrequencies(
        low: Double,
        high: Double,
        pointsPerOctave: Int
    ) -> [Double] {
        var frequencies: [Double] = []
        let octaveCount = log2(high / low)
        let totalPoints = Int(octaveCount * Double(pointsPerOctave)) + 1

        for i in 0..<totalPoints {
            let f = low * pow(2.0, Double(i) / Double(pointsPerOctave))
            frequencies.append(f)
        }

        return frequencies
    }

    private static func computePredictedSummation(
        measurements: [Int: ChannelTransferFunctionData],
        crossoverConfig: ActiveCrossoverConfig,
        eqConfigs: [Int: OutputChannelEQConfig],
        frequencies: [Double],
        sampleRate: Double
    ) -> [(frequency: Double, gainDB: Double)] {
        // Build channel responses from measurements
        var channelResponses: [AcousticSummationEngine.ChannelResponse] = []

        for (channelIndex, data) in measurements {
            guard let ir = data.averagedIR else { continue }

            // Compute complex response from IR
            let complexResponse = computeComplexResponseFromIR(ir, frequencies: frequencies, sampleRate: sampleRate)

            // Apply crossover filter (simplified - would use actual crossover sections in production)
            // For now, pass through
            let crossoverResponse = complexResponse

            // Apply EQ (simplified)
            let eqConfig = eqConfigs[channelIndex]
            let eqResponse = applyEQToResponse(
                response: crossoverResponse,
                eqConfig: eqConfig,
                frequencies: frequencies,
                sampleRate: sampleRate
            )

            let channelResponse = AcousticSummationEngine.ChannelResponse(
                channelIndex: channelIndex,
                channelLabel: data.channelLabel,
                complexResponse: eqResponse,
                delaySamples: 0.0  // Would use actual delay from config
            )

            channelResponses.append(channelResponse)
        }

        // Compute summation
        let (magnitudeDB, _) = AcousticSummationEngine.computeSummation(
            channels: channelResponses,
            frequencies: frequencies,
            sampleRate: sampleRate
        )

        return zip(frequencies, magnitudeDB).map { (frequency: $0, gainDB: $1) }
    }

    private static func computeComplexResponseFromIR(
        _ ir: [Float],
        frequencies: [Double],
        sampleRate: Double
    ) -> [(frequency: Double, real: Double, imag: Double)] {
        // Simplified FFT-based complex response computation
        let N = ir.count
        let half = N / 2 + 1

        let log2n = vDSP_Length(log2(Double(N)).rounded())
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return frequencies.map { (frequency: $0, real: 1.0, imag: 0.0) }
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realBuf = ir.map { Double($0) }
        var imagBuf = [Double](repeating: 0, count: N)

        realBuf.withUnsafeMutableBufferPointer { rp in
            imagBuf.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))
            }
        }

        var result: [(frequency: Double, real: Double, imag: Double)] = []
        for f in frequencies {
            let bin = Int(f * Double(N) / sampleRate)
            guard bin < half else {
                result.append((frequency: f, real: 1.0, imag: 0.0))
                continue
            }
            result.append((frequency: f, real: realBuf[bin], imag: imagBuf[bin]))
        }

        return result
    }

    private static func applyEQToResponse(
        response: [(frequency: Double, real: Double, imag: Double)],
        eqConfig: OutputChannelEQConfig?,
        frequencies: [Double],
        sampleRate: Double
    ) -> [(frequency: Double, real: Double, imag: Double)] {
        guard let eqConfig = eqConfig else { return response }

        var result: [(frequency: Double, real: Double, imag: Double)] = []

        for (idx, f) in frequencies.enumerated() {
            var real = response[idx].real
            var imag = response[idx].imag

            // Apply each EQ band
            for band in eqConfig.bands {
                guard !band.bypass else { continue }
                let coeffs = BiquadMath.calculateCoefficients(
                    type: band.filterType,
                    sampleRate: sampleRate,
                    frequency: Double(band.frequency),
                    q: Double(band.q),
                    gain: Double(band.gain)
                )

                let omega = 2.0 * Double.pi * f / sampleRate
                let cosW = cos(omega)
                let cos2W = cos(2.0 * omega)
                let sinW = sin(omega)
                let sin2W = sin(2.0 * omega)

                let numReal = coeffs.b0 + coeffs.b1 * cosW + coeffs.b2 * cos2W
                let numImag = coeffs.b1 * sinW + coeffs.b2 * sin2W
                let denReal = 1.0 + coeffs.a1 * cosW + coeffs.a2 * cos2W
                let denImag = coeffs.a1 * sinW + coeffs.a2 * sin2W

                let denMag = denReal * denReal + denImag * denImag
                guard denMag > 1e-30 else { continue }

                let eqReal = (numReal * denReal + numImag * denImag) / denMag
                let eqImag = (numImag * denReal - numReal * denImag) / denMag

                // Complex multiplication
                let newReal = real * eqReal - imag * eqImag
                let newImag = real * eqImag + imag * eqReal
                real = newReal
                imag = newImag
            }

            result.append((frequency: f, real: real, imag: imag))
        }

        return result
    }

    private static func computeResidual(
        predicted: [(frequency: Double, gainDB: Double)],
        target: [(frequency: Double, gainDB: Double)],
        frequencies: [Double]
    ) -> [(frequency: Double, gainDB: Double)] {
        var residual: [(frequency: Double, gainDB: Double)] = []

        for (idx, f) in frequencies.enumerated() {
            let predGain = predicted[idx].gainDB
            let targetGain = interpolateTarget(target, at: f)
            residual.append((frequency: f, gainDB: predGain - targetGain))
        }

        return residual
    }

    private static func interpolateTarget(
        _ target: [(frequency: Double, gainDB: Double)],
        at frequency: Double
    ) -> Double {
        guard !target.isEmpty else { return 0.0 }

        if target.count == 1 {
            return target[0].gainDB
        }

        for i in 0..<(target.count - 1) {
            if frequency >= target[i].frequency && frequency <= target[i + 1].frequency {
                let f0 = target[i].frequency
                let f1 = target[i + 1].frequency
                let t = (frequency - f0) / (f1 - f0)
                return target[i].gainDB + t * (target[i + 1].gainDB - target[i].gainDB)
            }
        }

        if frequency < target[0].frequency {
            return target[0].gainDB
        } else {
            return target[target.count - 1].gainDB
        }
    }

    private static func computeRMSError(
        predicted: [(frequency: Double, gainDB: Double)],
        target: [(frequency: Double, gainDB: Double)],
        frequencies: [Double]
    ) -> Double {
        var sumSquared: Double = 0

        for (idx, f) in frequencies.enumerated() {
            let predGain = predicted[idx].gainDB
            let targetGain = interpolateTarget(target, at: f)
            let error = predGain - targetGain
            sumSquared += error * error
        }

        return sqrt(sumSquared / Double(frequencies.count))
    }

    private static func adjustCrossoverFrequencies(
        crossoverConfig: inout ActiveCrossoverConfig,
        residual: [(frequency: Double, gainDB: Double)],
        frequencies: [Double],
        maxStepHz: Float
    ) {
        // Check residual sign around lower crossover
        let lowerFreq = Double(crossoverConfig.lowerPoint.lpHz)
        let residualAtLower = interpolateResidual(residual, at: lowerFreq * 0.8)
        let residualAtUpper = interpolateResidual(residual, at: lowerFreq * 1.2)

        // If residual is consistently positive, crossover is too high (reduce frequency)
        // If consistently negative, crossover is too low (increase frequency)
        if residualAtLower > 0.5 && residualAtUpper > 0.5 {
            crossoverConfig.lowerPoint.lpHz = max(20.0, crossoverConfig.lowerPoint.lpHz - maxStepHz)
            if !crossoverConfig.lowerPoint.asymmetricFrequency {
                crossoverConfig.lowerPoint.hpHz = crossoverConfig.lowerPoint.lpHz
            }
        } else if residualAtLower < -0.5 && residualAtUpper < -0.5 {
            crossoverConfig.lowerPoint.lpHz = min(20000.0, crossoverConfig.lowerPoint.lpHz + maxStepHz)
            if !crossoverConfig.lowerPoint.asymmetricFrequency {
                crossoverConfig.lowerPoint.hpHz = crossoverConfig.lowerPoint.lpHz
            }
        }

        // Similar logic for upper crossover in tri-amp mode
        if crossoverConfig.bandCount == .triAmp {
            let upperFreq = Double(crossoverConfig.upperPoint.lpHz)
            let residualAtLowerUpper = interpolateResidual(residual, at: upperFreq * 0.8)
            let residualAtUpperUpper = interpolateResidual(residual, at: upperFreq * 1.2)

            if residualAtLowerUpper > 0.5 && residualAtUpperUpper > 0.5 {
                crossoverConfig.upperPoint.lpHz = max(20.0, crossoverConfig.upperPoint.lpHz - maxStepHz)
                if !crossoverConfig.upperPoint.asymmetricFrequency {
                    crossoverConfig.upperPoint.hpHz = crossoverConfig.upperPoint.lpHz
                }
            } else if residualAtLowerUpper < -0.5 && residualAtUpperUpper < -0.5 {
                crossoverConfig.upperPoint.lpHz = min(20000.0, crossoverConfig.upperPoint.lpHz + maxStepHz)
                if !crossoverConfig.upperPoint.asymmetricFrequency {
                    crossoverConfig.upperPoint.hpHz = crossoverConfig.upperPoint.lpHz
                }
            }
        }
    }

    private static func interpolateResidual(
        _ residual: [(frequency: Double, gainDB: Double)],
        at frequency: Double
    ) -> Double {
        guard !residual.isEmpty else { return 0.0 }

        if residual.count == 1 {
            return residual[0].gainDB
        }

        for i in 0..<(residual.count - 1) {
            if frequency >= residual[i].frequency && frequency <= residual[i + 1].frequency {
                let f0 = residual[i].frequency
                let f1 = residual[i + 1].frequency
                let t = (frequency - f0) / (f1 - f0)
                return residual[i].gainDB + t * (residual[i + 1].gainDB - residual[i].gainDB)
            }
        }

        if frequency < residual[0].frequency {
            return residual[0].gainDB
        } else {
            return residual[residual.count - 1].gainDB
        }
    }

    private static func adjustPerOutputEQ(
        eqConfigs: inout [Int: OutputChannelEQConfig],
        residual: [(frequency: Double, gainDB: Double)],
        frequencies: [Double],
        sampleRate: Double,
        maxStepDB: Float,
        maxTotalCorrectionDB: Float
    ) {
        // Compute correction curve (negative of residual)
        let correction = residual.map { (frequency: $0.frequency, gainDB: -$0.gainDB) }

        // Fit EQ bands to correction curve
        let fittedBands = RoomCorrectionEngine.fitBands(
            measured: correction,
            target: Array(repeating: (frequency: 0.0, gainDB: 0.0), count: correction.count),
            sampleRate: sampleRate,
            maxBands: 20
        )

        // Apply corrections with step limiting
        for (channelIndex, var eqConfig) in eqConfigs {
            var totalCorrection: Float = 0

            for (idx, _) in eqConfig.bands.enumerated() {
                if idx < fittedBands.count {
                    let correctionGain = fittedBands[idx].gain
                    let clampedCorrection = max(-maxStepDB, min(maxStepDB, correctionGain))

                    // Check total correction limit
                    if abs(totalCorrection + clampedCorrection) <= maxTotalCorrectionDB {
                        eqConfig.bands[idx].gain += clampedCorrection
                        totalCorrection += clampedCorrection
                    }
                }
            }

            eqConfigs[channelIndex] = eqConfig
        }
    }
}

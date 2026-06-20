// DeviceClockPLL.swift
// Software Phase-Locked Loop for multi-device clock synchronisation.
// Measures drift between a secondary HAL device clock and the primary clock,
// and applies a fractional rate correction via SRCProcessor.

import CoreAudio
import Foundation
import Atomics

/// One PLL instance per secondary device.
/// All audio-thread-accessible state is nonisolated(unsafe) with atomic guards.
final class DeviceClockPLL: Sendable {

    // MARK: - Configuration

    struct Config {
        /// PLL loop bandwidth in Hz. Lower = more stable, slower lock. Default: 0.5 Hz.
        var bandwidthHz: Double = 0.5
        /// Damping factor. 0.707 = critically damped. Range: 0.5–2.0.
        var damping: Double = 0.707
        /// Maximum drift correction in parts-per-million. Default: 200 ppm.
        var maxCorrectionPPM: Double = 200.0
        /// Number of callbacks to average before PLL engages. Prevents false lock on startup.
        var lockInCallbacks: Int = 20
    }

    // MARK: - State (audio-thread-read, main-thread-write for config only)

    /// Computed correction factor applied to SRC rate. 1.0 = no correction.
    /// Read by PLLSRCWriter on the secondary device's render thread.
    nonisolated(unsafe) var correctionFactor: Double = 1.0

    /// Whether the PLL has acquired lock. Read-only for UI display.
    nonisolated(unsafe) var isLocked: Bool = false

    /// Current drift estimate in ppm. Read-only for UI display.
    nonisolated(unsafe) var measuredDriftPPM: Double = 0.0

    // MARK: - Private PLL State (audio thread only)

    // Timestamp ring buffer: stores (primaryHostTime, secondaryHostTime) pairs
    // from consecutive callbacks. Used to compute drift rate.
    nonisolated(unsafe) private var timestampPairs: [(primary: UInt64, secondary: UInt64)]
    nonisolated(unsafe) private var timestampWritePos: Int = 0
    private let timestampBufSize = 64

    // Loop filter state
    nonisolated(unsafe) private var phaseError:     Double = 0   // samples
    nonisolated(unsafe) private var integrator:     Double = 0   // accumulated phase error
    nonisolated(unsafe) private var callbackCount:  Int    = 0

    // PLL coefficients (computed from Config on main thread, read on audio thread)
    nonisolated(unsafe) private var kP: Double = 0   // proportional gain
    nonisolated(unsafe) private var kI: Double = 0   // integral gain
    private let hasNewConfig = ManagedAtomic<Bool>(false)
    nonisolated(unsafe) private var pendingKP: Double = 0
    nonisolated(unsafe) private var pendingKI: Double = 0

    let deviceUID: String
    private let nominalSampleRate: Double

    // MARK: - Init

    init(deviceUID: String, nominalSampleRate: Double, config: Config = Config()) {
        self.deviceUID         = deviceUID
        self.nominalSampleRate = nominalSampleRate
        self.timestampPairs    = Array(repeating: (0, 0), count: timestampBufSize)
        applyConfig(config, sampleRate: nominalSampleRate)
    }

    // MARK: - Main Thread API

    func applyConfig(_ config: Config, sampleRate: Double) {
        // Second-order digital PLL coefficient derivation.
        // ωn = 2π × bandwidthHz / sampleRate (normalised to update rate ≈ callbackRate)
        // For update rate ≈ sampleRate / frameCount ≈ 46 Hz at 48kHz/1024:
        let updateRateHz = sampleRate / 1024.0   // approximate; actual varies
        let wn = 2.0 * Double.pi * config.bandwidthHz / updateRateHz
        // kP = 2 × damping × ωn
        // kI = ωn²
        pendingKP = 2.0 * config.damping * wn
        pendingKI = wn * wn
        hasNewConfig.store(true, ordering: .releasing)
    }

    // MARK: - Audio Thread API

    /// Called from the PRIMARY device's render callback once per callback.
    /// Records the primary device's host time for drift measurement.
    @inline(__always)
    func recordPrimaryTimestamp(_ hostTime: UInt64) {
        timestampPairs[timestampWritePos].primary = hostTime
    }

    /// Called from the SECONDARY device's render callback once per callback.
    /// Records the secondary device's host time, computes drift, updates correction.
    @inline(__always)
    func recordSecondaryTimestamp(_ hostTime: UInt64, frameCount: Int) {
        // Apply pending config
        if hasNewConfig.exchange(false, ordering: .acquiringAndReleasing) {
            kP = pendingKP; kI = pendingKI
        }

        timestampPairs[timestampWritePos].secondary = hostTime
        timestampWritePos = (timestampWritePos + 1) % timestampBufSize
        callbackCount += 1

        guard callbackCount >= 20 else { return }  // wait for lock-in period

        // Compute drift rate from recent timestamp pairs.
        // Drift = (secondary interval - primary interval) / primary interval.
        // Use oldest and newest pairs for maximum averaging window.
        let oldIdx = timestampWritePos  // oldest (ring buffer wraps)
        let newIdx = (timestampWritePos + timestampBufSize - 1) % timestampBufSize

        let oldPair = timestampPairs[oldIdx]
        let newPair = timestampPairs[newIdx]

        // Convert host time to nanoseconds using mach_timebase_info
        // (factor stored at init; not recomputed on audio thread)
        let primaryInterval   = Double(newPair.primary   - oldPair.primary)   * hostTimeToNanos
        let secondaryInterval = Double(newPair.secondary - oldPair.secondary) * hostTimeToNanos

        guard primaryInterval > 0 else { return }

        let driftRatio = (secondaryInterval - primaryInterval) / primaryInterval
        measuredDriftPPM = driftRatio * 1_000_000.0

        // Phase error: how many samples the secondary is ahead/behind.
        // Positive = secondary is running fast (ahead of primary).
        phaseError = driftRatio * Double(frameCount)

        // Second-order loop filter: proportional + integral
        integrator += kI * phaseError
        let correction = kP * phaseError + integrator

        // Clamp to maxCorrectionPPM
        let maxCorrection = 200e-6  // 200 ppm as ratio
        let clampedCorrection = max(-maxCorrection, min(maxCorrection, correction))

        // Update correction factor: 1.0 + correction drives SRC rate
        correctionFactor = 1.0 + clampedCorrection
        isLocked = abs(measuredDriftPPM) < 10.0  // locked when drift < 10 ppm
    }

    // MARK: - Private

    nonisolated(unsafe) private var hostTimeToNanos: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()
}

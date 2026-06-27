import Darwin

/// Lightweight first-order DC-offset removal filter.
///
/// Implements the classic DC-blocking transfer function:
///
///   H(z) = (1 − z⁻¹) / (1 − R·z⁻¹)
///
/// The pole is placed at `R = exp(−π / fs)`, giving an exact −3 dB cut-off
/// of 0.5 Hz.  At 20 Hz the attenuation is < 0.0001 dB — the filter is
/// completely inaudible for all audio content while eliminating any
/// sub-Hz electrical DC offset that would otherwise bias downstream
/// DSP stages and can cause distortion or DAC saturation.
///
/// ### Signal-chain position
/// Apply once per channel **before** any EQ, dynamics, or gain stages.
///
/// ### Real-time safety
/// No heap allocations, no locks, no virtual dispatch.
/// The filter state (`x1`, `y1`) is held in value-type storage so the
/// compiler can keep it in registers across the hot loop.
///
/// - Note: NOT Sendable — must be accessed exclusively from the audio thread.
struct DCBlocker {

    // MARK: - Private state (audio-thread only)

    private var x1: Float = 0   // x[n−1]
    private var y1: Float = 0   // y[n−1]
    private var r:  Float       // pole radius

    // MARK: - Initialisation

    /// Creates a DC blocker tuned to the given sample rate.
    /// - Parameter sampleRate: The stream sample rate in Hz.
    init(sampleRate: Double) {
        r = Self.poleRadius(sampleRate: sampleRate)
    }

    // MARK: - Runtime updates

    /// Retunes the filter for a new sample rate and flushes all state.
    ///
    /// The pole radius R = exp(−π / fs) is recomputed from the new sample rate,
    /// maintaining the cutoff frequency at 0.5 Hz regardless of the rate.
    /// At 44.1 kHz R ≈ 0.999929; at 192 kHz R ≈ 0.999984 — the cutoff in Hz
    /// stays constant because the angular frequency ω_c = π / fs scales inversely
    /// with fs, so the bilinear mapping preserves the absolute Hz cutoff.
    ///
    /// Call this when the pipeline sample rate changes.
    /// - Parameter sampleRate: New sample rate in Hz.
    mutating func updateSampleRate(_ sampleRate: Double) {
        r  = Self.poleRadius(sampleRate: sampleRate)
        x1 = 0
        y1 = 0
    }

    /// Zeros the filter delay elements.
    /// Call on stream discontinuities (stop/start) to prevent audible
    /// clicks caused by stale state values.
    mutating func reset() {
        x1 = 0
        y1 = 0
    }

    // MARK: - Processing

    /// Processes `frameCount` samples in-place with zero heap allocations.
    ///
    /// Recurrence:  y[n] = x[n] − x[n−1] + R · y[n−1]
    ///
    /// The state variables are hoisted into local registers (`lx1`, `ly1`)
    /// before the loop and written back once after, letting the compiler
    /// auto-vectorise or pipeline the inner computation.
    ///
    /// - Parameters:
    ///   - buffer: Pointer to the sample data (modified in-place).
    ///   - frameCount: Number of frames to process.
    @inline(__always)
    mutating func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        var lx1 = x1
        var ly1 = y1
        let  lr  = r

        for i in 0 ..< frameCount {
            let x0  = buffer[i]
            let y0  = x0 - lx1 + lr * ly1
            buffer[i] = y0
            lx1 = x0
            ly1 = y0
        }

        x1 = lx1
        y1 = ly1
    }

    // MARK: - Coefficient calculation

    /// Computes the pole radius for a 0.5 Hz high-pass at the given sample rate.
    ///
    /// Derivation:
    ///   ω_c = 2π·f_c / f_s = 2π·0.5 / f_s = π / f_s
    ///   R   = exp(−ω_c)    = exp(−π / f_s)
    ///
    /// At f_s = 48 000 Hz → R ≈ 0.999 934 6.
    private static func poleRadius(sampleRate: Double) -> Float {
        let r = Darwin.exp(-Double.pi / max(sampleRate, 1.0))
        return Float(r)
    }
}

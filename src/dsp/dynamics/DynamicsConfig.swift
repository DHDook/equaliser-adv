import Foundation

// MARK: - Soft Clipper Configuration

/// Configuration for the soft clipper wave-shaper stage.
struct SoftClipperConfig: Codable, Equatable, Sendable {
    /// Whether the soft clipper is active. Default OFF.
    var isEnabled: Bool = false

    /// Input drive applied before the wave-shaper, in dB.
    /// Range: -6.0 dB to +18.0 dB. Default: 0.0 dB.
    var driveDB: Float = 0.0

    /// Clipping threshold, in dB.
    /// Range: -12.0 dB to 0.0 dB. Default: -1.5 dB.
    var thresholdDB: Float = -1.5

    /// Knee smoothness controlling the width of the soft-knee transition region.
    /// Range: 0.001 (hard knee) to 1.0 (wide, tube-like saturation). Default: 0.5.
    var kneeSmooth: Float = 0.5

    static let `default` = SoftClipperConfig()
}

// MARK: - Brickwall Limiter Configuration

/// Configuration for the look-ahead brickwall limiter.
struct BrickwallLimiterConfig: Codable, Equatable, Sendable {
    /// Whether the limiter is active. Default ON.
    var isEnabled: Bool = true

    /// Output ceiling — the absolute peak the limiter will allow through, in dB.
    /// Range: -6.0 dB to 0.0 dB. Default: -0.2 dB.
    var ceilingDB: Float = -0.2

    /// Gain reduction release time, in milliseconds.
    /// Range: 5.0 ms to 250.0 ms. Default: 20.0 ms.
    var releaseMs: Float = 20.0

    /// Internal fixed look-ahead time in milliseconds (not user-configurable).
    /// The ring buffer is sized to accommodate this at sample rates up to 384 kHz.
    static let lookAheadMs: Double = 2.0

    static let `default` = BrickwallLimiterConfig()
}

// MARK: - Combined Dynamics Configuration

/// Top-level dynamics configuration: soft clipper followed by brickwall limiter.
/// Placed at the end of the signal chain after all EQ and gain stages.
struct DynamicsConfig: Codable, Equatable, Sendable {
    var softClipper: SoftClipperConfig = .default
    var limiter: BrickwallLimiterConfig = .default

    static let `default` = DynamicsConfig()
}

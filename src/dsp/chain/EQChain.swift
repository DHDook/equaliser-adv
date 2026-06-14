import Atomics
import Foundation

/// Chain of biquad filters for one audio channel.
///
/// Pre-allocates `maxBandCount` filters. Unused bands are passthrough.
/// NOT Sendable — owned exclusively by `RenderCallbackContext` (audio thread).
///
/// Uses double-buffered coefficients for lock-free updates from the main thread:
/// - `pendingCoefficients` is written by the main thread
/// - `activeCoefficients` is read by the audio thread
/// - `hasPendingUpdate` is an atomic flag that signals when updates are available
///
/// Each band stores an array of sections (`[BiquadCoefficients]`) to support
/// higher-order filters (24 dB/oct = 2 sections, 48 dB/oct = 4 sections).
/// Only filters whose sections actually changed are rebuilt in `applyPendingUpdates()`.
/// A single-band slider drag rebuilds exactly 1 filter; a full preset load rebuilds all of them.
final class EQChain {
    // MARK: - Constants

    /// Maximum number of bands per layer (from EQConfiguration).
    static let maxBandCount = EQConfiguration.maxBandCount

    // MARK: - Properties

    /// Pre-allocated biquad filters (one per band).
    private let filters: [BiquadFilter]

    /// Number of active bands in this chain.
    private var activeBandCount: Int = 0

    /// Per-band bypass flags (active bands only).
    private var bypassFlags: [Bool]

    /// Layer-level bypass (all bands bypassed).
    private var layerBypass: Bool = false

    // MARK: - Double-Buffered Coefficients

    /// Coefficients currently in use by the audio thread.
    /// Each element is an array of sections for that band.
    private var activeCoefficients: [[BiquadCoefficients]]

    /// Coefficients staged for next update (written by main thread).
    private var pendingCoefficients: [[BiquadCoefficients]]

    /// Staged active band count (written by main thread).
    private var pendingActiveBandCount: Int = 0

    /// Staged bypass flags (written by main thread).
    private var pendingBypassFlags: [Bool]

    /// Staged layer bypass (written by main thread).
    private var pendingLayerBypass: Bool = false

    /// Atomic flag indicating pending coefficient updates.
    private let hasPendingUpdate = ManagedAtomic<Bool>(false)

    /// Whether the next `applyPendingUpdates()` should reset filter delay state.
    /// Set to `true` by `stageFullUpdate()` (preset load, sample rate change).
    /// Left `false` by `stageBandUpdate()` (incremental slider drag).
    /// Read and cleared on the audio thread inside `applyPendingUpdates()`.
    private var pendingFullReset: Bool = false

    // MARK: - Initialization

    /// Creates a new EQ chain with pre-allocated resources.
    /// - Parameter maxFrameCount: Maximum frames per render call (used for scratch buffer sizing).
    init(maxFrameCount: UInt32) {
        filters = (0..<Self.maxBandCount).map { _ in BiquadFilter(maxFrameCount: Int(maxFrameCount)) }

        activeCoefficients = [BiquadCoefficients](repeating: .identity, count: Self.maxBandCount)
            .map { [$0] }
        pendingCoefficients = [BiquadCoefficients](repeating: .identity, count: Self.maxBandCount)
            .map { [$0] }

        bypassFlags = [Bool](repeating: false, count: Self.maxBandCount)
        pendingBypassFlags = [Bool](repeating: false, count: Self.maxBandCount)
    }

    // MARK: - Main Thread API

    /// Stages new coefficients for a single band (called from main thread).
    ///
    /// This is the incremental update path — used for slider drags and single-parameter changes.
    /// It does NOT set `pendingFullReset`, so `applyPendingUpdates()` will preserve filter delay
    /// state on all unchanged bands, preventing audible clicks.
    /// - Parameters:
    ///   - index: Band index within this chain.
    ///   - sections: Array of biquad sections (1 section = 12 dB/oct, 2 = 24 dB/oct, etc.)
    ///   - bypass: Whether this band is bypassed.
    ///   - needsDoublePrecision: Whether this band requires double-precision processing.
    func stageBandUpdate(index: Int, sections: [BiquadCoefficients], bypass: Bool, needsDoublePrecision: Bool = false) {
        guard index >= 0 && index < Self.maxBandCount else { return }
        pendingCoefficients[index] = sections
        pendingBypassFlags[index] = bypass
        filters[index].useDoublePrecision = needsDoublePrecision
        hasPendingUpdate.store(true, ordering: .releasing)
    }

    /// Stages a full configuration update (called from main thread).
    ///
    /// Used for preset load, band count change, or sample rate change. Sets `pendingFullReset`
    /// so that `applyPendingUpdates()` resets all filter delay state — producing a clean start.
    /// - Parameters:
    ///   - sections: Per-band arrays of biquad sections.
    ///   - bypassFlags: Per-band bypass flags.
    ///   - activeBandCount: Number of active bands.
    ///   - layerBypass: Whether the entire layer is bypassed.
    ///   - needsDoublePrecision: Per-band flags for double-precision processing.
    func stageFullUpdate(
        sections: [[BiquadCoefficients]],
        bypassFlags: [Bool],
        activeBandCount: Int,
        layerBypass: Bool,
        needsDoublePrecision: [Bool] = [Bool](repeating: false, count: maxBandCount)
    ) {
        for i in 0..<Self.maxBandCount {
            pendingCoefficients[i] = i < sections.count ? sections[i] : [.identity]
            pendingBypassFlags[i] = i < bypassFlags.count ? bypassFlags[i] : false
            filters[i].useDoublePrecision = i < needsDoublePrecision.count ? needsDoublePrecision[i] : false
        }
        pendingActiveBandCount = min(activeBandCount, Self.maxBandCount)
        pendingLayerBypass = layerBypass
        pendingFullReset = true
        hasPendingUpdate.store(true, ordering: .releasing)
    }

    /// Sets the layer bypass state (called from main thread).
    func stageLayerBypass(_ bypass: Bool) {
        pendingLayerBypass = bypass
        hasPendingUpdate.store(true, ordering: .releasing)
    }

    // MARK: - Audio Thread API

    /// Applies any pending coefficient updates.
    /// Call once per render cycle before processing.
    ///
    /// Only rebuilds vDSP setups for bands whose sections actually changed.
    @inline(__always)
    func applyPendingUpdates() {
        guard hasPendingUpdate.exchange(false, ordering: .acquiringAndReleasing) else { return }

        let fullReset = pendingFullReset
        pendingFullReset = false

        activeBandCount = pendingActiveBandCount
        layerBypass = pendingLayerBypass

        for i in 0..<Self.maxBandCount {
            bypassFlags[i] = pendingBypassFlags[i]

            let pending = pendingCoefficients[i]
            if pending != activeCoefficients[i] {
                activeCoefficients[i] = pending
                filters[i].stageCoefficients(pending, resetState: fullReset)
            } else if fullReset {
                filters[i].stageCoefficients(pending, resetState: true)
            }
        }
    }

    /// Processes audio through all active bands in this chain.
    /// Input and output may alias (in-place processing supported).
    /// - Parameters:
    ///   - buffer: Audio buffer to process (modified in place).
    ///   - frameCount: Number of frames to process.
    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: UInt32) {
        // Apply any pending coefficient updates (no allocation — pointer swap only).
        for i in 0..<activeBandCount {
            filters[i].applyPendingSetup()
        }
        if layerBypass { return }
        if activeBandCount == 0 { return }

        for i in 0..<activeBandCount {
            if bypassFlags[i] { continue }
            filters[i].process(input: buffer, output: buffer, frameCount: frameCount)
        }
    }
}

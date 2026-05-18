import Accelerate
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
/// vDSP setups are pre-created on the main thread during staging and installed on
/// the audio thread during `applyPendingUpdates()`. This avoids allocation on the
/// audio thread — a real-time safety requirement.
///
/// Only filters whose coefficients actually changed are rebuilt in `applyPendingUpdates()`.
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
    private var activeCoefficients: [BiquadCoefficients]

    /// Coefficients staged for next update (written by main thread).
    private var pendingCoefficients: [BiquadCoefficients]

    /// Pre-built vDSP setups staged for next update (written by main thread).
    /// Created via `BiquadFilter.prepareSetup()` on the main thread, installed on the
    /// audio thread in `applyPendingUpdates()`. Ownership transfers to `BiquadFilter`
    /// on install, or is destroyed if unused.
    private var pendingSetups: [vDSP_biquad_Setup?]

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
    /// - Parameter maxFrameCount: Maximum frames per render call (unused, kept for API compatibility).
    init(maxFrameCount: UInt32) {
        // Pre-allocate filters (always maxBandCount)
        filters = (0..<Self.maxBandCount).map { _ in BiquadFilter() }

        // Pre-allocate coefficient arrays
        activeCoefficients = [BiquadCoefficients](repeating: .identity, count: Self.maxBandCount)
        pendingCoefficients = [BiquadCoefficients](repeating: .identity, count: Self.maxBandCount)

        // Pre-allocate vDSP setup staging array
        pendingSetups = [vDSP_biquad_Setup?](repeating: nil, count: Self.maxBandCount)

        // Pre-allocate bypass flags
        bypassFlags = [Bool](repeating: false, count: Self.maxBandCount)
        pendingBypassFlags = [Bool](repeating: false, count: Self.maxBandCount)
    }

    deinit {
        // Destroy any staged setups that weren't applied (ownership wasn't transferred)
        for setup in pendingSetups {
            if let s = setup {
                vDSP_biquad_DestroySetup(s)
            }
        }
    }

    // MARK: - Main Thread API

    /// Stages new coefficients for a single band (called from main thread).
    ///
    /// This is the incremental update path — used for slider drags and single-parameter changes.
    /// It does NOT set `pendingFullReset`, so `applyPendingUpdates()` will preserve filter delay
    /// state on all unchanged bands, preventing audible clicks.
    ///
    /// The vDSP setup is pre-created on the calling thread (main thread) to avoid
    /// allocation on the audio thread.
    /// - Parameters:
    ///   - index: Band index within this chain.
    ///   - coefficients: New biquad coefficients.
    ///   - bypass: Whether this band is bypassed.
    func stageBandUpdate(index: Int, coefficients: BiquadCoefficients, bypass: Bool) {
        guard index >= 0 && index < Self.maxBandCount else { return }
        pendingCoefficients[index] = coefficients
        pendingBypassFlags[index] = bypass

        // Pre-create vDSP setup on the main thread to avoid allocation on audio thread.
        // Destroy any previously staged setup that hasn't been applied yet.
        if let oldSetup = pendingSetups[index] {
            vDSP_biquad_DestroySetup(oldSetup)
        }
        pendingSetups[index] = BiquadFilter.prepareSetup(coefficients)

        hasPendingUpdate.store(true, ordering: .releasing)
    }

    /// Stages a full configuration update (called from main thread).
    ///
    /// Used for preset load, band count change, or sample rate change. Sets `pendingFullReset`
    /// so that `applyPendingUpdates()` resets all filter delay state — producing a clean start.
    ///
    /// The vDSP setups are pre-created on the calling thread (main thread) to avoid
    /// allocation on the audio thread.
    /// - Parameters:
    ///   - coefficients: All band coefficients.
    ///   - bypassFlags: Per-band bypass flags.
    ///   - activeBandCount: Number of active bands.
    ///   - layerBypass: Whether the entire layer is bypassed.
    func stageFullUpdate(
        coefficients: [BiquadCoefficients],
        bypassFlags: [Bool],
        activeBandCount: Int,
        layerBypass: Bool
    ) {
        // Copy coefficients and pre-create vDSP setups (pad with identity if needed)
        for i in 0..<Self.maxBandCount {
            let coeff = i < coefficients.count ? coefficients[i] : .identity
            pendingCoefficients[i] = coeff
            pendingBypassFlags[i] = i < bypassFlags.count ? bypassFlags[i] : false

            // Pre-create vDSP setup on the main thread
            if let oldSetup = pendingSetups[i] {
                vDSP_biquad_DestroySetup(oldSetup)
            }
            pendingSetups[i] = BiquadFilter.prepareSetup(coeff)
        }
        pendingActiveBandCount = min(activeBandCount, Self.maxBandCount)
        pendingLayerBypass = layerBypass
        // Full update resets delay state to give the new configuration a clean start
        pendingFullReset = true
        hasPendingUpdate.store(true, ordering: .releasing)
    }

    /// Sets the layer bypass state (called from main thread).
    ///
    /// Note: This is a standalone toggle for bypass state. When toggling bypass off,
    /// you should ensure `stageFullUpdate()` has been called previously (or will be called)
    /// to set the active band count correctly. If only bypass is toggled without prior
    /// full staging, `pendingActiveBandCount` remains at its initialised value (0).
    /// - Parameter bypass: Whether the entire layer is bypassed.
    func stageLayerBypass(_ bypass: Bool) {
        pendingLayerBypass = bypass
        hasPendingUpdate.store(true, ordering: .releasing)
    }

    // MARK: - Audio Thread API

    /// Applies any pending coefficient updates.
    /// Call once per render cycle before processing.
    ///
    /// Installs pre-built vDSP setups for bands whose coefficients changed.
    /// No allocation occurs on the audio thread — setups were created on the main thread.
    /// - For incremental updates (`stageBandUpdate`): installs exactly the 1 changed filter,
    ///   preserving delay state (no clicks). The other 63 filters are not touched.
    /// - For full updates (`stageFullUpdate`): installs all filters and resets delay state
    ///   (clean start for preset loads and sample rate changes).
    @inline(__always)
    func applyPendingUpdates() {
        guard hasPendingUpdate.exchange(false, ordering: .acquiringAndReleasing) else { return }

        // Capture and clear the full-reset flag
        let fullReset = pendingFullReset
        pendingFullReset = false

        // Update active band count and layer bypass
        activeBandCount = pendingActiveBandCount
        layerBypass = pendingLayerBypass

        // Update each band — only install setups for bands whose coefficients changed.
        // For a single-band slider drag, this loop touches exactly 1 filter out of 64.
        for i in 0..<Self.maxBandCount {
            bypassFlags[i] = pendingBypassFlags[i]

            let pending = pendingCoefficients[i]
            if pending != activeCoefficients[i] {
                // Coefficients changed: install the pre-built vDSP setup.
                // Use resetState only on full updates (preset loads) to avoid mid-stream clicks.
                activeCoefficients[i] = pending
                filters[i].setCoefficients(pending, setup: pendingSetups[i], resetState: fullReset)
                pendingSetups[i] = nil // Ownership transferred to BiquadFilter
            } else if fullReset {
                // Coefficients unchanged but a full reset was requested (e.g. the band was
                // already at identity before a preset load). Reset delay state so that any
                // residual ringing from a previous preset is cleared.
                filters[i].setCoefficients(pending, setup: pendingSetups[i], resetState: true)
                pendingSetups[i] = nil // Ownership transferred to BiquadFilter
            } else {
                // No coefficient change, no full reset — destroy unused pre-built setup.
                if let unusedSetup = pendingSetups[i] {
                    vDSP_biquad_DestroySetup(unusedSetup)
                    pendingSetups[i] = nil
                }
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
        // Layer bypass: skip all processing
        if layerBypass {
            return
        }

        // No active bands: passthrough
        if activeBandCount == 0 {
            return
        }

        // Process each active band in-place
        // BiquadFilter supports in-place processing (input == output)
        for i in 0..<activeBandCount {
            // Skip bypassed bands
            if bypassFlags[i] {
                continue
            }

            // Process through this band's biquad filter in-place
            filters[i].process(
                input: buffer,
                output: buffer,
                frameCount: frameCount
            )
        }
    }
}

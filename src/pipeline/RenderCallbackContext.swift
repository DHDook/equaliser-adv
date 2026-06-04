import AudioToolbox
import Atomics
import CoreAudio
import Darwin
import os.log

/// Context passed to both the input and output HAL render callbacks.
/// Contains ring buffers for inter-callback communication and all state
/// needed for real-time audio processing without requiring any allocations or locks.
///
/// Data flow (HAL input mode — ring buffers):
/// 1. Input callback captures audio from device → writes to ring buffers
/// 2. Output callback reads from ring buffers → processes through EQ → outputs
///
/// Data flow (shared memory capture mode — direct):
/// 1. Output callback polls driver shared memory → writes directly to inputBuffers
/// 2. Output callback processes inputBuffers through EQ → outputs
///    (bypasses intermediate AudioRingBuffer since both steps run on the same thread)
///
/// - Important: This class is `@unchecked Sendable` because it is accessed from
///   both the main thread (for setup) and the audio render thread (for processing).
///   All mutable state is designed for single-writer/single-reader access patterns.
final class RenderCallbackContext: @unchecked Sendable {
    // MARK: - Properties

    private static let maxMeterChannels = MeterConstants.maxMeterChannels
    private static let silenceDB: Float = MeterConstants.silenceDB

    /// Ring buffers for audio samples (one per channel).
    /// Written by input callback, read by output callback.
    let ringBuffers: [AudioRingBuffer]

    /// The INPUT HAL audio unit for pulling audio in the input callback.
    /// The input callback uses AudioUnitRender on this unit to get captured samples.
    let inputHALUnit: AudioComponentInstance?

    /// Per-channel EQ chain arrays. Index = layer (0 = user EQ, 1+ = future layers).
    /// Pre-allocated at init. Unused layers are passthrough (0 active bands).
    /// Left channel chains for left speaker, right channel chains for right speaker.
    let leftEQChains: [EQChain]
    let rightEQChains: [EQChain]

    /// Number of audio channels.
    let channelCount: UInt32

    /// Maximum number of frames per callback.
    let maxFrameCount: UInt32

    /// Driver capture for shared memory polling (optional, only in shared memory mode).
    /// When set, the output callback will poll the driver before reading from ring buffers.
    private nonisolated(unsafe) var driverCapture: DriverCapture?

    /// Pre-allocated buffers for input audio samples (one per channel for deinterleaved layout).
    /// Used by the input callback when pulling audio from the input HAL unit.
    private let inputBuffers: [UnsafeMutablePointer<Float>]

    /// Size of each channel buffer in samples (frames per channel).
    private let framesPerBuffer: Int

    /// Pre-allocated AudioBufferList with proper memory layout for multiple buffers.
    /// Used by the input callback to receive audio from AudioUnitRender.
    private let inputBufferListPtr: UnsafeMutablePointer<AudioBufferList>

    /// Size of the allocated AudioBufferList in bytes.
    private let inputBufferListSize: Int

    /// Pre-allocated buffers for reading from ring buffers (output callback).
    /// One per channel.
    private let outputReadBuffers: [UnsafeMutablePointer<Float>]

    /// The buffers that EQ and output copy operate on.
    /// In direct capture mode: inputBuffers (no intermediate ring buffer).
    /// In ring buffer mode: outputReadBuffers (read from AudioRingBuffer).
    private nonisolated(unsafe) var processingBuffers: [UnsafeMutablePointer<Float>]!

    /// Immutable pointers to processingBuffers (avoids array allocation in hot paths).
    private nonisolated(unsafe) var processingBufferPointers: [UnsafePointer<Float>]!

    // MARK: - Atomic Target Gains
    // Target gains are written by the main thread and read by the audio thread.
    // We use atomic Int32 storage with Float bit-casting for thread-safe access.
    // Float is not directly supported by Swift Atomics, so we use Int32 bit patterns.
    // Relaxed memory ordering is sufficient for single-writer/single-reader scenarios
    // where slight staleness is acceptable for audio processing.

    /// Target linear gain for input (stored as Int32 bit pattern of Float).
    /// Written by main thread, read by audio thread.
    private let targetInputGainAtomic: ManagedAtomic<Int32> = ManagedAtomic(1065353216) // Float 1.0 as Int32 bits (0x3F800000)

    /// Target linear gain for output (stored as Int32 bit pattern of Float).
    /// Written by main thread, read by audio thread.
    private let targetOutputGainAtomic: ManagedAtomic<Int32> = ManagedAtomic(1065353216) // Float 1.0 as Int32 bits (0x3F800000)

    /// Target boost gain (stored as Int32 bit pattern of Float).
    /// Written by main thread, read by audio thread.
    private let targetBoostGainAtomic: ManagedAtomic<Int32> = ManagedAtomic(1065353216) // Float 1.0 as Int32 bits (0x3F800000)

    /// Target volume gain for shared memory mode (stored as Int32 bit pattern of Float).
    /// 0.0 when muted or volume at 0%, 1.0 at normal volumes.
    /// Written by main thread, read by audio thread.

    // MARK: - Pre/Post EQ Peak Meter Atomics

    /// Pre-EQ peak level in dB (stored as Int32 bit pattern of Float).
    /// Written by audio thread, read by main thread for meter display.
    private let preEQPeakAtomic: ManagedAtomic<Int32> = ManagedAtomic(0)

    /// Post-EQ peak level in dB (stored as Int32 bit pattern of Float).
    /// Written by audio thread, read by main thread for meter display.
    private let postEQPeakAtomic: ManagedAtomic<Int32> = ManagedAtomic(0)

    // MARK: - Oversampling Processor

    /// 4x oversampling processor for improved high-frequency response.
    private nonisolated(unsafe) var oversamplingProcessor: OversamplingProcessor?

    private let targetVolumeGainAtomic: ManagedAtomic<Int32> = ManagedAtomic(0) // Float 0.0 — silent until VolumeManager sets correct value

    /// Stopping flag (stored as Int32 for atomic access).
    /// Set to 1 by main thread before stopping HAL units. Read by audio thread.
    /// When true, callbacks zero-fill output and return immediately — prevents
    /// use-after-free if HAL calls the callback between AudioOutputUnitStop and
    /// callbackContext deallocation.
    private let isStoppingAtomic: ManagedAtomic<Int32> = ManagedAtomic(0) // false

    /// Meters enabled flag (stored as Int32 for atomic access).
    /// Written by main thread, read by audio thread.
    /// When false, meter calculations are skipped entirely.
    private let metersEnabledAtomic: ManagedAtomic<Int32> = ManagedAtomic(0) // false

    // MARK: - Current Gains (Audio Thread Only)
    // Current gains are ONLY written by the audio thread during gain ramping.
    // They can be read for diagnostics, but should not be written from any other thread.

    /// Current linear gain for input (audio thread only).
    nonisolated(unsafe) var inputGainLinear: Float = 1.0

    /// Current linear gain for output (audio thread only).
    nonisolated(unsafe) var outputGainLinear: Float = 1.0

    /// Current boost gain (audio thread only).
    nonisolated(unsafe) var boostGainLinear: Float = 1.0

    /// Current volume gain for shared memory mode (audio thread only).
    /// Ensures digital silence at 0% volume when using shared memory capture.
    nonisolated(unsafe) var volumeGainLinear: Float = 0.0

    // MARK: - Gain Update API (Main Thread)

    /// Updates the target input gain (called from main thread).
    /// - Parameter linear: Linear gain value (will be clamped to >= 0).
    func setTargetInputGain(_ linear: Float) {
        let clamped = max(0, linear)
        let bits = Int32(bitPattern: clamped.bitPattern)
        targetInputGainAtomic.store(bits, ordering: .relaxed)
    }

    /// Updates the target output gain (called from main thread).
    /// - Parameter linear: Linear gain value (will be clamped to >= 0).
    func setTargetOutputGain(_ linear: Float) {
        let clamped = max(0, linear)
        let bits = Int32(bitPattern: clamped.bitPattern)
        targetOutputGainAtomic.store(bits, ordering: .relaxed)
    }

    /// Updates the target boost gain (called from main thread).
    /// - Parameter linear: Linear gain value (will be clamped to >= 1).
    func setTargetBoostGain(_ linear: Float) {
        let clamped = max(1, linear)
        let bits = Int32(bitPattern: clamped.bitPattern)
        targetBoostGainAtomic.store(bits, ordering: .relaxed)
    }

    /// Updates the target volume gain for shared memory mode (called from main thread).
    /// - Parameter linear: Linear gain value (0.0 = silence, 1.0 = pass-through, clamped to 0-1).
    func setTargetVolumeGain(_ linear: Float) {
        let clamped = max(0, min(1, linear))
        let bits = Int32(bitPattern: clamped.bitPattern)
        targetVolumeGainAtomic.store(bits, ordering: .relaxed)
    }

    /// Updates the meters enabled state (called from main thread).
    /// When disabled, meter calculations are skipped on the audio thread.
    func setMetersEnabled(_ enabled: Bool) {
        metersEnabledAtomic.store(enabled ? 1 : 0, ordering: .relaxed)
    }

    /// Sets the stopping flag (called from main thread before HAL stop).
    /// When true, render callbacks output silence and return early.
    func setIsStopping(_ stopping: Bool) {
        isStoppingAtomic.store(stopping ? 1 : 0, ordering: .relaxed)
    }

    /// Checks if the pipeline is stopping (called from audio thread).
    /// Returns true if callbacks should output silence and return early.
    var isStopping: Bool {
        isStoppingAtomic.load(ordering: .relaxed) != 0
    }

    // MARK: - Pre/Post EQ Peak Meter API

    /// Updates the pre-EQ peak level (called from audio thread).
    /// - Parameter peakDB: Peak level in dB.
    func setPreEQPeak(_ peakDB: Float) {
        let bits = Int32(bitPattern: peakDB.bitPattern)
        preEQPeakAtomic.store(bits, ordering: .relaxed)
    }

    /// Updates the post-EQ peak level (called from audio thread).
    /// - Parameter peakDB: Peak level in dB.
    func setPostEQPeak(_ peakDB: Float) {
        let bits = Int32(bitPattern: peakDB.bitPattern)
        postEQPeakAtomic.store(bits, ordering: .relaxed)
    }

    /// Returns the current pre-EQ peak level (called from main thread).
    var preEQPeak: Float {
        Float(bitPattern: UInt32(bitPattern: preEQPeakAtomic.load(ordering: .relaxed)))
    }

    /// Returns the current post-EQ peak level (called from main thread).
    var postEQPeak: Float {
        Float(bitPattern: UInt32(bitPattern: postEQPeakAtomic.load(ordering: .relaxed)))
    }

    // MARK: - Oversampling Processor API

    /// Sets oversampling enabled state (called from main thread).
    func setOversamplingEnabled(_ enabled: Bool) {
        oversamplingProcessor?.setEnabled(enabled)
    }

    // MARK: - Gain Read API (Audio Thread or Diagnostics)

    /// Returns the current target input gain.
    func getTargetInputGain() -> Float {
        Float(bitPattern: UInt32(bitPattern: targetInputGainAtomic.load(ordering: .relaxed)))
    }

    /// Returns the current target output gain.
    func getTargetOutputGain() -> Float {
        Float(bitPattern: UInt32(bitPattern: targetOutputGainAtomic.load(ordering: .relaxed)))
    }

    /// Returns the current target boost gain.
    func getTargetBoostGain() -> Float {
        Float(bitPattern: UInt32(bitPattern: targetBoostGainAtomic.load(ordering: .relaxed)))
    }

    /// Returns the current target volume gain for shared memory mode.
    func getTargetVolumeGain() -> Float {
        Float(bitPattern: UInt32(bitPattern: targetVolumeGainAtomic.load(ordering: .relaxed)))
    }

    /// Processing mode for audio thread:
    /// 0 = full bypass (System EQ OFF) - skip gains, bypass EQ
    /// 1 = normal (EQ + gains)
    /// 2 = gains only (Compare Flat mode) - apply gains, bypass EQ
    nonisolated(unsafe) var processingMode: Int32 = 1

    /// Number of channels exposed to the level meters (up to two for stereo visualization).
    private let meterChannelCount: Int

    /// Storage for latest input peak levels per channel (in dBFS).
    private let inputMeterStorage: UnsafeMutablePointer<Float>

    /// Storage for latest output peak levels per channel (in dBFS).
    private let outputMeterStorage: UnsafeMutablePointer<Float>

    /// Storage for latest input RMS levels per channel (in dBFS).
    private let inputRmsStorage: UnsafeMutablePointer<Float>

    /// Storage for latest output RMS levels per channel (in dBFS).
    private let outputRmsStorage: UnsafeMutablePointer<Float>

    /// Pre-allocated arrays for audio thread (avoid heap allocation in hot paths).
    /// Reused in applyGain(to: UnsafeMutablePointer<AudioBufferList>...) and updateOutputMeters.
    private var gainBuffers: [UnsafeMutablePointer<Float>] = []
    private var meterChannelPointers: [UnsafePointer<Float>] = []

    // MARK: - Dynamics Processing

    /// Dual-stage dynamics processor: soft clipper → brickwall limiter.
    /// Allocated once at pipeline start and accessed exclusively from the audio thread,
    /// except for atomic parameter updates issued by the main thread.
    let dynamicsProcessor: DynamicsProcessor

    /// Per-channel DC-offset blocking filters (0.5 Hz high-pass).
    /// Applied at the absolute front of the output processing chain, before EQ or any gain stage.
    /// Audio-thread exclusive — mutated (state update) on every render callback.
    nonisolated(unsafe) var dcBlockers: [DCBlocker] = []

    /// Atomic flag: 1 once THREAD_TIME_CONSTRAINT_POLICY has been applied to the output
    /// render thread.  Written once (0→1) from the audio thread; checked on every callback
    /// via a relaxed CAS so the fast path (already set) costs a single atomic load.
    let hasAppliedRealtimePolicy: ManagedAtomic<Int32> = ManagedAtomic(0)

    /// Pre-computed output buffer pointers (immutable, avoids array allocation on every callback).
    private let outputBufferPointersPrecomputed: [UnsafePointer<Float>]

    /// Pre-computed input buffer pointers (immutable, avoids array allocation in provideFrames).
    private let inputBufferPointers: [UnsafePointer<Float>]

    /// Pre-computed input buffer mutable pointers (immutable, avoids array allocation in provideFrames).
    private let inputBufferMutablePointers: [UnsafeMutablePointer<Float>]

    // MARK: - Driver Capture

    /// Sets the driver capture instance for polling.
    /// When set, the output callback uses direct capture mode: shared memory is polled
    /// directly into inputBuffers, bypassing the intermediate AudioRingBuffer.
    /// When cleared, reverts to ring buffer mode for HAL input capture.
    func setDriverCapture(_ capture: DriverCapture?) {
        driverCapture = capture
        if capture != nil {
            // Direct capture: EQ and output operate on inputBuffers directly,
            // avoiding two unnecessary memcpy operations through the ring buffer.
            processingBuffers = inputBuffers
            processingBufferPointers = inputBufferPointers
        } else {
            // Ring buffer mode: EQ and output operate on outputReadBuffers
            // (filled from AudioRingBuffer by readFromRingBuffers).
            processingBuffers = outputReadBuffers
            processingBufferPointers = outputBufferPointersPrecomputed
        }
    }

    // MARK: - Initialization

    /// Creates a new callback context with ring buffers and pre-allocated audio buffers.
    /// - Parameters:
    ///   - inputHALUnit: The INPUT HAL audio unit instance for capturing audio.
    ///   - channelCount: Number of audio channels.
    ///   - maxFrameCount: Maximum frames per callback (used for buffer sizing).
    ///   - ringBufferCapacity: Capacity of each ring buffer in samples (default from AudioConstants).
    init(
        inputHALUnit: AudioComponentInstance?,
        channelCount: UInt32,
        maxFrameCount: UInt32,
        ringBufferCapacity: Int = AudioConstants.ringBufferCapacity,
        sampleRate: Double = 48000.0,
        dynamicsConfig: DynamicsConfig = .default
    ) {
        self.inputHALUnit = inputHALUnit
        self.channelCount = channelCount
        self.maxFrameCount = maxFrameCount
        self.framesPerBuffer = Int(maxFrameCount)
        self.meterChannelCount = min(Int(channelCount), Self.maxMeterChannels)

        // Create the dynamics processor with the current sample rate and initial config.
        // applyConfig() is called immediately so the processor starts in the correct state.
        let dp = DynamicsProcessor(channelCount: channelCount, sampleRate: sampleRate)
        dp.applyConfig(dynamicsConfig, sampleRate: sampleRate)
        self.dynamicsProcessor = dp

        // Initialise one DC-blocker per channel, tuned to the current sample rate.
        // The pole is computed once here and stored; no allocation occurs in the render loop.
        self.dcBlockers = (0 ..< Int(channelCount)).map { _ in DCBlocker(sampleRate: sampleRate) }

        // Create oversampling processor for 4x upsampling before EQ
        self.oversamplingProcessor = OversamplingProcessor(channelCount: Int(channelCount), sampleRate: sampleRate)

        // Create EQ chains (one per layer per channel)
        let layerCount = EQLayerConstants.maxLayerCount
        self.leftEQChains = (0..<layerCount).map { _ in EQChain(maxFrameCount: maxFrameCount) }
        self.rightEQChains = (0..<layerCount).map { _ in EQChain(maxFrameCount: maxFrameCount) }

        // Create ring buffers (one per channel)
        var rings: [AudioRingBuffer] = []
        for _ in 0..<channelCount {
            rings.append(AudioRingBuffer(capacity: ringBufferCapacity))
        }
        self.ringBuffers = rings

        // Pre-allocate one buffer per channel for input callback — 64-byte SIMD-aligned.
        // 64-byte alignment lets ARM64 NEON / vDSP vector instructions read full cache lines
        // without penalty.  Must be freed with free() in deinit (not Swift's .deallocate()).
        var inputBufs: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<channelCount {
            inputBufs.append(Self.allocateSIMDAlignedBuffer(capacity: framesPerBuffer))
        }
        self.inputBuffers = inputBufs

        // Pre-allocate one buffer per channel for output callback reads — 64-byte SIMD-aligned.
        var outputBufs: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<channelCount {
            outputBufs.append(Self.allocateSIMDAlignedBuffer(capacity: framesPerBuffer))
        }
        self.outputReadBuffers = outputBufs

        // Pre-compute output buffer pointers (avoid array allocation on every callback)
        self.outputBufferPointersPrecomputed = outputBufs.map { UnsafePointer($0) }

        // Pre-compute input buffer pointer arrays (avoid array allocation in provideFrames)
        self.inputBufferPointers = inputBufs.map { UnsafePointer($0) }
        self.inputBufferMutablePointers = inputBufs

        // Default processing buffers to outputReadBuffers (HAL input / ring buffer mode).
        // Switched to inputBuffers when setDriverCapture() enables direct capture mode.
        self.processingBuffers = outputReadBuffers
        self.processingBufferPointers = outputBufferPointersPrecomputed

        self.inputMeterStorage = UnsafeMutablePointer<Float>.allocate(capacity: meterChannelCount)
        self.outputMeterStorage = UnsafeMutablePointer<Float>.allocate(capacity: meterChannelCount)
        self.inputRmsStorage = UnsafeMutablePointer<Float>.allocate(capacity: meterChannelCount)
        self.outputRmsStorage = UnsafeMutablePointer<Float>.allocate(capacity: meterChannelCount)
        inputMeterStorage.initialize(repeating: Self.silenceDB, count: meterChannelCount)
        outputMeterStorage.initialize(repeating: Self.silenceDB, count: meterChannelCount)
        inputRmsStorage.initialize(repeating: Self.silenceDB, count: meterChannelCount)
        outputRmsStorage.initialize(repeating: Self.silenceDB, count: meterChannelCount)

        // Pre-allocate arrays for audio thread hot paths
        gainBuffers.reserveCapacity(Int(channelCount))
        meterChannelPointers.reserveCapacity(Int(channelCount))

        // Calculate size for AudioBufferList with `channelCount` buffers
        // AudioBufferList has 1 AudioBuffer inline, so we need space for (channelCount - 1) additional
        let additionalBuffers = max(0, Int(channelCount) - 1)
        self.inputBufferListSize = MemoryLayout<AudioBufferList>.size
            + additionalBuffers * MemoryLayout<AudioBuffer>.size

        // Allocate and initialize the AudioBufferList
        self.inputBufferListPtr = UnsafeMutableRawPointer
            .allocate(byteCount: inputBufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            .assumingMemoryBound(to: AudioBufferList.self)

        // Set up the buffer list structure
        inputBufferListPtr.pointee.mNumberBuffers = channelCount

        // Get pointer to the mBuffers array
        let buffersPtr = UnsafeMutableAudioBufferListPointer(inputBufferListPtr)
        for (index, buffer) in buffersPtr.enumerated() {
            // Each buffer holds one channel
            var mutableBuffer = buffer
            mutableBuffer.mNumberChannels = 1
            mutableBuffer.mDataByteSize = UInt32(framesPerBuffer * MemoryLayout<Float>.size)
            mutableBuffer.mData = UnsafeMutableRawPointer(inputBuffers[index])
            buffersPtr[index] = mutableBuffer
        }
    }

    deinit {
        // Free SIMD-aligned input channel buffers.
        // These were allocated via posix_memalign so they must be released with free(),
        // not Swift's .deallocate() (which routes through swift_deallocRaw and is not
        // guaranteed to match the posix_memalign allocator on all Darwin releases).
        // Float is trivially destructible — no deinitialize() call needed.
        for buffer in inputBuffers {
            free(UnsafeMutableRawPointer(buffer))
        }

        // Free SIMD-aligned output read buffers (same reason as above).
        for buffer in outputReadBuffers {
            free(UnsafeMutableRawPointer(buffer))
        }

        inputMeterStorage.deinitialize(count: meterChannelCount)
        inputMeterStorage.deallocate()
        outputMeterStorage.deinitialize(count: meterChannelCount)
        outputMeterStorage.deallocate()
        inputRmsStorage.deinitialize(count: meterChannelCount)
        inputRmsStorage.deallocate()
        outputRmsStorage.deinitialize(count: meterChannelCount)
        outputRmsStorage.deallocate()

        // Deallocate the AudioBufferList
        inputBufferListPtr.deallocate()
    }

    // MARK: - Input Callback Support

    /// Returns a pointer to the pre-allocated input buffer list, sized for the given frame count.
    /// Used by the input callback to receive audio from AudioUnitRender.
    /// - Parameter frameCount: The number of frames to be rendered.
    /// - Returns: A pointer to the AudioBufferList.
    func prepareInputBufferList(frameCount: UInt32) -> UnsafeMutablePointer<AudioBufferList> {
        // Update the byte size for this render pass on each buffer
        let byteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        let buffersPtr = UnsafeMutableAudioBufferListPointer(inputBufferListPtr)

        for index in 0..<Int(channelCount) {
            buffersPtr[index].mDataByteSize = byteSize
        }

        return inputBufferListPtr
    }

    /// Writes captured audio samples to the ring buffers.
    /// Called by the input callback after AudioUnitRender succeeds.
    /// - Parameter frameCount: Number of frames to write.
    @inline(__always)
    func writeToRingBuffers(frameCount: UInt32) {
        let count = Int(frameCount)
        for (index, ringBuffer) in ringBuffers.enumerated() {
            _ = ringBuffer.write(inputBuffers[index], count: count)
        }
        updateMeterStorage(storage: inputMeterStorage, rmsStorage: inputRmsStorage, with: inputBufferPointers, frameCount: count)
    }

    /// Direct access to the input sample buffers (for diagnostics/debugging).
    var inputSampleBuffers: [UnsafeMutablePointer<Float>] {
        inputBuffers
    }

    /// Applies gain to a set of channel buffers, with per-callback ramping.
    @inline(__always)
    func applyGain(
        to buffers: [UnsafeMutablePointer<Float>],
        frameCount: UInt32,
        currentGain: inout Float,
        targetGain: Float
    ) {
        let count = Int(frameCount)
        guard count > 0 else {
            currentGain = targetGain
            return
        }

        let gainDelta = targetGain - currentGain
        let gainStep = gainDelta / Float(count)
        var gain = currentGain
        var index = 0

        while index < count {
            for buffer in buffers {
                buffer[index] *= gain
            }
            gain += gainStep
            index += 1
        }

        currentGain = targetGain
    }

    // MARK: - Output Callback Support

    /// Provides frames for processing, handling both direct capture and ring buffer modes.
    ///
    /// In direct capture mode (driverCapture set): polls shared memory directly into
    /// inputBuffers (= processingBuffers), bypassing the intermediate AudioRingBuffer.
    ///
    /// In ring buffer mode (driverCapture nil): reads from AudioRingBuffer into
    /// outputReadBuffers (= processingBuffers). This is used by HAL input capture
    /// where producer and consumer run on different threads.
    ///
    /// - Parameter frameCount: Maximum frames to provide (typically the output callback's frameCount).
    /// - Returns: Number of frames available in processingBuffers, or 0 if no data.
    @inline(__always)
    func provideFrames(frameCount: UInt32) -> Int {
        if let capture = driverCapture {
            // Direct capture: poll shared memory → inputBuffers (= processingBuffers)
            // Read exactly frameCount frames (the output device's requested amount).
            // The shared memory ring (65536 frames) absorbs clock drift — we consume
            // at the output device's rate, not the driver's rate. This prevents
            // over-consumption that causes periodic overflow resets and artefacts.
            guard let (polled, _, channelCount) = capture.pollIntoBuffers(
                destBuffers: inputBuffers,
                maxFrames: frameCount
            ) else { return 0 }

            guard channelCount == self.channelCount else { return 0 }

            let polledCount = Int(polled)
            let requestedCount = Int(frameCount)

            // Zero-fill the remainder on underrun to prevent stale data from
            // the previous callback leaking through.
            if polledCount < requestedCount {
                for buffer in inputBuffers {
                    memset(buffer + polledCount, 0,
                           (requestedCount - polledCount) * MemoryLayout<Float>.size)
                }
            }

            // Apply volume gain to ensure digital silence at 0% volume (shared memory mode).
            // The driver's WriteMix path writes pre-volume audio to shared memory, bypassing
            // the driver's volume attenuation (applied only in ReadInput for HAL input mode).
            // This gain is unconditional — even in bypass mode, 0% volume should produce silence.
            let targetVolumeGain = getTargetVolumeGain()
            applyGain(to: inputBufferMutablePointers, frameCount: frameCount,
                      currentGain: &volumeGainLinear, targetGain: targetVolumeGain)

            // Apply input gain to the full frameCount (skip in full bypass mode).
            // Using frameCount (not polled) ensures gain ramp state stays correct
            // across callbacks, even when partial data was read.
            if processingMode != 0 {
                let targetInputGain = getTargetInputGain()
                applyGain(to: inputBufferMutablePointers, frameCount: frameCount,
                          currentGain: &inputGainLinear, targetGain: targetInputGain)
            }

            // Update input meters
            updateMeterStorage(storage: inputMeterStorage, rmsStorage: inputRmsStorage,
                               with: inputBufferPointers, frameCount: requestedCount)
            return requestedCount
        } else {
            // Ring buffer mode: read from AudioRingBuffer → outputReadBuffers (= processingBuffers)
            return readFromRingBuffers(frameCount: frameCount)
        }
    }

    /// Reads audio samples from ring buffers into the output read buffers.
    /// Called by provideFrames() in ring buffer mode.
    /// - Parameter frameCount: Number of frames to read.
    /// - Returns: The number of frames actually read (may be less if underrun).
    @inline(__always)
    private func readFromRingBuffers(frameCount: UInt32) -> Int {
        let count = Int(frameCount)
        var minRead = count

        for (index, ringBuffer) in ringBuffers.enumerated() {
            let read = ringBuffer.read(into: outputReadBuffers[index], count: count)
            minRead = min(minRead, read)
        }

        return minRead
    }

    // MARK: - Buffer Allocation

    /// Allocates a `Float` buffer of `capacity` samples aligned to 64 bytes.
    ///
    /// 64-byte alignment (one ARM64 cache line / two NEON 256-bit registers) lets
    /// vDSP and hand-written SIMD code read every element without a cross-alignment
    /// penalty.  The returned pointer MUST be freed with `free()`, NOT with
    /// Swift's `.deallocate()`.
    ///
    /// - Parameter capacity: Number of `Float` elements to allocate.
    /// - Returns: Zeroed, 64-byte-aligned pointer to `capacity` floats.
    private static func allocateSIMDAlignedBuffer(capacity: Int) -> UnsafeMutablePointer<Float> {
        let byteCount = capacity * MemoryLayout<Float>.size
        var rawPtr: UnsafeMutableRawPointer? = nil
        let result = posix_memalign(&rawPtr, 64, byteCount)
        precondition(result == 0, "posix_memalign(\(byteCount), align=64) failed: \(result)")
        let ptr = rawPtr!.assumingMemoryBound(to: Float.self)
        memset(ptr, 0, byteCount)
        return ptr
    }

    // MARK: - DC Offset Removal

    /// Applies the 0.5 Hz DC-blocking high-pass filter to every channel's processing buffer.
    ///
    /// Must be called from the audio render thread immediately after `provideFrames` returns
    /// a non-zero frame count, and **before** EQ or any gain stage.  The filter state is
    /// maintained across callbacks so the transient at stream start settles within ~2 seconds.
    ///
    /// - Parameter frameCount: Number of frames to process (must match the current render slice).
    @inline(__always)
    func applyDCBlock(frameCount: UInt32) {
        let count = Int(frameCount)
        for ch in 0 ..< Int(channelCount) {
            dcBlockers[ch].process(buffer: processingBuffers[ch], frameCount: count)
        }
    }

    // MARK: - Real-Time Thread Priority

    /// Elevates the calling (audio render) thread to the macOS Mach real-time scheduling class.
    ///
    /// The first call performs `thread_policy_set(THREAD_TIME_CONSTRAINT_POLICY)` and sends
    /// the send-right returned by `mach_thread_self()` back to the kernel.  Every subsequent
    /// call returns in a single relaxed atomic load — no kernel round-trip, no lock.
    ///
    /// Policy constants:
    /// - `period`      = 10 ms  — nominal callback interval at 512 frames / 48 kHz
    /// - `computation` =  5 ms  — CPU budget (50 % of period, generous for EQ + dynamics)
    /// - `constraint`  = 10 ms  — hard real-time deadline
    /// - `preemptible` =  1     — allow higher-priority threads (interrupts, etc.) to preempt
    ///
    /// Must be called from the audio render thread.
    @inline(__always)
    func applyRealtimePriorityIfNeeded() {
        guard hasAppliedRealtimePolicy.compareExchange(
            expected: 0, desired: 1, ordering: .relaxed
        ).exchanged else { return }

        // Convert nanoseconds → Mach absolute time units.
        // On Apple Silicon: numer = denom = 1 (1 ns = 1 unit).
        // On Intel:         numer = 1, denom = 3 (approximately).
        var tbInfo = mach_timebase_info_data_t()
        mach_timebase_info(&tbInfo)
        let toAbsoluteTime: (UInt64) -> UInt32 = { nanos in
            let result = nanos &* UInt64(tbInfo.denom) / UInt64(tbInfo.numer)
            return UInt32(min(result, UInt64(UInt32.max)))
        }

        var policy = thread_time_constraint_policy_data_t(
            period:      toAbsoluteTime(10_000_000),
            computation: toAbsoluteTime( 5_000_000),
            constraint:  toAbsoluteTime(10_000_000),
            preemptible: boolean_t(1)
        )

        let selfThread = mach_thread_self()
        // THREAD_TIME_CONSTRAINT_POLICY_COUNT is a sizeof()-based C macro that Swift cannot
        // import directly ("structure not supported").  Reproduce it using MemoryLayout,
        // which is identical to the macro's definition:
        //   sizeof(thread_time_constraint_policy_data_t) / sizeof(integer_t)
        let policyCount = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.size /
            MemoryLayout<integer_t>.size
        )

        withUnsafeMutablePointer(to: &policy) { policyPtr in
            _ = thread_policy_set(
                selfThread,
                thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                UnsafeMutableRawPointer(policyPtr).assumingMemoryBound(to: integer_t.self),
                policyCount
            )
        }
        // Release the send-right returned by mach_thread_self().
        mach_port_deallocate(mach_task_self_, selfThread)
    }

    /// Returns pointers to the processing buffers (immutable, for passing to render context).
    /// Points to either outputReadBuffers (ring buffer mode) or inputBuffers (direct capture).
    /// - Returns: Pre-computed array of immutable pointers to the active processing buffers.
    var outputBufferPointers: [UnsafePointer<Float>] {
        processingBufferPointers
    }

    // MARK: - Dynamics Processing API

    /// Processes audio in-place through the soft clipper and brickwall limiter.
    /// Must be called from the audio render thread only.
    @inline(__always)
    func processDynamics(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        dynamicsProcessor.process(bufferList: bufferList, frameCount: frameCount)
    }

    /// Updates dynamics parameters from the main thread.
    /// - Parameters:
    ///   - config: New dynamics configuration to apply atomically.
    ///   - sampleRate: Current pipeline sample rate (needed for time-constant recalculation).
    func updateDynamicsConfig(_ config: DynamicsConfig, sampleRate: Double) {
        dynamicsProcessor.applyConfig(config, sampleRate: sampleRate)
    }

    /// Processes all EQ layers on processing buffers in-place.
    /// Called from audio thread after provideFrames() fills the processing buffers.
    /// - Parameter frameCount: Number of frames to process.
    @inline(__always)
    func processEQ(frameCount: UInt32) {
        // Apply 4x oversampling before EQ if enabled
        if let oversampler = oversamplingProcessor {
            let upsampledFrameCount = frameCount * 4
            var upsampledBuffer = Array(repeating: 0.0, count: Int(upsampledFrameCount) * Int(channelCount))

            // Upsample each channel
            for ch in 0..<Int(channelCount) {
                let inputPtr = processingBuffers[ch]
                var inputArray = Array(repeating: 0.0, count: Int(frameCount))
                for i in 0..<Int(frameCount) {
                    inputArray[i] = inputPtr[i]
                }

                let outputPtr = UnsafeMutablePointer<Float>(mutating: upsampledBuffer[ch * Int(upsampledFrameCount)...])
                oversampler.upsample(input: [inputPtr], frameCount: Int(frameCount), output: outputPtr)
            }

            // Process EQ on upsampled data
            let upsampledPointers = (0..<Int(channelCount)).map { UnsafePointer<Float>(upsampledBuffer[$0 * Int(upsampledFrameCount)...]) }
            let upsampledMutablePointers = (0..<Int(channelCount)).map { UnsafeMutablePointer<Float>(mutating: upsampledBuffer[$0 * Int(upsampledFrameCount)...]) }

            // Process L channel through all layers in series
            for chain in leftEQChains {
                chain.applyPendingUpdates()
                chain.process(buffer: upsampledMutablePointers[0], frameCount: upsampledFrameCount)
            }

            // Process R channel through all layers in series (if stereo)
            if channelCount > 1 {
                for chain in rightEQChains {
                    chain.applyPendingUpdates()
                    chain.process(buffer: upsampledMutablePointers[1], frameCount: upsampledFrameCount)
                }
            }

            // Downsample back to original rate
            for ch in 0..<Int(channelCount) {
                let inputPtr = UnsafePointer<Float>(upsampledBuffer[ch * Int(upsampledFrameCount)...])
                let outputPtr = processingBuffers[ch]
                oversampler.downsample(input: inputPtr, frameCount: Int(frameCount), output: [outputPtr])
            }
        } else {
            // Process EQ without oversampling
            // Process L channel through all layers in series
            for chain in leftEQChains {
                chain.applyPendingUpdates()
                chain.process(buffer: processingBuffers[0], frameCount: frameCount)
            }

            // Process R channel through all layers in series (if stereo)
            if channelCount > 1 {
                for chain in rightEQChains {
                    chain.applyPendingUpdates()
                    chain.process(buffer: processingBuffers[1], frameCount: frameCount)
                }
            }
        }
    }

    /// Returns the latest per-channel meter snapshots in dBFS.
    func meterSnapshot() -> (input: [Float], output: [Float]) {
        let input = Array(UnsafeBufferPointer(start: inputMeterStorage, count: meterChannelCount))
        let output = Array(UnsafeBufferPointer(start: outputMeterStorage, count: meterChannelCount))
        return (input, output)
    }

    /// Returns the latest per-channel RMS meter snapshots in dBFS.
    func rmsSnapshot() -> (input: [Float], output: [Float]) {
        let input = Array(UnsafeBufferPointer(start: inputRmsStorage, count: meterChannelCount))
        let output = Array(UnsafeBufferPointer(start: outputRmsStorage, count: meterChannelCount))
        return (input, output)
    }

    func updateOutputMeters(from bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let channels = UnsafeMutableAudioBufferListPointer(bufferList)
        // Reuse pre-allocated array to avoid heap allocation on audio thread
        meterChannelPointers.removeAll(keepingCapacity: true)
        for buffer in channels {
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                meterChannelPointers.append(UnsafePointer(data))
            }
        }
        if meterChannelPointers.isEmpty {
            return
        }
        updateMeterStorage(storage: outputMeterStorage, rmsStorage: outputRmsStorage, with: meterChannelPointers, frameCount: Int(frameCount))
    }

    @inline(__always)
    func applyGain(
        to bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: UInt32,
        currentGain: inout Float,
        targetGain: Float
    ) {
        let channels = UnsafeMutableAudioBufferListPointer(bufferList)
        // Reuse pre-allocated array to avoid heap allocation on audio thread
        gainBuffers.removeAll(keepingCapacity: true)
        for buffer in channels {
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                gainBuffers.append(data)
            }
        }
        if gainBuffers.isEmpty {
            currentGain = targetGain
            return
        }
        applyGain(to: gainBuffers, frameCount: frameCount, currentGain: &currentGain, targetGain: targetGain)
    }

    private func updateMeterStorage(
        storage: UnsafeMutablePointer<Float>,
        rmsStorage: UnsafeMutablePointer<Float>,
        with channels: [UnsafePointer<Float>],
        frameCount: Int
    ) {
        // Skip all meter calculations when meters are disabled
        guard metersEnabledAtomic.load(ordering: .relaxed) != 0 else { return }

        // Assert that frameCount doesn't exceed pre-allocated buffer capacity.
        // CoreAudio guarantees frameCount <= maxFrameCount, but we validate for safety.
        // This catches any edge cases during development/testing.
        precondition(
            frameCount <= framesPerBuffer,
            "frameCount (\(frameCount)) exceeds framesPerBuffer (\(framesPerBuffer))"
        )

        guard frameCount > 0 else {
            for index in 0..<meterChannelCount {
                storage[index] = Self.silenceDB
                rmsStorage[index] = Self.silenceDB
            }
            return
        }

        for channel in 0..<meterChannelCount {
            guard !channels.isEmpty else {
                storage[channel] = Self.silenceDB
                rmsStorage[channel] = Self.silenceDB
                continue
            }

            let sourceIndex = min(channel, channels.count - 1)
            let buffer = channels[sourceIndex]
            var peak: Float = 0
            var sumSquares: Float = 0
            var frame = 0
            while frame < frameCount {
                let sample = abs(buffer[frame])
                peak = max(peak, sample)
                sumSquares += sample * sample
                frame += 1
            }
            let db = AudioMath.linearToDB(max(peak, 1e-7), silence: Self.silenceDB)
            let rms = sqrt(sumSquares / Float(frameCount))
            let rmsDb = AudioMath.linearToDB(max(rms, 1e-7), silence: Self.silenceDB)
            storage[channel] = db
            rmsStorage[channel] = rmsDb
        }
    }

    // MARK: - Utility


    /// Zeros out the given AudioBufferList.
    /// - Parameters:
    ///   - bufferList: The buffer list to zero.
    ///   - frameCount: Number of frames to zero.
    static func zeroFill(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in abl {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    /// Resets all ring buffers to empty state.
    /// - Warning: Only call when no audio is running.
    func resetRingBuffers() {
        for ringBuffer in ringBuffers {
            ringBuffer.reset()
        }
        inputMeterStorage.initialize(repeating: Self.silenceDB, count: meterChannelCount)
        outputMeterStorage.initialize(repeating: Self.silenceDB, count: meterChannelCount)
    }

    /// Returns diagnostic information about ring buffer state.
    func getDiagnostics() -> (availableToRead: [Int], underruns: [UInt64], overflows: [UInt64]) {
        let available = ringBuffers.map { $0.availableToRead() }
        let underruns = ringBuffers.map { $0.getUnderrunCount() }
        let overflows = ringBuffers.map { $0.getOverflowCount() }
        return (available, underruns, overflows)
    }

    // MARK: - RTA Audio Taps

    /// Pre-EQ mono ring buffer. `nil` = RTA not active. Written exclusively from the audio thread.
    nonisolated(unsafe) var rtaInputBuffer: LockFreeAudioRingBuffer? = nil

    /// Post-dynamics mono ring buffer. `nil` = RTA not active. Written exclusively from the audio thread.
    nonisolated(unsafe) var rtaOutputBuffer: LockFreeAudioRingBuffer? = nil

    /// Stereo goniometer engine. `nil` = goniometer not wired. Written exclusively from the audio thread.
    nonisolated(unsafe) var goniometerEngine: GoniometerBufferEngine? = nil

    /// Writes pre-EQ stereo audio (from processingBuffers) to the RTA input ring buffer.
    /// Call from the audio render thread immediately after `provideFrames()`.
    @inline(__always)
    func writeRTAInput(frameCount: Int) {
        guard let buf = rtaInputBuffer, frameCount > 0, channelCount >= 1 else { return }
        buf.writeStereoSamples(
            leftChannel:  processingBuffers[0],
            rightChannel: channelCount > 1 ? processingBuffers[1] : processingBuffers[0],
            frameCount: frameCount
        )
    }

    /// Writes pre-EQ stereo audio to the goniometer circular buffer.
    /// Call from the audio render thread alongside `writeRTAInput()`.
    @inline(__always)
    func writeGoniometer(frameCount: Int) {
        guard let eng = goniometerEngine, frameCount > 0, channelCount >= 1 else { return }
        eng.writeStereoInterleaved(
            left:   processingBuffers[0],
            right:  channelCount > 1 ? processingBuffers[1] : processingBuffers[0],
            frames: frameCount
        )
    }

    /// Writes post-dynamics stereo audio (from the HAL output buffer list) to the RTA output ring buffer.
    /// Call from the audio render thread immediately after `processDynamics()`.
    @inline(__always)
    func writeRTAOutput(from bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard let buf = rtaOutputBuffer, frameCount > 0 else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard !abl.isEmpty,
              let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let rightPtr = abl.count > 1
            ? abl[1].mData?.assumingMemoryBound(to: Float.self)
            : nil
        buf.writeStereoSamples(
            leftChannel:  leftPtr,
            rightChannel: rightPtr ?? leftPtr,
            frameCount: frameCount
        )
    }
}

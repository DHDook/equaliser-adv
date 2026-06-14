// AllPassChain.swift
// Cascaded all-pass biquad sections for mixed-phase phase correction.
// One instance per channel. Updated from the main thread via double-buffered
// coefficient staging, identical to EQChain.

import Atomics
import Foundation

/// A single all-pass biquad section with its per-sample state.
private struct AllPassSection {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0
    var a1: Float = 0, a2: Float = 0
    var w1: Float = 0, w2: Float = 0   // Direct-Form II transposed state
}

/// Cascaded all-pass IIR filter for group-delay correction.
/// Lock-free double-buffered coefficient update, audio-thread safe.
final class AllPassChain: @unchecked Sendable {

    // Maximum number of all-pass sections (one per biquad section across all bands).
    // Supports up to 32 bands × 8 sections (96 dB/oct HP/LP) = 256 sections.
    // In practice: 32 bands × ≤8 sections at the absolute maximum slope.
    private static let maxSections = 256

    // Pre-allocated flat storage — no heap allocation on the audio thread.
    private let activeStore:  UnsafeMutablePointer<AllPassSection>
    private let pendingStore: UnsafeMutablePointer<AllPassSection>
    nonisolated(unsafe) private var activeCount:  Int = 0
    private var pendingCount: Int = 0
    private let hasPending = ManagedAtomic<Bool>(false)

    init() {
        activeStore  = .allocate(capacity: Self.maxSections)
        activeStore.initialize(repeating: AllPassSection(), count: Self.maxSections)
        pendingStore = .allocate(capacity: Self.maxSections)
        pendingStore.initialize(repeating: AllPassSection(), count: Self.maxSections)
    }

    deinit {
        activeStore.deinitialize(count: Self.maxSections)
        activeStore.deallocate()
        pendingStore.deinitialize(count: Self.maxSections)
        pendingStore.deallocate()
    }

    // MARK: - Main Thread API

    /// Stages a new set of all-pass sections derived from the biquad band coefficients.
    /// Called from the main thread only.
    ///
    /// - Parameter sectionSets: One `[BiquadCoefficients]` array per active band.
    ///   Bypassed bands must be excluded by the caller.
    func stageSections(from sectionSets: [[BiquadCoefficients]]) {
        var count = 0
        for sections in sectionSets {
            for sec in sections {
                guard count < Self.maxSections else { break }
                pendingStore[count] = AllPassChain.allPassSection(from: sec)
                count += 1
            }
        }
        pendingCount = count
        hasPending.store(true, ordering: .releasing)
    }

    // MARK: - Audio Thread API

    /// Applies pending coefficient update if one is waiting.
    /// Call once per render cycle before `process()`.
    @inline(__always)
    func applyPendingUpdates() {
        guard hasPending.load(ordering: .acquiring) else { return }
        // Copy section data — no heap allocation, just a memcpy.
        let bytes = pendingCount * MemoryLayout<AllPassSection>.stride
        activeStore.withMemoryRebound(to: UInt8.self, capacity: bytes) { dst in
            pendingStore.withMemoryRebound(to: UInt8.self, capacity: bytes) { src in
                dst.assign(from: src, count: bytes)
            }
        }
        activeCount = pendingCount
        hasPending.store(false, ordering: .relaxed)
    }

    /// Processes `frameCount` samples in-place through all active all-pass sections.
    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: UInt32) {
        guard activeCount > 0 else { return }
        for i in 0..<activeCount {
            processSingleSection(sectionIdx: i, buffer: buffer, frameCount: frameCount)
        }
    }

    // MARK: - Private

    @inline(__always)
    private func processSingleSection(
        sectionIdx: Int,
        buffer: UnsafeMutablePointer<Float>,
        frameCount: UInt32
    ) {
        let b0 = activeStore[sectionIdx].b0
        let b1 = activeStore[sectionIdx].b1
        let b2 = activeStore[sectionIdx].b2
        let a1 = activeStore[sectionIdx].a1
        let a2 = activeStore[sectionIdx].a2
        var w1 = activeStore[sectionIdx].w1
        var w2 = activeStore[sectionIdx].w2

        // Direct-Form II Transposed
        for n in 0..<Int(frameCount) {
            let x = buffer[n]
            let y = b0 * x + w1
            w1 = b1 * x - a1 * y + w2
            w2 = b2 * x - a2 * y
            buffer[n] = y
        }
        activeStore[sectionIdx].w1 = w1
        activeStore[sectionIdx].w2 = w2
    }

    /// Constructs an all-pass biquad from a source biquad's denominator coefficients.
    ///
    /// For a 2nd-order section: H_AP(z) = (a2 + a1·z⁻¹ + 1·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²)
    /// For a 1st-order degenerate section (a2 == 0): H_AP(z) = (a1 + z⁻¹) / (1 + a1·z⁻¹)
    private static func allPassSection(from sec: BiquadCoefficients) -> AllPassSection {
        let isFirstOrder = abs(sec.a2) < 1e-12 && abs(sec.b2) < 1e-12
        if isFirstOrder {
            return AllPassSection(
                b0: Float(sec.a1),
                b1: 1.0,
                b2: 0.0,
                a1: Float(sec.a1),
                a2: 0.0
            )
        } else {
            return AllPassSection(
                b0: Float(sec.a2),
                b1: Float(sec.a1),
                b2: 1.0,
                a1: Float(sec.a1),
                a2: Float(sec.a2)
            )
        }
    }

    /// Clears processing state (call when mode is disabled).
    func reset() {
        for i in 0..<activeCount {
            activeStore[i].w1 = 0
            activeStore[i].w2 = 0
        }
    }
}

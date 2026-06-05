// DSPRNG.swift
// Lightweight deterministic PRNG for audio thread use

import Foundation

/// Lightweight deterministic pseudo-random number generator for audio thread use.
/// Uses a simple xorshift algorithm for speed and determinism.
final class DSPRNG: @unchecked Sendable {

    private var state: UInt64

    init(seed: UInt64 = 0) {
        self.state = seed == 0 ? 0x5EED5EED5EED5EED : seed
    }

    /// Generates a random Float in the range [0, 1).
    @inline(__always)
    func nextFloat() -> Float {
        // Use xorshift64* for fast, good quality random numbers
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let x = state &* 0x2545F4914F6CDD1D
        return Float(x) / Float(UInt64.max)
    }

    /// Generates a random Float in the specified range.
    /// - Parameter range: The range for the random value
    @inline(__always)
    func nextFloat(in range: ClosedRange<Float>) -> Float {
        let normalized = nextFloat()
        return range.lowerBound + normalized * (range.upperBound - range.lowerBound)
    }

    /// Resets the PRNG to its initial seed.
    func reset(seed: UInt64 = 0) {
        state = seed == 0 ? 0x5EED5EED5EED5EED : seed
    }
}

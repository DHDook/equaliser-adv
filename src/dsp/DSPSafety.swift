// DSPSafety.swift
// Global DSP safety layer for NaN/Inf detection and recovery

import Foundation
import AudioToolbox
import CoreAudio
import os.log

/// Global DSP safety utilities for detecting and recovering from invalid floating-point values.
enum DSPSafety {

    private static let logger = Logger(subsystem: "net.knage.equaliser", category: "DSPSafety")
    nonisolated(unsafe) private static var nanLogged = false
    nonisolated(unsafe) private static var infLogged = false

    /// Sanitizes a floating-point sample, replacing NaN/Inf with zero.
    /// - Parameter value: The sample value to sanitize
    /// - Returns: The sanitized value (zero if NaN/Inf, otherwise unchanged)
    @inline(__always)
    static func sanitize(_ value: Float) -> Float {
        if value.isNaN {
            logNaN()
            return 0.0
        }
        if value.isInfinite {
            logInf()
            return 0.0
        }
        return value
    }

    /// Sanitizes an array of floating-point samples in-place.
    /// - Parameter buffer: Pointer to the buffer to sanitize
    /// - Parameter count: Number of samples to process
    @inline(__always)
    static func sanitizeBuffer(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            let value = buffer[i]
            if value.isNaN {
                logNaN()
                buffer[i] = 0.0
            } else if value.isInfinite {
                logInf()
                buffer[i] = 0.0
            }
        }
    }

    /// Sanitizes an AudioBufferList in-place.
    /// - Parameter bufferList: Pointer to the AudioBufferList to sanitize
    @inline(__always)
    static func sanitizeAudioBufferList(_ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        for bufferIndex in 0..<abl.count {
            guard let mData = abl[bufferIndex].mData else { continue }
            let frameCount = Int(abl[bufferIndex].mDataByteSize / UInt32(MemoryLayout<Float>.size))
            let buffer = mData.bindMemory(to: Float.self, capacity: frameCount)
            sanitizeBuffer(buffer, count: frameCount)
        }
    }

    /// Checks if a value is valid (not NaN or Inf).
    /// - Parameter value: The value to check
    /// - Returns: True if the value is valid, false otherwise
    @inline(__always)
    static func isValid(_ value: Float) -> Bool {
        value.isFinite
    }

    /// Clamps a value to a safe range, replacing NaN/Inf with the clamp bounds.
    /// - Parameters:
    ///   - value: The value to clamp
    ///   - min: Minimum allowed value
    ///   - max: Maximum allowed value
    /// - Returns: The clamped value
    @inline(__always)
    static func clampSafe(_ value: Float, min: Float, max: Float) -> Float {
        if value.isNaN || value.isInfinite {
            return (min + max) / 2.0
        }
        return Swift.max(min, Swift.min(max, value))
    }

    // MARK: - Private Logging

    private static func logNaN() {
        #if DEBUG
        if !nanLogged {
            logger.error("NaN detected in DSP pipeline - replaced with zero")
            nanLogged = true
        }
        #endif
    }

    private static func logInf() {
        #if DEBUG
        if !infLogged {
            logger.error("Inf detected in DSP pipeline - replaced with zero")
            infLogged = true
        }
        #endif
    }

    /// Resets the logging flags (useful for testing).
    static func resetLoggingFlags() {
        nanLogged = false
        infLogged = false
    }
}

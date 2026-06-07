//
//  ConvolutionEngine.swift
//  Equaliser
//
//  Uniformly-partitioned FFT convolution engine.
//

import Foundation
import Accelerate

/// Uniformly-partitioned FFT convolution engine for FIR impulse response processing.
final class ConvolutionEngine {
    
    private var leftIR: [Float] = []
    private var rightIR: [Float] = []
    private var enabled: Bool = false
    
    init() {}
    
    /// Updates the impulse response for both channels.
    func updateIR(left: [Float], right: [Float]) {
        leftIR = left
        rightIR = right
    }
    
    /// Enables or disables convolution processing.
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }
    
    /// Processes a single audio frame through the convolution engine.
    /// Returns the processed samples.
    func process(left: Float, right: Float) -> (left: Float, right: Float) {
        guard enabled else { return (left, right) }
        
        // TODO: Implement uniformly-partitioned FFT convolution
        // For now, pass through unchanged
        return (left, right)
    }
}

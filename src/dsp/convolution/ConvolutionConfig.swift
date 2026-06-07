//
//  ConvolutionConfig.swift
//  Equaliser
//
//  Convolution engine configuration.
//

import Foundation

/// Configuration for the FIR convolution engine.
struct ConvolutionConfig: Codable, Equatable {
    /// Whether convolution processing is enabled.
    var enabled: Bool = false
    
    /// Display name of the loaded impulse response file.
    var irDisplayName: String? = nil
    
    /// Security-scoped bookmark for the IR file URL.
    var irBookmark: Data? = nil
}

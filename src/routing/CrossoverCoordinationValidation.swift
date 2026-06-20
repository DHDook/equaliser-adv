// CrossoverCoordinationValidation.swift
// Bass management / crossover coordination validation.
// Detects and warns when bass management and active crossover frequencies
// are set in a way that would produce incorrect results.

import Foundation

struct CrossoverCoordinationWarning: Equatable, Sendable {
    enum WarningType: Equatable {
        /// Active crossover lower frequency is BELOW bass management HP frequency.
        /// The woofer output will be band-rejected, not band-passed.
        case wooferBandReject(crossoverHz: Float, bassManagementHz: Float)
        /// Active crossover lower frequency equals bass management HP frequency exactly.
        /// This is valid but may cause a 6 dB dip at the crossover point.
        case wooferFrequencyOverlap(crossoverHz: Float, bassManagementHz: Float)
        /// Bass management is enabled but no subMono output channel is defined.
        case bassManagementEnabledButNoSubOutput
    }
    var type: WarningType
    var suggestion: String
}

/// Validates coordination between active crossover and bass management settings.
/// Call whenever ActiveCrossoverConfig or BassManagementConfig changes.
func validateCrossoverCoordination(
    crossover: ActiveCrossoverConfig,
    bassManagement: BassManagementConfig,
    outputChannelMatrix: OutputChannelMatrixConfig
) -> [CrossoverCoordinationWarning] {
    var warnings: [CrossoverCoordinationWarning] = []

    // Rule 1: Check crossover vs bass management frequency coordination
    if crossover.isEnabled && crossover.bandCount != .fullRange && bassManagement.enabled {
        let lowerCrossoverHz = crossover.lowerCrossoverHz
        if lowerCrossoverHz < bassManagement.crossoverHz {
            warnings.append(CrossoverCoordinationWarning(
                type: .wooferBandReject(crossoverHz: lowerCrossoverHz, bassManagementHz: bassManagement.crossoverHz),
                suggestion: "Set the active crossover's lower frequency above the bass management crossover frequency (\(bassManagement.crossoverHz) Hz), or disable bass management."
            ))
        } else if abs(lowerCrossoverHz - bassManagement.crossoverHz) < 10 {
            warnings.append(CrossoverCoordinationWarning(
                type: .wooferFrequencyOverlap(crossoverHz: lowerCrossoverHz, bassManagementHz: bassManagement.crossoverHz),
                suggestion: "The active crossover lower frequency is very close to the bass management crossover. Consider separating them by at least 10 Hz."
            ))
        }
    }

    // Rule 2: Check if bass management is enabled but no sub output channel
    if bassManagement.enabled {
        let hasSubOutput = outputChannelMatrix.channels.contains { $0.source == .subMono }
        if !hasSubOutput {
            warnings.append(CrossoverCoordinationWarning(
                type: .bassManagementEnabledButNoSubOutput,
                suggestion: "Bass management is enabled but no output channel is assigned to the subwoofer signal. Add a Sub output channel."
            ))
        }
    }

    return warnings
}

// SpeakerSystemPreset.swift
// Complete speaker system configuration snapshot.
// Contains everything needed to fully configure the output channel matrix
// and active crossover for a specific set of speakers and amplifiers.

import Foundation

/// A complete speaker system configuration snapshot.
/// Contains everything needed to fully configure the output channel matrix
/// and active crossover for a specific set of speakers and amplifiers.
struct SpeakerSystemPreset: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    /// Complete active crossover configuration.
    var activeCrossoverConfig: ActiveCrossoverConfig

    /// Per-output channel configurations (EQ, trim, delay, polarity, limiter,
    /// group delay all-pass, correction IR paths).
    /// Device UIDs and channel indices are stored but marked as "topology hints" —
    /// the user may need to reassign to different physical channels on a new system.
    var outputChannels: [OutputChannelConfig]

    /// The topology type this preset was created for, for display and validation.
    var topologyHint: String   // e.g. "Vertical Bi-Amp", "Horizontal Tri-Amp"

    /// Optional description / notes.
    var notes: String = ""
}

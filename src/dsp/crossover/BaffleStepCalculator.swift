// BaffleStepCalculator.swift
// Baffle step compensation calculator.
// Derives the correct shelving filter frequency and gain for baffle step
// compensation from physical cabinet dimensions.

import Foundation

enum BaffleStepCalculator {

    struct BaffleGeometry: Sendable {
        /// Effective baffle width in metres.
        /// For a rectangular baffle, use the narrower dimension.
        /// For a circular baffle (open baffle), use the diameter.
        var widthMetres: Float

        /// Distance from the driver centre to the nearest baffle edge (metres).
        /// When nil, estimated as widthMetres / 2 (centred driver assumption).
        var driverToEdgeMetres: Float?

        /// Speed of sound in m/s. Default 343 m/s at 20°C.
        var speedOfSoundMs: Float = 343.0
    }

    struct BaffleStepResult: Sendable {
        /// Transition frequency in Hz below which the step begins.
        /// Computed as: f = speedOfSound / (2π × driverToEdge)
        var transitionHz: Float

        /// Recommended shelf gain in dB. Approximately +6 dB for a full baffle step.
        /// May be less for drivers that are partially open-baffled or for very wide baffles.
        var recommendedGainDB: Float

        /// Recommended Q for the low shelf filter. Default 0.707 (Butterworth shelf).
        var recommendedQ: Float

        /// Human-readable description of the result.
        var description: String
    }

    /// Computes baffle step compensation parameters from physical geometry.
    ///
    /// Algorithm:
    ///   1. Effective driver-to-edge distance = driverToEdgeMetres ?? widthMetres / 2
    ///   2. Transition frequency = speedOfSound / (2π × driverToEdge)
    ///      This is where the baffle step begins (–3 dB point of the step response).
    ///   3. Full step magnitude = 6.02 dB (3-space to 2-space, exact).
    ///      For real cabinets with rounded edges or cloth grilles, 4–5 dB is more typical.
    ///      Return 6.0 dB as the theoretical value; note in description.
    ///   4. Shelf frequency for EQ: set at transitionHz / 1.5 to place the
    ///      shelf corner at the –3 dB point of the step response.
    ///   5. Recommended Q = 0.707 (Butterworth shelf) for a smooth transition.
    ///
    /// - Parameter geometry: Physical baffle dimensions.
    /// - Returns: Computed baffle step compensation parameters.
    static func computeCompensation(geometry: BaffleGeometry) -> BaffleStepResult {
        // Step 1: Effective driver-to-edge distance
        let driverToEdge = geometry.driverToEdgeMetres ?? (geometry.widthMetres / 2.0)

        // Step 2: Transition frequency (–3 dB point)
        let transitionHz = geometry.speedOfSoundMs / (2.0 * Float.pi * driverToEdge)

        // Step 3: Full step magnitude (theoretical)
        let recommendedGainDB: Float = 6.0

        // Step 4: Shelf frequency (transitionHz / 1.5)
        let shelfFrequency = transitionHz / 1.5

        // Step 5: Recommended Q
        let recommendedQ: Float = 0.707

        // Description
        let description = """
        Baffle step transition at \(String(format: "%.1f", transitionHz)) Hz.
        Recommended low shelf: \(String(format: "%.1f", shelfFrequency)) Hz, +\(String(format: "%.1f", recommendedGainDB)) dB, Q \(String(format: "%.2f", recommendedQ)).
        This compensates for the +6 dB rise above the transition frequency caused by baffle diffraction.
        Real cabinets with rounded edges or cloth grilles may require less gain (4–5 dB).
        """

        return BaffleStepResult(
            transitionHz: transitionHz,
            recommendedGainDB: recommendedGainDB,
            recommendedQ: recommendedQ,
            description: description
        )
    }
}

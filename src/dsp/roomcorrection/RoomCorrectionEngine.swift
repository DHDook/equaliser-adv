// RoomCorrectionEngine.swift — static greedy parametric band fitting.
// Main thread only. Pure function — no state, no allocation constraints.
import Foundation

enum RoomCorrectionEngine {

    static let maxCorrectionBands:  Int   = 20
    static let maxCorrectionGainDB: Float = 12.0
    static let stopResidualDB:      Float = 0.5

    /// Fits parametric EQ bands to the inverse of (measured − target).
    static func fitBands(
        measured: [(frequency: Double, gainDB: Double)],
        target:   [(frequency: Double, gainDB: Double)],
        sampleRate: Double,
        maxBands: Int = maxCorrectionBands
    ) -> [EQBandConfiguration] {

        guard !measured.isEmpty else { return [] }
        let N = 1000
        let fGrid = (0..<N).map { 20.0 * pow(1000.0, Double($0) / Double(N - 1)) }

        var residual = fGrid.map { f in
            interpolateLog(curve: target, atHz: f) - interpolateLog(curve: measured, atHz: f)
        }

        var bands = [EQBandConfiguration]()

        for _ in 0..<maxBands {
            guard let peakIdx = residual.indices.max(by: { abs(residual[$0]) < abs(residual[$1]) })
            else { break }
            let peakMag = abs(residual[peakIdx])
            guard peakMag >= Double(stopResidualDB) else { break }

            let peakHz  = fGrid[peakIdx]
            let gainDB  = Float(max(-Double(maxCorrectionGainDB),
                                    min(Double(maxCorrectionGainDB), residual[peakIdx])))

            let halfPwr = peakMag * 0.7071
            var lo = peakIdx; while lo > 0     && abs(residual[lo]) > halfPwr { lo -= 1 }
            var hi = peakIdx; while hi < N - 1 && abs(residual[hi]) > halfPwr { hi += 1 }
            let bwHz = fGrid[hi] - fGrid[lo]
            let q    = Float(max(0.4, min(8.0, peakHz / max(bwHz, 1.0))))

            let band = EQBandConfiguration(
                frequency: Float(peakHz),
                q: q,
                gain: gainDB,
                filterType: .parametric,
                bypass: false,
                slope: .db12
            )
            bands.append(band)

            let designRate = BiquadMath.designSampleRate(actualRate: sampleRate,
                                                          coefficientDecouplingEnabled: true)
            let coeffs = BiquadMath.calculateCoefficients(
                type: .parametric, sampleRate: designRate,
                frequency: peakHz, q: Double(q), gain: Double(gainDB))
            for k in 0..<N {
                let f = fGrid[k]; let w = 2.0 * Double.pi * f / sampleRate
                let cr = cos(w); let sr = sin(w)
                let cr2 = cos(2*w); let sr2 = sin(2*w)
                let nR = coeffs.b0 + coeffs.b1*cr + coeffs.b2*cr2
                let nI = coeffs.b1*sr + coeffs.b2*sr2
                let dR = 1.0 + coeffs.a1*cr + coeffs.a2*cr2
                let dI = coeffs.a1*sr + coeffs.a2*sr2
                let denom = dR*dR + dI*dI
                if denom > 1e-30 {
                    residual[k] -= 20.0 * log10(max(1e-9, sqrt((nR*nR+nI*nI)/denom)))
                }
            }
        }
        return bands
    }

    private static func interpolateLog(
        curve: [(frequency: Double, gainDB: Double)], atHz f: Double
    ) -> Double {
        guard curve.count > 1 else { return curve.first?.gainDB ?? 0 }
        if f <= curve.first!.frequency { return curve.first!.gainDB }
        if f >= curve.last!.frequency  { return curve.last!.gainDB  }
        for i in 0..<(curve.count - 1) {
            let lo = curve[i], hi = curve[i+1]
            if f >= lo.frequency && f <= hi.frequency {
                let t = log(f / lo.frequency) / log(hi.frequency / lo.frequency)
                return lo.gainDB + t * (hi.gainDB - lo.gainDB)
            }
        }
        return 0
    }
}

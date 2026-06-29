// CamillaDSPExporterTests.swift
import XCTest
@testable import Equaliser

final class CamillaDSPExporterTests: XCTestCase {

    // MARK: - Top-level YAML structure

    func testExport_ContainsAllTopLevelSections() {
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig())
        XCTAssertTrue(yaml.contains("devices:"),  "YAML must contain 'devices:' section")
        XCTAssertTrue(yaml.contains("filters:"),  "YAML must contain 'filters:' section")
        XCTAssertTrue(yaml.contains("mixers:"),   "YAML must contain 'mixers:' section")
        XCTAssertTrue(yaml.contains("pipeline:"), "YAML must contain 'pipeline:' section")
    }

    func testExport_SampleRateInDevicesSection() {
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(sampleRate: 96000))
        XCTAssertTrue(yaml.contains("samplerate: 96000"),
            "Devices section must include the correct sample rate")
    }

    func testExport_CaptureDeviceIsNotchSixty() {
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig())
        XCTAssertTrue(yaml.contains("Notch Sixty"), "Capture device must be 'Notch Sixty'")
    }

    func testExport_ProducesNonEmptyString() {
        XCTAssertFalse(CamillaDSPExporter.exportToYAML(minimalConfig()).isEmpty)
    }

    // MARK: - EQ bands

    func testExport_PeakingBand_UsesCorrectCamillaDSPType() {
        let band = EQBandConfiguration(frequency: 1000, q: 1.41, gain: -3.0,
                                        filterType: .parametric, bypass: false)
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(leftEQBands: [band]))
        XCTAssertTrue(yaml.contains("type: Peaking"), "Parametric band must map to 'Peaking'")
        XCTAssertTrue(yaml.contains("freq: 1000.0"))
        XCTAssertTrue(yaml.contains("gain: -3.00"))
        XCTAssertTrue(yaml.contains("q: 1.4100"))
    }

    func testExport_BypassedBand_NotIncluded() {
        let band = EQBandConfiguration(frequency: 1000, q: 1.41, gain: -3.0,
                                        filterType: .parametric, bypass: true)
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(leftEQBands: [band]))
        XCTAssertFalse(yaml.contains("eq_L_0"),
            "Bypassed band must not appear in the YAML filter dictionary")
    }

    func testExport_AllIIRFilterTypes_MapCorrectly() {
        let typeMappings: [(FilterType, String)] = [
            (.parametric, "Peaking"),
            (.lowShelf,   "Lowshelf"),
            (.highShelf,  "Highshelf"),
            (.lowPass,    "Lowpass"),
            (.highPass,   "Highpass"),
            (.bandPass,   "Bandpass"),
            (.notch,      "Bandstop"),
            (.allPass,    "Allpass")
        ]
        for (filterType, expectedStr) in typeMappings {
            let band = EQBandConfiguration(frequency: 1000, q: 1.0, gain: 0,
                                            filterType: filterType, bypass: false)
            let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(leftEQBands: [band]))
            XCTAssertTrue(yaml.contains("type: \(expectedStr)"),
                "FilterType.\(filterType) must map to '\(expectedStr)'")
        }
    }

    // MARK: - FIR band

    func testExport_FIRBand_ExportedAsConvFilter() {
        var band = EQBandConfiguration(frequency: 1000, q: 1.0, gain: 0,
                                        filterType: .fir, bypass: false)
        band.firKernelLeft = [1.0, 0.5, 0.25]
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(leftEQBands: [band]))
        XCTAssertTrue(yaml.contains("type: Conv"), "FIR band must be exported as Conv filter")
        XCTAssertTrue(yaml.contains("type: Values"), "Conv filter must use 'Values' type")
        XCTAssertTrue(yaml.contains("1.00000000"), "Kernel values must appear in the YAML")
    }

    func testExport_FIRBand_WithNilKernel_Omitted() {
        let band = EQBandConfiguration(frequency: 1000, q: 1.0, gain: 0,
                                        filterType: .fir, bypass: false)
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(leftEQBands: [band]))
        XCTAssertFalse(yaml.contains("type: Conv"),
            "FIR band with nil kernel must be omitted from export")
    }

    // MARK: - Crossover

    func testExport_Crossover_LR4_ProducesBiquadCombo() {
        var xo = ActiveCrossoverConfig()
        xo.isEnabled = true
        xo.bandCount = .biAmp
        xo.lowerPoint.frequency = 300
        xo.lowerPoint.slope = .db24
        xo.lowerPoint.filterType = .linkwitzRiley
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(activeCrossover: xo))
        XCTAssertTrue(yaml.contains("type: BiquadCombo"), "Crossover must use BiquadCombo")
        XCTAssertTrue(yaml.contains("LinkwitzRileyLowpass"), "LP must be LinkwitzRileyLowpass")
        XCTAssertTrue(yaml.contains("LinkwitzRileyHighpass"), "HP must be LinkwitzRileyHighpass")
        XCTAssertTrue(yaml.contains("order: 4"), "LR24 must export as order: 4")
        XCTAssertTrue(yaml.contains("freq: 300.0"))
    }

    func testExport_Crossover_Disabled_NoBiquadCombo() {
        var xo = ActiveCrossoverConfig(); xo.isEnabled = false
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(activeCrossover: xo))
        XCTAssertFalse(yaml.contains("BiquadCombo"),
            "Disabled crossover must not produce BiquadCombo entries")
    }

    func testExport_FilterSlopeToOrder_AllCases() {
        // Spot-check a few: db12→2, db24→4, db48→8, db96→16
        let cases: [(FilterSlope, Int)] = [(.db12, 2), (.db24, 4), (.db48, 8), (.db96, 16)]
        for (slope, expectedOrder) in cases {
            var xo = ActiveCrossoverConfig()
            xo.isEnabled = true
            xo.bandCount = .biAmp
            xo.lowerPoint.slope = slope
            let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(activeCrossover: xo))
            XCTAssertTrue(yaml.contains("order: \(expectedOrder)"),
                "\(slope) must produce order: \(expectedOrder)")
        }
    }

    // MARK: - Per-channel delay and gain

    func testExport_ChannelDelay_AppearsInFiltersAndPipeline() {
        var ch = makeChannel(); ch.delayMs = 2.5
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(outputMatrix: matrix(ch)))
        XCTAssertTrue(yaml.contains("ch0_delay"), "Delay filter must appear in YAML")
        XCTAssertTrue(yaml.contains("delay: 2.5000"), "Delay value must be correct")
        XCTAssertTrue(yaml.contains("unit: ms"), "Delay unit must be ms")
    }

    func testExport_ChannelGainTrim_AppearsInFilters() {
        var ch = makeChannel(); ch.gainTrimDB = -3.5
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(outputMatrix: matrix(ch)))
        XCTAssertTrue(yaml.contains("ch0_gain"), "Gain trim filter must appear in YAML")
        XCTAssertTrue(yaml.contains("gain: -3.50"), "Gain trim value must be correct")
    }

    func testExport_PolarityInversion_InvertedTrue() {
        var ch = makeChannel(); ch.polarityInverted = true
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(outputMatrix: matrix(ch)))
        XCTAssertTrue(yaml.contains("inverted: true"),
            "Polarity inversion must set inverted: true")
    }

    // MARK: - All-pass group delay correction

    func testExport_AllPassCoefficients_ExportedAsRawBiquad() {
        var ch = makeChannel()
        ch.groupDelayAllPassCoefficients = [
            BiquadCoefficients(b0: 0.9, b1: -1.8, b2: 0.9, a1: -1.8, a2: 0.81)
        ]
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(outputMatrix: matrix(ch)))
        XCTAssertTrue(yaml.contains("ch0_ap0"), "All-pass section must appear in YAML")
        XCTAssertTrue(yaml.contains("type: Raw"), "All-pass must use Raw biquad type")
        XCTAssertTrue(yaml.contains("a1:"), "Raw biquad must include a1 coefficient")
    }

    // MARK: - Mixer section

    func testExport_MixerSection_ChannelCountMatchesOutputMatrix() {
        var ch1 = makeChannel(source: .mainsLeftLow)
        var ch2 = makeChannel(source: .mainsLeftHigh)
        var m = OutputChannelMatrixConfig(isEnabled: true, channels: [ch1, ch2])
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(outputMatrix: m))
        XCTAssertTrue(yaml.contains("out: 2"), "Mixer output count must match enabled channels")
    }

    func testExport_NoOutputMatrix_UsesStereoPassthrough() {
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig(outputMatrix: nil))
        XCTAssertTrue(yaml.contains("stereo_passthrough"),
            "Missing output matrix must produce stereo_passthrough mixer")
    }

    // MARK: - Pipeline ordering

    func testExport_Pipeline_EQBeforeCrossoverBeforeMixer() {
        let band = EQBandConfiguration(frequency: 1000, q: 1.41, gain: -3.0,
                                        filterType: .parametric, bypass: false)
        var xo = ActiveCrossoverConfig(); xo.isEnabled = true; xo.bandCount = .biAmp
        let yaml = CamillaDSPExporter.exportToYAML(
            minimalConfig(leftEQBands: [band], activeCrossover: xo))

        guard let eqRange    = yaml.range(of: "eq_L_0"),
              let xoRange    = yaml.range(of: "xo_lower_LP"),
              let mixerRange = yaml.range(of: "type: Mixer") else {
            XCTFail("Pipeline sections eq_L_0, xo_lower_LP, type: Mixer must all be present")
            return
        }
        XCTAssertLessThan(eqRange.lowerBound, xoRange.lowerBound,
            "EQ must appear before crossover in pipeline")
        XCTAssertLessThan(xoRange.lowerBound, mixerRange.lowerBound,
            "Crossover must appear before mixer in pipeline")
    }

    func testExport_NoTrailingWhitespace() {
        let yaml = CamillaDSPExporter.exportToYAML(minimalConfig())
        for line in yaml.components(separatedBy: "\n") {
            XCTAssertEqual(line, line.trimmingCharacters(in: .init(charactersIn: " \t")),
                "Line must not have trailing whitespace: '\(line)'")
        }
    }

    // MARK: - Helpers

    private func minimalConfig(
        sampleRate: Int = 48000,
        leftEQBands: [EQBandConfiguration] = [],
        rightEQBands: [EQBandConfiguration] = [],
        roomCorrectionBands: [EQBandConfiguration] = [],
        activeCrossover: ActiveCrossoverConfig? = nil,
        outputMatrix: OutputChannelMatrixConfig? = nil
    ) -> CamillaDSPExportConfig {
        CamillaDSPExportConfig(
            sampleRate: sampleRate,
            chunkSize: 1024,
            captureDeviceName: "Notch Sixty",
            playbackDeviceName: "Test Output",
            leftEQBands: leftEQBands,
            rightEQBands: rightEQBands,
            roomCorrectionBands: roomCorrectionBands,
            activeCrossover: activeCrossover,
            outputMatrix: outputMatrix,
            bassManagementCrossoverHz: nil,
            bassManagementSlope: nil
        )
    }

    private func makeChannel(source: SignalSource = .mainsLeft) -> OutputChannelConfig {
        OutputChannelConfig(source: source, isEnabled: true)
    }

    private func matrix(_ ch: OutputChannelConfig) -> OutputChannelMatrixConfig {
        OutputChannelMatrixConfig(isEnabled: true, channels: [ch])
    }
}

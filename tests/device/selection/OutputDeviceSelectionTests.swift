import XCTest
@testable import Equaliser

private let kAudioDeviceTransportTypeBuiltIn: UInt32 = 0x626C746E
private let kAudioDeviceTransportTypeUSB: UInt32 = 0x75736220
private let kAudioDeviceTransportTypeVirtual: UInt32 = 0x76697274

final class OutputDeviceSelectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeDevice(uid: String, name: String = "Device", transport: UInt32 = kAudioDeviceTransportTypeBuiltIn) -> AudioDevice {
        AudioDevice(id: 1, uid: uid, name: name, transportType: transport)
    }

    private func makeDriverDevice(uid: String = "Equaliser-Virtual") -> AudioDevice {
        AudioDevice(id: 99, uid: uid, name: "Equaliser", transportType: kAudioDeviceTransportTypeVirtual)
    }

    // MARK: - preserveCurrent

    func testDetermine_currentSelectedValid_preservesCurrent() {
        let devices = [
            makeDevice(uid: "speakers", name: "Speakers"),
            makeDevice(uid: "headphones", name: "Headphones")
        ]

        let result = OutputDeviceSelection.determine(
            currentSelected: "speakers",
            macDefault: "headphones",
            availableDevices: devices
        )

        XCTAssertEqual(result, .preserveCurrent("speakers"))
    }

    func testDetermine_currentSelectedIsDriver_doesNotPreserve() {
        let devices = [
            makeDriverDevice(),
            makeDevice(uid: "speakers", name: "Speakers")
        ]

        let result = OutputDeviceSelection.determine(
            currentSelected: "Equaliser-Virtual",
            macDefault: "speakers",
            availableDevices: devices
        )

        XCTAssertEqual(result, .useMacDefault("speakers"))
    }

    // MARK: - useMacDefault

    func testDetermine_noCurrentSelected_usesMacDefault() {
        let devices = [
            makeDevice(uid: "speakers", name: "Speakers")
        ]

        let result = OutputDeviceSelection.determine(
            currentSelected: nil,
            macDefault: "speakers",
            availableDevices: devices
        )

        XCTAssertEqual(result, .useMacDefault("speakers"))
    }

    func testDetermine_currentNotInList_usesMacDefault() {
        let devices = [
            makeDevice(uid: "speakers", name: "Speakers")
        ]

        let result = OutputDeviceSelection.determine(
            currentSelected: "removed-device",
            macDefault: "speakers",
            availableDevices: devices
        )

        XCTAssertEqual(result, .useMacDefault("speakers"))
    }

    func testDetermine_macDefaultIsDriver_usesFallback() {
        let devices = [
            makeDriverDevice()
        ]

        let result = OutputDeviceSelection.determine(
            currentSelected: nil,
            macDefault: "Equaliser-Virtual",
            availableDevices: devices
        )

        XCTAssertEqual(result, .useFallback)
    }

    // MARK: - useFallback

    func testDetermine_noValidDevices_usesFallback() {
        let devices: [AudioDevice] = []

        let result = OutputDeviceSelection.determine(
            currentSelected: nil,
            macDefault: nil,
            availableDevices: devices
        )

        XCTAssertEqual(result, .useFallback)
    }

    func testDetermine_bothNilWithDevices_usesFallback() {
        let devices = [
            makeDevice(uid: "speakers", name: "Speakers")
        ]

        let result = OutputDeviceSelection.determine(
            currentSelected: nil,
            macDefault: nil,
            availableDevices: devices
        )

        XCTAssertEqual(result, .useFallback)
    }

    func testDetermine_macDefaultNotInList_usesFallback() {
        let devices = [
            makeDevice(uid: "speakers", name: "Speakers")
        ]

        let result = OutputDeviceSelection.determine(
            currentSelected: nil,
            macDefault: "removed-device",
            availableDevices: devices
        )

        XCTAssertEqual(result, .useFallback)
    }

    // MARK: - Equatable

    func testOutputDeviceSelection_equatable() {
        XCTAssertEqual(OutputDeviceSelection.preserveCurrent("a"), OutputDeviceSelection.preserveCurrent("a"))
        XCTAssertNotEqual(OutputDeviceSelection.preserveCurrent("a"), OutputDeviceSelection.preserveCurrent("b"))
        XCTAssertEqual(OutputDeviceSelection.useMacDefault("x"), OutputDeviceSelection.useMacDefault("x"))
        XCTAssertEqual(OutputDeviceSelection.useFallback, OutputDeviceSelection.useFallback)
        XCTAssertNotEqual(OutputDeviceSelection.useFallback, OutputDeviceSelection.useMacDefault("x"))
    }
}

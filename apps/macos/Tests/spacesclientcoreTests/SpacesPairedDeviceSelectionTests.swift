import Foundation
import XCTest

@testable import spacesclientcore

final class SpacesPairedDeviceSelectionTests: XCTestCase {
    func testResolvesExactIDBeforeNameAndUniqueNameCaseInsensitively() throws {
        let database = try makeDatabase(devices: [
            device(id: "device-aaa", name: "Build Box"), device(id: "device-bbb", name: "device-aaa"), device(id: "device-ccc", name: "GPU Rig"),
        ])

        // An exact ID match wins even when another device uses that string as its name.
        XCTAssertEqual(try SpacesPairedDeviceSelection.resolve("device-aaa", database: database).id, "device-aaa")
        XCTAssertEqual(try SpacesPairedDeviceSelection.resolve("gpu rig", database: database).id, "device-ccc")
        XCTAssertEqual(try SpacesPairedDeviceSelection.resolve(" Build Box ", database: database).id, "device-aaa")
    }

    func testAmbiguousNameListsCandidates() throws {
        let database = try makeDatabase(devices: [device(id: "device-one", name: "Linux Box"), device(id: "device-two", name: "linux box")])

        XCTAssertThrowsError(try SpacesPairedDeviceSelection.resolve("Linux Box", database: database)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.localizedStandardContains("matches multiple"))
            XCTAssertTrue(message.contains("device-one"))
            XCTAssertTrue(message.contains("device-two"))
        }
    }

    func testUnknownSelectorListsPairedDevices() throws {
        let database = try makeDatabase(devices: [device(id: "device-one", name: "Linux Box")])

        XCTAssertThrowsError(try SpacesPairedDeviceSelection.resolve("nope", database: database)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.localizedStandardContains("No device matches"))
            XCTAssertTrue(message.contains("device-one"))
        }
    }

    func testUnknownSelectorWithNoDevicesPointsAtPairing() throws {
        let database = try makeDatabase(devices: [])

        XCTAssertThrowsError(try SpacesPairedDeviceSelection.resolve("anything", database: database)) { error in
            XCTAssertTrue(error.localizedDescription.localizedStandardContains("spaces device pair"))
        }
    }

    /// `spaces device list` has to answer "where is this device being reached, and where else could it
    /// be reached", because a device that answers on its tailnet address but not its LAN one is
    /// otherwise indistinguishable from one that is simply down.
    func testDeviceRowShowsTheDialedAddressLabeledWithEveryCandidate() {
        var device = device(id: "device-one", name: "Linux Box")
        device.hosts = ["192.0.2.10", "100.64.0.9"]
        device.activeHost = "100.64.0.9"

        let row = SpacesPairedDeviceSelection.deviceRows([device])

        XCTAssertEqual(row, "device-one\tLinux Box\tremote\tTailscale · 100.64.0.9:47847\t192.0.2.10,100.64.0.9")
    }

    /// Until a connection proves one, the preferred candidate is what the device is dialed at, and that
    /// is what the row reports.
    func testDeviceRowFallsBackToThePreferredCandidateBeforeOneIsProven() {
        var device = device(id: "device-two", name: "Studio Mac")
        device.hosts = ["192.0.2.10", "100.64.0.9"]

        let row = SpacesPairedDeviceSelection.deviceRows([device])

        XCTAssertEqual(row, "device-two\tStudio Mac\tremote\tLocal network · 192.0.2.10:47847\t192.0.2.10,100.64.0.9")
    }

    private func device(id: String, name: String) -> SpacesPairedDeviceRecord {
        SpacesPairedDeviceRecord(
            id: id, name: name, platform: "remote", hosts: ["192.0.2.10"], port: 47_847, certificateFingerprint: "SHA256:ab", sshHost: nil,
            sshUser: nil, sshPort: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil)
    }

    private func makeDatabase(devices: [SpacesPairedDeviceRecord]) throws -> SpacesClientDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        for record in devices { try database.upsert(device: record) }
        return database
    }
}

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

    private func device(id: String, name: String) -> SpacesPairedDeviceRecord {
        SpacesPairedDeviceRecord(
            id: id, name: name, platform: "remote", host: "192.0.2.10", port: 47_847, certificateFingerprint: "SHA256:ab", sshHost: nil, sshUser: nil,
            sshPort: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil)
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

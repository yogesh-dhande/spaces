import Foundation
import XCTest
import spacesdevicecore

@testable import spacesdeviceapi

final class SpacesDeviceAPISettingsStoreTests: XCTestCase {
    func testLoadOrCreatePersistsStableDefaultEndpointAndDaemonIdentity() throws {
        try withTemporaryProfile { _ in
            let store = SpacesDeviceAPISettingsStore()

            let created = try store.loadOrCreate()
            let reloaded = try SpacesDeviceAPISettingsStore().loadOrCreate()

            XCTAssertEqual(created.host, SpacesDeviceAPIDefaults.host)
            XCTAssertEqual(created.port, SpacesDeviceAPIDefaults.port)
            XCTAssertEqual(reloaded, created)
            XCTAssertFalse(created.transportKey.isEmpty)
            XCTAssertNoThrow(try SpacesDeviceAPITransport.decodeTransportKey(created.transportKey))
            XCTAssertTrue(created.certificateFingerprint.hasPrefix("SHA256:"))
        }
    }

    func testEnvironmentOverridesEndpointAndDaemonIdentityWithoutChangingStoredDefaults() throws {
        try withTemporaryProfile { _ in
            let transportKey = SpacesDeviceAPISettings.generateTransportKey()
            let certificateFingerprint = "SHA256:test-fingerprint"
            let environment = [
                SpacesDeviceAPIDefaults.hostEnvironmentVariable: "127.0.0.1", SpacesDeviceAPIDefaults.portEnvironmentVariable: "51234",
                SpacesDeviceAPIDefaults.transportKeyEnvironmentVariable: transportKey,
                SpacesDeviceAPIDefaults.certificateFingerprintEnvironmentVariable: certificateFingerprint,
            ]
            let overridden = try SpacesDeviceAPISettingsStore(environment: environment).loadOrCreate()
            let stored = try SpacesDeviceAPISettingsStore().loadOrCreate()

            XCTAssertEqual(overridden.host, "127.0.0.1")
            XCTAssertEqual(overridden.port, 51_234)
            XCTAssertEqual(overridden.transportKey, transportKey)
            XCTAssertEqual(overridden.certificateFingerprint, certificateFingerprint)
            XCTAssertEqual(stored.host, SpacesDeviceAPIDefaults.host)
            XCTAssertEqual(stored.port, SpacesDeviceAPIDefaults.port)
            XCTAssertNotEqual(stored.transportKey, transportKey)
            XCTAssertNotEqual(stored.certificateFingerprint, certificateFingerprint)
        }
    }

    func testEnvironmentPortOverrideAllowsEphemeralPortWithoutChangingStoredDefaults() throws {
        try withTemporaryProfile { _ in
            let environment = [SpacesDeviceAPIDefaults.portEnvironmentVariable: "0"]
            let overridden = try SpacesDeviceAPISettingsStore(environment: environment).loadOrCreate()
            let stored = try SpacesDeviceAPISettingsStore().loadOrCreate()

            XCTAssertEqual(overridden.port, 0)
            XCTAssertEqual(stored.port, SpacesDeviceAPIDefaults.port)
        }
    }

    func testRotateTransportKeyPersistsNewKey() throws {
        try withTemporaryProfile { _ in
            let store = SpacesDeviceAPISettingsStore()
            let original = try store.loadOrCreate()
            let rotated = try store.rotateTransportKey()

            XCTAssertEqual(rotated.host, original.host)
            XCTAssertEqual(rotated.port, original.port)
            XCTAssertNotEqual(rotated.transportKey, original.transportKey)
            XCTAssertEqual(try SpacesDeviceAPISettingsStore().loadOrCreate(), rotated)
        }
    }

    func testRotateTransportKeyDoesNotPersistEnvironmentEndpointOverrides() throws {
        try withTemporaryProfile { _ in
            let environment = [
                SpacesDeviceAPIDefaults.hostEnvironmentVariable: "127.0.0.1", SpacesDeviceAPIDefaults.portEnvironmentVariable: "51234",
            ]
            let store = SpacesDeviceAPISettingsStore(environment: environment)
            let originalStored = try SpacesDeviceAPISettingsStore().loadOrCreate()

            let rotated = try store.rotateTransportKey()
            let stored = try SpacesDeviceAPISettingsStore().loadOrCreate()

            XCTAssertEqual(rotated.host, "127.0.0.1")
            XCTAssertEqual(rotated.port, 51_234)
            XCTAssertEqual(stored.host, originalStored.host)
            XCTAssertEqual(stored.port, originalStored.port)
            XCTAssertNotEqual(stored.transportKey, originalStored.transportKey)
        }
    }

    private func withTemporaryProfile(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let originalRuntimePath = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        unsetenv("SPACES_RUNTIME_DIR")
        defer {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimePath { setenv("SPACES_RUNTIME_DIR", originalRuntimePath, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        try body(root)
    }
}

import Foundation
import XCTest
import spacesmobilecore

@testable import spacesmobilebridge

final class SpacesMobileBridgeSettingsStoreTests: XCTestCase {
    func testLoadOrCreatePersistsStableDefaultEndpointAndDaemonIdentity() throws {
        try withTemporaryProfile { _ in
            let store = SpacesMobileBridgeSettingsStore()

            let created = try store.loadOrCreate()
            let reloaded = try SpacesMobileBridgeSettingsStore().loadOrCreate()

            XCTAssertEqual(created.host, SpacesMobileBridgeDefaults.host)
            XCTAssertEqual(created.port, SpacesMobileBridgeDefaults.port)
            XCTAssertEqual(reloaded, created)
            XCTAssertFalse(created.transportKey.isEmpty)
            XCTAssertNoThrow(try SpacesMobileBridgeTransport.decodeTransportKey(created.transportKey))
            XCTAssertTrue(created.certificateFingerprint.hasPrefix("SHA256:"))
        }
    }

    func testEnvironmentOverridesEndpointAndDaemonIdentityWithoutChangingStoredDefaults() throws {
        try withTemporaryProfile { _ in
            let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
            let certificateFingerprint = "SHA256:test-fingerprint"
            let environment = [
                SpacesMobileBridgeDefaults.hostEnvironmentVariable: "127.0.0.1", SpacesMobileBridgeDefaults.portEnvironmentVariable: "51234",
                SpacesMobileBridgeDefaults.transportKeyEnvironmentVariable: transportKey,
                SpacesMobileBridgeDefaults.certificateFingerprintEnvironmentVariable: certificateFingerprint,
            ]
            let overridden = try SpacesMobileBridgeSettingsStore(environment: environment).loadOrCreate()
            let stored = try SpacesMobileBridgeSettingsStore().loadOrCreate()

            XCTAssertEqual(overridden.host, "127.0.0.1")
            XCTAssertEqual(overridden.port, 51_234)
            XCTAssertEqual(overridden.transportKey, transportKey)
            XCTAssertEqual(overridden.certificateFingerprint, certificateFingerprint)
            XCTAssertEqual(stored.host, SpacesMobileBridgeDefaults.host)
            XCTAssertEqual(stored.port, SpacesMobileBridgeDefaults.port)
            XCTAssertNotEqual(stored.transportKey, transportKey)
            XCTAssertNotEqual(stored.certificateFingerprint, certificateFingerprint)
        }
    }

    func testRotateTransportKeyPersistsNewKey() throws {
        try withTemporaryProfile { _ in
            let store = SpacesMobileBridgeSettingsStore()
            let original = try store.loadOrCreate()
            let rotated = try store.rotateTransportKey()

            XCTAssertEqual(rotated.host, original.host)
            XCTAssertEqual(rotated.port, original.port)
            XCTAssertNotEqual(rotated.transportKey, original.transportKey)
            XCTAssertEqual(try SpacesMobileBridgeSettingsStore().loadOrCreate(), rotated)
        }
    }

    func testRotateTransportKeyDoesNotPersistEnvironmentEndpointOverrides() throws {
        try withTemporaryProfile { _ in
            let environment = [
                SpacesMobileBridgeDefaults.hostEnvironmentVariable: "127.0.0.1", SpacesMobileBridgeDefaults.portEnvironmentVariable: "51234",
            ]
            let store = SpacesMobileBridgeSettingsStore(environment: environment)
            let originalStored = try SpacesMobileBridgeSettingsStore().loadOrCreate()

            let rotated = try store.rotateTransportKey()
            let stored = try SpacesMobileBridgeSettingsStore().loadOrCreate()

            XCTAssertEqual(rotated.host, "127.0.0.1")
            XCTAssertEqual(rotated.port, 51_234)
            XCTAssertEqual(stored.host, originalStored.host)
            XCTAssertEqual(stored.port, originalStored.port)
            XCTAssertNotEqual(stored.transportKey, originalStored.transportKey)
        }
    }

    func testStableFallbackPortsAreDeterministicForProfile() throws {
        try withTemporaryProfile { _ in
            let store = SpacesMobileBridgeSettingsStore()

            let first = try store.stableFallbackPorts(limit: 8)
            let second = try SpacesMobileBridgeSettingsStore().stableFallbackPorts(limit: 8)

            XCTAssertEqual(first, second)
            XCTAssertEqual(Set(first).count, first.count)
            XCTAssertTrue(
                first.allSatisfy {
                    $0 >= SpacesMobileBridgeSettingsStore.stableFallbackPortBase
                        && $0 < SpacesMobileBridgeSettingsStore.stableFallbackPortBase + SpacesMobileBridgeSettingsStore.stableFallbackPortCount
                })
        }
    }

    func testUpdatePortPersistsStoredPort() throws {
        try withTemporaryProfile { _ in
            let store = SpacesMobileBridgeSettingsStore()

            let updated = try store.updatePort(48_123)

            XCTAssertEqual(updated.port, 48_123)
            XCTAssertEqual(try SpacesMobileBridgeSettingsStore().loadOrCreate().port, 48_123)
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

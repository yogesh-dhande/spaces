import Foundation
import XCTest

@testable import spacesmobilebridge

final class SpacesMobileBridgeSettingsStoreTests: XCTestCase {
    func testLoadOrCreatePersistsStableDefaultEndpointAndPairingCode() throws {
        try withTemporaryProfile { _ in
            let store = SpacesMobileBridgeSettingsStore()

            let created = try store.loadOrCreate()
            let reloaded = try SpacesMobileBridgeSettingsStore().loadOrCreate()

            XCTAssertEqual(created.host, SpacesMobileBridgeDefaults.host)
            XCTAssertEqual(created.port, SpacesMobileBridgeDefaults.port)
            XCTAssertEqual(reloaded, created)
            XCTAssertEqual(created.pairingCode.count, 6)
        }
    }

    func testEnvironmentOverridesEndpointAndPairingCodeWithoutChangingStoredDefaults() throws {
        try withTemporaryProfile { _ in
            let environment = [
                SpacesMobileBridgeDefaults.hostEnvironmentVariable: "127.0.0.1", SpacesMobileBridgeDefaults.portEnvironmentVariable: "51234",
                SpacesMobileBridgeDefaults.pairingCodeEnvironmentVariable: "246810",
            ]
            let overridden = try SpacesMobileBridgeSettingsStore(environment: environment).loadOrCreate()
            let stored = try SpacesMobileBridgeSettingsStore().loadOrCreate()

            XCTAssertEqual(overridden.host, "127.0.0.1")
            XCTAssertEqual(overridden.port, 51_234)
            XCTAssertEqual(overridden.pairingCode, "246810")
            XCTAssertEqual(stored.host, SpacesMobileBridgeDefaults.host)
            XCTAssertEqual(stored.port, SpacesMobileBridgeDefaults.port)
            XCTAssertNotEqual(stored.pairingCode, "246810")
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

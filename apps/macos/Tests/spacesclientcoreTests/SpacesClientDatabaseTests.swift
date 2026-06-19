import Foundation
import XCTest

@testable import spacesclientcore
@testable import spacesterminalcore

final class SpacesClientDatabaseTests: XCTestCase {
    func testDefaultPathUsesEnvironmentOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let overridePath = root.appendingPathComponent("Client/spaces-client.db", isDirectory: false).path
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        setenv(SpacesClientDatabase.databasePathEnvironmentVariable, overridePath, 1)
        defer {
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(try SpacesClientDatabase.defaultPath(), overridePath)
    }

    func testPairedDeviceMetadataAndActiveSelectionPersistWithoutToken() throws {
        try withTemporaryProfile { root in
            let databaseURL = root.appendingPathComponent("Client/spaces-client.db", isDirectory: false)
            let database = try SpacesClientDatabase(path: databaseURL.path)
            let record = device(id: "device-1")

            try database.upsert(device: record)
            try database.setActiveDeviceID(record.id)
            try SpacesDeviceCredentialStore.saveToken("SECRET-TOKEN", deviceID: record.id)
            defer { try? SpacesDeviceCredentialStore.deleteToken(deviceID: record.id) }

            let reopened = try SpacesClientDatabase(path: databaseURL.path)
            XCTAssertEqual(try reopened.pairedDevice(id: record.id), record)
            XCTAssertEqual(try reopened.activeDeviceID(), record.id)
            XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: record.id), "SECRET-TOKEN")

            let databaseBytes = try Data(contentsOf: databaseURL)
            XCTAssertNil(String(data: databaseBytes, encoding: .utf8)?.range(of: "SECRET-TOKEN"))
        }
    }

    func testFailedMigrationRestoresBackup() throws {
        try withTemporaryProfile { root in
            let databaseURL = root.appendingPathComponent("Client/spaces-client.db", isDirectory: false)
            let database = try SpacesClientDatabase(path: databaseURL.path)
            let record = device(id: "device-rollback")
            try database.upsert(device: record)
            try SpacesDeviceCredentialStore.saveToken("SECRET-TOKEN", deviceID: record.id)
            defer { try? SpacesDeviceCredentialStore.deleteToken(deviceID: record.id) }

            let failingStep = SpacesClientMigrationStep(fromVersion: 1, toVersion: 2, description: "Intentional failure") { _ in
                throw NSError(domain: "SpacesClientDatabaseTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
            }
            XCTAssertThrowsError(try SpacesClientDatabase(path: databaseURL.path, currentVersion: 2, migrationSteps: [failingStep]))

            let restored = try SpacesClientDatabase(path: databaseURL.path)
            XCTAssertEqual(try restored.pairedDevice(id: record.id), record)

            let backupURLs = try restored.backupURLs()
            XCTAssertEqual(backupURLs.count, 1)
            let backupBytes = try Data(contentsOf: backupURLs[0])
            XCTAssertNil(String(data: backupBytes, encoding: .utf8)?.range(of: "SECRET-TOKEN"))
        }
    }

    private func device(id: String) -> SpacesPairedDeviceRecord {
        SpacesPairedDeviceRecord(
            id: id, name: "Studio Mac", platform: "macos", host: "studio.local", port: 7443, certificateFingerprint: "SHA256:abc",
            sshHost: "studio.local", sshUser: "yogesh", sshPort: 22, createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z",
            lastSelectedAt: "2026-06-17T00:01:00Z")
    }

    private func withTemporaryProfile(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDatabasePath = currentEnvironmentValue("SPACES_DB_PATH")
        let originalRuntimePath = currentEnvironmentValue("SPACES_RUNTIME_DIR")
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        let originalClientSecretDirectory = currentEnvironmentValue(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
        setenv("SPACES_DB_PATH", root.appendingPathComponent("daemon/spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("daemon/runtime").path, 1)
        setenv(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable, root.appendingPathComponent("Client/Secrets").path, 1)
        unsetenv(SpacesClientDatabase.databasePathEnvironmentVariable)
        SpacesProfile.resetCacheForTesting()
        defer {
            restoreEnvironmentValue(originalDatabasePath, name: "SPACES_DB_PATH")
            restoreEnvironmentValue(originalRuntimePath, name: "SPACES_RUNTIME_DIR")
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            restoreEnvironmentValue(originalClientSecretDirectory, name: SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        try body(root)
    }

    private func currentEnvironmentValue(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }

    private func restoreEnvironmentValue(_ value: String?, name: String) { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
}

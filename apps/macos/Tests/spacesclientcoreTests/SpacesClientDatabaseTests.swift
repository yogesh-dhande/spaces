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

    func testDefaultPathUsesCurrentProfileRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileRoot = root.appendingPathComponent("profile-a", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let originalDatabasePath = currentEnvironmentValue("SPACES_DB_PATH")
        let originalRuntimePath = currentEnvironmentValue("SPACES_RUNTIME_DIR")
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        setenv("SPACES_DB_PATH", profileRoot.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", profileRoot.appendingPathComponent("runtime").path, 1)
        unsetenv(SpacesClientDatabase.databasePathEnvironmentVariable)
        SpacesProfile.resetCacheForTesting()
        defer {
            restoreEnvironmentValue(originalDatabasePath, name: "SPACES_DB_PATH")
            restoreEnvironmentValue(originalRuntimePath, name: "SPACES_RUNTIME_DIR")
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(try SpacesClientDatabase.defaultPath(), profileRoot.appendingPathComponent("Client/spaces-client.db", isDirectory: false).path)
    }

    func testDefaultPathUsesHomeScopedProfileRoot() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let originalHome = currentEnvironmentValue("HOME")
        let originalDatabasePath = currentEnvironmentValue("SPACES_DB_PATH")
        let originalRuntimePath = currentEnvironmentValue("SPACES_RUNTIME_DIR")
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        setenv("HOME", home.path, 1)
        unsetenv("SPACES_DB_PATH")
        unsetenv("SPACES_RUNTIME_DIR")
        unsetenv(SpacesClientDatabase.databasePathEnvironmentVariable)
        SpacesProfile.resetCacheForTesting()
        defer {
            restoreEnvironmentValue(originalHome, name: "HOME")
            restoreEnvironmentValue(originalDatabasePath, name: "SPACES_DB_PATH")
            restoreEnvironmentValue(originalRuntimePath, name: "SPACES_RUNTIME_DIR")
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: home)
        }

        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        let profile = try SpacesProfile.resolve(
            environment: ["HOME": home.path], homeDirectoryURL: home, currentDirectoryPath: currentDirectoryPath,
            executablePath: SpacesProfile.currentExecutablePath(currentDirectoryPath: currentDirectoryPath))
        XCTAssertEqual(
            try SpacesClientDatabase.defaultPath(),
            URL(fileURLWithPath: profile.rootDirectory, isDirectory: true).appendingPathComponent("Client", isDirectory: true).appendingPathComponent(
                "spaces-client.db", isDirectory: false
            ).path)
    }

    func testPairedDevicesAreScopedToCurrentProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileA = root.appendingPathComponent("profile-a", isDirectory: true)
        let profileB = root.appendingPathComponent("profile-b", isDirectory: true)
        try FileManager.default.createDirectory(at: profileA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileB, withIntermediateDirectories: true)
        let originalDatabasePath = currentEnvironmentValue("SPACES_DB_PATH")
        let originalRuntimePath = currentEnvironmentValue("SPACES_RUNTIME_DIR")
        let originalClientDatabasePath = currentEnvironmentValue(SpacesClientDatabase.databasePathEnvironmentVariable)
        unsetenv(SpacesClientDatabase.databasePathEnvironmentVariable)
        defer {
            restoreEnvironmentValue(originalDatabasePath, name: "SPACES_DB_PATH")
            restoreEnvironmentValue(originalRuntimePath, name: "SPACES_RUNTIME_DIR")
            restoreEnvironmentValue(originalClientDatabasePath, name: SpacesClientDatabase.databasePathEnvironmentVariable)
            SpacesProfile.resetCacheForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        setenv("SPACES_DB_PATH", profileA.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", profileA.appendingPathComponent("runtime").path, 1)
        SpacesProfile.resetCacheForTesting()
        let profileADatabasePath = try SpacesClientDatabase.defaultPath()
        let databaseA = try SpacesClientDatabase()
        let record = device(id: "profile-a-device")
        try databaseA.upsert(device: record)
        XCTAssertEqual(try databaseA.pairedDevices().map(\.id), [record.id])

        setenv("SPACES_DB_PATH", profileB.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", profileB.appendingPathComponent("runtime").path, 1)
        SpacesProfile.resetCacheForTesting()
        let profileBDatabasePath = try SpacesClientDatabase.defaultPath()
        let databaseB = try SpacesClientDatabase()

        XCTAssertNotEqual(profileADatabasePath, profileBDatabasePath)
        XCTAssertTrue(try databaseB.pairedDevices().isEmpty)
    }

    func testPairedDeviceMetadataPersistsWithoutToken() throws {
        try withTemporaryProfile { root in
            let databaseURL = root.appendingPathComponent("Client/spaces-client.db", isDirectory: false)
            let database = try SpacesClientDatabase(path: databaseURL.path)
            let record = device(id: "device-1")

            try database.upsert(device: record)
            try SpacesDeviceCredentialStore.saveToken("SECRET-TOKEN", deviceID: record.id)
            defer { try? SpacesDeviceCredentialStore.deleteToken(deviceID: record.id) }

            let reopened = try SpacesClientDatabase(path: databaseURL.path)
            XCTAssertEqual(try reopened.pairedDevice(id: record.id), record)
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

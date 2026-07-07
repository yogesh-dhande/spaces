import Foundation
import XCTest
import spacesterminalcore

@testable import spacesclientcore

final class SpacesDeviceCredentialStoreTests: XCTestCase {
    func testDefaultSecretDirectoryIsProfileScopedAndOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originalSecretDirectory = currentEnvironmentValue(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
        unsetenv(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
        defer {
            restoreEnvironmentValue(originalSecretDirectory, name: SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
            try? FileManager.default.removeItem(at: root)
        }
        let profile = SpacesProfile(
            source: .explicitDatabasePath, databasePath: root.appendingPathComponent("spaces.db").path, rootDirectory: root.path,
            runtimeDirectory: root.appendingPathComponent("runtime").path, ipcNotificationObject: "test", developmentContext: nil, branchSlug: nil,
            worktreeHash: nil)

        try SpacesDeviceCredentialStore.saveToken("TOKEN", deviceID: "device-one", profile: profile)

        let secretDirectory = root.appendingPathComponent(SpacesDeviceCredentialStore.secretDirectoryName, isDirectory: true)
        XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: "device-one", profile: profile), "TOKEN")
        let directoryPermissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: secretDirectory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryPermissions.int16Value, 0o700)
        let secretFile = secretDirectory.appendingPathComponent("device-auth-token-device-one.secret")
        let filePermissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: secretFile.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(filePermissions.int16Value, 0o600)

        try SpacesDeviceCredentialStore.deleteToken(deviceID: "device-one", profile: profile)
        XCTAssertNil(try SpacesDeviceCredentialStore.token(deviceID: "device-one", profile: profile))
    }

    func testEnvironmentSecretDirectoryOverridesProfileDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secretDirectory = root.appendingPathComponent("Env/Secrets", isDirectory: true)
        let originalSecretDirectory = currentEnvironmentValue(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
        setenv(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable, secretDirectory.path, 1)
        defer {
            restoreEnvironmentValue(originalSecretDirectory, name: SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
            try? FileManager.default.removeItem(at: root)
        }
        let profile = SpacesProfile(
            source: .explicitDatabasePath, databasePath: root.appendingPathComponent("spaces.db").path,
            rootDirectory: root.appendingPathComponent("profile").path, runtimeDirectory: root.appendingPathComponent("runtime").path,
            ipcNotificationObject: "test", developmentContext: nil, branchSlug: nil, worktreeHash: nil)

        try SpacesDeviceCredentialStore.saveToken("TOKEN", deviceID: "device-one", profile: profile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: secretDirectory.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("profile").appendingPathComponent(SpacesDeviceCredentialStore.secretDirectoryName).path))
        XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: "device-one", profile: profile), "TOKEN")
    }

    func testEnvironmentSecretDirectoryStoresSecretsOutsideClientDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secretDirectory = root.appendingPathComponent("Client/Secrets", isDirectory: true)
        let originalSecretDirectory = currentEnvironmentValue(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
        setenv(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable, secretDirectory.path, 1)
        defer {
            restoreEnvironmentValue(originalSecretDirectory, name: SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
            try? FileManager.default.removeItem(at: root)
        }

        try SpacesDeviceCredentialStore.saveToken("TOKEN", deviceID: "device/one")

        XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: "device/one"), "TOKEN")
        XCTAssertTrue(try SpacesDeviceCredentialStore.hasToken(deviceID: "device/one"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretDirectory.path))

        try SpacesDeviceCredentialStore.deleteToken(deviceID: "device/one")

        XCTAssertNil(try SpacesDeviceCredentialStore.token(deviceID: "device/one"))
    }

    func testSanitizeFileComponentKeepsSecretsInsideDirectory() {
        XCTAssertEqual(SpacesDeviceCredentialStore.sanitizeFileComponent("../device id"), "device_id")
        XCTAssertEqual(SpacesDeviceCredentialStore.sanitizeFileComponent("device-sha256-abc_DEF.123"), "device-sha256-abc_DEF.123")
    }

    private func currentEnvironmentValue(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }

    private func restoreEnvironmentValue(_ value: String?, name: String) { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
}

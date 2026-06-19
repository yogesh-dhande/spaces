import Foundation
import XCTest

@testable import spacesclientcore

final class SpacesDeviceCredentialStoreTests: XCTestCase {
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
        try SpacesDeviceCredentialStore.saveTransportKey("TRANSPORT", deviceID: "device/one")

        XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: "device/one"), "TOKEN")
        XCTAssertEqual(try SpacesDeviceCredentialStore.transportKey(deviceID: "device/one"), "TRANSPORT")
        XCTAssertTrue(try SpacesDeviceCredentialStore.hasToken(deviceID: "device/one"))
        XCTAssertTrue(try SpacesDeviceCredentialStore.hasTransportKey(deviceID: "device/one"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretDirectory.path))

        try SpacesDeviceCredentialStore.deleteToken(deviceID: "device/one")
        try SpacesDeviceCredentialStore.deleteTransportKey(deviceID: "device/one")

        XCTAssertNil(try SpacesDeviceCredentialStore.token(deviceID: "device/one"))
        XCTAssertNil(try SpacesDeviceCredentialStore.transportKey(deviceID: "device/one"))
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

import Foundation
import XCTest
import spacesmobilecore

@testable import spacescli

final class SpacesMobilePairingStoreTests: XCTestCase {
    func testIssueTokenAndAuthorizeAllowedBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let store = try SpacesMobilePairingStore()
        let clientApp = SpacesMobileClientApp(
            installationID: "INSTALLATION-1", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPad Pro",
            appVersion: "1.0")

        let token = try store.issueToken(for: clientApp, pairingCode: "246810", expectedPairingCode: "246810")
        XCTAssertFalse(token.isEmpty)
        XCTAssertNoThrow(try store.authorize(clientApp: clientApp, authToken: token))
    }

    func testAuthorizeRejectsUnsupportedBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalOverride = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        defer {
            if let originalOverride { setenv("SPACES_DB_PATH", originalOverride, 1) } else { unsetenv("SPACES_DB_PATH") }
            try? FileManager.default.removeItem(at: root)
        }

        let store = try SpacesMobilePairingStore()
        let clientApp = SpacesMobileClientApp(
            installationID: "INSTALLATION-2", bundleID: "com.example.thirdparty", platform: "ios", deviceName: "Third Party", appVersion: "1.0")

        XCTAssertThrowsError(try store.issueToken(for: clientApp, pairingCode: "246810", expectedPairingCode: "246810")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported mobile bundle"))
        }
    }
}

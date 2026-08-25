import Foundation
import XCTest
import spacesdevicecore
import spacesdeviceapi

@testable import spacesclientcore

/// `bootstrapLocalDevice` runs on every sidebar reload, and the daemon keeps the token the client presents
/// rather than rotating it, so almost every run ends up holding the token it already had on disk. Writing
/// it back regardless made each reload replace the secret file atomically (temp write, rename, chmod),
/// dirtying a page for identical bytes; macOS filed disk-writes resource reports against the app with this
/// as the dominant stack. These tests pin the resulting contract: persist a token that actually changed,
/// leave the file alone when it did not.
final class SpacesDeviceClientLocalTokenPersistenceTests: XCTestCase {
    private var secretDirectory: URL!
    private var databasePath: String!
    private var previousSecretDirectory: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("spaces-local-token-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        secretDirectory = root.appendingPathComponent("client-secrets", isDirectory: true)
        databasePath = root.appendingPathComponent("spaces.db", isDirectory: false).path
        // Restored in tearDown so a mutated environment cannot leak into another test in this process.
        previousSecretDirectory = ProcessInfo.processInfo.environment[SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable]
        setenv(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable, secretDirectory.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousSecretDirectory {
            setenv(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable, previousSecretDirectory, 1)
        } else {
            unsetenv(SpacesDeviceCredentialStore.secretDirectoryEnvironmentVariable)
        }
        try? FileManager.default.removeItem(at: secretDirectory.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    func testFirstBootstrapPersistsTheIssuedToken() throws {
        let database = try SpacesClientDatabase(path: databasePath)
        let recorder = PresentedTokenRecorder()
        _ = try SpacesDeviceClient.bootstrapLocalDevice(
            database: database, clientApp: Self.clientApp, bootstrap: Self.provider(issuing: "token-1", recordingPresentedInto: recorder))

        XCTAssertEqual(recorder.recorded, [nil], "Nothing is stored yet, so the first bootstrap presents no token.")
        XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: SpacesPairedDeviceRecord.localDeviceID), "token-1")
    }

    func testRebootstrapWithTheSameTokenLeavesTheSecretFileUntouched() throws {
        let database = try SpacesClientDatabase(path: databasePath)
        _ = try SpacesDeviceClient.bootstrapLocalDevice(
            database: database, clientApp: Self.clientApp, bootstrap: Self.provider(issuing: "token-1"))
        let afterFirstWrite = try fileIdentity()

        // The daemon keeps the presented token, which is what it does for every reload of a client whose
        // credentials are already valid. The stored value is already correct, so nothing should be rewritten.
        let recorder = PresentedTokenRecorder()
        for _ in 0..<5 {
            _ = try SpacesDeviceClient.bootstrapLocalDevice(
                database: database, clientApp: Self.clientApp, bootstrap: Self.provider(issuing: "token-1", recordingPresentedInto: recorder))
        }

        XCTAssertEqual(recorder.recorded, Array(repeating: "token-1", count: 5), "Each reload presents the token it already holds.")
        XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: SpacesPairedDeviceRecord.localDeviceID), "token-1")
        XCTAssertEqual(
            try fileIdentity(), afterFirstWrite,
            "An unchanged token must not replace the secret file: the atomic write swaps in a new inode every time it runs.")
    }

    func testRotatedTokenIsPersisted() throws {
        let database = try SpacesClientDatabase(path: databasePath)
        _ = try SpacesDeviceClient.bootstrapLocalDevice(
            database: database, clientApp: Self.clientApp, bootstrap: Self.provider(issuing: "token-1"))
        let afterFirstWrite = try fileIdentity()

        // A daemon that rejects the presented token mints a replacement; the client must store the new one
        // or every later Device API request authenticates with a revoked token.
        _ = try SpacesDeviceClient.bootstrapLocalDevice(
            database: database, clientApp: Self.clientApp, bootstrap: Self.provider(issuing: "token-2"))

        XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: SpacesPairedDeviceRecord.localDeviceID), "token-2")
        XCTAssertNotEqual(try fileIdentity(), afterFirstWrite, "A rotated token replaces the stored secret.")
    }

    func testTokenIsRestoredAfterTheSecretFileGoesMissing() throws {
        let database = try SpacesClientDatabase(path: databasePath)
        _ = try SpacesDeviceClient.bootstrapLocalDevice(
            database: database, clientApp: Self.clientApp, bootstrap: Self.provider(issuing: "token-1"))
        try FileManager.default.removeItem(at: secretFileURL())

        // With no stored token the client presents nothing, and whatever the daemon issues has to land on
        // disk — the skip must key off the presented value, not off having bootstrapped before.
        _ = try SpacesDeviceClient.bootstrapLocalDevice(
            database: database, clientApp: Self.clientApp, bootstrap: Self.provider(issuing: "token-1"))

        XCTAssertEqual(try SpacesDeviceCredentialStore.token(deviceID: SpacesPairedDeviceRecord.localDeviceID), "token-1")
    }

    // MARK: - Helpers

    private static let clientApp = SpacesDeviceClientApp(
        installationID: "installation", bundleID: "dev.usespaces.spaces.tests", platform: "macos", deviceName: "test-mac", appVersion: "0.0.0")

    /// Collects the tokens the client presented across bootstraps. The bootstrap provider is `@Sendable`
    /// and `bootstrapLocalDevice` calls it under its own lock, so the recording side needs its own.
    private final class PresentedTokenRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String?] = []

        func record(_ value: String?) {
            lock.withLock { values.append(value) }
        }

        var recorded: [String?] { lock.withLock { values } }
    }

    /// A stand-in for the daemon's bootstrap round-trip that issues `token` and reports what the client
    /// presented, so a test can assert on the presented value without a live control socket.
    private static func provider(
        issuing token: String, recordingPresentedInto recorder: PresentedTokenRecorder? = nil
    ) -> SpacesDeviceClient.LocalBootstrapProvider {
        { _, presentedToken in
            recorder?.record(presentedToken)
            return SpacesDeviceAPIControlResponse(
                ok: true, message: "Bootstrapped local Device API client.",
                result: .localClientBootstrap(
                    SpacesDeviceAPILocalClientBootstrap(
                        deviceID: SpacesPairedDeviceRecord.localDeviceID, name: "test-mac", platform: "macos", host: "127.0.0.1", port: 47847,
                        certificateFingerprint: "fingerprint", authToken: token)))
        }
    }

    private func secretFileURL() throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: secretDirectory, includingPropertiesForKeys: nil)
        let secrets = contents.filter { $0.pathExtension == "secret" }
        guard let url = secrets.first, secrets.count == 1 else {
            throw XCTSkip("Expected exactly one stored secret, found \(secrets.count).")
        }
        return url
    }

    /// Identifies the stored secret by inode and modification date. `saveToken` writes atomically, so any
    /// rewrite — even of identical bytes — swaps in a different inode.
    private func fileIdentity() throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: secretFileURL().path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(inode)@\(modified)"
    }
}

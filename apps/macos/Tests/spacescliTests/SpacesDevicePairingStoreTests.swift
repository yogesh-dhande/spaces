import Foundation
import XCTest
import spacesdevicecore
import spacesterminalcore

@testable import spacescli
@testable import spacesdeviceapi

final class SpacesDevicePairingStoreTests: XCTestCase {
    func testIssueTokenAndAuthorizeAllowedBundle() throws {
        try withTemporaryProfile {
            let store = try SpacesDevicePairingStore()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-1", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPad Pro",
                appVersion: "1.0")

            let token = try store.issueToken(for: clientApp)
            XCTAssertFalse(token.isEmpty)
            XCTAssertNoThrow(try store.authorize(clientApp: clientApp, authToken: token))
        }
    }

    func testIssueTokenAndAuthorizeMacClientBundle() throws {
        try withTemporaryProfile {
            let store = try SpacesDevicePairingStore()
            let clientApp = SpacesDeviceClientApp(
                installationID: "MAC-INSTALLATION-1", bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos",
                deviceName: "MacBook Pro", appVersion: "1.0")

            let token = try store.issueToken(for: clientApp)
            XCTAssertFalse(token.isEmpty)
            XCTAssertNoThrow(try store.authorize(clientApp: clientApp, authToken: token))
        }
    }

    func testRebootstrapKeepsPresentedTokenStable() throws {
        try withTemporaryProfile {
            let store = try SpacesDevicePairingStore()
            let clientApp = SpacesDeviceClientApp(
                installationID: "MAC-INSTALLATION-STABLE", bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos",
                deviceName: "MacBook Pro", appVersion: "1.0")

            let token = try store.issueToken(for: clientApp)
            // Re-bootstrapping while presenting the current token keeps the local first-party client
            // authorized during endpoint or credential recovery
            // instead of invalidating the tokens held by its live Device API connections.
            let reissued = try store.issueToken(for: clientApp, presentedToken: token)
            XCTAssertEqual(reissued, token)
            XCTAssertNoThrow(try store.authorize(clientApp: clientApp, authToken: token))
        }
    }

    func testIssueTokenMintsFreshTokenWithoutOrWithStalePresentedToken() throws {
        try withTemporaryProfile {
            let store = try SpacesDevicePairingStore()
            let clientApp = SpacesDeviceClientApp(
                installationID: "MAC-INSTALLATION-FRESH", bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos",
                deviceName: "MacBook Pro", appVersion: "1.0")

            let firstToken = try store.issueToken(for: clientApp)
            // No presented token (first launch, or a client that lost its token) mints a fresh one
            // and invalidates the prior token.
            let rotated = try store.issueToken(for: clientApp)
            XCTAssertNotEqual(rotated, firstToken)
            XCTAssertThrowsError(try store.authorize(clientApp: clientApp, authToken: firstToken))
            XCTAssertNoThrow(try store.authorize(clientApp: clientApp, authToken: rotated))

            // A stale presented token cannot resurrect itself; it too mints a fresh token.
            let afterStale = try store.issueToken(for: clientApp, presentedToken: firstToken)
            XCTAssertNotEqual(afterStale, rotated)
            XCTAssertNoThrow(try store.authorize(clientApp: clientApp, authToken: afterStale))
        }
    }

    /// The steady state this store spends nearly all its time in: an already-paired client re-presents its
    /// current token, so nothing about the pairing changes except when it was last seen. That used to
    /// re-encode and atomically rewrite the whole pairings file — on `issueToken`, which the daemon runs on
    /// its main actor for every `bootstrapLocalClient`, and on `authorize`, which runs in front of every
    /// request including each keystroke's control request. It must now write nothing.
    func testSteadyStateBootstrapAndAuthorizeWriteNothing() throws {
        try withTemporaryProfile {
            let store = try SpacesDevicePairingStore()
            let clientApp = SpacesDeviceClientApp(
                installationID: "MAC-INSTALLATION-STEADY", bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos",
                deviceName: "MacBook Pro", appVersion: "1.0")
            let token = try store.issueToken(for: clientApp)

            let markedAt = try markPairingsFile()
            XCTAssertEqual(try store.issueToken(for: clientApp, presentedToken: token), token)
            try store.authorize(clientApp: clientApp, authToken: token)
            XCTAssertEqual(try pairingsFileModificationDate(), markedAt, "A pairing that only changed when it was last seen must not be rewritten.")
        }
    }

    /// Everything about a pairing other than `lastUsedAt` still persists immediately: a renamed device, a
    /// new app version, and a rotated token all have to survive a daemon restart the moment they happen.
    func testAChangedPairingIsPersistedImmediately() throws {
        try withTemporaryProfile {
            let store = try SpacesDevicePairingStore()
            let clientApp = SpacesDeviceClientApp(
                installationID: "MAC-INSTALLATION-CHANGED", bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos",
                deviceName: "MacBook Pro", appVersion: "1.0")
            let token = try store.issueToken(for: clientApp)

            let renamed = SpacesDeviceClientApp(
                installationID: clientApp.installationID, bundleID: clientApp.bundleID, platform: clientApp.platform, deviceName: "Renamed Mac",
                appVersion: "1.1")
            let markedAt = try markPairingsFile()
            try store.authorize(clientApp: renamed, authToken: token)
            XCTAssertNotEqual(try pairingsFileModificationDate(), markedAt, "A renamed device must be persisted when it is seen.")
            XCTAssertEqual(try store.listDevices().first?.deviceName, "Renamed Mac")
            XCTAssertEqual(try store.listDevices().first?.appVersion, "1.1")
        }
    }

    /// The bound on how stale the skipped write can leave `lastUsedAt`: once the persisted timestamp is
    /// older than an hour, the next sighting spends one write refreshing it, so the paired-devices list
    /// stays accurate at the granularity it is read at.
    func testAnHourOldLastUsedAtIsRefreshed() throws {
        try withTemporaryProfile {
            let store = try SpacesDevicePairingStore()
            let clientApp = SpacesDeviceClientApp(
                installationID: "MAC-INSTALLATION-STALE", bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos",
                deviceName: "MacBook Pro", appVersion: "1.0")
            let token = try store.issueToken(for: clientApp)

            let staleTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 60 * 60))
            try rewritePairings { pairing in
                SpacesDevicePairedInstallation(
                    installationID: pairing.installationID, bundleID: pairing.bundleID, platform: pairing.platform, deviceName: pairing.deviceName,
                    appVersion: pairing.appVersion, tokenHash: pairing.tokenHash, createdAt: pairing.createdAt, lastUsedAt: staleTimestamp)
            }
            XCTAssertEqual(try store.listDevices().first?.lastUsedAt, staleTimestamp)

            try store.authorize(clientApp: clientApp, authToken: token)
            XCTAssertNotEqual(try store.listDevices().first?.lastUsedAt, staleTimestamp, "A last-used timestamp older than the bound is refreshed.")
        }
    }

    func testAuthorizeRejectsUnsupportedBundle() throws {
        try withTemporaryProfile {
            let store = try SpacesDevicePairingStore()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-2", bundleID: "com.example.thirdparty", platform: "ios", deviceName: "Third Party", appVersion: "1.0")

            XCTAssertThrowsError(try store.issueToken(for: clientApp)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unsupported Spaces client bundle"))
            }
        }
    }

    func testListRevokeAndResetOmitSecretsAndInvalidateAuth() throws {
        try withTemporaryProfile {
            let store = try SpacesDevicePairingStore()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-3", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
                appVersion: "1.0")
            let token = try store.issueToken(for: clientApp)

            let devices = try store.listDevices()
            XCTAssertEqual(devices.map(\.installationID), ["INSTALLATION-3"])
            XCTAssertNoThrow(try store.authorize(clientApp: clientApp, authToken: token))

            try store.revoke(installationID: "INSTALLATION-3")
            XCTAssertEqual(try store.listDevices(), [])
            XCTAssertThrowsError(try store.authorize(clientApp: clientApp, authToken: token))

            _ = try store.issueToken(for: clientApp)
            try store.removeAll()
            XCTAssertEqual(try store.listDevices(), [])
        }
    }

    /// The supervisor builds a fresh store per control request while the running server holds its own, so
    /// mutual exclusion has to cover the pairings file rather than the instance. This drives the losing
    /// interleaving directly: one store is stopped inside its write, holding the pairing it loaded, while
    /// another store is told to revoke that same pairing. Under a per-instance lock the revoke reads,
    /// filters, and writes in that window, and the paused write then puts the revoked token back.
    func testARevokeIsNotUndoneByAnotherStoreInstanceRefreshingLastUsedAt() throws {
        try withTemporaryProfile {
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-SHARED-LOCK", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let token = try SpacesDevicePairingStore().issueToken(for: clientApp)
            // Two hours stale, so the authorization below is one of the rare ones that actually writes.
            let staleTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 60 * 60))
            try rewritePairings { pairing in
                SpacesDevicePairedInstallation(
                    installationID: pairing.installationID, bundleID: pairing.bundleID, platform: pairing.platform, deviceName: pairing.deviceName,
                    appVersion: pairing.appVersion, tokenHash: pairing.tokenHash, createdAt: pairing.createdAt, lastUsedAt: staleTimestamp)
            }

            let pausingFileManager = PausingSaveFileManager()
            let refreshingStore = try SpacesDevicePairingStore(fileManager: pausingFileManager)
            pausingFileManager.arm()
            let refreshFinished = expectation(description: "The last-used refresh finishes its write.")
            DispatchQueue.global().async {
                try? refreshingStore.authorize(clientApp: clientApp, authToken: token)
                refreshFinished.fulfill()
            }
            XCTAssertEqual(pausingFileManager.reachedSave.wait(timeout: .now() + 5), .success, "The refresh must reach its write.")

            let revokingFileManager = SignallingLoadFileManager()
            let revokingStore = try SpacesDevicePairingStore(fileManager: revokingFileManager)
            revokingFileManager.arm()
            let revokeFinished = expectation(description: "The revoke finishes.")
            DispatchQueue.global().async {
                try? revokingStore.revoke(installationID: clientApp.installationID)
                revokeFinished.fulfill()
            }
            // The revoke must not even read the file while another instance is mid-write, which is what
            // one lock per file buys: the load, the edit, and the write are one critical section for every
            // instance, so the two mutations serialize instead of overwriting each other.
            XCTAssertEqual(
                revokingFileManager.reachedLoad.wait(timeout: .now() + 0.5), .timedOut,
                "A store holding the pairings file mid-write must exclude another instance naming the same file.")

            pausingFileManager.releaseSave.signal()
            wait(for: [refreshFinished, revokeFinished], timeout: 10)

            let reader = try SpacesDevicePairingStore()
            XCTAssertEqual(try reader.listDevices(), [], "A revoked pairing must not be restored by a write that started before it.")
            XCTAssertThrowsError(try reader.authorize(clientApp: clientApp, authToken: token), "A revoked token must stay unusable.")
        }
    }

    private func pairingsFileURL() throws -> URL {
        try TerminalServicePaths.terminalRootDirectory().appendingPathComponent("device-pairings.json", isDirectory: false)
    }

    /// Stamps the pairings file with a fixed, distant modification date and returns it, so a later
    /// comparison detects a rewrite regardless of the filesystem's timestamp resolution.
    @discardableResult private func markPairingsFile() throws -> Date {
        let markedAt = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: markedAt], ofItemAtPath: try pairingsFileURL().path)
        return markedAt
    }

    private func pairingsFileModificationDate() throws -> Date {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: try pairingsFileURL().path)[.modificationDate] as? Date)
    }

    private func rewritePairings(_ transform: (SpacesDevicePairedInstallation) -> SpacesDevicePairedInstallation) throws {
        let url = try pairingsFileURL()
        let pairings = try JSONDecoder().decode([SpacesDevicePairedInstallation].self, from: try Data(contentsOf: url)).map(transform)
        try JSONEncoder().encode(pairings).write(to: url, options: [.atomic])
    }

    private func withTemporaryProfile(_ body: () throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDatabasePath = currentEnvironmentValue("SPACES_DB_PATH")
        let originalRuntimePath = currentEnvironmentValue("SPACES_RUNTIME_DIR")
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime").path, 1)
        defer {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimePath { setenv("SPACES_RUNTIME_DIR", originalRuntimePath, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        try body()
    }

    private func currentEnvironmentValue(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }
}

/// Stops a store inside `savePairings`, which calls `createDirectory` before writing, so the store is
/// paused holding the pairings lock with its edit still unwritten. Armed after construction, because
/// resolving the profile root creates directories too.
private final class PausingSaveFileManager: FileManager, @unchecked Sendable {
    let reachedSave = DispatchSemaphore(value: 0)
    let releaseSave = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isArmed = false

    func arm() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil)
        throws
    {
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        lock.lock()
        let shouldPause = isArmed
        isArmed = false
        lock.unlock()
        guard shouldPause else { return }
        reachedSave.signal()
        releaseSave.wait()
    }
}

/// Reports when a store gets as far as reading the pairings file, which is the first thing every
/// mutation does once it holds the lock — so no report means the store is still waiting for it.
private final class SignallingLoadFileManager: FileManager, @unchecked Sendable {
    let reachedLoad = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isArmed = false

    func arm() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }

    override func fileExists(atPath path: String) -> Bool {
        lock.lock()
        let shouldSignal = isArmed
        lock.unlock()
        if shouldSignal { reachedLoad.signal() }
        return super.fileExists(atPath: path)
    }
}

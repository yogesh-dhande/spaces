import Foundation
import XCTest
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesdeviceapi
@testable import spacesui

/// Guards the connect-time recovery contract of `DeviceTerminalSessionStateModel` (issue #185 follow-ups):
///
/// - Test A: a request sender vended to the render host before a local endpoint recovery must observe the
///   rebuilt request client, not keep targeting the cancelled stale-endpoint client. It drives a real
///   in-process `SpacesDeviceAPIServer` because `SpacesDeviceAPIRequestSessionClient` has no protocol seam
///   to fake, then swings the model's `requestClientBox` to a second server the way the local recovery
///   does (that recovery bootstraps through the real local control socket and cannot run hermetically).
/// - Test B: a superseded stream client's late disconnect callback must not tear down the client that
///   replaced it, while a current-stream disconnect still clears it. It drives the generation guard through
///   the model's install-for-testing seam because the concrete stream client offers no way to force
///   callback orderings.
///
/// XCTest rather than Swift Testing deliberately, matching `DeviceTerminalSessionStateModelTranscriptTests`:
/// Test A round-trips per-session filesystem and profile-database state that the server re-resolves from
/// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` at request time. Swift Testing runs all suites concurrently in one
/// process, so another suite mutating that process-global env between writes and reads breaks the
/// round-trip; XCTest classes run serially within their process, which keeps the env stable. The model is
/// `@MainActor`, so the test methods are too; the class itself stays nonisolated so the nonisolated
/// `setUpWithError`/`tearDownWithError` overrides can touch the stored env-restore state.
final class DeviceTerminalSessionStateModelRecoveryTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var profileRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profileRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        if let profileRoot { try? FileManager.default.removeItem(at: profileRoot) }
        try super.tearDownWithError()
    }

    /// Fix 2: a sender vended before a recovery follows the rebuilt request client.
    @MainActor func testVendedRequestSenderFollowsRebuiltRequestClient() throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedRecoveryPairingStore()
        let clientApp = Self.makeClientApp(installationID: "INSTALLATION-RECOVERY-\(UUID().uuidString)")

        // Server A is the stale endpoint the model is seeded against.
        let serverA = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try serverA.start()

        let device = SpacesPairedDeviceRecord(
            id: "recovery-device-\(UUID().uuidString)", name: "Mac", platform: "macos", host: "127.0.0.1", port: serverA.listeningPort,
            certificateFingerprint: identity.certificateFingerprint, createdAt: "2026-07-20T00:00:00Z", updatedAt: "2026-07-20T00:00:00Z",
            lastSelectedAt: "2026-07-20T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: device, sessionID: "session-\(UUID().uuidString)",
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "session", title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-20T00:00:00Z",
                workspaceID: "workspace", kind: .shell),
            clientApp: clientApp,
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: pairingStore.authToken))

        // Vend the sender BEFORE any recovery, as the render host does.
        let sender = model.terminalServiceRequestSender

        // The stale endpoint goes away; a fresh server takes over (as the local daemon does after an
        // idle-shut-down rebind) and the recovery swings the box to a client pointed at it.
        serverA.stop()
        let serverB = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try serverB.start()
        defer { serverB.stop() }
        let clientB = try SpacesDeviceAPIRequestSessionClient(
            host: "127.0.0.1", port: serverB.listeningPort, certificateFingerprint: identity.certificateFingerprint)
        model.requestClientBox.replace(with: clientB).cancel()

        // The previously vended sender must now reach server B. The session does not exist there, so the
        // server answers `ok == false` — a real response, not the connection error a stale-endpoint client
        // would throw. Pre-fix (sender capturing the client by value) this send targets stopped server A
        // and throws.
        let response = try sender(
            TerminalServiceRequest(command: .state(TerminalServiceSessionRequest(sessionID: "missing-session-\(UUID().uuidString)"))))
        XCTAssertFalse(response.ok)
    }

    /// Fix 3: a superseded stream client's late disconnect is ignored; a current-stream disconnect clears it.
    @MainActor func testSupersededStreamDisconnectIsIgnoredWhileCurrentDisconnectClears() throws {
        let unreachableDevice = SpacesPairedDeviceRecord(
            id: "remote-unreachable-\(UUID().uuidString)", name: "Remote", platform: "linux", host: "127.0.0.1", port: 1,
            certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), createdAt: "2026-07-20T00:00:00Z",
            updatedAt: "2026-07-20T00:00:00Z", lastSelectedAt: "2026-07-20T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: unreachableDevice, sessionID: "session-\(UUID().uuidString)",
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "session", title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-20T00:00:00Z",
                workspaceID: "workspace", kind: .shell),
            clientApp: Self.makeClientApp(installationID: "INSTALLATION-GUARD-\(UUID().uuidString)"),
            preparedCredentials: .init(certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), authToken: "token"))

        let staleClient = FakeStreamClient()
        let staleGeneration = model.installStreamClientForTesting(staleClient)
        // A newer stream supersedes the first.
        let currentClient = FakeStreamClient()
        let currentGeneration = model.installStreamClientForTesting(currentClient)
        XCTAssertNotEqual(staleGeneration, currentGeneration)

        // The superseded client's late disconnect must be ignored — the current stream stays installed.
        model.handleStreamDisconnect(nil, generation: staleGeneration)
        XCTAssertTrue(model.hasActiveStreamClientForTesting)

        // The current stream's disconnect clears it, as before the guard.
        model.handleStreamDisconnect(nil, generation: currentGeneration)
        XCTAssertFalse(model.hasActiveStreamClientForTesting)
    }

    // MARK: Fixtures

    private static func makeClientApp(installationID: String) -> SpacesDeviceClientApp {
        SpacesDeviceClientApp(
            installationID: installationID, bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
            appVersion: "1.0")
    }

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair only
    /// needs a stable certificate to pin. Mirrors `DeviceTerminalSessionStateModelTranscriptTests`.
    private static let tlsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "device-terminal-session-state-model-recovery-tests-tls-\(UUID().uuidString)", isDirectory: true)
}

/// `TerminalRemoteStateStreamClient` requires only `stop()`; the model treats any conforming object as an
/// installed stream, which is all the generation-guard test needs.
private final class FakeStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable {
    func stop() {}
}

/// A pairing store that authorizes any request carrying its fixed token. Mirrors the file-private fixture
/// `DeviceTerminalSessionStateModelTranscriptTests` defines for the same purpose.
private final class AlwaysAuthorizedRecoveryPairingStore: SpacesDevicePairingStoreProtocol {
    let authToken = "valid-token"

    func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
    func listDevices() throws -> [SpacesDevicePairedClient] { [] }
    func revoke(installationID _: String) throws {}
    func removeAll() throws {}
    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
        guard clientApp != nil, authToken == self.authToken else {
            throw NSError(
                domain: "DeviceTerminalSessionStateModelRecoveryTests", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
        }
    }
    func validate(clientApp _: SpacesDeviceClientApp) throws {}
}

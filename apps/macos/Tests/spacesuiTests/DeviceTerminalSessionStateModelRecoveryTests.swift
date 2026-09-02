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
///   does (that recovery bootstraps through the real local control socket and cannot run hermetically). A
///   companion test proves the same vended sender — and a transcript fetch — present the box's rotated auth
///   token to the second server, because the box carries the client and its token together.
/// - Test B: a superseded stream client's late disconnect callback must not tear down the client that
///   replaced it, while a current-stream disconnect still clears it. It drives the generation guard through
///   the model's install-for-testing seam because the concrete stream client offers no way to force
///   callback orderings.
/// - Test C: a reachable daemon rejecting the subscribe surfaces `SpacesDeviceAPIRequestClientError`
///   `.requestRejected` to `onDisconnect` carrying the daemon's error code (`.unauthorized`), which the
///   disconnect handler branches on to re-authenticate. It drives a real in-process `SpacesDeviceAPIServer`
///   whose pairing store rejects the token, because the stream client has no seam to fake the wire response.
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
            id: "recovery-device-\(UUID().uuidString)", name: "Mac", platform: "macos", hosts: ["127.0.0.1"], port: serverA.listeningPort,
            certificateFingerprint: identity.certificateFingerprint, createdAt: "2026-07-20T00:00:00Z", updatedAt: "2026-07-20T00:00:00Z",
            lastSelectedAt: "2026-07-20T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: device, sessionID: "session-\(UUID().uuidString)",
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "session", title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-20T00:00:00Z",
                workspaceID: "workspace", kind: .shell), clientApp: clientApp,
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
            resolver: SpacesDeviceEndpointResolver(
                hosts: ["127.0.0.1"], port: serverB.listeningPort, certificateFingerprint: identity.certificateFingerprint))
        model.requestClientBox.replace(with: clientB, authToken: pairingStore.authToken).cancel()

        // The previously vended sender must now reach server B. The session does not exist there, so the
        // server answers `ok == false` — a real response, not the connection error a stale-endpoint client
        // would throw. Pre-fix (sender capturing the client by value) this send targets stopped server A
        // and throws.
        let response = try sender(
            TerminalServiceRequest(command: .state(TerminalServiceSessionRequest(sessionID: "missing-session-\(UUID().uuidString)"))))
        XCTAssertFalse(response.ok)
    }

    /// Fix A: a sender vended before a recovery — and a transcript fetch — authenticate with the box's
    /// rotated auth token, not the token captured at init. A local daemon whose pairing state was reset
    /// mints a fresh token that the recovery swings into the box alongside the rebuilt client, so every
    /// vended sender must present the new token. Asserts on the token the in-process server actually
    /// received on the wire, driving the same box replacement the local recovery performs (that recovery
    /// bootstraps through the real local control socket and cannot run hermetically).
    @MainActor func testVendedSenderAndTranscriptFetchFollowRebuiltAuthToken() async throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let clientApp = Self.makeClientApp(installationID: "INSTALLATION-TOKEN-\(UUID().uuidString)")

        // Server A is the stale endpoint the model is seeded against with the pre-rotation token.
        let storeA = AlwaysAuthorizedRecoveryPairingStore()
        let serverA = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: storeA)
        try serverA.start()

        let device = SpacesPairedDeviceRecord(
            id: "recovery-device-\(UUID().uuidString)", name: "Mac", platform: "macos", hosts: ["127.0.0.1"], port: serverA.listeningPort,
            certificateFingerprint: identity.certificateFingerprint, createdAt: "2026-07-20T00:00:00Z", updatedAt: "2026-07-20T00:00:00Z",
            lastSelectedAt: "2026-07-20T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: device, sessionID: "session-\(UUID().uuidString)",
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "session", title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-20T00:00:00Z",
                workspaceID: "workspace", kind: .shell), clientApp: clientApp,
            preparedCredentials: .init(certificateFingerprint: identity.certificateFingerprint, authToken: storeA.authToken))

        // Vend the sender BEFORE any recovery, as the render host does.
        let sender = model.terminalServiceRequestSender

        // The daemon's pairing state resets: a fresh server mints a new token, and the recovery swings the
        // box to the rebuilt client AND the rotated token together.
        serverA.stop()
        let rotatedToken = "rotated-token-\(UUID().uuidString)"
        let storeB = RecordingRecoveryPairingStore()
        let serverB = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: storeB)
        try serverB.start()
        defer { serverB.stop() }
        let clientB = try SpacesDeviceAPIRequestSessionClient(
            resolver: SpacesDeviceEndpointResolver(
                hosts: ["127.0.0.1"], port: serverB.listeningPort, certificateFingerprint: identity.certificateFingerprint))
        model.requestClientBox.replace(with: clientB, authToken: rotatedToken).cancel()

        // The previously vended sender routes through the box, so it presents the rotated token to server B.
        _ = try sender(TerminalServiceRequest(command: .state(TerminalServiceSessionRequest(sessionID: "missing-session-\(UUID().uuidString)"))))
        // fetchTranscript routes through the same box, so it too presents the rotated token (server B has no
        // such session, so it answers `.sessionNotAvailable`, which fetchTranscript maps to an empty
        // transcript without recovering — the device is not the local device).
        _ = try await model.fetchTranscript(maxBytes: 1000)

        XCTAssertFalse(storeB.presentedTokens.isEmpty, "server B received no request to authorize")
        XCTAssertTrue(
            storeB.presentedTokens.allSatisfy { $0 == rotatedToken },
            "a request reached server B without the rotated token: \(storeB.presentedTokens)")
    }

    /// Fix 3: a superseded stream client's late disconnect is ignored; a current-stream disconnect clears it.
    @MainActor func testSupersededStreamDisconnectIsIgnoredWhileCurrentDisconnectClears() throws {
        let unreachableDevice = SpacesPairedDeviceRecord(
            id: "remote-unreachable-\(UUID().uuidString)", name: "Remote", platform: "linux", hosts: ["127.0.0.1"], port: 1,
            certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), createdAt: "2026-07-20T00:00:00Z",
            updatedAt: "2026-07-20T00:00:00Z", lastSelectedAt: "2026-07-20T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: unreachableDevice, sessionID: "session-\(UUID().uuidString)",
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "session", title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-20T00:00:00Z",
                workspaceID: "workspace", kind: .shell), clientApp: Self.makeClientApp(installationID: "INSTALLATION-GUARD-\(UUID().uuidString)"),
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

    /// Fix B1: a reachable daemon that rejects the subscribe must surface the rejection to `onDisconnect`
    /// as `SpacesDeviceAPIRequestClientError.requestRejected` carrying the daemon's error code, not an
    /// opaque `.connectionFailed`. The disconnect handler branches on `.unauthorized` to re-authenticate,
    /// so the code has to survive the stream client's decode-error mapping. Drives a real in-process
    /// `SpacesDeviceAPIServer` whose pairing store rejects the presented token (which the server maps to
    /// `.unauthorized`), because the concrete stream client has no seam to fake the wire response.
    @MainActor func testStreamSubscribeRejectionSurfacesRequestRejectedWithErrorCode() throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedRecoveryPairingStore()
        let clientApp = Self.makeClientApp(installationID: "INSTALLATION-STREAM-REJECT-\(UUID().uuidString)")

        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        // Present a token the store rejects, so the reachable daemon answers the subscribe with an
        // `.unauthorized` response line rather than a connection failure.
        let request = SpacesDeviceAPIRequest(
            command: .subscribe(SpacesDeviceTerminalSubscriptionRequest(sessionID: "session-\(UUID().uuidString)", clientID: nil)),
            authToken: "revoked-token", clientApp: clientApp)

        let disconnected = expectation(description: "onDisconnect received the rejection")
        let received = DisconnectErrorBox()
        let client = try SpacesDeviceAPIStateStreamClient(
            request: request,
            resolver: SpacesDeviceEndpointResolver(
                hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint), onEvent: { _ in },
            onDisconnect: { error in if received.storeFirst(error) { disconnected.fulfill() } })
        try client.start()
        defer { client.stop() }
        wait(for: [disconnected], timeout: 5)

        guard let error = received.error, case SpacesDeviceAPIRequestClientError.requestRejected(_, let code) = error else {
            return XCTFail("expected requestRejected, got \(String(describing: received.error))")
        }
        XCTAssertEqual(code, .unauthorized)
    }

    /// Fix 1: a transcript request the reachable daemon rejects for an unauthorized (revoked) token must
    /// surface as `SpacesDeviceClientError.requestRejected` carrying the daemon's `.unauthorized` error code,
    /// not an opaque `.unavailable`. The instance-level transcript recovery branches on that code to
    /// re-bootstrap credentials, so the code has to survive the request/response mapping. Drives a real
    /// in-process `SpacesDeviceAPIServer` whose pairing store rejects the presented token (which the server
    /// maps to `.unauthorized`), because the concrete request client has no seam to fake the wire response.
    func testTranscriptRejectedAsUnauthorizedSurfacesRequestRejectedWithErrorCode() throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedRecoveryPairingStore()
        let clientApp = Self.makeClientApp(installationID: "INSTALLATION-TRANSCRIPT-REJECT-\(UUID().uuidString)")

        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let client = try SpacesDeviceAPIRequestSessionClient(
            resolver: SpacesDeviceEndpointResolver(
                hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
        defer { client.cancel() }

        // Present a token the store rejects, so the reachable daemon answers the transcript request with an
        // `.unauthorized` response rather than a connection failure.
        XCTAssertThrowsError(
            try DeviceTerminalSessionStateModel.fetchTranscript(
                sessionID: "session-\(UUID().uuidString)", maxBytes: 1000, requestClient: client, authToken: "revoked-token", clientApp: clientApp)
        ) { error in
            guard case SpacesDeviceClientError.requestRejected(_, let code) = error else { return XCTFail("expected requestRejected, got \(error)") }
            XCTAssertEqual(code, .unauthorized)
        }
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

    /// `tlsRoot` is process-lifetime, shared across every test method in this class, so it is cleaned up
    /// once here rather than per-test in `tearDownWithError`.
    override class func tearDown() {
        try? FileManager.default.removeItem(at: tlsRoot)
        super.tearDown()
    }
}

/// `TerminalRemoteStateStreamClient` requires only `stop()`; the model treats any conforming object as an
/// installed stream, which is all the generation-guard test needs.
private final class FakeStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable { func stop() {} }

/// Captures the first error the stream client reports to `onDisconnect`, thread-safely because that
/// callback runs off the test thread. Only the first error is kept: after surfacing the coded rejection the
/// stream client cancels its connection, which can fire `onDisconnect` again from the close path, so the
/// first error is the one carrying the daemon's rejection.
private final class DisconnectErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    private var value: (any Error)?

    /// Stores the error and returns true only for the first call, so the caller fulfills its expectation once.
    func storeFirst(_ error: (any Error)?) -> Bool {
        lock.withLock {
            guard !stored else { return false }
            stored = true
            value = error
            return true
        }
    }

    var error: (any Error)? { lock.withLock { value } }
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
                domain: "DeviceTerminalSessionStateModelRecoveryTests", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."]
            )
        }
    }
    func validate(clientApp _: SpacesDeviceClientApp) throws {}
}

/// Records every auth token presented to it and authorizes any request carrying a real client app, so a
/// test can assert on the token the in-process server actually received on the wire. Thread-safe because
/// `authorize` runs on the server's own queue.
private final class RecordingRecoveryPairingStore: SpacesDevicePairingStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String?] = []

    var presentedTokens: [String?] { lock.withLock { tokens } }

    func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { "recording-token" }
    func listDevices() throws -> [SpacesDevicePairedClient] { [] }
    func revoke(installationID _: String) throws {}
    func removeAll() throws {}
    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
        lock.withLock { tokens.append(authToken) }
        guard clientApp != nil else {
            throw NSError(
                domain: "DeviceTerminalSessionStateModelRecoveryTests", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing device client app."]
            )
        }
    }
    func validate(clientApp _: SpacesDeviceClientApp) throws {}
}

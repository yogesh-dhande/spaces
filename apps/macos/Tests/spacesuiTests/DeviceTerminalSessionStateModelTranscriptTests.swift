import Foundation
import XCTest
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty

@testable import spacesdeviceapi
@testable import spacesui

/// Exercises `DeviceTerminalSessionStateModel.fetchTranscript`: the mapping the render host's
/// ended-session scrollback replay uses to fetch a transcript suffix (and the run identity it belongs
/// to) through a session's owning device. Like `DeviceTerminalSessionStateModelTerminalLinkTests`, it
/// drives a real in-process `SpacesDeviceAPIServer` because `SpacesDeviceAPIRequestSessionClient` has no
/// protocol seam to fake.
///
/// This is XCTest rather than Swift Testing deliberately: the positive path round-trips per-session
/// filesystem and profile-database state that the server re-resolves from `SPACES_DB_PATH` and
/// `SPACES_RUNTIME_DIR` at request time. Swift Testing runs all suites concurrently in one process, so
/// another suite mutating that process-global env between this test's writes and the server's reads
/// breaks the round-trip; XCTest classes run serially within their process, which keeps the env stable.
final class DeviceTerminalSessionStateModelTranscriptTests: XCTestCase {
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

    func testFetchTranscriptRoundTripsTheSuffixAndRunIdentity() throws {
        try withServer { pairingStore, clientApp, requestClient in
            let sessionID = "transcript-session-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            let transcript = Data("row-1\nrow-2\nrow-3\n".utf8)
            try transcript.write(to: URL(fileURLWithPath: paths.outputPath))
            // Persist runtime state so the server reports the run identity, and assert it round-trips
            // through the model unchanged — the render host validates it against the armed replay run.
            let runtimeState = TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 77, state: .exited, updatedAt: "2026-06-05T00:00:04Z",
                exitedAt: "2026-06-05T00:00:04Z", columns: 8, rows: 5)
            try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)

            let result = try DeviceTerminalSessionStateModel.fetchTranscript(
                sessionID: sessionID, maxBytes: 1_000_000, requestClient: requestClient, authToken: pairingStore.authToken, clientApp: clientApp)
            XCTAssertEqual(result.data, transcript)
            XCTAssertEqual(result.runIdentity, "77|2026-06-05T00:00:04Z")
            XCTAssertEqual(result.runIdentity, runtimeState.runIdentity)
        }
    }

    func testFetchTranscriptReturnsEmptyDataWhenTheDeviceReportsNoTranscript() throws {
        // A missing `output.log` makes the server answer `.sessionNotAvailable`, a definitive "nothing to
        // replay". The model must map that to an empty transcript with no run identity (not throw) so the
        // render host latches its `.unavailable` verdict instead of retrying the doomed fetch on every
        // scroll gesture.
        try withServer { pairingStore, clientApp, requestClient in
            let result = try DeviceTerminalSessionStateModel.fetchTranscript(
                sessionID: "missing-transcript-session-\(UUID().uuidString)", maxBytes: 1000, requestClient: requestClient,
                authToken: pairingStore.authToken, clientApp: clientApp)
            XCTAssertTrue(result.data.isEmpty)
            XCTAssertNil(result.runIdentity)
        }
    }

    // MARK: Server harness

    private func withServer(
        _ body: (
            _ pairingStore: AlwaysAuthorizedTranscriptPairingStore, _ clientApp: SpacesDeviceClientApp,
            _ requestClient: SpacesDeviceAPIRequestSessionClient
        ) throws -> Void
    ) throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedTranscriptPairingStore()
        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }
        let clientApp = SpacesDeviceClientApp(
            installationID: "INSTALLATION-TRANSCRIPT-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
            deviceName: "Mac", appVersion: "1.0")
        let requestClient = try SpacesDeviceAPIRequestSessionClient(
            host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
        defer { requestClient.cancel() }
        try body(pairingStore, clientApp, requestClient)
    }

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair
    /// only needs a stable certificate to pin. Mirrors `SpacesDeviceAPIServerTransportTests`.
    private static let tlsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "device-terminal-session-state-model-transcript-tests-tls-\(UUID().uuidString)", isDirectory: true)
}

/// A pairing store that authorizes any request carrying its fixed token. Mirrors the file-private
/// fixture `DeviceTerminalSessionStateModelTerminalLinkTests` defines for the same purpose.
private final class AlwaysAuthorizedTranscriptPairingStore: SpacesDevicePairingStoreProtocol {
    let authToken = "valid-token"

    func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
    func listDevices() throws -> [SpacesDevicePairedClient] { [] }
    func revoke(installationID _: String) throws {}
    func removeAll() throws {}
    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
        guard clientApp != nil, authToken == self.authToken else {
            throw NSError(
                domain: "DeviceTerminalSessionStateModelTranscriptTests", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
        }
    }
    func validate(clientApp _: SpacesDeviceClientApp) throws {}
}

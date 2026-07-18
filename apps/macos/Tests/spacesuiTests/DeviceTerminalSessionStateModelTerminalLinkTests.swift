import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesdeviceapi
@testable import spacesui

/// Exercises `DeviceTerminalSessionStateModel.sendTerminalServiceRequest`'s terminal-link cases: the
/// mapping the mac GUI uses to resolve a terminal link and fetch its bytes through a session's owning
/// device (local or remote). `SpacesDeviceAPIRequestSessionClient` is a concrete `final class` that
/// always opens a real pinned-TLS connection — there is no protocol seam to fake it through — so these
/// tests spin up a real, in-process `SpacesDeviceAPIServer` the way `SpacesDeviceAPIServerTransportTests`
/// does, and drive it through the model's request sender. The daemon's own link-resolution logic (path
/// classification, workspace-root scoping, transfer authorization) is already covered by that suite;
/// these tests instead prove the model maps `TerminalServiceCommand` <-> `SpacesDeviceAPIRequest`
/// correctly, including the failure path and the `artifactKind` field carried in Step 1.
///
/// Mutates the process-global profile environment, so the suite runs serialized (mirroring
/// `AppKitControllerWindowSummonTests`). `handleResolveTerminalLinkRequest` opens the profile database
/// to load workspace roots for every local-file link. Pinning both the database and runtime directory
/// keeps that access off the developer's profile and gives this temporary profile its own daemon lock.
/// Relative-path anchoring is covered hermetically by the resolver's own unit tests in `spacescliTests`.
@Suite(.serialized) final class DeviceTerminalSessionStateModelTerminalLinkTests {
    private let originalDatabasePath: String?
    private let originalRuntimeDirectory: String?
    private let profileRoot: URL

    init() throws {
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profileRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    deinit {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        try? FileManager.default.removeItem(at: profileRoot)
    }

    @Test func resolveTerminalLinkMapsExternalURLRequestAndUnwrapsMetadataIncludingArtifactKind() throws {
        try withServer { pairingStore, clientApp, requestClient in
            let response = try DeviceTerminalSessionStateModel.sendTerminalServiceRequest(
                TerminalServiceRequest(
                    command: .resolveTerminalLink(
                        TerminalServiceTerminalLinkResolveRequest(sessionID: "missing-session", terminalLink: "https://example.com/screenshot.png"))),
                defaultSessionID: "missing-session", requestClient: requestClient, authToken: pairingStore.authToken, clientApp: clientApp)

            #expect(response.ok)
            let metadata = try #require(response.terminalLinkMetadata)
            #expect(metadata.source == "externalURL")
            #expect(metadata.originalLink == "https://example.com/screenshot.png")
            #expect(metadata.externalURL == "https://example.com/screenshot.png")
            // Step 1 renamed the classifier field to `artifactKind`; this proves the model's mapping
            // survives that rename end to end (Device API enum -> terminal-service wire string).
            #expect(metadata.artifactKind == "image")
        }
    }

    @Test func resolveTerminalLinkSurfacesDeviceAPIFailureAsAnOkFalseResponseWithoutThrowing() throws {
        try withServer { _, clientApp, requestClient in
            // Omitting the auth token reproduces the same unauthenticated rejection
            // `SpacesDeviceAPIServerTransportTests.testTerminalLinkResolveRequiresAuthentication` asserts
            // against the daemon directly; here it proves the model forwards that failure as a normal
            // `ok == false` response (mirroring `.control`/`.state`) instead of throwing.
            let response = try DeviceTerminalSessionStateModel.sendTerminalServiceRequest(
                TerminalServiceRequest(
                    command: .resolveTerminalLink(TerminalServiceTerminalLinkResolveRequest(sessionID: "session-1", terminalLink: "image.png"))),
                defaultSessionID: "session-1", requestClient: requestClient, authToken: nil, clientApp: clientApp)

            #expect(!response.ok)
            #expect(response.message.localizedStandardContains("device auth token"))
            #expect(response.terminalLinkMetadata == nil)
        }
    }

    @Test func readTerminalLinkChunkMapsRequestFieldsAndUnwrapsChunkAfterLocalFileResolve() throws {
        try withServer { pairingStore, clientApp, requestClient in
            let sessionID = "session-link-\(UUID().uuidString)"
            // Absolute, under the resolver's fixed `/tmp` allowlist, and cleaned up below. Deliberately
            // literal `/tmp`, not `FileManager.default.temporaryDirectory` (`/var/folders/...`, which the
            // resolver does not allowlist). Being absolute means resolution never needs the session's
            // working directory, so this test writes no launch configuration or session state.
            let fixtureDir = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixtureDir) }
            let imageFile = fixtureDir.appendingPathComponent("preview.png")
            let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
            try imageData.write(to: imageFile)

            let resolveResponse = try DeviceTerminalSessionStateModel.sendTerminalServiceRequest(
                TerminalServiceRequest(
                    command: .resolveTerminalLink(TerminalServiceTerminalLinkResolveRequest(sessionID: sessionID, terminalLink: imageFile.path))),
                defaultSessionID: sessionID, requestClient: requestClient, authToken: pairingStore.authToken, clientApp: clientApp)
            #expect(resolveResponse.ok, "\(resolveResponse.message)")
            let metadata = try #require(resolveResponse.terminalLinkMetadata)
            #expect(metadata.source == "localFile")

            let chunkResponse = try DeviceTerminalSessionStateModel.sendTerminalServiceRequest(
                TerminalServiceRequest(
                    command: .readTerminalLinkChunk(
                        TerminalServiceTerminalLinkChunkRequest(sessionID: sessionID, terminalLinkID: metadata.id, offset: 0, limit: 16))),
                defaultSessionID: sessionID, requestClient: requestClient, authToken: pairingStore.authToken, clientApp: clientApp)

            #expect(chunkResponse.ok, "\(chunkResponse.message)")
            let chunk = try #require(chunkResponse.terminalLinkChunk)
            #expect(chunk.linkID == metadata.id)
            #expect(chunk.offset == 0)
            #expect(chunk.isFinal)
            #expect(Data(base64Encoded: chunk.base64Data) == imageData)
        }
    }

    @Test func resolveTerminalLinkWithoutALinkThrowsWithoutIssuingADeviceAPIRequest() throws {
        // A nil `terminalLink` has nothing to resolve; the model must reject it locally (mirroring the
        // `.control` case's `AppKitController.deviceTerminalControlRequest` guard) rather than opening a
        // connection for a request the daemon would also reject. Point at a closed port so any attempt to
        // actually send would fail loudly instead of silently succeeding.
        let requestClient = try SpacesDeviceAPIRequestSessionClient(
            host: "127.0.0.1", port: Self.closedPort, certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64))
        let clientApp = Self.makeClientApp(installationID: "INSTALLATION-LINK-GUARD")

        do {
            _ = try DeviceTerminalSessionStateModel.sendTerminalServiceRequest(
                TerminalServiceRequest(
                    command: .resolveTerminalLink(TerminalServiceTerminalLinkResolveRequest(sessionID: "session-1", terminalLink: nil))),
                defaultSessionID: "session-1", requestClient: requestClient, authToken: nil, clientApp: clientApp)
            Issue.record("expected sendTerminalServiceRequest to throw for a missing terminal link")
        } catch let error as WorkspaceError {
            guard case .invalidArgument = error else {
                Issue.record("expected .invalidArgument, got \(error)")
                return
            }
        }
    }

    @Test func readTerminalLinkChunkWithoutALinkIDThrowsWithoutIssuingADeviceAPIRequest() throws {
        let requestClient = try SpacesDeviceAPIRequestSessionClient(
            host: "127.0.0.1", port: Self.closedPort, certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64))
        let clientApp = Self.makeClientApp(installationID: "INSTALLATION-CHUNK-GUARD")

        do {
            _ = try DeviceTerminalSessionStateModel.sendTerminalServiceRequest(
                TerminalServiceRequest(
                    command: .readTerminalLinkChunk(TerminalServiceTerminalLinkChunkRequest(sessionID: "session-1", terminalLinkID: nil))),
                defaultSessionID: "session-1", requestClient: requestClient, authToken: nil, clientApp: clientApp)
            Issue.record("expected sendTerminalServiceRequest to throw for a missing terminal link id")
        } catch let error as WorkspaceError {
            guard case .invalidArgument = error else {
                Issue.record("expected .invalidArgument, got \(error)")
                return
            }
        }
    }

    // The `fetchTranscript` mapping is covered by `DeviceTerminalSessionStateModelTranscriptTests`
    // (XCTest): its positive path round-trips per-session filesystem and profile-database state that the
    // in-process server re-resolves from `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` at request time, and
    // parallel Swift Testing suites mutating that process-global env make such assertions flaky here.

    // MARK: Server harness

    /// A dedicated, never-listening port. The guard-clause tests above assert the model throws before
    /// ever calling `requestClient.send`, so this only needs to construct a valid client, not connect.
    private static let closedPort = 1

    private func withServer(
        _ body: (
            _ pairingStore: AlwaysAuthorizedTerminalLinkPairingStore, _ clientApp: SpacesDeviceClientApp,
            _ requestClient: SpacesDeviceAPIRequestSessionClient
        ) throws -> Void
    ) throws {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
        let pairingStore = AlwaysAuthorizedTerminalLinkPairingStore()
        let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }
        let clientApp = Self.makeClientApp(installationID: "INSTALLATION-LINK-\(UUID().uuidString)")
        let requestClient = try SpacesDeviceAPIRequestSessionClient(
            host: "127.0.0.1", port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
        try body(pairingStore, clientApp, requestClient)
    }

    private static func makeClientApp(installationID: String) -> SpacesDeviceClientApp {
        SpacesDeviceClientApp(
            installationID: installationID, bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
            appVersion: "1.0")
    }

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair
    /// only needs a stable certificate to pin. Mirrors `SpacesDeviceAPIServerTransportTests`.
    private static let tlsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "device-terminal-session-state-model-terminal-link-tests-tls-\(UUID().uuidString)", isDirectory: true)
}

/// A pairing store that authorizes any request carrying its fixed token. Mirrors the fixture
/// `SpacesDeviceAPIServerTransportTests` uses for the same purpose; that fixture is file-private to its
/// own test target, so this suite defines its own rather than exporting a shared test-only type.
private final class AlwaysAuthorizedTerminalLinkPairingStore: SpacesDevicePairingStoreProtocol {
    let authToken = "valid-token"

    func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
    func listDevices() throws -> [SpacesDevicePairedClient] { [] }
    func revoke(installationID _: String) throws {}
    func removeAll() throws {}
    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
        guard clientApp != nil, authToken == self.authToken else {
            throw NSError(
                domain: "DeviceTerminalSessionStateModelTerminalLinkTests", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
        }
    }
    func validate(clientApp _: SpacesDeviceClientApp) throws {}
}

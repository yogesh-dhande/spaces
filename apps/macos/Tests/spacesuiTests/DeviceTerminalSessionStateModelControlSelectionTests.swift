import Dispatch
import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesdeviceapi
@testable import spacesui

extension ProcessProfileEnvironmentSuites {
    /// Pins the fix to `DeviceTerminalSessionStateModel.sendTerminalServiceRequest`'s `.control` case: a
    /// Mac mirroring a paired device's session must receive the daemon-authoritative selection text on
    /// `setSelection`/`readSelectionText`, because that text can extend past the mirror's
    /// viewport-clipped snapshot and is otherwise unrecoverable locally. The adapter used to construct
    /// `TerminalControlResponse(ok:message:)` directly from the Device API response and drop
    /// `response.terminalSelectionText`, so `controlResponse` existed but its `selectionText` was always
    /// nil.
    ///
    /// Drives the same real, in-process `SpacesDeviceAPIServer` harness as
    /// `DeviceTerminalSessionStateModelTerminalLinkTests` (see that suite's doc comment for why a fake
    /// request client cannot stand in), except the terminal-control command reaches the daemon's own
    /// `handleTerminalControlRequest`, which resolves the session purely from the filesystem
    /// (`TerminalSessionPaths.forSession(id:)`) and forwards to whatever answers the session's control
    /// socket. So this suite stands up a real `TerminalControlServer` on that socket instead of a running
    /// terminal session.
    ///
    /// Mutates the process-global profile environment for the same reason the terminal-link suite does:
    /// `TerminalSessionPaths.forSession(id:)` resolves under `SPACES_RUNTIME_DIR`. Nests under
    /// `ProcessProfileEnvironmentSuites` rather than declaring its own `.serialized` trait; see that
    /// parent's doc comment for why a per-suite trait alone does not keep two such suites from clobbering
    /// each other's environment overrides.
    @Suite final class DeviceTerminalSessionStateModelControlSelectionTests {
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

        @Test func controlRequestMapsSelectionTextFromTheDeviceAPIResponseOntoTheControlResponse() throws {
            try withServer { pairingStore, clientApp, requestClient in
                let sessionID = "session-control-selection-\(UUID().uuidString)"

                // `handleTerminalControlRequest` resolves the session's control socket purely from the
                // filesystem: it rejects only when a readable runtime state says the session is not
                // interactive (absent/unreadable passes) and otherwise requires the control socket file
                // to exist. So standing up a real `TerminalControlServer` on that socket, with no session
                // launch config or runtime state, is enough to exercise the daemon's mapping.
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: paths.controlSocketPath).deletingLastPathComponent(), withIntermediateDirectories: true)

                let expectedSelectionText = "line one\nline two from scrollback"
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.control-selection.test")
                ) { request in
                    #expect(request.command == "readSelectionText")
                    return TerminalControlResponse(ok: true, message: "", selectionText: expectedSelectionText)
                }
                try controlServer.start()
                defer { controlServer.stop() }

                let response = try DeviceTerminalSessionStateModel.sendTerminalServiceRequest(
                    TerminalServiceRequest(
                        command: .control(
                            .init(sessionID: sessionID, controlRequest: TerminalControlRequest(command: "readSelectionText")))),
                    defaultSessionID: sessionID, requestClient: requestClient, authToken: pairingStore.authToken, clientApp: clientApp)

                #expect(response.ok, "\(response.message)")
                // The regression pin: before the fix `controlResponse` was constructed straight from
                // `TerminalControlResponse(ok:message:)`, which always leaves `selectionText` nil.
                #expect(response.controlResponse?.selectionText == expectedSelectionText)
            }
        }

        // MARK: Server harness

        private func withServer(
            _ body: (
                _ pairingStore: AlwaysAuthorizedControlSelectionPairingStore, _ clientApp: SpacesDeviceClientApp,
                _ requestClient: SpacesDeviceAPIRequestSessionClient
            ) throws -> Void
        ) throws {
            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: Self.tlsRoot)
            let pairingStore = AlwaysAuthorizedControlSelectionPairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            defer { server.stop() }
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-CONTROL-SELECTION-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID,
                platform: "macos", deviceName: "Mac", appVersion: "1.0")
            let requestClient = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
            try body(pairingStore, clientApp, requestClient)
        }

        /// One pinned-TLS identity per test process: generation is expensive and every server/client pair
        /// only needs a stable certificate to pin. Mirrors `SpacesDeviceAPIServerTransportTests` and
        /// `DeviceTerminalSessionStateModelTerminalLinkTests`.
        private static let tlsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "device-terminal-session-state-model-control-selection-tests-tls-\(UUID().uuidString)", isDirectory: true)
    }
}

/// A pairing store that authorizes any request carrying its fixed token. Mirrors the fixture
/// `SpacesDeviceAPIServerTransportTests` uses for the same purpose; that fixture, and the near-identical
/// one in `DeviceTerminalSessionStateModelTerminalLinkTests`, are file-private to their own test files, so
/// this suite defines its own rather than exporting a shared test-only type.
private final class AlwaysAuthorizedControlSelectionPairingStore: SpacesDevicePairingStoreProtocol {
    let authToken = "valid-token"

    func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
    func listDevices() throws -> [SpacesDevicePairedClient] { [] }
    func revoke(installationID _: String) throws {}
    func removeAll() throws {}
    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
        guard clientApp != nil, authToken == self.authToken else {
            throw NSError(
                domain: "DeviceTerminalSessionStateModelControlSelectionTests", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
        }
    }
    func validate(clientApp _: SpacesDeviceClientApp) throws {}
}

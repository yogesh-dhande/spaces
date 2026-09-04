import Foundation
import Network
import UIKit
import spacesdevicecore
import spacesterminalcore

enum SpacesDeviceAPIClientError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String, code: SpacesDeviceErrorCode? = nil)
    /// The peer closed the connection before answering: the receive completed with no bytes decoded, so
    /// this is EOF, not a daemon response. A transport failure, never a daemon answer, unlike
    /// `.requestFailed`, which is the shape of a decoded rejection (`ok == false`); a caller must not
    /// treat this one as "the daemon answered and said no" (see `TerminalViewerModel.isConnectionLevelInputTransportError`).
    case connectionClosed
    case transportAuthenticationFailed
    /// Every candidate in the paired device's `hosts` list was tried and none answered, with no pin
    /// mismatch seen on any of them (a mismatch instead throws `transportAuthenticationFailed`, which
    /// routes into re-pair recovery — see `SpacesDeviceEndpointResolver.connect`). Carries the hosts
    /// that were tried so the message can name them and point at Tailscale as the likely fix, since the
    /// most common cause is being away from the device's local network with Tailscale not connected.
    case allCandidatesUnreachable(hosts: [String])
    case missingOverview
    /// The stream never produced a usable response at all: the client's own wait for the first payload
    /// ran out, or bytes arrived that failed to decode as either a state event or a response envelope.
    /// This is the "the daemon never answered" shape, as opposed to `.streamRejected` below (the daemon
    /// answered, but declined the subscription), see `isStreamHostTransportFailure` for why the two are
    /// kept apart.
    case streamFailed(String, code: SpacesDeviceErrorCode? = nil)
    /// A response envelope decoded cleanly off the stream and reported `ok == false`: the daemon
    /// answered and rejected the subscription (e.g. the session ended, or is not live yet). This proves
    /// the address itself is good, so it must not count as a failed candidate the way a genuine dial or
    /// transport failure does, see `isStreamHostTransportFailure`.
    case streamRejected(String, code: SpacesDeviceErrorCode? = nil)
    /// The stream connection stayed open but stopped delivering bytes for longer than
    /// `TerminalStreamLiveness.silenceTimeoutSeconds`, which the daemon's keepalive rules out for a
    /// healthy link (see `StreamSubscription.start`). Transient: the viewer reconnects on it.
    case streamStalled
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The Device API host or port is invalid."
        case .requestFailed(let message, _): message
        case .connectionClosed: "The Device API connection closed before it answered."
        case .transportAuthenticationFailed: "The secure Device API transport could not authenticate."
        case .allCandidatesUnreachable(let hosts):
            "Could not reach the device at any of its known addresses (\(hosts.joined(separator: ", "))). If you're away from its network, make sure Tailscale is connected on both devices."
        case .missingOverview: "The Device API did not return a workspace or terminal overview."
        case .streamFailed(let message, _): message
        case .streamRejected(let message, _): message
        case .streamStalled: "The terminal stream stopped responding."
        case .requestTimedOut: "The Device API request timed out."
        }
    }
}

extension SpacesDeviceAPIClientError: SpacesDeviceErrorCodeProviding {
    var spacesDeviceErrorCode: SpacesDeviceErrorCode? {
        switch self {
        case .requestFailed(_, let code), .streamFailed(_, let code), .streamRejected(_, let code): code
        default: nil
        }
    }
}

extension SpacesDeviceAPIClientError {
    /// Mirrors Mac's `SpacesDeviceAPIStreamEndpoint.isHostTransportFailure`: the address-failure
    /// classifier that decides whether a stream disconnect is evidence the *address* is bad (worth
    /// recording against the resolver's per-host failure count) or evidence that the daemon on the other
    /// end answered (a decoded rejection, or bytes that failed to decode at all), which must not poison
    /// a candidate that is demonstrably still there. Recording a rejection would let a stream serving a
    /// stale session on host A read, once combined with a real dial failure on host B, as "every
    /// candidate is down" (see `openSessionStream`).
    ///
    /// Unlike Mac, a pinned-certificate mismatch counts here as a transport failure: this backend folds
    /// a pin rejection into the same failed-candidate bucket it uses for a dead dial (see
    /// `SpacesDeviceEndpointResolver.noteStreamFailed`'s doc comment), so this classifier stays
    /// consistent with the resolver instead of carving out an exception only the stream path would honor.
    static func isStreamHostTransportFailure(_ error: any Error) -> Bool {
        if let clientError = error as? SpacesDeviceAPIClientError {
            switch clientError {
            case .streamFailed, .streamStalled: return true
            case .streamRejected: return false
            default: return false
            }
        }
        if error is TerminalServiceTLSError { return true }
        if let networkError = error as? NWError {
            switch networkError {
            case .posix(let code): return isRetryableStreamHostPOSIXCode(code)
            // A name that does not resolve, or a handshake the path broke, is evidence about this address just as
            // a refused dial is. A pin mismatch never reaches here as `.tls` (the verify block surfaces it as
            // `TerminalServiceTLSError`, handled above), so this does not change how a mismatch is classified.
            case .dns, .tls: return true
            default: return false
            }
        }
        if let posixError = error as? POSIXError { return isRetryableStreamHostPOSIXCode(posixError.code) }
        return false
    }

    /// The connection-level drop shapes a dial or a subscribe write can surface. `EPIPE` belongs with
    /// `ECONNRESET`: the peer went away underneath a write, which the input path already treats as a
    /// lost link, and leaving it out would keep the cached host and redial the same broken address.
    private static func isRetryableStreamHostPOSIXCode(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .ECONNABORTED, .ECONNREFUSED, .ECONNRESET, .EHOSTDOWN, .EHOSTUNREACH, .ENETDOWN, .ENETUNREACH, .ENOTCONN, .EPIPE, .ETIMEDOUT: return true
        default: return false
        }
    }
}

/// What a session stream reports when it ends. `dialExhaustedAllCandidates` is the verdict of
/// `SpacesDeviceEndpointResolver.noteStreamFailed(host:)` for the failed dial that ended this stream,
/// captured at the moment the failure was recorded and carried with the event itself (not re-queried
/// off the shared resolver, and not parked on the handle, which the owning model may not have
/// installed yet when a fast dial failure reports). `false` for a clean close, a decoded rejection
/// (the daemon answered), and a backend with no such concept (Demo Mode).
struct SpacesDeviceAPIStreamDisconnect: Sendable {
    let error: (any Error)?
    let dialExhaustedAllCandidates: Bool

    init(error: (any Error)?, dialExhaustedAllCandidates: Bool = false) {
        self.error = error
        self.dialExhaustedAllCandidates = dialExhaustedAllCandidates
    }
}

final class SpacesDeviceAPIStreamHandle: @unchecked Sendable {
    /// The address this stream actually connected to, for a backend that has one (a real network
    /// backend; `nil` for Demo Mode, which has no host at all). Distinct from
    /// `SpacesDeviceAPIClient.currentResolvedHost()`, which reports the *command* path's most recently
    /// proven address; this stream may be running on a different candidate (see
    /// `SpacesDeviceEndpointResolver`'s doc comment on why streams and commands pick hosts differently).
    /// The input-timeout ping-corroboration probe (`TerminalViewerModel.startInputTimeoutCorroborationProbe`)
    /// needs exactly this stream's own host, not the command path's, to ask the right question.
    let host: String?
    private let cancelHandler: @Sendable () -> Void

    init(host: String? = nil, cancelHandler: @escaping @Sendable () -> Void) {
        self.host = host
        self.cancelHandler = cancelHandler
    }

    func cancel() { cancelHandler() }
}

struct SpacesDeviceAPIClient: Sendable {
    /// Placeholder used only when a caller (in practice, only tests) doesn't supply a real device name.
    /// Never used in production: every production call site passes `UIDevice.current.name` explicitly.
    private static let fallbackDeviceName = "iOS Device"

    let settings: SpacesMobileConnectionSettings
    /// This device's display name, captured once by the caller and stored rather than read here on
    /// demand: `UIDevice.current.name` is main-actor-isolated, but this type's request path is not.
    private let deviceName: String
    /// The transport seam. Defaults to the pinned-TLS network backend; Demo Mode injects an in-memory
    /// backend. Every request round trip and session stream funnels through it, so swapping the backend
    /// reroutes the entire client without touching call sites.
    private let backend: any SpacesDeviceAPIBackend

    init(
        settings: SpacesMobileConnectionSettings, deviceName: String = SpacesDeviceAPIClient.fallbackDeviceName,
        backend: (any SpacesDeviceAPIBackend)? = nil
    ) {
        self.settings = settings
        self.deviceName = deviceName
        self.backend = backend ?? SpacesDeviceNetworkBackend(settings: settings)
    }

    /// Test seam: injects canned request/response handling while session streams keep using the real
    /// network path (a closure never intercepted streams, matching the historical behavior). The mobile
    /// unit suite drives the client through this closure.
    init(
        settings: SpacesMobileConnectionSettings, deviceName: String = SpacesDeviceAPIClient.fallbackDeviceName,
        requestHandler: @escaping @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse
    ) { self.init(settings: settings, deviceName: deviceName, backend: SpacesDeviceClosureBackend(settings: settings, handler: requestHandler)) }

    func makeCommandChannel() -> SpacesDeviceAPICommandChannel {
        SpacesDeviceAPICommandChannel(transport: backend.makeRequestTransport(), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
    }

    func pair(pairingLink: SpacesDevicePairingLink, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> String {
        // Refuse to redeem an incompatible link before the one-time pairing window is consumed.
        switch SpacesWireCompatibility.evaluate(daemonProtocolVersion: pairingLink.protocolVersion, localVersion: SpacesWireProtocol.version) {
        case .compatible: break
        case .daemonTooOld:
            throw SpacesDeviceAPIClientError.requestFailed(
                "\(pairingLink.name) is running Spaces \(pairingLink.appVersion), which is older than this app. Update Spaces on \(pairingLink.name), then pair again."
            )
        case .clientTooOld:
            throw SpacesDeviceAPIClientError.requestFailed(
                "\(pairingLink.name) is running Spaces \(pairingLink.appVersion), which is newer than this app. Update Spaces on this device, then pair again."
            )
        }
        let response = try await sendRequest(
            .init(
                command: .pair(
                    .init(pairingCode: pairingLink.code, pairingNonce: pairingLink.nonce, clientProtocolVersion: SpacesWireProtocol.version)),
                clientApp: clientAppIdentity), commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let issuedAuthToken = response.issuedAuthToken else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return an auth token.")
        }
        return issuedAuthToken
    }

    func fetchOverview(commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> SpacesDeviceOverviewPayload {
        let response = try await sendRequest(
            .init(command: .overview, authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), timeout: .seconds(8),
            commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let overview = response.overview else { throw SpacesDeviceAPIClientError.missingOverview }
        return overview
    }

    /// Frozen-core handshake read: fetches the daemon's wire protocol + restart-impact status.
    func fetchDaemonStatus(commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> TerminalServiceDaemonStatus {
        let response = try await sendRequest(
            .init(command: .daemonStatus, authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), timeout: .seconds(8),
            commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let status = response.daemonStatus else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return daemon status.")
        }
        return status
    }

    /// Frozen-core restart request: asks the daemon to restart itself (the device's service manager
    /// respawns it). iOS cannot restart a daemon out of band, so this RPC is the only restart path.
    func requestDaemonRestart(commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws {
        let response = try await sendRequest(
            .init(command: .requestDaemonRestart, authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), timeout: .seconds(8),
            commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func fetchWorkspaceCreateOptions(projectID: String? = nil, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceWorkspaceCreateOptions
    {
        let response = try await sendRequest(
            .init(command: .workspaceCreateOptions(.init(projectID: projectID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let options = response.workspaceCreateOptions else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return workspace create options.")
        }
        return options
    }

    func createWorkspace(_ config: CreateWorkspaceConfig, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .createWorkspace(
                    .init(
                        projectID: config.projectID, branch: config.branch, baseBranch: config.baseBranch, directoryName: config.directoryName,
                        allowExistingBranchReuse: config.allowExistingBranchReuse)), authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    /// Starts every configured process and coding agent in the workspace. Browser sessions and ad hoc
    /// terminals are not launched — the daemon opens neither, they are opened on demand.
    func launchWorkspace(workspaceID: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .launchWorkspace(.init(workspaceID: workspaceID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
    }

    func stopWorkspace(workspaceID: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .stopWorkspace(.init(workspaceID: workspaceID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
    }

    func restartWorkspace(workspaceID: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .restartWorkspace(.init(workspaceID: workspaceID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
    }

    /// Deletes a workspace: the daemon stops it, removes its git worktree, and drops the workspace and its
    /// settings. Branch deletion is opt-in and is the one part that can partly fail (a protected branch, a
    /// remote that refused), so its report comes back as the response's `mutationNotice`.
    func archiveWorkspace(
        workspaceID: String, deleteLocalBranch: Bool, deleteRemoteBranch: Bool, commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .archiveWorkspace(
                    .init(workspaceID: workspaceID, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    /// Hides or unhides a workspace. `isHidden` is daemon-owned workspace state, so this is the same flag
    /// the Mac sidebar's Hide action and Workspace Visibility dialog toggle — hiding here hides it there.
    func setWorkspaceHidden(workspaceID: String, isHidden: Bool, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .updateWorkspaceMetadata(.init(workspaceID: workspaceID, isHidden: isHidden, updatesHidden: true)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    /// Hides or unhides a project. `isHidden` is daemon-owned project state, mirroring
    /// `setWorkspaceHidden` above — the same flag the Mac sidebar's project-level Hide toggles. iOS never
    /// calls this with `isHidden: true`: hiding a project is Mac-only, iOS only recovers one.
    func setProjectHidden(projectID: String, isHidden: Bool, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .updateProjectMetadata(.init(projectID: projectID, isHidden: isHidden, updatesHidden: true)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    func openWorkspaceTerminal(workspaceID: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .openWorkspaceTerminal(.init(workspaceID: workspaceID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
    }

    func stopWorkspaceTerminal(workspaceID: String, sessionID: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .stopWorkspaceTerminal(.init(workspaceID: workspaceID, sessionID: sessionID)), authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    /// Renames an ad hoc workspace terminal session. The daemon rejects sessions owned by a configured
    /// process (those own their name through the workspace config) or by a coding agent (renamed through
    /// `renameAgentSession`).
    func renameTerminalSession(workspaceID: String, sessionID: String, title: String, commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .renameTerminalSession(.init(workspaceID: workspaceID, sessionID: sessionID, title: title)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    func renameAgentSession(workspaceID: String, agentID: String, title: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .renameAgentSession(.init(workspaceID: workspaceID, agentID: agentID, title: title)), authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    /// Replaces the workspace's whole configuration. The daemon overwrites every configured field from the
    /// request, so a caller sends the workspace's current config with only its own edit applied.
    func updateWorkspaceConfig(workspaceID: String, config: SpacesDeviceWorkspaceConfig, commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .updateWorkspaceConfig(.init(workspaceID: workspaceID, config: config)), authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    /// Reads one file inside a workspace's checkout (capped at 10 MiB on the daemon side; see
    /// `SpacesDeviceAPIServer.workspaceFileMaxBytes`). Wire parity with the Mac client; no iOS UI in v1.
    func workspaceFileRead(workspaceID: String, relativePath: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceWorkspaceFileReadResult
    {
        let response = try await sendRequest(
            .init(
                command: .workspaceFileRead(.init(workspaceID: workspaceID, relativePath: relativePath)), authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity), timeout: .seconds(60), commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let result = response.workspaceFileRead else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return a workspace file read result.")
        }
        return result
    }

    func workspaceRevisionFileRead(
        workspaceID: String, revision: String, relativePath: String, oldPath: String? = nil,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceWorkspaceRevisionFileReadResult
    {
        let response = try await sendRequest(
            .init(
                command: .workspaceRevisionFileRead(
                    .init(workspaceID: workspaceID, revision: revision, relativePath: relativePath, oldPath: oldPath)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), timeout: .seconds(60), commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let result = response.workspaceRevisionFileRead else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return a workspace revision file read result.")
        }
        return result
    }

    /// Compare-and-swap write to one file inside a workspace's checkout. `expectedSHA256` should be the
    /// hash last read via `workspaceFileRead`, or `nil` to assert the file must not exist yet. A mismatch
    /// is not thrown: `didWrite` is `false` and the result carries the disk content to merge against. Wire
    /// parity with the Mac client; no iOS UI in v1.
    func workspaceFileWrite(
        workspaceID: String, relativePath: String, base64Data: String, expectedSHA256: String? = nil,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceWorkspaceFileWriteResult {
        let response = try await sendRequest(
            .init(
                command: .workspaceFileWrite(
                    .init(workspaceID: workspaceID, relativePath: relativePath, base64Data: base64Data, expectedSHA256: expectedSHA256)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), timeout: .seconds(60), commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let result = response.workspaceFileWrite else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return a workspace file write result.")
        }
        return result
    }

    func runWorkspaceProcess(
        workspaceID: String, processKey: String, processTemplateID: String?, commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .runWorkspaceProcess(.init(workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    func stopWorkspaceProcess(workspaceID: String, processID: String, processKey: String?, commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .stopWorkspaceProcess(.init(workspaceID: workspaceID, processID: processID, processKey: processKey, processTemplateID: nil)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    func restartWorkspaceProcess(workspaceID: String, processID: String, processKey: String?, commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .restartWorkspaceProcess(
                    .init(workspaceID: workspaceID, processID: processID, processKey: processKey, processTemplateID: nil)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    func stopCodingAgent(workspaceID: String, agentID: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .stopCodingAgent(.init(workspaceID: workspaceID, agentID: agentID)), authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    /// Manually fires an automation, respecting the daemon's concurrency gate. The response carries the
    /// resulting run (started, queued, or skipped) but no overview, so the caller reloads the overview to
    /// reflect it — see `SpacesMobileAppModel.triggerAutomation`.
    func triggerAutomation(id: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .triggerAutomation(.init(id: id)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
    }

    /// Sets a one-time next run for an automation, overriding only its next occurrence. Like
    /// `triggerAutomation`, the response carries no overview, so the caller reloads it: see
    /// `SpacesMobileAppModel.setAutomationNextRun`.
    func setAutomationNextRun(id: String, nextRunTime: Date, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .setAutomationNextRun(.init(id: id, nextRunTime: TerminalSessionTimestamp.fractionalString(from: nextRunTime))),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    /// Cancels a running (or queued) automation run.
    func cancelAutomationRun(runID: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .cancelAutomationRun(.init(runID: runID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
    }

    /// Ends a finished run's still-live attributed coding agents (the run itself has already reached a
    /// terminal status; only its spawned coding-agent sessions are still up).
    func endAutomationAgents(runID: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .endAutomationAgents(.init(runID: runID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
    }

    /// Reads one automation's retained run history from the daemon (the newest runs it keeps per automation),
    /// rather than the recent-runs window the overview carries. The per-automation "View Runs" screen fetches
    /// through this so a chatty automation filling the global overview window can't leave another automation's
    /// history looking empty. Read-only (replay-safe), so it uses `sendRequest` rather than `mutation`.
    func listAutomationRuns(automationID: String, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> [TerminalServiceAutomationRunSummary]
    {
        let response = try await sendRequest(
            .init(
                command: .listAutomationRuns(.init(automationID: automationID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        return response.automationRuns ?? []
    }

    func fetchState(sessionID: String, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> GhosttyRemoteSessionStatePayload
    {
        let request = SpacesDeviceAPIRequest(
            command: .state(.init(sessionID: sessionID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let sessionState = response.sessionState else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return terminal state.")
        }
        return sessionState
    }

    func attach(
        sessionID: String, client: TerminalClient, mode: TerminalAttachmentMode, appearance: ThemeAppearance,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .attach, sessionID: sessionID, client: client, attachmentMode: mode, appearance: appearance)),
            authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func detach(sessionID: String, clientID: String, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws
    {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .detach, sessionID: sessionID, clientID: clientID)), authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    /// Renews an attached remote client's lease without changing its attachment mode. A foreground
    /// terminal detail uses the `.notFound` response to distinguish an expired client row, which it
    /// must reattach as a viewer before it can take ownership again, from a transient transport failure.
    func heartbeat(sessionID: String, clientID: String, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws
    {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .heartbeat, sessionID: sessionID, clientID: clientID)), authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func takeOver(sessionID: String, clientID: String, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> GhosttyRemoteSessionStatePayload?
    {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .takeover, sessionID: sessionID, clientID: clientID)), authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        return response.sessionState
    }

    func sendText(
        context: TerminalCommandContext, text: String, appendNewline: Bool = false, asPaste: Bool = false, timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .send, sessionID: context.sessionID, clientID: context.clientID, text: text, ownerEpoch: context.ownerEpoch,
                    appendNewline: appendNewline, asPaste: asPaste)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func sendKey(context: TerminalCommandContext, key: String, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws
    {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(action: .key, sessionID: context.sessionID, clientID: context.clientID, key: key, ownerEpoch: context.ownerEpoch)),
            authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    /// Pastes a staged image into the session. Multi-MiB base64-encoded payloads take meaningfully
    /// longer to transmit than ordinary text/key input, so this uses a 30 s default timeout instead
    /// of the 6 s timeout used elsewhere for interactive input.
    func pasteImage(
        context: TerminalCommandContext, fileExtension: String, imageData: Data, timeout: Duration = .seconds(30),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalPasteImage(
                SpacesDeviceTerminalPasteImageRequest(
                    sessionID: context.sessionID, clientID: context.clientID, ownerEpoch: context.ownerEpoch, fileExtension: fileExtension,
                    imageData: imageData)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func clearScreen(context: TerminalCommandContext, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws
    {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(action: .clearScreen, sessionID: context.sessionID, clientID: context.clientID, ownerEpoch: context.ownerEpoch)),
            authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    /// Clears the daemon's shared selection for every viewer of the session, not just this client. Not
    /// owner-gated: iOS never creates a selection (#514), it only ever clears the one the daemon already
    /// has, which any attached client may do regardless of who is driving the terminal.
    func clearSelection(sessionID: String, clientID: String, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws
    {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .clearSelection, sessionID: sessionID, clientID: clientID)), authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    /// Reads the daemon's shared selection as plain text, including the parts scrolled out of the
    /// viewport that painted highlight never carries. The Copy pill's only use of this: the highlight
    /// itself is projected/clipped per frame, but the text this returns is always the full selection.
    func readSelectionText(sessionID: String, clientID: String, timeout: Duration = .seconds(6), commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> String
    {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .readSelectionText, sessionID: sessionID, clientID: clientID)),
            authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let selectionText = response.terminalSelectionText else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return selection text.")
        }
        return selectionText
    }

    func resize(
        context: TerminalCommandContext, columns: Int, rows: Int, resizeSerial: UInt64?, timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .resize, sessionID: context.sessionID, clientID: context.clientID, columns: columns, rows: rows,
                    ownerEpoch: context.ownerEpoch, resizeSerial: resizeSerial)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func scroll(
        context: TerminalCommandContext, horizontal: Double, vertical: Double, scrollMods: Int32? = nil,
        pointerPosition: TerminalScrollPointerPosition? = nil, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .scroll, sessionID: context.sessionID, clientID: context.clientID, ownerEpoch: context.ownerEpoch,
                    scrollHorizontal: horizontal, scrollVertical: vertical, scrollMods: scrollMods, scrollPointerX: pointerPosition?.x,
                    scrollPointerY: pointerPosition?.y, scrollPointerMods: pointerPosition?.mods)), authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    /// Sends one mouse button press or release, forwarded to the session's terminal when a mouse-aware
    /// application there is tracking the mouse. The pointer is normalized the same way `scroll`'s is.
    func mouseButton(
        context: TerminalCommandContext, button: UInt8, pressed: Bool, pointerPosition: TerminalScrollPointerPosition? = nil,
        timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .mouseButton, sessionID: context.sessionID, clientID: context.clientID, ownerEpoch: context.ownerEpoch,
                    mouseButton: button, mousePressed: pressed, mousePointerX: pointerPosition?.x, mousePointerY: pointerPosition?.y,
                    mousePointerMods: pointerPosition?.mods)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    /// Pushes the app's light/dark appearance to a live session so the daemon re-themes it mid-session.
    /// Appearance is a per-client view preference, not owner-gated, so a viewer may send it; the daemon
    /// treats a same-value request as a cheap no-op (see the session core's setAppearance handler).
    func setAppearance(
        sessionID: String, clientID: String, appearance: ThemeAppearance, timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .setAppearance, sessionID: sessionID, clientID: clientID, appearance: appearance)),
            authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func resolveTerminalLink(sessionID: String, link: String, timeout: Duration = .seconds(6), commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> SpacesDeviceTerminalLinkMetadata
    {
        let request = SpacesDeviceAPIRequest(
            command: .resolveTerminalLink(.init(sessionID: sessionID, terminalLink: link)), authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let metadata = response.terminalLinkMetadata else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return terminal link metadata.")
        }
        return metadata
    }

    func readTerminalLinkChunk(
        sessionID: String, linkID: String, offset: Int64, limit: Int, timeout: Duration = .seconds(6),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceTerminalLinkChunk {
        let request = SpacesDeviceAPIRequest(
            command: .readTerminalLinkChunk(.init(sessionID: sessionID, terminalLinkID: linkID, offset: offset, limit: limit)),
            authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let chunk = response.terminalLinkChunk else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return terminal link data.")
        }
        return chunk
    }

    func subscribe(
        sessionID: String, clientID: String, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
    ) async throws -> SpacesDeviceAPIStreamHandle {
        let request = SpacesDeviceAPIRequest(
            command: .subscribe(.init(sessionID: sessionID, clientID: clientID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        return try await backend.openSessionStream(request: request, onEvent: onEvent, onDisconnect: onDisconnect)
    }

    /// The address this client's backend most recently proved reachable, if it has resolved one yet.
    /// Distinct from `settings.primaryHost` or a paired-device record's persisted `activeHost`: those
    /// are snapshots that can go stale (settings captured at construction, a record written after the
    /// fact), while this asks the live resolver what actually completed a handshake. `nil` for a backend
    /// with no such concept (Demo Mode, the closure test backend) and for a network backend that has not
    /// resolved anything yet.
    func currentResolvedHost() async -> String? { await backend.currentResolvedHost() }

    /// Clears this client's endpoint resolution so the next request or stream re-races every candidate
    /// address instead of continuing on whichever one most recently answered — the foreground
    /// re-preference for LAN over Tailscale. Resets only the shared resolver; it does not close any
    /// specific `SpacesDeviceAPICommandChannel`'s open connection, since a client has no visibility into
    /// channels its callers built independently. A caller holding such a channel should also call its own
    /// `close()` so its current connection is dropped and the next send reconnects through the reset
    /// resolver, and must leave any open session stream alone — see `SpacesMobileAppModel.resetActiveConnectionEndpoint()`.
    func resetEndpointResolution() async { await backend.resetEndpointResolution() }

    /// Pings `host` specifically, bypassing the backend's normal multi-candidate address resolution.
    /// Backs the input-timeout ping-corroboration probe (see
    /// `TerminalViewerModel.startInputTimeoutCorroborationProbe`): a bare request timeout on an
    /// otherwise-live stream is inconclusive on its own, so before treating it as a lost connection the
    /// viewer asks specifically the host the stream already depends on whether the daemon is still
    /// there: a fresh multi-candidate race would answer a different, less useful question ("is the
    /// daemon reachable *somewhere*"). Returns `nil` when any response comes back (an error response
    /// still proves the daemon answered), or the failure otherwise.
    func sendPinnedPing(host: String, timeout: Duration) async -> (any Error)? {
        let request = SpacesDeviceAPIRequest(command: .ping, authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        return await backend.sendPinnedPing(request: request, host: host, timeout: timeout)
    }

    private func mutation(_ request: SpacesDeviceAPIRequest, commandChannel: SpacesDeviceAPICommandChannel?) async throws -> SpacesDeviceAPIResponse {
        let response = try await sendRequest(request, timeout: .seconds(30), commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        return response
    }

    private func sendRequest(_ request: SpacesDeviceAPIRequest, timeout: Duration = .seconds(3)) async throws -> SpacesDeviceAPIResponse {
        try await sendRequest(request, timeout: timeout, commandChannel: nil)
    }

    private func sendRequest(_ request: SpacesDeviceAPIRequest, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel?)
        async throws -> SpacesDeviceAPIResponse
    {
        if let commandChannel { return try await commandChannel.send(request: request, timeout: timeout) }
        let temporaryCommandChannel = makeCommandChannel()
        do {
            let response = try await temporaryCommandChannel.send(request: request, timeout: timeout)
            await temporaryCommandChannel.close()
            return response
        } catch {
            await temporaryCommandChannel.close()
            throw error
        }
    }

    private var clientAppIdentity: SpacesDeviceClientApp {
        SpacesDeviceClientApp(
            installationID: settings.installationID, bundleID: Bundle.main.bundleIdentifier ?? SpacesDeviceFirstPartyPolicy.allowedBundleID,
            platform: "ios", deviceName: deviceName, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

}

/// Thin actor over `any SpacesDeviceAPIRequestTransport`. Keeps its name and public surface
/// (`send(request:timeout:)`, `close()`) so `SpacesMobileAppModel`, `TerminalViewerModel`, and
/// `ConnectionSettingsView` compile unchanged. It owns the auth-token/client-app defaulting so every
/// backend transport receives a fully-addressed request.
actor SpacesDeviceAPICommandChannel {
    private let transport: any SpacesDeviceAPIRequestTransport
    private let authToken: String?
    private let clientApp: SpacesDeviceClientApp
    /// Whether a round trip is on the wire. The transport under this channel keeps ONE connection and the
    /// wire is line framed with no request identifiers, so the reply to whatever was written last is the
    /// next line to arrive and nothing tells two callers apart. Both this actor and the transport actor
    /// suspend inside a send (the write, then the read), and an actor lets another call in at every
    /// suspension, so without this gate a second caller writes its request while the first is still
    /// waiting on its reply and each then reads the other's answer. That is not a rare interleaving now
    /// that one viewer's attach, state reads, takeover, heartbeat, resize, and input all ride the same
    /// channel: the foreground heartbeat and the state read behind it are issued together.
    private var isRoundTripInFlight = false
    /// Callers waiting their turn, resumed one at a time in arrival order — by `endRoundTrip` handing the
    /// gate on, by that waiter's own timeout task giving up, or by the waiter's task being cancelled.
    /// Each carries an id so any of the three can remove exactly its own entry rather than guessing which
    /// continuation is still pending; removal is what keeps the resume to exactly one of the three.
    private var roundTripWaiters: [RoundTripWaiter] = []
    private var nextRoundTripWaiterID: UInt64 = 0

    private struct RoundTripWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<RoundTripTurnOutcome, Never>
    }

    /// What a suspended `waitForTurn` was resumed with. `endRoundTrip` hands the gate directly to the
    /// head waiter rather than clearing `isRoundTripInFlight` and letting whoever wakes up race for it
    /// again, so `.gateHandedOff` means the gate is already this waiter's: `beginRoundTrip` returns
    /// without re-checking or re-setting the flag. `.giveUp` covers both a timeout and a cancellation:
    /// neither owns the gate, so `beginRoundTrip` throws directly rather than looping.
    private enum RoundTripTurnOutcome {
        case gateHandedOff
        case giveUp
    }

    init(transport: any SpacesDeviceAPIRequestTransport, authToken: String?, clientApp: SpacesDeviceClientApp) {
        self.transport = transport
        self.authToken = authToken
        self.clientApp = clientApp
    }

    func close() async { await transport.close() }

    /// `timeout` is a deadline over the whole round trip, not just the time on the wire: it also bounds
    /// the wait for this channel's gate, so a fast request queued behind a slow one cannot silently
    /// inherit the slow one's duration (a 3 s detach queued behind a 12 s state read must not
    /// take 15 s). `beginRoundTrip` throws `requestTimedOut` without ever acquiring the gate if the
    /// wait alone exhausts `timeout`; only a caller that acquires the gate reaches the transport, and it
    /// does so with whatever of `timeout` the wait left, so the transport's own budget cannot be inflated
    /// by time this call already spent waiting.
    func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
        var request = request
        if request.authToken == nil {
            request = SpacesDeviceAPIRequest(command: request.command, authToken: authToken, clientApp: request.clientApp ?? clientApp)
        }
        let waitStartedAt = ContinuousClock.now
        try await beginRoundTrip(timeout: timeout)
        defer { endRoundTrip() }
        let remainingTimeout = timeout - (ContinuousClock.now - waitStartedAt)
        // The gate can be handed over just as the deadline expires. Sending anyway would give the
        // transport a zero budget it can still write a mutating command inside, leaving the caller
        // reporting a timeout for a command that executed; an exhausted deadline fails before the send.
        guard remainingTimeout > .zero else { throw SpacesDeviceAPIClientError.requestTimedOut }
        // A failure here leaves the transport to drop its connection and the next caller to redial, which
        // is why the gate is released for a throwing send exactly as for a successful one.
        return try await transport.send(request: request, timeout: remainingTimeout)
    }

    private func beginRoundTrip(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        // A `while` loop rather than a single wait: resuming a waiter and setting `isRoundTripInFlight`
        // back to true are two separate actor turns, so a fresh caller can slip in and reacquire the gate
        // between them. Looping re-checks the gate rather than trusting a stale "it's your turn" signal —
        // except when the turn arrives as an explicit handoff (see below), where there is nothing to
        // re-check: the gate is already this caller's.
        while isRoundTripInFlight {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw SpacesDeviceAPIClientError.requestTimedOut }
            switch await waitForTurn(timeout: remaining) {
            case .gateHandedOff:
                // `endRoundTrip` kept `isRoundTripInFlight` true and resumed this waiter as the gate's
                // new owner. Returning here (rather than falling through to `isRoundTripInFlight = true`
                // below and looping again) is what makes the handoff a direct pass rather than a
                // re-race: a fresh caller cannot slip in ahead of a waiter that already owns the gate.
                return
            case .giveUp:
                if Task.isCancelled { throw CancellationError() }
                throw SpacesDeviceAPIClientError.requestTimedOut
            }
        }
        isRoundTripInFlight = true
    }

    /// Suspends until either this waiter is handed the gate (`endRoundTrip` resumes it with
    /// `.gateHandedOff`), `timeout` elapses (its own timeout task resumes it with `.giveUp`), or the
    /// calling task is cancelled (the cancellation handler resumes it with `.giveUp`). Whichever of the
    /// three runs first removes the waiter from `roundTripWaiters` before resuming it — that removal is
    /// what arbitrates among them, so the continuation is resumed exactly once regardless of which side
    /// wins the race.
    private func waitForTurn(timeout: Duration) async -> RoundTripTurnOutcome {
        let id = nextRoundTripWaiterID
        nextRoundTripWaiterID += 1
        let channel = self
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RoundTripTurnOutcome, Never>) in
                roundTripWaiters.append(RoundTripWaiter(id: id, continuation: continuation))
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    await channel.timeoutRoundTripWaiter(id: id)
                }
            }
        } onCancel: {
            Task.detached { await channel.cancelRoundTripWaiter(id: id) }
        }
    }

    private func timeoutRoundTripWaiter(id: UInt64) {
        guard let index = roundTripWaiters.firstIndex(where: { $0.id == id }) else { return }
        roundTripWaiters.remove(at: index).continuation.resume(returning: .giveUp)
    }

    /// A cancelled caller must not stay queued until its own timeout: this is the other end of
    /// `waitForTurn`'s `withTaskCancellationHandler`. Removal from `roundTripWaiters` is what makes this
    /// safe against the timeout task or `endRoundTrip` also racing for the same waiter — whichever finds
    /// the id first is the one that resumes it, and this is a no-op for a waiter already taken by either.
    private func cancelRoundTripWaiter(id: UInt64) {
        guard let index = roundTripWaiters.firstIndex(where: { $0.id == id }) else { return }
        roundTripWaiters.remove(at: index).continuation.resume(returning: .giveUp)
    }

    private func endRoundTrip() {
        guard !roundTripWaiters.isEmpty else {
            isRoundTripInFlight = false
            return
        }
        // Hand the gate directly to the head waiter instead of clearing `isRoundTripInFlight` first: a
        // caller that has been queued the longest must not lose the gate to a fresh caller that happens
        // to notice it free first. `isRoundTripInFlight` stays true across the handoff; the resumed
        // waiter already owns it (see `beginRoundTrip`'s `.gateHandedOff` case) and never re-sets it.
        roundTripWaiters.removeFirst().continuation.resume(returning: .gateHandedOff)
    }
}

/// Production backend: the pinned-TLS Device API over `NWConnection`.
struct SpacesDeviceNetworkBackend: SpacesDeviceAPIBackend {
    let settings: SpacesMobileConnectionSettings
    /// Shared by both `makeRequestTransport()` and `openSessionStream(...)`: this backend value is
    /// created once per `SpacesDeviceAPIClient` but read from two independent call paths, and both
    /// must converge on the same cached winner and in-flight candidate walk (see
    /// `SpacesDeviceEndpointResolver`'s doc comment).
    let resolver: SpacesDeviceEndpointResolver

    /// Silence budget handed to every session stream this backend opens. Only tests pass anything other
    /// than the default, and they pass a shorter one so a stalled-stream assertion does not wait out the production timeout.
    let streamSilenceTimeout: TimeInterval

    init(settings: SpacesMobileConnectionSettings, streamSilenceTimeout: TimeInterval = TerminalStreamLiveness.silenceTimeoutSeconds) {
        self.settings = settings
        self.streamSilenceTimeout = streamSilenceTimeout
        resolver = SpacesDeviceEndpointResolver(settings: settings)
    }

    func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { SpacesDeviceNetworkRequestTransport(resolver: resolver) }

    func openSessionStream(
        request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
    ) async throws -> SpacesDeviceAPIStreamHandle {
        let label: String
        if case .subscribe(let payload) = request.command {
            label = "spaces.device.api.stream.\(payload.sessionID).\(payload.clientID)"
        } else {
            label = "spaces.device.api.stream"
        }
        let queue = DispatchQueue(label: label)
        // Non-blocking by design — it hands `StreamSubscription` an unstarted connection and lets that
        // own the handshake inside its own "connect plus first payload" budget, so a subscribe against
        // a hung endpoint cannot stall the caller's post-subscribe state refresh (which is what
        // surfaces an authentication failure fast). That rules out racing candidates here the way
        // `connect(timeout:queue:)` does for commands: a stream cannot pay a blocking race without
        // delaying the very error reporting the viewer depends on. So a stream instead converges across
        // reconnect attempts rather than within one — `nextStreamHost()` prefers the resolver's cached
        // winner (typically already warm from a command-channel request or the resolver's own
        // construction-time seed) and otherwise walks to the next candidate this backend has not
        // already reported failed, so a viewer that keeps reconnecting an already-attached owner (no
        // intervening command request to refresh the cache) still makes forward progress through every
        // candidate instead of retrying the same dead address forever.
        let host = await resolver.nextStreamHost() ?? ""
        guard let nwPort = UInt16(exactly: settings.port).flatMap(NWEndpoint.Port.init(rawValue:)), !host.isEmpty else {
            throw SpacesDeviceAPIClientError.invalidEndpoint
        }
        let pinRejection = SpacesPinnedTLSPinRejection()
        let parameters = SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: settings.certificateFingerprint, pinRejection: pinRejection)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        // A stream that ends with a transport-level error means the address it was on may no longer be
        // good (the device left the network it was reachable on, the daemon restarted somewhere else,
        // etc.), report the failure to the resolver here, next to the thing that learned the address, so
        // the next stream this backend opens (via `nextStreamHost()`) moves on to a different candidate
        // instead of retrying the same dead one indefinitely. A `nil` error is a clean cancellation (the
        // caller closed the stream on purpose, e.g. the viewer was dismissed) and must not invalidate an
        // address that never actually failed. Nor must a decoded rejection (`.streamRejected`) or a
        // decode failure: both prove the daemon on the other end of this address answered, which is the
        // opposite of address evidence, see `SpacesDeviceAPIClientError.isStreamHostTransportFailure`.
        // Skipping the resolver call for those also skips `dialExhaustedAllCandidates`, which stays at its
        // default `false`, so a rejection never contributes to "every candidate is down".
        //
        // The failure must land on the resolver, and the verdict it returns must travel with this
        // `onDisconnect` call itself, not through a property set on `handle` afterward: `connect()`
        // starts the subscription before it installs the returned handle onto the model
        // (`TerminalViewerModel.streamHandle = handle` runs only once `subscribe()` resumes), and both
        // that resumption and a fast dial failure's disconnect callback are ordinary main-actor jobs, so
        // a failure reported before the handle is installed would otherwise find no handle to stamp the
        // verdict onto and silently lose it. Carrying the verdict on the event itself, captured here at
        // the moment the failure is recorded, sidesteps that ordering entirely. Recording the failure,
        // capturing its verdict, and invoking the callback race in one `Task` on the main actor rather
        // than several independent ones.
        let resolver = self.resolver
        let handle = SpacesDeviceAPIStreamHandle(host: host) { connection.cancel() }
        let invalidatingOnDisconnect: @MainActor (Error?) -> Void = { error in
            guard let error else {
                onDisconnect(SpacesDeviceAPIStreamDisconnect(error: nil))
                return
            }
            guard SpacesDeviceAPIClientError.isStreamHostTransportFailure(error) else {
                onDisconnect(SpacesDeviceAPIStreamDisconnect(error: error))
                return
            }
            Task { @MainActor in
                let exhausted = await resolver.noteStreamFailed(host: host)
                onDisconnect(SpacesDeviceAPIStreamDisconnect(error: error, dialExhaustedAllCandidates: exhausted))
            }
        }
        StreamSubscription(
            connection: connection, pinRejection: pinRejection, request: request, silenceTimeout: streamSilenceTimeout, onEvent: onEvent,
            onDisconnect: invalidatingOnDisconnect
        ).start(on: queue)
        return handle
    }

    /// The resolver's cached winner, if it has one — see `SpacesDeviceAPIClient.currentResolvedHost()`.
    func currentResolvedHost() async -> String? { await resolver.currentCachedHost() }

    /// Forgets the resolver's cached winner (see `SpacesDeviceAPIClient.resetEndpointResolution()`).
    func resetEndpointResolution() async { await resolver.clearCachedWinner() }

    /// Opens a one-shot pinned-TLS connection to `host` specifically (bypassing the resolver's normal
    /// multi-candidate race, see `SpacesDeviceEndpointResolver.connect(host:timeout:queue:)`), sends
    /// `request`, and waits for a response. Returns `nil` when any response comes back at all (even a
    /// rejection proves the daemon answered), or the failure when the connection or round trip itself
    /// did not complete within `timeout`. Used only for the input-timeout ping-corroboration probe (see
    /// `SpacesDeviceAPIClient.sendPinnedPing(host:timeout:)`).
    ///
    /// `timeout` is one end-to-end deadline across connect, send, and read, not a budget reissued to
    /// each stage: a link that accepts the dial and then never answers must still fail around one
    /// `timeout`, not the sum of three. `deadline` is captured once at entry and each stage is handed
    /// only what remains of it (mirrors `SpacesDeviceAPICommandChannel.send(request:timeout:)`'s
    /// deadline math). A remainder at or below zero fails immediately with the same `requestTimedOut`
    /// the transport itself throws on an ordinary timeout, without spending a stage on a connection
    /// that has no budget left to use.
    func sendPinnedPing(request: SpacesDeviceAPIRequest, host: String, timeout: Duration) async -> (any Error)? {
        let queue = DispatchQueue(label: "spaces.device.api.ping.\(host)")
        let deadline = ContinuousClock.now + timeout
        func remainingOrTimeout() throws -> Duration {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw SpacesDeviceAPIClientError.requestTimedOut }
            return remaining
        }
        do {
            let connection = try await resolver.connect(host: host, timeout: remainingOrTimeout(), queue: queue)
            defer { connection.cancel() }
            try await SpacesDeviceNetworkRequestTransport.send(
                data: encodeDeviceAPIRequestLine(request), on: connection, timeout: remainingOrTimeout())
            _ = try await SpacesDeviceNetworkRequestTransport.readLine(from: connection, timeout: remainingOrTimeout())
            return nil
        } catch {
            // A cancelled probe (the caller lost interest: a healthy frame arrived on the stream this
            // probe was corroborating, or the viewer was dismissed while it was in flight) says nothing
            // about `host` itself: the probe never got, or stopped waiting for, an answer, which is not
            // the same as the daemon failing to answer. Recording it anyway would poison an address that
            // may still be perfectly healthy for the next reconnect, and could even manufacture a false
            // "every candidate has failed" verdict by combining a merely-cancelled probe with one
            // genuinely failed candidate. Mirrors the streaming path's own `nil`-error exemption above.
            //
            // `error is CancellationError` alone is not enough: a cancellation that lands during
            // `resolver.connect` never reaches here as `CancellationError` at all, because
            // `SpacesDeviceEndpointResolver.attempt` catches every failure (cancellation included),
            // reduces it to a bare pin-mismatch bit, and `connect(host:timeout:queue:)` rethrows that
            // as a generic `requestFailed`, discarding the original error. `Task.isCancelled` is the
            // only signal that survives that translation.
            guard !(error is CancellationError), !Task.isCancelled else { return error }
            await resolver.noteStreamFailed(host: host)
            return error
        }
    }
}

/// Test backend: routes request round trips through a closure while session streams keep using the
/// real network path (a closure never intercepted streams). Backs `SpacesDeviceAPIClient(settings:requestHandler:)`.
struct SpacesDeviceClosureBackend: SpacesDeviceAPIBackend {
    private let networkBackend: SpacesDeviceNetworkBackend
    private let handler: @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse

    init(settings: SpacesMobileConnectionSettings, handler: @escaping @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse) {
        networkBackend = SpacesDeviceNetworkBackend(settings: settings)
        self.handler = handler
    }

    func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { SpacesDeviceClosureRequestTransport(handler: handler) }

    func openSessionStream(
        request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
    ) async throws -> SpacesDeviceAPIStreamHandle {
        try await networkBackend.openSessionStream(request: request, onEvent: onEvent, onDisconnect: onDisconnect)
    }

    /// Routes the ping through the same `handler` closure every other request already goes through,
    /// rather than a bespoke fake: a test controls the ping-corroboration probe's outcome the same way
    /// it controls every other request: answer `.ping` from `handler` (probe "answered"), or throw
    /// (probe "failed"), with no separate seam to keep in sync.
    func sendPinnedPing(request: SpacesDeviceAPIRequest, host: String, timeout: Duration) async -> (any Error)? {
        do {
            _ = try await handler(request)
            return nil
        } catch { return error }
    }

}

private struct SpacesDeviceClosureRequestTransport: SpacesDeviceAPIRequestTransport {
    let handler: @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse

    func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse { try await handler(request) }
    func close() async {}
}

/// Holds an app-backgrounded notification observer for the lifetime of its owner, unregistering it when
/// the owner goes away. Exists so an actor can register from its `init`: a nonisolated initializer cannot
/// touch an actor-isolated stored property of non-Sendable type, and the observer token is exactly that.
/// `@unchecked Sendable` is sound because `observe` is called once, from that initializer, before the
/// owner escapes; the token is never written again.
private final class BackgroundNotificationObserver: @unchecked Sendable {
    private var token: (any NSObjectProtocol)?

    func observe(_ handler: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            handler()
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

/// Network request transport: owns one pinned-TLS command connection. This is the request/response
/// half of the former command channel; auth-token/client-app defaulting now lives in the channel.
actor SpacesDeviceNetworkRequestTransport: SpacesDeviceAPIRequestTransport {
    private let resolver: SpacesDeviceEndpointResolver
    private let queue = DispatchQueue(label: "spaces.device.api.command")
    private var connection: NWConnection?
    private let backgroundObserver = BackgroundNotificationObserver()

    init(resolver: SpacesDeviceEndpointResolver) {
        self.resolver = resolver
        // A cached socket cannot survive process suspension: iOS tears it down while the app is in the
        // background, and the next request on it fails with ENOTCONN before `connectIfNeeded` ever gets
        // to redial. Dropping the cache here — at the one place that owns it — means every channel built
        // on this transport (the overview poll, an open terminal viewer, one-shot mutation channels)
        // dials fresh on the way back to the foreground instead of surfacing a spurious connection error.
        backgroundObserver.observe { [weak self] in
            guard let self else { return }
            Task { await self.close() }
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
        let connection = try await connectIfNeeded(timeout: timeout)
        do {
            try await Self.send(data: encodeDeviceAPIRequestLine(request), on: connection, timeout: timeout)
            let responseData = try await Self.readLine(from: connection, timeout: timeout)
            return try SpacesDeviceAPICodec.decodeResponse(responseData)
        } catch {
            close()
            // A send/receive failure means the cached "known-good" address may no longer be reachable
            // (e.g. this device left the network it was last connected from) — clear the resolver's
            // cache so the very next attempt re-walks every candidate from the top instead of retrying
            // the same address first.
            await resolver.clearCachedWinner()
            throw error
        }
    }

    private func connectIfNeeded(timeout: Duration) async throws -> NWConnection {
        if let connection { return connection }
        let resolved = try await resolver.connect(timeout: timeout, queue: queue)
        connection = resolved.connection
        return resolved.connection
    }

    /// `fileprivate` (not `private`): `SpacesDeviceNetworkBackend.sendPinnedPing` reuses this to write
    /// the ping request on a connection it opened itself, rather than duplicating the wire framing.
    fileprivate static func send(data: Data, on connection: NWConnection, timeout: Duration) async throws {
        try await SpacesDeviceAPIConnectionSupport.withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = OneShotContinuation(continuation)
                connection.send(
                    content: data, contentContext: .defaultMessage, isComplete: false,
                    completion: .contentProcessed { error in if let error { resume.resume(throwing: error) } else { resume.resume(returning: ()) } })
            }
        }
    }

    /// `fileprivate` (not `private`): see `send(data:on:timeout:)` above.
    fileprivate static func readLine(from connection: NWConnection, timeout: Duration) async throws -> Data {
        try await SpacesDeviceAPIConnectionSupport.withTimeout(timeout) { try await readLineAccumulating(from: connection, data: Data()) }
    }

    private static func readLineAccumulating(from connection: NWConnection, data: Data) async throws -> Data {
        if let newlineIndex = data.firstIndex(of: 0x0A) { return Data(data.prefix(upTo: newlineIndex)) }
        return try await withCheckedThrowingContinuation { continuation in
            let resume = OneShotContinuation(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    resume.resume(throwing: error)
                    return
                }
                var nextData = data
                if let content, !content.isEmpty { nextData.append(content) }
                if let newlineIndex = nextData.firstIndex(of: 0x0A) {
                    resume.resume(returning: Data(nextData.prefix(upTo: newlineIndex)))
                    return
                }
                if isComplete {
                    if nextData.isEmpty {
                        resume.resume(throwing: SpacesDeviceAPIClientError.connectionClosed)
                    } else {
                        resume.resume(returning: nextData)
                    }
                    return
                }
                Task {
                    do { resume.resume(returning: try await readLineAccumulating(from: connection, data: nextData)) } catch {
                        resume.resume(throwing: error)
                    }
                }
            }
        }
    }
}

/// Not file-private: `SpacesDeviceEndpointResolver` (a separate file) also walks candidate connects
/// through `waitUntilReady`.
enum SpacesDeviceAPIConnectionSupport {
    /// Drives `connection` to `.ready`, capped at `timeout`.
    ///
    /// `pinRejection` is the box the connection's pinned-TLS parameters were built with, when the
    /// caller needs to tell a rejected pin apart from any other handshake failure. Its verdict, not
    /// the `NWError` shape, decides identity: a failure is rethrown as the verify block's own
    /// `TerminalServiceTLSError` whenever one was recorded, so the single authority
    /// `SpacesDeviceAPIAuthentication.isTransportAuthenticationFailure` recognizes it.
    static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue, timeout: Duration, pinRejection: SpacesPinnedTLSPinRejection? = nil)
        async throws
    {
        try await withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = OneShotContinuation(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resume.resume(returning: ())
                    case .failed(let error): resume.resume(throwing: pinRejection?.error ?? error)
                    case .waiting:
                        // Network.framework treats a rejected pinned certificate as a retryable
                        // condition and parks the connection in `.waiting` rather than failing it
                        // outright, so left alone this would silently keep redialing the same rejected
                        // handshake for the rest of the timeout budget instead of surfacing the failure
                        // (the "silently retries forever" symptom a rotated daemon identity produces).
                        // A rejected pin is not going to resolve itself on the next retry, so it
                        // resolves the wait immediately. Every other `.waiting` cause (a momentarily
                        // unreachable route, an interface still coming up as the app returns to the
                        // foreground) is genuinely retryable and keeps its chance at the remaining
                        // budget, which is why only the verify block's own verdict ends the wait here.
                        guard let rejection = pinRejection?.error else { return }
                        resume.resume(throwing: rejection)
                    case .cancelled: resume.resume(throwing: SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled."))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    static func withTimeout<T: Sendable>(_ timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let timeoutState = TimeoutOperationHolder<T>()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                let operationState = TimeoutOperation(continuation)
                timeoutState.set(operationState)

                let operationTask = Task {
                    do { operationState.resume(returning: try await operation()) } catch { operationState.resume(throwing: error) }
                }
                operationState.addTask(operationTask)

                let timeoutTask = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    operationState.resume(throwing: SpacesDeviceAPIClientError.requestTimedOut)
                }
                operationState.addTask(timeoutTask)
            }
        } onCancel: {
            timeoutState.cancel()
        }
    }
}

private final class TimeoutOperationHolder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: TimeoutOperation<T>?

    func set(_ operation: TimeoutOperation<T>) {
        lock.lock()
        self.operation = operation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let operation = operation
        self.operation = nil
        lock.unlock()
        operation?.resume(throwing: CancellationError())
    }
}

private final class TimeoutOperation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var tasks: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    func addTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = continuation == nil
        if !shouldCancel { tasks.append(task) }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func resume(returning value: T) { finish { continuation in continuation.resume(returning: value) } }

    func resume(throwing error: any Error) { finish { continuation in continuation.resume(throwing: error) } }

    private func finish(_ resume: (CheckedContinuation<T, any Error>) -> Void) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let tasks = tasks
        self.tasks = []
        lock.unlock()

        for task in tasks { task.cancel() }
        resume(continuation)
    }
}

private final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    func resume(returning value: T) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private final class StreamLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let onDisconnect: @MainActor (Error?) -> Void

    init(onDisconnect: @escaping @MainActor (Error?) -> Void) { self.onDisconnect = onDisconnect }

    func finish(error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        Task { @MainActor in onDisconnect(error) }
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

private final class StreamSubscription: @unchecked Sendable {
    /// One budget covering the whole way from starting the connection to decoding the first payload,
    /// since this type owns the handshake as well as the wait for terminal state.
    private static let initialEventTimeout: Duration = .seconds(12)

    private let connection: NWConnection
    private let pinRejection: SpacesPinnedTLSPinRejection
    private let request: SpacesDeviceAPIRequest
    private let lifecycle: StreamLifecycle
    private let onEvent: @MainActor (GhosttyRemoteSessionStatePayload) -> Void
    /// How long the connection may deliver no bytes at all before this subscription treats it as dead.
    /// Injected only so tests can compress the wait; production always passes
    /// `TerminalStreamLiveness.silenceTimeoutSeconds`.
    private let silenceTimeout: TimeInterval
    private var buffer = Data()
    private var decodedState = false
    private var connectionReady = false
    /// Uptime of the last bytes received, keepalives included. Confined to the stream's queue, which runs
    /// both the receive callbacks and the silence check.
    private var lastReceiveUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

    init(
        connection: NWConnection, pinRejection: SpacesPinnedTLSPinRejection, request: SpacesDeviceAPIRequest, silenceTimeout: TimeInterval,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @MainActor (Error?) -> Void
    ) {
        self.connection = connection
        self.pinRejection = pinRejection
        self.request = request
        self.silenceTimeout = silenceTimeout
        self.onEvent = onEvent
        lifecycle = StreamLifecycle(onDisconnect: onDisconnect)
    }

    /// Starts the unstarted connection the caller handed over and drives it to the first payload. This
    /// owns the handshake deliberately: doing it here rather than awaiting a ready connection in
    /// `openSessionStream` keeps subscribing non-blocking, so the viewer's post-subscribe state refresh
    /// still runs (and can surface an authentication failure promptly) even when the endpoint accepts
    /// TCP but never completes TLS.
    ///
    /// `pinRejection` carries the connection's own pinned-TLS verdict, so a handshake that failed
    /// because the daemon's identity did not match reaches the re-pair recovery flow, while a handshake
    /// that merely stalled or dropped reads as the stalled stream it is and gets retried.
    func start(on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + Self.initialEventTimeout.timeInterval) { [weak self] in
            guard let self, !decodedState else { return }
            if !connectionReady, let rejection = pinRejection.error {
                lifecycle.finish(error: rejection)
            } else {
                lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed("Timed out waiting for terminal state."))
            }
            connection.cancel()
        }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connectionReady = true
                lastReceiveUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
                // Armed only once the connection is up: everything before that (dial, TLS handshake, the
                // wait for the first payload) is already covered by `initialEventTimeout`, and starting
                // the silence clock earlier would just double-count the handshake.
                scheduleSilenceCheck(on: queue)
                sendInitialRequest()
            case .failed(let error):
                lifecycle.finish(error: pinRejection.error ?? error)
                // Cancel, like every other way a stream ends here (the initial-event timeout, a send
                // failure, a decode failure, a receive error, a clean close). A connection holds its
                // handler blocks until it is cancelled, and those blocks hold this subscription, its
                // buffer, and the per-stream `DispatchQueue` — so a termination that only reports the drop
                // orphans all of it. Network.framework reaches `.failed` rarely (an unreachable endpoint,
                // a refused port, and a rejected pin all sit in `.waiting` instead, and a connection that
                // dies after `.ready` surfaces through the outstanding receive), which is exactly why this
                // branch must not be the one that forgets: nothing downstream would notice.
                connection.cancel()
            case .cancelled: lifecycle.finish(error: nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func sendInitialRequest() {
        do {
            let data = try encodeDeviceAPIRequestLine(request)
            connection.send(
                content: data, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { [self] error in
                    if let error {
                        lifecycle.finish(error: error)
                        connection.cancel()
                        return
                    }
                    receiveNext()
                })
        } catch {
            lifecycle.finish(error: error)
            connection.cancel()
        }
    }

    /// Re-arms itself on the stream's queue until the stream ends, and finishes the subscription once the
    /// connection has been silent for `silenceTimeout`. This is the client half of the terminal stream's
    /// liveness contract: the daemon writes a keepalive every
    /// `TerminalStreamLiveness.keepaliveIntervalSeconds`, so silence past the timeout means the transport
    /// is gone even though TCP still believes the peer is there — which is exactly the case that used to
    /// leave the viewer rendering a frozen screen while its request channel kept working.
    private func scheduleSilenceCheck(on queue: DispatchQueue) {
        let checkInterval = TerminalStreamLiveness.silenceCheckIntervalSeconds(forTimeout: silenceTimeout)
        queue.asyncAfter(deadline: .now() + checkInterval) { [weak self] in
            guard let self, !lifecycle.isFinished else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- lastReceiveUptimeNanoseconds) / 1_000_000_000
            guard elapsed < silenceTimeout else {
                lifecycle.finish(error: SpacesDeviceAPIClientError.streamStalled)
                connection.cancel()
                return
            }
            scheduleSilenceCheck(on: queue)
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] content, _, isComplete, error in
            if let content, !content.isEmpty {
                // Any bytes count as proof of life, including the daemon's empty-line keepalives, which
                // the framing loop below drops before decoding.
                lastReceiveUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
                buffer.append(content)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer.prefix(upTo: newlineIndex))
                    buffer.removeSubrange(...newlineIndex)
                    guard !line.isEmpty else { continue }
                    do {
                        let payload = try GhosttyRemoteSessionStateCodec.decodeLine(line)
                        decodedState = true
                        Task { @MainActor in onEvent(payload) }
                    } catch {
                        if let response = try? SpacesDeviceAPICodec.decodeResponse(line), !response.ok {
                            lifecycle.finish(error: SpacesDeviceAPIClientError.streamRejected(response.message, code: response.errorCode))
                            connection.cancel()
                            return
                        }
                        lifecycle.finish(error: error)
                        connection.cancel()
                        return
                    }
                }
            }

            if let error {
                lifecycle.finish(error: error)
                connection.cancel()
                return
            }

            if isComplete {
                if !decodedState, !buffer.isEmpty, let response = try? SpacesDeviceAPICodec.decodeResponse(buffer), !response.ok {
                    lifecycle.finish(error: SpacesDeviceAPIClientError.streamRejected(response.message, code: response.errorCode))
                } else {
                    lifecycle.finish(error: nil)
                }
                connection.cancel()
                return
            }

            receiveNext()
        }
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}

private func encodeDeviceAPIRequestLine(_ request: SpacesDeviceAPIRequest) throws -> Data {
    var data = try SpacesDeviceAPICodec.encodeRequest(request)
    data.append(0x0A)
    return data
}

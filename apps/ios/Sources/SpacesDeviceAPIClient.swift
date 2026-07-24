import Foundation
import Network
import spacesdevicecore
import spacesterminalcore

enum SpacesDeviceAPIClientError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String, code: SpacesDeviceErrorCode? = nil)
    case transportAuthenticationFailed
    /// Every candidate in the paired device's `hosts` list was tried and none answered, with no pin
    /// mismatch seen on any of them (a mismatch instead throws `transportAuthenticationFailed`, which
    /// routes into re-pair recovery — see `SpacesDeviceEndpointResolver.connect`). Carries the hosts
    /// that were tried so the message can name them and point at Tailscale as the likely fix, since the
    /// most common cause is being away from the device's local network with Tailscale not connected.
    case allCandidatesUnreachable(hosts: [String])
    case missingOverview
    case streamFailed(String, code: SpacesDeviceErrorCode? = nil)
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The Device API host or port is invalid."
        case .requestFailed(let message, _): message
        case .transportAuthenticationFailed: "The secure Device API transport could not authenticate."
        case .allCandidatesUnreachable(let hosts):
            "Could not reach the device at any of its known addresses (\(hosts.joined(separator: ", "))). If you're away from its network, make sure Tailscale is connected on both devices."
        case .missingOverview: "The Device API did not return a workspace or terminal overview."
        case .streamFailed(let message, _): message
        case .requestTimedOut: "The Device API request timed out."
        }
    }
}

extension SpacesDeviceAPIClientError: SpacesDeviceErrorCodeProviding {
    var spacesDeviceErrorCode: SpacesDeviceErrorCode? {
        switch self {
        case .requestFailed(_, let code), .streamFailed(_, let code): code
        default: nil
        }
    }
}

final class SpacesDeviceAPIStreamHandle: @unchecked Sendable {
    private let cancelHandler: @Sendable () -> Void

    init(cancelHandler: @escaping @Sendable () -> Void) { self.cancelHandler = cancelHandler }

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

    func createWorkspace(
        projectID: String, branch: String?, baseBranch: String?, directoryName: String?, allowExistingBranchReuse: Bool,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .createWorkspace(
                    .init(
                        projectID: projectID, branch: branch, baseBranch: baseBranch, directoryName: directoryName,
                        allowExistingBranchReuse: allowExistingBranchReuse)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel)
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
    /// process or coding agent — those own their name through the workspace config, not the session.
    func renameTerminalSession(workspaceID: String, sessionID: String, title: String, commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .renameTerminalSession(.init(workspaceID: workspaceID, sessionID: sessionID, title: title)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
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

    func runCodingAgent(workspaceID: String, agentName: String, agentLauncherID: String?, commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .runCodingAgent(.init(workspaceID: workspaceID, agentName: agentName, agentLauncherID: agentLauncherID)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    func stopCodingAgent(workspaceID: String, agentID: String, agentName: String?, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws
        -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .stopCodingAgent(.init(workspaceID: workspaceID, agentID: agentID, agentName: agentName, agentLauncherID: nil)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
    }

    func restartCodingAgent(workspaceID: String, agentID: String, agentName: String?, commandChannel: SpacesDeviceAPICommandChannel? = nil)
        async throws -> SpacesDeviceAPIResponse
    {
        try await mutation(
            .init(
                command: .restartCodingAgent(.init(workspaceID: workspaceID, agentID: agentID, agentName: agentName, agentLauncherID: nil)),
                authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity), commandChannel: commandChannel)
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
        sessionID: String, clientID: String, text: String, ownerEpoch: UInt64?, appendNewline: Bool = false, asPaste: Bool = false,
        timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .send, sessionID: sessionID, clientID: clientID, text: text, ownerEpoch: ownerEpoch, appendNewline: appendNewline,
                    asPaste: asPaste)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func sendKey(
        sessionID: String, clientID: String, key: String, ownerEpoch: UInt64?, timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .key, sessionID: sessionID, clientID: clientID, key: key, ownerEpoch: ownerEpoch)),
            authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    /// Pastes a staged image into the session. Multi-MiB base64-encoded payloads take meaningfully
    /// longer to transmit than ordinary text/key input, so this uses a 30 s default timeout instead
    /// of the 6 s timeout used elsewhere for interactive input.
    func pasteImage(
        sessionID: String, clientID: String, ownerEpoch: UInt64, fileExtension: String, imageData: Data, timeout: Duration = .seconds(30),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalPasteImage(
                SpacesDeviceTerminalPasteImageRequest(
                    sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch, fileExtension: fileExtension, imageData: imageData)),
            authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func clearScreen(
        sessionID: String, clientID: String, ownerEpoch: UInt64?, timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .clearScreen, sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch)),
            authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func resize(
        sessionID: String, clientID: String, columns: Int, rows: Int, ownerEpoch: UInt64?, resizeSerial: UInt64?, timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .resize, sessionID: sessionID, clientID: clientID, columns: columns, rows: rows, ownerEpoch: ownerEpoch,
                    resizeSerial: resizeSerial)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func scroll(
        sessionID: String, clientID: String, horizontal: Double, vertical: Double, ownerEpoch: UInt64?, scrollMods: Int32? = nil,
        pointerPosition: TerminalScrollPointerPosition? = nil, timeout: Duration = .seconds(3), commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .scroll, sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch, scrollHorizontal: horizontal,
                    scrollVertical: vertical, scrollMods: scrollMods, scrollPointerX: pointerPosition?.x, scrollPointerY: pointerPosition?.y,
                    scrollPointerMods: pointerPosition?.mods)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity)
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
        onDisconnect: @escaping @MainActor (Error?) -> Void
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

    init(transport: any SpacesDeviceAPIRequestTransport, authToken: String?, clientApp: SpacesDeviceClientApp) {
        self.transport = transport
        self.authToken = authToken
        self.clientApp = clientApp
    }

    func close() async { await transport.close() }

    func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
        var request = request
        if request.authToken == nil {
            request = SpacesDeviceAPIRequest(command: request.command, authToken: authToken, clientApp: request.clientApp ?? clientApp)
        }
        return try await transport.send(request: request, timeout: timeout)
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

    init(settings: SpacesMobileConnectionSettings) {
        self.settings = settings
        resolver = SpacesDeviceEndpointResolver(settings: settings)
    }

    func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { SpacesDeviceNetworkRequestTransport(resolver: resolver) }

    func openSessionStream(
        request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
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
        let parameters = SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: settings.certificateFingerprint)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        // A stream that ends with an error means the address it was on may no longer be good (the device
        // left the network it was reachable on, the daemon restarted somewhere else, etc.) — report the
        // failure to the resolver here, next to the thing that learned the address, so the next stream
        // this backend opens (via `nextStreamHost()`) moves on to a different candidate instead of
        // retrying the same dead one indefinitely. A `nil` error is a clean cancellation (the caller
        // closed the stream on purpose, e.g. the viewer was dismissed) and must not invalidate an
        // address that never actually failed.
        let resolver = self.resolver
        let invalidatingOnDisconnect: @MainActor (Error?) -> Void = { error in
            if error != nil { Task { await resolver.noteStreamFailed(host: host) } }
            onDisconnect(error)
        }
        StreamSubscription(connection: connection, host: host, port: nwPort, request: request, onEvent: onEvent, onDisconnect: invalidatingOnDisconnect)
            .start(on: queue)
        return SpacesDeviceAPIStreamHandle { connection.cancel() }
    }

    /// The resolver's cached winner, if it has one — see `SpacesDeviceAPIClient.currentResolvedHost()`.
    func currentResolvedHost() async -> String? { await resolver.currentCachedHost() }

    /// Forgets the resolver's cached winner — see `SpacesDeviceAPIClient.resetEndpointResolution()`.
    func resetEndpointResolution() async { await resolver.clearCachedWinner() }
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
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) async throws -> SpacesDeviceAPIStreamHandle {
        try await networkBackend.openSessionStream(request: request, onEvent: onEvent, onDisconnect: onDisconnect)
    }
}

private struct SpacesDeviceClosureRequestTransport: SpacesDeviceAPIRequestTransport {
    let handler: @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse

    func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse { try await handler(request) }
    func close() async {}
}

/// Network request transport: owns one pinned-TLS command connection. This is the request/response
/// half of the former command channel; auth-token/client-app defaulting now lives in the channel.
actor SpacesDeviceNetworkRequestTransport: SpacesDeviceAPIRequestTransport {
    private let resolver: SpacesDeviceEndpointResolver
    private let queue = DispatchQueue(label: "spaces.device.api.command")
    private var connection: NWConnection?

    init(resolver: SpacesDeviceEndpointResolver) {
        self.resolver = resolver
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

    private static func send(data: Data, on connection: NWConnection, timeout: Duration) async throws {
        try await SpacesDeviceAPIConnectionSupport.withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = OneShotContinuation(continuation)
                connection.send(
                    content: data, contentContext: .defaultMessage, isComplete: false,
                    completion: .contentProcessed { error in if let error { resume.resume(throwing: error) } else { resume.resume(returning: ()) } })
            }
        }
    }

    private static func readLine(from connection: NWConnection, timeout: Duration) async throws -> Data {
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
                        resume.resume(throwing: SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled."))
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
/// through `waitUntilReady`/`canOpenPlainTCPConnection`/`isRequestTimedOut`.
enum SpacesDeviceAPIConnectionSupport {
    static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue, timeout: Duration) async throws {
        try await withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = OneShotContinuation(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resume.resume(returning: ())
                    case .failed(let error): resume.resume(throwing: error)
                    case .cancelled: resume.resume(throwing: SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled."))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    static func canOpenPlainTCPConnection(host: String, port: NWEndpoint.Port, timeout: Duration) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        do {
            try await waitUntilReady(connection, queue: DispatchQueue(label: "spaces.device.api.tcp-probe"), timeout: timeout)
            connection.cancel()
            return true
        } catch {
            connection.cancel()
            return false
        }
    }

    static func isRequestTimedOut(_ error: Error) -> Bool {
        if case SpacesDeviceAPIClientError.requestTimedOut = error { return true }
        return false
    }

    /// Classifies a stream that never produced its first payload. An open TCP port behind a TLS
    /// handshake that never completed means the daemon's certificate did not match the pinned
    /// fingerprint, which has to reach the re-pair recovery flow rather than read as a stalled stream.
    static func pendingSecureConnectionTimeoutError(host: String, port: NWEndpoint.Port) async -> Error {
        if await canOpenPlainTCPConnection(host: host, port: port, timeout: .milliseconds(750)) {
            return SpacesDeviceAPIClientError.transportAuthenticationFailed
        }
        return SpacesDeviceAPIClientError.streamFailed("Timed out waiting for terminal state.")
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
}

private final class StreamSubscription: @unchecked Sendable {
    /// One budget covering the whole way from starting the connection to decoding the first payload,
    /// since this type owns the handshake as well as the wait for terminal state.
    private static let initialEventTimeout: Duration = .seconds(12)

    private let connection: NWConnection
    private let host: String
    private let port: NWEndpoint.Port
    private let request: SpacesDeviceAPIRequest
    private let lifecycle: StreamLifecycle
    private let onEvent: @MainActor (GhosttyRemoteSessionStatePayload) -> Void
    private var buffer = Data()
    private var decodedState = false
    private var connectionReady = false

    init(
        connection: NWConnection, host: String, port: NWEndpoint.Port, request: SpacesDeviceAPIRequest,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @MainActor (Error?) -> Void
    ) {
        self.connection = connection
        self.host = host
        self.port = port
        self.request = request
        self.onEvent = onEvent
        lifecycle = StreamLifecycle(onDisconnect: onDisconnect)
    }

    /// Starts the unstarted connection the caller handed over and drives it to the first payload. This
    /// owns the handshake deliberately: doing it here rather than awaiting a ready connection in
    /// `openSessionStream` keeps subscribing non-blocking, so the viewer's post-subscribe state refresh
    /// still runs (and can surface an authentication failure promptly) even when the endpoint accepts
    /// TCP but never completes TLS.
    ///
    /// `host`/`port` exist only for that timeout's classification: an endpoint whose TCP port is open
    /// while TLS never completed is a certificate-pin mismatch, which must route into re-pair recovery
    /// rather than read as a stalled stream.
    func start(on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + Self.initialEventTimeout.timeInterval) { [weak self] in
            guard let self, !decodedState else { return }
            guard !connectionReady else {
                lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed("Timed out waiting for terminal state."))
                connection.cancel()
                return
            }
            let host = host
            let port = port
            Task { [weak self] in
                let error = await SpacesDeviceAPIConnectionSupport.pendingSecureConnectionTimeoutError(host: host, port: port)
                queue.async { [weak self] in
                    guard let self, !decodedState else { return }
                    if connectionReady {
                        lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed("Timed out waiting for terminal state."))
                    } else {
                        lifecycle.finish(error: error)
                    }
                    connection.cancel()
                }
            }
        }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connectionReady = true
                sendInitialRequest()
            case .failed(let error): lifecycle.finish(error: error)
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

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] content, _, isComplete, error in
            if let content, !content.isEmpty {
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
                            lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed(response.message, code: response.errorCode))
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
                    lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed(response.message, code: response.errorCode))
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

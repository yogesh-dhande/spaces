import Foundation
import Network
import spacesdevicecore
import spacesterminalcore

enum SpacesDeviceAPIClientError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String, code: SpacesDeviceErrorCode? = nil)
    case transportAuthenticationFailed
    case missingOverview
    case streamFailed(String, code: SpacesDeviceErrorCode? = nil)
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The Device API host or port is invalid."
        case .requestFailed(let message, _):
            message
        case .transportAuthenticationFailed:
            "The secure Device API transport could not authenticate."
        case .missingOverview:
            "The Device API did not return a workspace or terminal overview."
        case .streamFailed(let message, _):
            message
        case .requestTimedOut:
            "The Device API request timed out."
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
    let settings: SpacesMobileConnectionSettings
    private let requestOverride: (@Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse)?

    init(
        settings: SpacesMobileConnectionSettings,
        requestOverride: (@Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse)? = nil
    ) {
        self.settings = settings
        self.requestOverride = requestOverride
    }

    func makeCommandChannel() -> SpacesDeviceAPICommandChannel {
        SpacesDeviceAPICommandChannel(settings: settings, clientApp: clientAppIdentity)
    }

    func pair(pairingLink: SpacesDevicePairingLink, commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> String {
        // Refuse to redeem an incompatible link before the one-time pairing window is consumed.
        switch SpacesWireCompatibility.evaluate(daemonProtocolVersion: pairingLink.protocolVersion, localVersion: SpacesWireProtocol.version) {
        case .compatible:
            break
        case .daemonTooOld:
            throw SpacesDeviceAPIClientError.requestFailed(
                "\(pairingLink.name) is running Spaces \(pairingLink.appVersion), which is older than this app. Update Spaces on \(pairingLink.name), then pair again.")
        case .clientTooOld:
            throw SpacesDeviceAPIClientError.requestFailed(
                "\(pairingLink.name) is running Spaces \(pairingLink.appVersion), which is newer than this app. Update Spaces on this device, then pair again.")
        }
        let response = try await sendRequest(
            .init(
                command: .pair(.init(pairingCode: pairingLink.code, pairingNonce: pairingLink.nonce, clientProtocolVersion: SpacesWireProtocol.version)),
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let issuedAuthToken = response.issuedAuthToken else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return an auth token.")
        }
        return issuedAuthToken
    }

    func fetchOverview(commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> SpacesDeviceOverviewPayload {
        let response = try await sendRequest(
            .init(command: .overview, authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            timeout: .seconds(8),
            commandChannel: commandChannel
        )
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let overview = response.overview else { throw SpacesDeviceAPIClientError.missingOverview }
        return overview
    }

    /// Frozen-core handshake read: fetches the daemon's wire protocol + restart-impact status.
    func fetchDaemonStatus(commandChannel: SpacesDeviceAPICommandChannel? = nil) async throws -> TerminalServiceDaemonStatus {
        let response = try await sendRequest(
            .init(command: .daemonStatus, authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            timeout: .seconds(8),
            commandChannel: commandChannel
        )
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
            .init(command: .requestDaemonRestart, authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            timeout: .seconds(8),
            commandChannel: commandChannel
        )
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func fetchWorkspaceCreateOptions(
        projectID: String? = nil,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceWorkspaceCreateOptions {
        let response = try await sendRequest(
            .init(
                command: .workspaceCreateOptions(.init(projectID: projectID)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity
            ),
            commandChannel: commandChannel
        )
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let options = response.workspaceCreateOptions else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return workspace create options.")
        }
        return options
    }

    func createWorkspace(
        projectID: String,
        branch: String?,
        baseBranch: String?,
        directoryName: String?,
        allowExistingBranchReuse: Bool,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .createWorkspace(
                    .init(
                        projectID: projectID,
                        branch: branch,
                        baseBranch: baseBranch,
                        directoryName: directoryName,
                        allowExistingBranchReuse: allowExistingBranchReuse
                    )),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity
            ),
            commandChannel: commandChannel
        )
    }

    /// Starts every configured process and coding agent in the workspace. Browser sessions and ad hoc
    /// terminals are not launched — the daemon opens neither, they are opened on demand.
    func launchWorkspace(
        workspaceID: String,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .launchWorkspace(.init(workspaceID: workspaceID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func stopWorkspace(
        workspaceID: String,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .stopWorkspace(.init(workspaceID: workspaceID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func restartWorkspace(
        workspaceID: String,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .restartWorkspace(.init(workspaceID: workspaceID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    /// Hides or unhides a workspace. `isHidden` is daemon-owned workspace state, so this is the same flag
    /// the Mac sidebar's Hide action and Workspace Visibility dialog toggle — hiding here hides it there.
    func setWorkspaceHidden(
        workspaceID: String,
        isHidden: Bool,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .updateWorkspaceMetadata(.init(workspaceID: workspaceID, isHidden: isHidden, updatesHidden: true)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func openWorkspaceTerminal(
        workspaceID: String,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(command: .openWorkspaceTerminal(.init(workspaceID: workspaceID)), authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func stopWorkspaceTerminal(
        workspaceID: String,
        sessionID: String,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .stopWorkspaceTerminal(.init(workspaceID: workspaceID, sessionID: sessionID)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    /// Renames an ad hoc workspace terminal session. The daemon rejects sessions owned by a configured
    /// process or coding agent — those own their name through the workspace config, not the session.
    func renameTerminalSession(
        workspaceID: String,
        sessionID: String,
        title: String,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .renameTerminalSession(.init(workspaceID: workspaceID, sessionID: sessionID, title: title)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    /// Replaces the workspace's whole configuration. The daemon overwrites every configured field from the
    /// request, so a caller sends the workspace's current config with only its own edit applied.
    func updateWorkspaceConfig(
        workspaceID: String,
        config: SpacesDeviceWorkspaceConfig,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .updateWorkspaceConfig(.init(workspaceID: workspaceID, config: config)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func runWorkspaceProcess(
        workspaceID: String,
        processKey: String,
        processTemplateID: String?,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .runWorkspaceProcess(
                    .init(workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func stopWorkspaceProcess(
        workspaceID: String,
        processID: String,
        processKey: String?,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .stopWorkspaceProcess(.init(workspaceID: workspaceID, processID: processID, processKey: processKey, processTemplateID: nil)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func restartWorkspaceProcess(
        workspaceID: String,
        processID: String,
        processKey: String?,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .restartWorkspaceProcess(.init(workspaceID: workspaceID, processID: processID, processKey: processKey, processTemplateID: nil)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func runCodingAgent(
        workspaceID: String,
        agentName: String,
        agentLauncherID: String?,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .runCodingAgent(.init(workspaceID: workspaceID, agentName: agentName, agentLauncherID: agentLauncherID)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func stopCodingAgent(
        workspaceID: String,
        agentID: String,
        agentName: String?,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .stopCodingAgent(.init(workspaceID: workspaceID, agentID: agentID, agentName: agentName, agentLauncherID: nil)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func restartCodingAgent(
        workspaceID: String,
        agentID: String,
        agentName: String?,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceAPIResponse {
        try await mutation(
            .init(
                command: .restartCodingAgent(.init(workspaceID: workspaceID, agentID: agentID, agentName: agentName, agentLauncherID: nil)),
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
    }

    func fetchState(
        sessionID: String,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> GhosttyRemoteSessionStatePayload {
        let request = SpacesDeviceAPIRequest(
            command: .state(.init(sessionID: sessionID)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let sessionState = response.sessionState else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return terminal state.")
        }
        return sessionState
    }

    func attach(
        sessionID: String,
        client: TerminalClient,
        mode: TerminalAttachmentMode,
        appearance: ThemeAppearance,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(action: .attach, sessionID: sessionID, client: client, attachmentMode: mode, appearance: appearance)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func detach(
        sessionID: String,
        clientID: String,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .detach, sessionID: sessionID, clientID: clientID)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func takeOver(
        sessionID: String,
        clientID: String,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> GhosttyRemoteSessionStatePayload? {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .takeover, sessionID: sessionID, clientID: clientID)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        return response.sessionState
    }

    func sendText(
        sessionID: String,
        clientID: String,
        text: String,
        ownerEpoch: UInt64?,
        appendNewline: Bool = false,
        asPaste: Bool = false,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .send, sessionID: sessionID, clientID: clientID, text: text, ownerEpoch: ownerEpoch, appendNewline: appendNewline,
                    asPaste: asPaste)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func sendKey(
        sessionID: String,
        clientID: String,
        key: String,
        ownerEpoch: UInt64?,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .key, sessionID: sessionID, clientID: clientID, key: key, ownerEpoch: ownerEpoch)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    /// Pastes a staged image into the session. Multi-MiB base64-encoded payloads take meaningfully
    /// longer to transmit than ordinary text/key input, so this uses a 30 s default timeout instead
    /// of the 6 s timeout used elsewhere for interactive input.
    func pasteImage(
        sessionID: String,
        clientID: String,
        ownerEpoch: UInt64,
        fileExtension: String,
        imageData: Data,
        timeout: Duration = .seconds(30),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalPasteImage(
                SpacesDeviceTerminalPasteImageRequest(
                    sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch, fileExtension: fileExtension, imageData: imageData)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func clearScreen(
        sessionID: String,
        clientID: String,
        ownerEpoch: UInt64?,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .clearScreen, sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func resize(
        sessionID: String,
        clientID: String,
        columns: Int,
        rows: Int,
        ownerEpoch: UInt64?,
        resizeSerial: UInt64?,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .resize,
                    sessionID: sessionID,
                    clientID: clientID,
                    columns: columns,
                    rows: rows,
                    ownerEpoch: ownerEpoch,
                    resizeSerial: resizeSerial
                )),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func scroll(
        sessionID: String,
        clientID: String,
        horizontal: Double,
        vertical: Double,
        ownerEpoch: UInt64?,
        scrollMods: Int32? = nil,
        pointerPosition: TerminalScrollPointerPosition? = nil,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(
                    action: .scroll,
                    sessionID: sessionID,
                    clientID: clientID,
                    ownerEpoch: ownerEpoch,
                    scrollHorizontal: horizontal,
                    scrollVertical: vertical,
                    scrollMods: scrollMods,
                    scrollPointerX: pointerPosition?.x,
                    scrollPointerY: pointerPosition?.y,
                    scrollPointerMods: pointerPosition?.mods
                )),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    /// Pushes the app's light/dark appearance to a live session so the daemon re-themes it mid-session.
    /// Appearance is a per-client view preference, not owner-gated, so a viewer may send it; the daemon
    /// treats a same-value request as a cheap no-op (see the session core's setAppearance handler).
    func setAppearance(
        sessionID: String,
        clientID: String,
        appearance: ThemeAppearance,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .setAppearance, sessionID: sessionID, clientID: clientID, appearance: appearance)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
    }

    func resolveTerminalLink(
        sessionID: String,
        link: String,
        timeout: Duration = .seconds(6),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceTerminalLinkMetadata {
        let request = SpacesDeviceAPIRequest(
            command: .resolveTerminalLink(.init(sessionID: sessionID, terminalLink: link)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let metadata = response.terminalLinkMetadata else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return terminal link metadata.")
        }
        return metadata
    }

    func readTerminalLinkChunk(
        sessionID: String,
        linkID: String,
        offset: Int64,
        limit: Int,
        timeout: Duration = .seconds(6),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws -> SpacesDeviceTerminalLinkChunk {
        let request = SpacesDeviceAPIRequest(
            command: .readTerminalLinkChunk(.init(sessionID: sessionID, terminalLinkID: linkID, offset: offset, limit: limit)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        guard let chunk = response.terminalLinkChunk else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return terminal link data.")
        }
        return chunk
    }

    func subscribe(
        sessionID: String,
        clientID: String,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) throws -> SpacesDeviceAPIStreamHandle {
        let endpoint = try makeConnection()
        let request = SpacesDeviceAPIRequest(
            command: .subscribe(.init(sessionID: sessionID, clientID: clientID)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let queue = DispatchQueue(label: "spaces.device.api.stream.\(sessionID).\(clientID)")
        StreamSubscription(
            connection: endpoint.connection, host: endpoint.host, port: endpoint.port, request: request, onEvent: onEvent, onDisconnect: onDisconnect
        )
        .start(on: queue)
        return SpacesDeviceAPIStreamHandle { endpoint.connection.cancel() }
    }

    private func mutation(
        _ request: SpacesDeviceAPIRequest,
        commandChannel: SpacesDeviceAPICommandChannel?
    ) async throws -> SpacesDeviceAPIResponse {
        let response = try await sendRequest(request, timeout: .seconds(30), commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message, code: response.errorCode) }
        return response
    }

    private func sendRequest(_ request: SpacesDeviceAPIRequest, timeout: Duration = .seconds(3)) async throws -> SpacesDeviceAPIResponse {
        try await sendRequest(request, timeout: timeout, commandChannel: nil)
    }

    private func sendRequest(
        _ request: SpacesDeviceAPIRequest,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel?
    ) async throws -> SpacesDeviceAPIResponse {
        if let requestOverride {
            return try await requestOverride(request)
        }
        if let commandChannel {
            return try await commandChannel.send(request: request, timeout: timeout)
        }
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

    private func makeConnection() throws -> (connection: NWConnection, host: String, port: NWEndpoint.Port) {
        let host = settings.trimmedHost
        guard let port = NWEndpoint.Port(rawValue: UInt16(settings.port)), !host.isEmpty else {
            throw SpacesDeviceAPIClientError.invalidEndpoint
        }
        let parameters = SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: settings.certificateFingerprint)
        return (NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters), host, port)
    }

    private var clientAppIdentity: SpacesDeviceClientApp {
        SpacesDeviceClientApp(
            installationID: settings.installationID,
            bundleID: Bundle.main.bundleIdentifier ?? SpacesDeviceFirstPartyPolicy.allowedBundleID,
            platform: "ios",
            deviceName: ProcessInfo.processInfo.hostName,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }

}

actor SpacesDeviceAPICommandChannel {
    private let host: String
    private let port: Int
    private let certificateFingerprint: String
    private let clientApp: SpacesDeviceClientApp
    private let authToken: String?
    private let queue = DispatchQueue(label: "spaces.device.api.command")
    private var connection: NWConnection?

    init(settings: SpacesMobileConnectionSettings, clientApp: SpacesDeviceClientApp) {
        host = settings.trimmedHost
        port = settings.port
        certificateFingerprint = settings.certificateFingerprint
        authToken = settings.trimmedAuthToken
        self.clientApp = clientApp
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
        guard !host.isEmpty, port > 0 else { throw SpacesDeviceAPIClientError.invalidEndpoint }
        var request = request
        if request.authToken == nil {
            request = SpacesDeviceAPIRequest(
                command: request.command,
                authToken: authToken,
                clientApp: request.clientApp ?? clientApp
            )
        }
        let connection = try await connectIfNeeded(timeout: timeout)
        do {
            try await Self.send(data: encodeDeviceAPIRequestLine(request), on: connection, timeout: timeout)
            let responseData = try await Self.readLine(from: connection, timeout: timeout)
            return try SpacesDeviceAPICodec.decodeResponse(responseData)
        } catch {
            close()
            throw error
        }
    }

    private func connectIfNeeded(timeout: Duration) async throws -> NWConnection {
        if let connection { return connection }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw SpacesDeviceAPIClientError.invalidEndpoint }
        let parameters = SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint)
        let createdConnection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        do {
            try await SpacesDeviceAPIConnectionSupport.waitUntilReady(createdConnection, queue: queue, timeout: timeout)
        } catch {
            createdConnection.cancel()
            if SpacesDeviceAPIConnectionSupport.isRequestTimedOut(error),
                await SpacesDeviceAPIConnectionSupport.canOpenPlainTCPConnection(host: host, port: nwPort, timeout: .milliseconds(750))
            {
                throw SpacesDeviceAPIClientError.transportAuthenticationFailed
            }
            throw error
        }
        connection = createdConnection
        return createdConnection
    }

    private static func send(data: Data, on connection: NWConnection, timeout: Duration) async throws {
        try await SpacesDeviceAPIConnectionSupport.withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = OneShotContinuation(continuation)
                connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
                    if let error {
                        resume.resume(throwing: error)
                    } else {
                        resume.resume(returning: ())
                    }
                })
            }
        }
    }

    private static func readLine(from connection: NWConnection, timeout: Duration) async throws -> Data {
        try await SpacesDeviceAPIConnectionSupport.withTimeout(timeout) {
            try await readLineAccumulating(from: connection, data: Data())
        }
    }

    private static func readLineAccumulating(from connection: NWConnection, data: Data) async throws -> Data {
        if let newlineIndex = data.firstIndex(of: 0x0A) {
            return Data(data.prefix(upTo: newlineIndex))
        }
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
                    do {
                        resume.resume(returning: try await readLineAccumulating(from: connection, data: nextData))
                    } catch {
                        resume.resume(throwing: error)
                    }
                }
            }
        }
    }
}

private enum SpacesDeviceAPIConnectionSupport {
    static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue, timeout: Duration) async throws {
        try await withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = OneShotContinuation(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resume.resume(returning: ())
                    case .failed(let error):
                        resume.resume(throwing: error)
                    case .cancelled:
                        resume.resume(throwing: SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled."))
                    default:
                        break
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
                    do {
                        operationState.resume(returning: try await operation())
                    } catch {
                        operationState.resume(throwing: error)
                    }
                }
                operationState.addTask(operationTask)

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
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

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func addTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = continuation == nil
        if !shouldCancel { tasks.append(task) }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func resume(returning value: T) {
        finish { continuation in
            continuation.resume(returning: value)
        }
    }

    func resume(throwing error: any Error) {
        finish { continuation in
            continuation.resume(throwing: error)
        }
    }

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

    init(onDisconnect: @escaping @MainActor (Error?) -> Void) {
        self.onDisconnect = onDisconnect
    }

    func finish(error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        Task { @MainActor in onDisconnect(error) }
    }
}

private final class StreamSubscription: @unchecked Sendable {
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
        connection: NWConnection,
        host: String,
        port: NWEndpoint.Port,
        request: SpacesDeviceAPIRequest,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) {
        self.connection = connection
        self.host = host
        self.port = port
        self.request = request
        self.onEvent = onEvent
        lifecycle = StreamLifecycle(onDisconnect: onDisconnect)
    }

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
            case .failed(let error):
                lifecycle.finish(error: error)
            case .cancelled:
                lifecycle.finish(error: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendInitialRequest() {
        do {
            let data = try encodeDeviceAPIRequestLine(request)
            connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { [self] error in
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
                if !decodedState,
                    !buffer.isEmpty,
                    let response = try? SpacesDeviceAPICodec.decodeResponse(buffer),
                    !response.ok
                {
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

private extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}

private func encodeDeviceAPIRequestLine(_ request: SpacesDeviceAPIRequest) throws -> Data {
    var data = try SpacesDeviceAPICodec.encodeRequest(request)
    data.append(0x0A)
    return data
}

import Darwin
import Foundation
import Network
import Security
import spacesdevicecore
import spacesterminalcore

enum SpacesDeviceAPIClientError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String)
    case transportAuthenticationFailed
    case missingOverview
    case streamFailed(String)
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The Device API host or port is invalid."
        case .requestFailed(let message):
            message
        case .transportAuthenticationFailed:
            "The secure Device API transport could not authenticate."
        case .missingOverview:
            "The Device API did not return a workspace or terminal overview."
        case .streamFailed(let message):
            message
        case .requestTimedOut:
            "The Device API request timed out."
        }
    }
}

final class SpacesDeviceAPIStreamHandle: @unchecked Sendable {
    private let cancelHandler: @Sendable () -> Void

    init(cancelHandler: @escaping @Sendable () -> Void) { self.cancelHandler = cancelHandler }

    func cancel() { cancelHandler() }
}

enum SpacesMobileDirectCredentialStore {
    private static let service = "dev.usespaces.spacesmobile.remote-terminal"

    static func endpoint(from endpoint: SpacesDeviceTerminalDaemonEndpoint?) -> SpacesDeviceTerminalDaemonEndpoint? {
        guard let endpoint else { return nil }
        if let token = endpoint.authToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            save(token: token, endpoint: endpoint)
            return endpoint
        }
        guard let token = token(for: endpoint) else { return nil }
        return SpacesDeviceTerminalDaemonEndpoint(
            host: endpoint.host, port: endpoint.port, authToken: token, certificateFingerprint: endpoint.certificateFingerprint)
    }

    private static func save(token: String, endpoint: SpacesDeviceTerminalDaemonEndpoint) {
        let query = baseQuery(endpoint: endpoint)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func token(for endpoint: SpacesDeviceTerminalDaemonEndpoint) -> String? {
        var query = baseQuery(endpoint: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery(endpoint: SpacesDeviceTerminalDaemonEndpoint) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(endpoint.host):\(endpoint.port):\(endpoint.certificateFingerprint)",
        ]
    }
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
        let response = try await sendRequest(
            .init(command: .pair(.init(pairingCode: pairingLink.code, pairingNonce: pairingLink.nonce)), clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
        guard let sessionState = response.sessionState else {
            throw SpacesDeviceAPIClientError.requestFailed("The Device API did not return terminal state.")
        }
        return sessionState
    }

    func attach(
        sessionID: String,
        client: TerminalClient,
        mode: TerminalAttachmentMode,
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(.init(action: .attach, sessionID: sessionID, client: client, attachmentMode: mode)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
        return response.sessionState
    }

    func sendText(
        sessionID: String,
        clientID: String,
        text: String,
        ownerEpoch: UInt64?,
        appendNewline: Bool = false,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesDeviceAPICommandChannel? = nil
    ) async throws {
        let request = SpacesDeviceAPIRequest(
            command: .terminalControl(
                .init(action: .send, sessionID: sessionID, clientID: clientID, text: text, ownerEpoch: ownerEpoch, appendNewline: appendNewline)),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
    }

    func scroll(
        sessionID: String,
        clientID: String,
        horizontal: Double,
        vertical: Double,
        ownerEpoch: UInt64?,
        scrollMods: Int32? = nil,
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
                    scrollMods: scrollMods
                )),
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
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
        let parameters = try SpacesDeviceAPITransport.parameters(transportKey: settings.transportKey, role: .client)
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

struct SpacesDeviceTerminalDaemonClient: Sendable {
    let endpoint: SpacesDeviceTerminalDaemonEndpoint
    private let commandChannel: DirectTerminalServiceCommandChannel

    init(endpoint: SpacesDeviceTerminalDaemonEndpoint) {
        self.endpoint = endpoint
        commandChannel = DirectTerminalServiceCommandChannel(endpoint: endpoint)
    }

    func subscribe(
        sessionID: String,
        clientID: String,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) throws -> SpacesDeviceAPIStreamHandle {
        let connection = try Self.makePinnedTLSConnection(endpoint: endpoint)
        let request = TerminalServiceRequest(command: .subscribe(.init(sessionID: sessionID))).withAuthToken(endpoint.authToken)
        let queue = DispatchQueue(label: "spaces.mobile.direct.stream.\(sessionID).\(clientID)")
        DirectTerminalServiceStreamSubscription(
            connection: connection, request: request, onEvent: onEvent, onDisconnect: onDisconnect
        )
        .start(on: queue)
        return SpacesDeviceAPIStreamHandle { connection.cancel() }
    }

    func fetchState(sessionID: String, timeout: Duration = .seconds(3)) async throws -> GhosttyRemoteSessionStatePayload {
        let response = try await send(.init(command: .state(.init(sessionID: sessionID))), timeout: timeout)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
        guard let sessionState = response.sessionState else {
            throw SpacesDeviceAPIClientError.requestFailed("Remote spacesd did not return terminal state.")
        }
        return sessionState
    }

    func attach(sessionID: String, client: TerminalClient, mode: TerminalAttachmentMode, timeout: Duration = .seconds(3)) async throws {
        try await control(
            sessionID: sessionID,
            request: TerminalControlRequest(command: "attach", client: client, attachmentMode: mode),
            timeout: timeout)
    }

    func detach(sessionID: String, clientID: String, timeout: Duration = .seconds(3)) async throws {
        try await control(sessionID: sessionID, request: TerminalControlRequest(command: "detach", clientID: clientID), timeout: timeout)
    }

    func heartbeat(sessionID: String, clientID: String, timeout: Duration = .seconds(3)) async throws {
        try await control(sessionID: sessionID, request: TerminalControlRequest(command: "heartbeat", clientID: clientID), timeout: timeout)
    }

    func takeOver(sessionID: String, clientID: String, timeout: Duration = .seconds(3)) async throws -> GhosttyRemoteSessionStatePayload? {
        let response = try await controlResponse(
            sessionID: sessionID, request: TerminalControlRequest(command: "takeover", clientID: clientID), timeout: timeout)
        return response.sessionState
    }

    func sendText(
        sessionID: String,
        clientID: String,
        text: String,
        ownerEpoch: UInt64?,
        appendNewline: Bool = false,
        timeout: Duration = .seconds(3)
    ) async throws {
        try await control(
            sessionID: sessionID,
            request: TerminalControlRequest(
                command: "send", text: text, clientID: clientID, ownerEpoch: ownerEpoch, appendNewline: appendNewline),
            timeout: timeout)
    }

    func sendKey(sessionID: String, clientID: String, key: String, ownerEpoch: UInt64?, timeout: Duration = .seconds(3)) async throws {
        try await control(
            sessionID: sessionID,
            request: TerminalControlRequest(command: "key", key: key, clientID: clientID, ownerEpoch: ownerEpoch),
            timeout: timeout)
    }

    func clearScreen(sessionID: String, clientID: String, ownerEpoch: UInt64?, timeout: Duration = .seconds(3)) async throws {
        try await control(
            sessionID: sessionID,
            request: TerminalControlRequest(command: "clearScreen", clientID: clientID, ownerEpoch: ownerEpoch),
            timeout: timeout)
    }

    func resize(
        sessionID: String,
        clientID: String,
        columns: Int,
        rows: Int,
        ownerEpoch: UInt64?,
        resizeSerial: UInt64?,
        timeout: Duration = .seconds(3)
    ) async throws {
        try await control(
            sessionID: sessionID,
            request: TerminalControlRequest(
                command: "resize", clientID: clientID, columns: columns, rows: rows, ownerEpoch: ownerEpoch, resizeSerial: resizeSerial),
            timeout: timeout)
    }

    func scroll(
        sessionID: String,
        clientID: String,
        horizontal: Double,
        vertical: Double,
        ownerEpoch: UInt64?,
        scrollMods: Int32? = nil,
        timeout: Duration = .seconds(3)
    ) async throws {
        try await control(
            sessionID: sessionID,
            request: TerminalControlRequest(
                command: "scroll", clientID: clientID, ownerEpoch: ownerEpoch, scrollHorizontal: horizontal, scrollVertical: vertical,
                scrollMods: scrollMods),
            timeout: timeout)
    }

    func resolveTerminalLink(sessionID: String, link: String, timeout: Duration = .seconds(6)) async throws
        -> SpacesDeviceTerminalLinkMetadata
    {
        let response = try await send(
            .init(command: .resolveTerminalLink(.init(sessionID: sessionID, terminalLink: link))), timeout: timeout)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
        guard let metadata = response.terminalLinkMetadata else {
            throw SpacesDeviceAPIClientError.requestFailed("Remote spacesd did not return terminal link metadata.")
        }
        return try Self.mobileLinkMetadata(metadata)
    }

    func readTerminalLinkChunk(sessionID: String, linkID: String, offset: Int64, limit: Int, timeout: Duration = .seconds(6)) async throws
        -> SpacesDeviceTerminalLinkChunk
    {
        let response = try await send(
            .init(
                command: .readTerminalLinkChunk(
                    .init(sessionID: sessionID, terminalLinkID: linkID, offset: offset, limit: limit))),
            timeout: timeout)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
        guard let chunk = response.terminalLinkChunk else {
            throw SpacesDeviceAPIClientError.requestFailed("Remote spacesd did not return terminal link data.")
        }
        return SpacesDeviceTerminalLinkChunk(
            linkID: chunk.linkID, offset: chunk.offset, byteCount: chunk.byteCount, isFinal: chunk.isFinal, base64Data: chunk.base64Data)
    }

    private func control(sessionID: String, request: TerminalControlRequest, timeout: Duration) async throws {
        _ = try await controlResponse(sessionID: sessionID, request: request, timeout: timeout)
    }

    private func controlResponse(sessionID: String, request: TerminalControlRequest, timeout: Duration) async throws -> TerminalServiceResponse {
        let response = try await send(.init(command: .control(.init(sessionID: sessionID, controlRequest: request))), timeout: timeout)
        guard response.ok else { throw SpacesDeviceAPIClientError.requestFailed(response.message) }
        guard let controlResponse = response.controlResponse else {
            throw SpacesDeviceAPIClientError.requestFailed("Remote spacesd did not return terminal control response.")
        }
        guard controlResponse.ok else { throw SpacesDeviceAPIClientError.requestFailed(controlResponse.message) }
        return response
    }

    private func send(_ request: TerminalServiceRequest, timeout: Duration) async throws -> TerminalServiceResponse {
        try await commandChannel.send(request: request, timeout: timeout)
    }

    private static func mobileLinkMetadata(_ metadata: TerminalServiceTerminalLinkMetadata) throws -> SpacesDeviceTerminalLinkMetadata {
        guard let source = SpacesDeviceTerminalLinkSource(rawValue: metadata.source) else {
            throw SpacesDeviceAPIClientError.requestFailed("Remote spacesd returned an unknown terminal link source.")
        }
        let mediaKind: SpacesDeviceTerminalLinkMediaKind?
        if let value = metadata.mediaKind {
            guard let parsed = SpacesDeviceTerminalLinkMediaKind(rawValue: value) else {
                throw SpacesDeviceAPIClientError.requestFailed("Remote spacesd returned an unknown terminal link media kind.")
            }
            mediaKind = parsed
        } else {
            mediaKind = nil
        }
        return SpacesDeviceTerminalLinkMetadata(
            id: metadata.id, source: source, originalLink: metadata.originalLink, displayName: metadata.displayName,
            contentType: metadata.contentType, mediaKind: mediaKind, byteCount: metadata.byteCount, externalURL: metadata.externalURL)
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    fileprivate static func makePinnedTLSConnection(endpoint: SpacesDeviceTerminalDaemonEndpoint) throws -> NWConnection {
        let expectedFingerprint = endpoint.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedFingerprint.isEmpty else { throw TerminalServiceTLSError.missingCertificateFingerprint }
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { throw TerminalServiceTLSError.invalidPort(endpoint.port) }

        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(securityOptions, true)
        sec_protocol_options_set_verify_block(
            securityOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]
                guard let certificate = chain?.first else {
                    complete(false)
                    return
                }
                let actualFingerprint = TerminalServiceTLSFingerprint.fingerprint(certificate: certificate)
                complete(TerminalServiceTLSFingerprint.matches(expectedFingerprint, actualFingerprint))
            }, DispatchQueue.global(qos: .userInitiated))

        return NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options()))
    }
}

private actor DirectTerminalServiceCommandChannel {
    private let endpoint: SpacesDeviceTerminalDaemonEndpoint
    private let queue = DispatchQueue(label: "spaces.mobile.direct.command")
    private var connection: NWConnection?
    private var readBuffer = Data()

    init(endpoint: SpacesDeviceTerminalDaemonEndpoint) {
        self.endpoint = endpoint
    }

    func send(request: TerminalServiceRequest, timeout: Duration) async throws -> TerminalServiceResponse {
        var request = request
        if request.authToken == nil {
            request = request.withAuthToken(endpoint.authToken)
        }
        let command = request.commandName
        let controlCommand = request.command.controlCommandName
        let sessionID = request.sessionID ?? "-"
        let connectionWasOpen = connection != nil
        let startedAt = Date()
        var didReconnectAfterClosedConnection = false
        do {
            let response: TerminalServiceResponse
            do {
                response = try await sendOnce(request: request, timeout: timeout, sessionID: sessionID, command: command)
            } catch {
                guard connectionWasOpen, Self.isClosedConnectionError(error) else { throw error }
                close()
                didReconnectAfterClosedConnection = true
                response = try await sendOnce(request: request, timeout: timeout, sessionID: sessionID, command: command)
            }
            logEvent(
                sessionID: sessionID,
                name: "direct_command_request",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                attributes: [
                    "command": command,
                    "control_command": controlCommand ?? "",
                    "connection_reused": connectionWasOpen ? "1" : "0",
                    "reconnected_after_closed": didReconnectAfterClosedConnection ? "1" : "0",
                    "ok": response.ok ? "1" : "0",
                ])
            if !response.ok, response.message.localizedStandardContains("unauthorized") {
                close()
            }
            return response
        } catch {
            close()
            logEvent(
                sessionID: sessionID,
                name: "direct_command_request",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                attributes: [
                    "command": command,
                    "control_command": controlCommand ?? "",
                    "connection_reused": connectionWasOpen ? "1" : "0",
                    "error": String(describing: error),
                ])
            throw error
        }
    }

    private func sendOnce(request: TerminalServiceRequest, timeout: Duration, sessionID: String, command: String) async throws
        -> TerminalServiceResponse
    {
        let connection = try await connectIfNeeded(timeout: timeout, sessionID: sessionID, command: command)
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try await Self.send(data: data, on: connection, timeout: timeout)
        let responseData = try await readLine(from: connection, timeout: timeout)
        return try JSONDecoder().decode(TerminalServiceResponse.self, from: responseData)
    }

    private static func isClosedConnectionError(_ error: any Error) -> Bool {
        if case SpacesDeviceAPIClientError.requestFailed(let message) = error {
            return message.localizedStandardContains("direct remote connection was cancelled")
                || message.localizedStandardContains("connection was cancelled")
        }
        let description = String(describing: error)
        return description.localizedStandardContains("posixerrorcode: 54")
            || description.localizedStandardContains("connection reset")
            || description.localizedStandardContains("connection was cancelled")
            || description.localizedStandardContains("connection was aborted")
    }

    func close() {
        connection?.cancel()
        connection = nil
        readBuffer.removeAll(keepingCapacity: true)
    }

    private func connectIfNeeded(timeout: Duration, sessionID: String, command: String) async throws -> NWConnection {
        if let connection { return connection }
        let startedAt = Date()
        let createdConnection = try SpacesDeviceTerminalDaemonClient.makePinnedTLSConnection(endpoint: endpoint)
        do {
            try await SpacesDeviceAPIConnectionSupport.waitUntilReady(createdConnection, queue: queue, timeout: timeout)
        } catch {
            createdConnection.cancel()
            logEvent(
                sessionID: sessionID,
                name: "direct_command_connect",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                attributes: ["command": command, "error": String(describing: error)])
            throw error
        }
        connection = createdConnection
        logEvent(
            sessionID: sessionID,
            name: "direct_command_connect",
            elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            attributes: ["command": command, "connection_reused": "0"])
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

    private func readLine(from connection: NWConnection, timeout: Duration) async throws -> Data {
        try await SpacesDeviceAPIConnectionSupport.withTimeout(timeout) {
            try await self.readLineAccumulating(from: connection)
        }
    }

    private func readLineAccumulating(from connection: NWConnection) async throws -> Data {
        if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer.prefix(upTo: newlineIndex))
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            return line
        }
        let (content, isComplete) = try await Self.receiveChunk(from: connection)
        if let content, !content.isEmpty { readBuffer.append(content) }
        if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer.prefix(upTo: newlineIndex))
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            return line
        }
        if isComplete {
            if readBuffer.isEmpty {
                throw SpacesDeviceAPIClientError.requestFailed("The direct remote connection was cancelled.")
            }
            defer { readBuffer.removeAll(keepingCapacity: true) }
            return readBuffer
        }
        return try await readLineAccumulating(from: connection)
    }

    private static func receiveChunk(from connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            let resume = OneShotContinuation(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    resume.resume(throwing: error)
                    return
                }
                resume.resume(returning: (content, isComplete))
            }
        }
    }

    private nonisolated func logEvent(sessionID: String, name: String, elapsedMS: Int? = nil, count: Int? = nil, attributes: [String: String]) {
        SpacesDeviceTerminalPerformanceLogger.emit(
            SpacesDeviceTerminalPerformanceEvent(
                sessionID: sessionID, source: "ios-direct-daemon", name: name, elapsedMS: elapsedMS, count: count, attributes: attributes))
    }
}

private final class DirectTerminalServiceStreamSubscription: @unchecked Sendable {
    private static let initialEventTimeout: Duration = .seconds(12)

    private let connection: NWConnection
    private let request: TerminalServiceRequest
    private let lifecycle: StreamLifecycle
    private let onEvent: @MainActor (GhosttyRemoteSessionStatePayload) -> Void
    private var buffer = Data()
    private var decodedState = false

    init(
        connection: NWConnection,
        request: TerminalServiceRequest,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) {
        self.connection = connection
        self.request = request
        self.onEvent = onEvent
        lifecycle = StreamLifecycle(onDisconnect: onDisconnect)
    }

    func start(on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + Self.initialEventTimeout.timeInterval) { [weak self] in
            guard let self, !decodedState else { return }
            lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed("Timed out waiting for remote terminal state."))
            connection.cancel()
        }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
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
            var data = try JSONEncoder().encode(request)
            data.append(0x0A)
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
                        if let response = try? JSONDecoder().decode(TerminalServiceResponse.self, from: line), !response.ok {
                            lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed(response.message))
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
                    let response = try? JSONDecoder().decode(TerminalServiceResponse.self, from: buffer),
                    !response.ok
                {
                    lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed(response.message))
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

actor SpacesDeviceAPICommandChannel {
    private let host: String
    private let port: Int
    private let transportKey: String
    private let clientApp: SpacesDeviceClientApp
    private let authToken: String?
    private let queue = DispatchQueue(label: "spaces.device.api.command")
    private var connection: NWConnection?

    init(settings: SpacesMobileConnectionSettings, clientApp: SpacesDeviceClientApp) {
        host = settings.trimmedHost
        port = settings.port
        transportKey = settings.transportKey
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
        let parameters = try SpacesDeviceAPITransport.parameters(transportKey: transportKey, role: .client)
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
                            lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed(response.message))
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
                    lifecycle.finish(error: SpacesDeviceAPIClientError.streamFailed(response.message))
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

    var timeval: timeval {
        let wholeSeconds = Int(timeInterval.rounded(.down))
        let microseconds = Int32((timeInterval - TimeInterval(wholeSeconds)) * 1_000_000)
        return Darwin.timeval(tv_sec: wholeSeconds, tv_usec: microseconds)
    }
}

private func encodeDeviceAPIRequestLine(_ request: SpacesDeviceAPIRequest) throws -> Data {
    var data = try SpacesDeviceAPICodec.encodeRequest(request)
    data.append(0x0A)
    return data
}

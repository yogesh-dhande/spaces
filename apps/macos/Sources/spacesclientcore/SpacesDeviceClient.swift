import Foundation
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore

#if canImport(Network)
    import Network
#endif

public struct SpacesDeviceOverview: Sendable, Equatable {
    public let device: SpacesPairedDeviceRecord
    public let overview: SpacesDeviceOverviewPayload

    public init(device: SpacesPairedDeviceRecord, overview: SpacesDeviceOverviewPayload) {
        self.device = device
        self.overview = overview
    }

    public var isLocal: Bool { device.id == SpacesPairedDeviceRecord.localDeviceID }
}

public enum SpacesDeviceClientError: LocalizedError, Equatable {
    case missingLocalBootstrap
    case missingOverview
    case missingTransportKey(String)
    case requestRejected(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingLocalBootstrap: "The local daemon did not return Device API credentials."
        case .missingOverview: "The device did not return project and workspace data."
        case .missingTransportKey(let deviceName): "Missing secure transport key for \(deviceName). Remove and reconnect this device."
        case .requestRejected(let message): message
        case .unavailable(let message): message
        }
    }
}

public enum SpacesDeviceClient {
    public typealias LocalBootstrapProvider = @Sendable (SpacesDeviceClientApp) throws -> SpacesDeviceAPIControlResponse
    typealias DeviceRequestProvider =
        @Sendable (SpacesDeviceAPIRequest, SpacesPairedDeviceRecord, SpacesDeviceClientApp, SpacesProfile?) throws -> SpacesDeviceAPIResponse
    static let defaultRequestTimeoutSeconds: TimeInterval = 10
    static let longRunningMutationTimeoutSeconds: TimeInterval = 60

    public static func macOSClientApp(
        installationID: String = SpacesDevicePairingClient.localMacClientInstallationID(), deviceName: String = Host.current().localizedName ?? "Mac",
        appVersion: String? = nil
    ) -> SpacesDeviceClientApp {
        SpacesDeviceClientApp(
            installationID: installationID, bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos", deviceName: deviceName,
            appVersion: appVersion)
    }

    @discardableResult public static func bootstrapLocalDevice(
        database providedDatabase: SpacesClientDatabase? = nil, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
        now: Date = Date(), bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalBootstrapProvider
    ) throws -> SpacesPairedDeviceRecord {
        let database = try providedDatabase ?? SpacesClientDatabase.defaultDatabase()
        let response = try bootstrap(clientApp)
        guard response.ok else { throw SpacesDeviceClientError.requestRejected(response.message) }
        guard let bootstrap = response.localClientBootstrap else { throw SpacesDeviceClientError.missingLocalBootstrap }
        let timestamp = ISO8601DateFormatter().string(from: now)
        let existingCreatedAt = (try? database.pairedDevice(id: bootstrap.deviceID)?.createdAt) ?? timestamp
        let record = SpacesPairedDeviceRecord(
            id: bootstrap.deviceID, name: bootstrap.name, platform: bootstrap.platform, host: bootstrap.host, port: bootstrap.port,
            certificateFingerprint: bootstrap.certificateFingerprint, createdAt: existingCreatedAt, updatedAt: timestamp, lastSelectedAt: timestamp)
        try database.upsert(device: record)
        try SpacesDeviceCredentialStore.saveToken(bootstrap.authToken, deviceID: record.id, profile: profile)
        try SpacesDeviceCredentialStore.saveTransportKey(bootstrap.transportKey, deviceID: record.id, profile: profile)
        return record
    }

    public static func localOverview(
        database providedDatabase: SpacesClientDatabase? = nil, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
        bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalBootstrapProvider
    ) throws -> SpacesDeviceOverview {
        try localOverview(
            database: providedDatabase, clientApp: clientApp, profile: profile, bootstrap: bootstrap,
            requestProvider: { request, device, clientApp, profile in
                try SpacesDeviceClient.request(request, device: device, clientApp: clientApp, profile: profile)
            })
    }

    static func localOverview(
        database providedDatabase: SpacesClientDatabase? = nil, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
        bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalBootstrapProvider, requestProvider: DeviceRequestProvider
    ) throws -> SpacesDeviceOverview {
        let database = try providedDatabase ?? SpacesClientDatabase.defaultDatabase()
        let device = try bootstrapLocalDevice(database: database, clientApp: clientApp, profile: profile, bootstrap: bootstrap)
        do { return try overview(device: device, clientApp: clientApp, profile: profile, requestProvider: requestProvider) } catch {
            guard isRetryableLocalDeviceAPIConnectionError(error) else { throw error }
            let refreshedDevice = try bootstrapLocalDevice(database: database, clientApp: clientApp, profile: profile, bootstrap: bootstrap)
            return try overview(device: refreshedDevice, clientApp: clientApp, profile: profile, requestProvider: requestProvider)
        }
    }

    /// Fetches the overview for a specific paired device, independent of which device is currently active.
    /// Used to populate the multi-device sidebar where every paired device is shown at once.
    public static func overview(device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil)
        throws -> SpacesDeviceOverview
    {
        try overview(
            device: device, clientApp: clientApp, profile: profile,
            requestProvider: { request, device, clientApp, profile in
                try SpacesDeviceClient.request(request, device: device, clientApp: clientApp, profile: profile)
            })
    }

    private static func overview(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile?, requestProvider: DeviceRequestProvider
    ) throws -> SpacesDeviceOverview {
        let response = try requestProvider(.init(command: .overview), device, clientApp, profile)
        guard let overview = response.overview else { throw SpacesDeviceClientError.missingOverview }
        return SpacesDeviceOverview(device: device, overview: overview)
    }

    /// Frozen-core handshake read: fetches the daemon's wire protocol + restart-impact status so the
    /// caller can classify compatibility against this build.
    public static func daemonStatus(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> TerminalServiceDaemonStatus {
        let response = try request(.init(command: .daemonStatus), device: device, clientApp: clientApp, profile: profile)
        guard let status = response.daemonStatus else { throw SpacesDeviceClientError.requestRejected(response.message) }
        return status
    }

    /// Frozen-core restart request: asks the daemon to restart itself. The OS service manager
    /// (launchd `KeepAlive` / systemd `Restart=always`) respawns it from the updated binary.
    @discardableResult
    public static func requestDaemonRestart(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .requestDaemonRestart), device: device, clientApp: clientApp, profile: profile)
    }

    public static func workspaceCreateOptions(
        selectedProjectID: String?, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceWorkspaceCreateOptions {
        let response = try request(
            .init(command: .workspaceCreateOptions(.init(projectID: selectedProjectID))), device: device, clientApp: clientApp, profile: profile)
        guard let options = response.workspaceCreateOptions else {
            throw SpacesDeviceClientError.requestRejected("The device did not return workspace create options.")
        }
        return options
    }

    public static func previewProject(
        dir: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceProjectPreview {
        let response = try request(.init(command: .previewProject(.init(dir: dir))), device: device, clientApp: clientApp, profile: profile)
        guard let preview = response.projectPreview else { throw SpacesDeviceClientError.requestRejected(response.message) }
        return preview
    }

    public static func listDirectories(
        path: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> [String] {
        let response = try request(.init(command: .listDirectories(.init(path: path))), device: device, clientApp: clientApp, profile: profile)
        return response.directorySuggestions?.paths ?? []
    }

    public static func createProject(
        projectDir: String?, gitURL: String?, config: SpacesDeviceProjectConfig? = nil, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .createProject(.init(projectDir: projectDir, gitURL: gitURL, config: config))), device: device, clientApp: clientApp,
            profile: profile)
    }

    public static func deleteProject(
        projectID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .deleteProject(.init(projectID: projectID))), device: device, clientApp: clientApp, profile: profile)
    }

    public static func importProjectSpacesYAML(
        projectID: String, updateAllWorkspaces: Bool = false, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .importProject(.init(projectID: projectID, updateAllWorkspaces: updateAllWorkspaces))), device: device,
            clientApp: clientApp, profile: profile)
    }

    public static func exportProjectSpacesYAML(
        projectID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .exportProject(.init(projectID: projectID))), device: device, clientApp: clientApp, profile: profile)
    }

    public static func createWorkspace(
        projectID: String, branch: String?, baseBranch: String?, directoryName: String? = nil, notes: String? = nil,
        allowExistingBranchReuse: Bool = false, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .createWorkspace(
                    .init(
                        projectID: projectID, branch: branch, baseBranch: baseBranch, directoryName: directoryName, notes: notes,
                        allowExistingBranchReuse: allowExistingBranchReuse))), device: device, clientApp: clientApp, profile: profile)
    }

    public static func launchWorkspace(
        workspaceID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .launchWorkspace(.init(workspaceID: workspaceID))), device: device, clientApp: clientApp, profile: profile)
    }

    public static func stopWorkspace(
        workspaceID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .stopWorkspace(.init(workspaceID: workspaceID))), device: device, clientApp: clientApp, profile: profile)
    }

    public static func restartWorkspace(
        workspaceID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .restartWorkspace(.init(workspaceID: workspaceID))), device: device, clientApp: clientApp, profile: profile)
    }

    public static func archiveWorkspace(
        workspaceID: String, deleteLocalBranch: Bool = false, deleteRemoteBranch: Bool = false, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .archiveWorkspace(
                    .init(workspaceID: workspaceID, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch))), device: device,
            clientApp: clientApp, profile: profile)
    }

    public static func runWorkspaceSetup(
        workspaceID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .runWorkspaceSetup(.init(workspaceID: workspaceID))), device: device, clientApp: clientApp, profile: profile)
    }

    public static func updateProjectConfig(
        projectID: String, config: SpacesDeviceProjectConfig, updateAllWorkspaces: Bool = false, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .updateProjectConfig(.init(projectID: projectID, config: config, updateAllWorkspaces: updateAllWorkspaces))),
            device: device, clientApp: clientApp, profile: profile)
    }

    public static func updateWorkspaceConfig(
        workspaceID: String, config: SpacesDeviceWorkspaceConfig, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .updateWorkspaceConfig(.init(workspaceID: workspaceID, config: config))), device: device, clientApp: clientApp,
            profile: profile)
    }

    public static func updateWorkspaceMetadata(
        workspaceID: String, branch: String? = nil, notes: String? = nil, updatesBranch: Bool = false, updatesNotes: Bool = false,
        isHidden: Bool? = nil, updatesHidden: Bool = false, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .updateWorkspaceMetadata(
                    .init(
                        workspaceID: workspaceID, branch: branch, notes: notes, updatesBranch: updatesBranch, updatesNotes: updatesNotes,
                        isHidden: isHidden, updatesHidden: updatesHidden))), device: device, clientApp: clientApp, profile: profile)
    }

    public static func openWorkspaceTerminal(
        workspaceID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .openWorkspaceTerminal(.init(workspaceID: workspaceID))), device: device, clientApp: clientApp, profile: profile)
    }

    public static func stopWorkspaceTerminal(
        workspaceID: String, sessionID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .stopWorkspaceTerminal(.init(workspaceID: workspaceID, sessionID: sessionID))), device: device, clientApp: clientApp,
            profile: profile)
    }

    public static func runWorkspaceProcess(
        workspaceID: String, processKey: String, processTemplateID: String?, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .runWorkspaceProcess(.init(workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID))),
            device: device, clientApp: clientApp, profile: profile)
    }

    public static func stopWorkspaceProcess(
        workspaceID: String, processID: String?, processKey: String?, processTemplateID: String?, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .stopWorkspaceProcess(
                    .init(workspaceID: workspaceID, processID: processID, processKey: processKey, processTemplateID: processTemplateID))),
            device: device, clientApp: clientApp, profile: profile)
    }

    public static func restartWorkspaceProcess(
        workspaceID: String, processID: String?, processKey: String?, processTemplateID: String?, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .restartWorkspaceProcess(
                    .init(workspaceID: workspaceID, processID: processID, processKey: processKey, processTemplateID: processTemplateID))),
            device: device, clientApp: clientApp, profile: profile)
    }

    public static func runCodingAgent(
        workspaceID: String, agentName: String, agentLauncherID: String?, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .runCodingAgent(.init(workspaceID: workspaceID, agentName: agentName, agentLauncherID: agentLauncherID))), device: device,
            clientApp: clientApp, profile: profile)
    }

    public static func stopCodingAgent(
        workspaceID: String, agentID: String?, agentName: String?, agentLauncherID: String?, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .stopCodingAgent(.init(workspaceID: workspaceID, agentID: agentID, agentName: agentName, agentLauncherID: agentLauncherID))),
            device: device, clientApp: clientApp, profile: profile)
    }

    public static func restartCodingAgent(
        workspaceID: String, agentID: String?, agentName: String?, agentLauncherID: String?, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .restartCodingAgent(
                    .init(workspaceID: workspaceID, agentID: agentID, agentName: agentName, agentLauncherID: agentLauncherID))), device: device,
            clientApp: clientApp, profile: profile)
    }

    public static func request(
        _ request: SpacesDeviceAPIRequest, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        #if canImport(Network)
            guard let transportKey = try SpacesDeviceCredentialStore.transportKey(deviceID: device.id, profile: profile) else {
                throw SpacesDeviceClientError.missingTransportKey(device.name)
            }
            let authToken = try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: profile)
            let client = try SpacesDeviceAPIRequestClient(
                host: device.host, port: device.port, transportKey: transportKey, timeoutSeconds: requestTimeoutSeconds(for: request.command))
            let response = try client.request(authenticated(request, authToken: authToken, clientApp: clientApp))
            guard response.ok else { throw SpacesDeviceClientError.requestRejected(response.message) }
            return response
        #else
            throw SpacesDeviceClientError.unavailable("Device API requests require Network.framework.")
        #endif
    }

    private static func authenticated(_ request: SpacesDeviceAPIRequest, authToken: String?, clientApp: SpacesDeviceClientApp)
        -> SpacesDeviceAPIRequest
    { SpacesDeviceAPIRequest(command: request.command, authToken: authToken, clientApp: clientApp) }

    public static func defaultLocalBootstrapProvider(_ clientApp: SpacesDeviceClientApp) throws -> SpacesDeviceAPIControlResponse {
        try SpacesDeviceAPIControlClient.bootstrapLocalClientEnsuringCurrentTerminalService(clientApp: clientApp)
    }

    static func isRetryableLocalDeviceAPIConnectionError(_ error: any Error) -> Bool {
        #if canImport(Network)
            if let requestError = error as? SpacesDeviceAPIRequestClientError {
                switch requestError {
                case .timeout, .emptyResponse, .connectionFailed: return true
                case .invalidPort: return false
                }
            }
            if let networkError = error as? NWError {
                switch networkError {
                case .posix(let code): return isRetryableLocalDeviceAPIPOSIXCode(code)
                default: return false
                }
            }
        #endif

        if let posixError = error as? POSIXError { return isRetryableLocalDeviceAPIPOSIXCode(posixError.code) }
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(nsError.code)) else { return false }
        return isRetryableLocalDeviceAPIPOSIXCode(code)
    }

    private static func isRetryableLocalDeviceAPIPOSIXCode(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .ECONNABORTED, .ECONNREFUSED, .ECONNRESET, .EHOSTDOWN, .EHOSTUNREACH, .ENETDOWN, .ENETUNREACH, .ENOTCONN, .ETIMEDOUT: return true
        default: return false
        }
    }

    static func requestTimeoutSeconds(for command: SpacesDeviceAPICommand) -> TimeInterval {
        switch command {
        case .createProject, .deleteProject, .importProject, .exportProject, .createWorkspace, .launchWorkspace, .stopWorkspace, .restartWorkspace,
            .archiveWorkspace, .runWorkspaceSetup, .openWorkspaceTerminal, .stopWorkspaceTerminal, .runWorkspaceProcess, .stopWorkspaceProcess,
            .restartWorkspaceProcess, .runCodingAgent, .stopCodingAgent, .restartCodingAgent:
            longRunningMutationTimeoutSeconds
        case .pair, .ping, .daemonStatus, .requestDaemonRestart, .overview, .previewProject, .listDirectories, .workspaceCreateOptions,
            .updateProjectConfig, .updateWorkspaceConfig, .updateWorkspaceMetadata, .state, .terminalControl, .resolveTerminalLink,
            .readTerminalLinkChunk, .subscribe:
            defaultRequestTimeoutSeconds
        }
    }
}

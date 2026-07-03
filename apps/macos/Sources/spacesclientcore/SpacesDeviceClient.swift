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

/// Outcome of a compatibility-aware device refresh (`SpacesDeviceClient.resolveOverview`).
public struct SpacesDeviceOverviewResolution: Sendable {
    /// The overview to render, or `nil` when the device is reachable but wire-incompatible — the
    /// caller shows the compatibility block instead of stale workspace data.
    public let overview: SpacesDeviceOverview?
    /// The frozen-core status backing the verdict, or `nil` if neither the overview nor the fallback
    /// handshake could supply one (e.g. a daemon too old to report any status).
    public let daemonStatus: TerminalServiceDaemonStatus?
    /// The compatibility verdict, or `nil` when no status was available to evaluate.
    public let compatibility: SpacesWireCompatibility?

    public init(overview: SpacesDeviceOverview?, daemonStatus: TerminalServiceDaemonStatus?, compatibility: SpacesWireCompatibility?) {
        self.overview = overview
        self.daemonStatus = daemonStatus
        self.compatibility = compatibility
    }
}

public enum SpacesDeviceClientError: LocalizedError, Equatable {
    case missingLocalBootstrap
    case missingOverview
    case missingTransportKey(deviceName: String, isLocal: Bool)
    case requestRejected(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingLocalBootstrap: "The local daemon did not return Device API credentials."
        case .missingOverview: "The device did not return project and workspace data."
        // The recovery differs by device: a remote device's transport key is only obtainable by
        // re-pairing, but the local device re-bootstraps itself on launch, so "remove and reconnect"
        // is wrong for this Mac (you cannot un-pair your own device). Guide the local case to a
        // restart, which re-establishes the key. This is only reached when the in-app self-heal
        // (`ensureLocalDeviceCredentials`) could not re-bootstrap — typically the local daemon being
        // unreachable — so a relaunch (which relaunches the daemon) is the actionable next step.
        case .missingTransportKey(let deviceName, let isLocal):
            isLocal
                ? "Missing secure transport key for \(deviceName). Restart Spaces to reconnect this device."
                : "Missing secure transport key for \(deviceName). Remove and reconnect this device."
        case .requestRejected(let message): message
        case .unavailable(let message): message
        }
    }
}

public enum SpacesDeviceClient {
    public typealias LocalBootstrapProvider = @Sendable (SpacesDeviceClientApp, _ presentedToken: String?) throws -> SpacesDeviceAPIControlResponse
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
        // Present the token we already hold so the daemon keeps it instead of rotating it: the local
        // device re-bootstraps on every sidebar reload, and a rotated token would invalidate the
        // tokens held by live Device API connections (terminal streams and control requests).
        let presentedToken = (try? SpacesDeviceCredentialStore.token(deviceID: SpacesPairedDeviceRecord.localDeviceID, profile: profile)) ?? nil
        let response = try bootstrap(clientApp, presentedToken)
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

    /// Ensures the local device's Device API credentials (transport key and auth token) are present,
    /// re-bootstrapping to regenerate them when either is missing. Only the local device can self-heal
    /// this way: it is bootstrapped, not paired through a one-time window, so a fresh bootstrap
    /// re-establishes its credentials. A remote device with missing credentials genuinely needs to be
    /// removed and re-paired, so callers must not route remote devices here. Cheap when the credentials
    /// already exist (two keychain existence checks, no daemon round-trip).
    @discardableResult public static func ensureLocalDeviceCredentials(
        database providedDatabase: SpacesClientDatabase? = nil, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
        bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalBootstrapProvider
    ) throws -> SpacesPairedDeviceRecord? {
        let localDeviceID = SpacesPairedDeviceRecord.localDeviceID
        let hasCredentials =
            ((try? SpacesDeviceCredentialStore.hasTransportKey(deviceID: localDeviceID, profile: profile)) ?? false)
            && ((try? SpacesDeviceCredentialStore.hasToken(deviceID: localDeviceID, profile: profile)) ?? false)
        if hasCredentials { return nil }
        return try bootstrapLocalDevice(database: providedDatabase, clientApp: clientApp, profile: profile, bootstrap: bootstrap)
    }

    /// True when a local-device failure is a daemon-reachability problem rather than an error from a
    /// reachable daemon. Reachability covers: the control socket being unavailable; the Device API network
    /// transport failing to connect (timeout/refused/reset); spacesd failing to start at all (startup
    /// timeout, or a missing executable); and the daemon answering that its Device API is not running.
    /// Callers degrade these to an offline sidebar. Anything else — a persistence/credential failure after
    /// a reachable daemon returned a valid bootstrap, or a reachable daemon rejecting the overview with a
    /// real error (database/migration/authorization/malformed payload) — means spacesd is reachable, so it
    /// must surface as a real error instead of being hidden behind an offline state.
    public static func isLocalDaemonUnreachableError(_ error: any Error) -> Bool {
        if SpacesDeviceAPIControlClient.isControlEndpointUnavailable(error) { return true }
        // The Device API network transport (used by the overview round-trip) couldn't reach the daemon.
        if isRetryableLocalDeviceAPIConnectionError(error) { return true }
        #if os(macOS)
            // The terminal service couldn't bring spacesd up at all — it timed out starting, or the
            // executable is missing — so the local daemon is down, the same offline state as an unreachable
            // socket. These cases exist only in the macOS TerminalService, which is where local bootstrap runs.
            if let terminalError = error as? TerminalServiceError {
                switch terminalError {
                case .serviceStartupTimedOut, .executableNotFound: return true
                case .requestFailed: return false
                }
            }
        #endif
        if case SpacesDeviceClientError.requestRejected(let message) = error {
            return message == SpacesDeviceAPIControlClient.deviceAPINotRunningMessage
        }
        return false
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

    #if canImport(Network)
        /// Opens a live device-overview subscription: the paired daemon pushes a
        /// fresh overview whenever its database changes, so the client stays current
        /// without polling. The returned client must be retained and `stop()`ped.
        public static func subscribeOverview(
            device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
            onOverview: @escaping @Sendable (SpacesDeviceOverview) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
        ) throws -> SpacesDeviceAPIOverviewStreamClient {
            let (transportKey, authToken) = try credentialsEnsuringLocalRecovery(device: device, clientApp: clientApp, profile: profile)
            let client = try SpacesDeviceAPIOverviewStreamClient(
                authToken: authToken, clientApp: clientApp, host: device.host, port: device.port, transportKey: transportKey,
                onOverview: { onOverview(SpacesDeviceOverview(device: device, overview: $0)) }, onDisconnect: onDisconnect)
            try client.start()
            return client
        }
    #endif

    /// Frozen-core handshake read: fetches the daemon's wire protocol + restart-impact status so the
    /// caller can classify compatibility against this build.
    public static func daemonStatus(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> TerminalServiceDaemonStatus {
        try daemonStatus(
            device: device, clientApp: clientApp, profile: profile,
            requestProvider: { request, device, clientApp, profile in
                try SpacesDeviceClient.request(request, device: device, clientApp: clientApp, profile: profile)
            })
    }

    private static func daemonStatus(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile?, requestProvider: DeviceRequestProvider
    ) throws -> TerminalServiceDaemonStatus {
        let response = try requestProvider(.init(command: .daemonStatus), device, clientApp, profile)
        guard let status = response.daemonStatus else { throw SpacesDeviceClientError.requestRejected(response.message) }
        return status
    }

    /// Refreshes a device, reading its compatibility verdict from the overview's inline frozen-core
    /// status so the common compatible case costs a single round-trip. The standalone `daemonStatus`
    /// handshake is issued only when the overview cannot carry the verdict: a daemon that predates the
    /// inline field, or an incompatible daemon whose overview does not decode at all. This is the
    /// per-refresh hot path; see `docs/implementation.md` (device compatibility handshake).
    public static func resolveOverview(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceOverviewResolution {
        try resolveOverview(
            device: device, clientApp: clientApp, profile: profile,
            requestProvider: { request, device, clientApp, profile in
                try SpacesDeviceClient.request(request, device: device, clientApp: clientApp, profile: profile)
            })
    }

    static func resolveOverview(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile?, requestProvider: DeviceRequestProvider
    ) throws -> SpacesDeviceOverviewResolution {
        let payload: SpacesDeviceOverviewPayload
        do { payload = try overview(device: device, clientApp: clientApp, profile: profile, requestProvider: requestProvider).overview } catch {
            // The overview did not decode (a wire-incompatible daemon's payload) or the device is
            // unreachable. Ask the frozen core, which stays decodable across versions: an incompatible
            // verdict means "blocked" (render the block, no overview); anything else is a genuine
            // connection error to surface.
            if let status = try? daemonStatus(device: device, clientApp: clientApp, profile: profile, requestProvider: requestProvider) {
                let verdict = SpacesWireCompatibility.evaluate(daemonStatus: status)
                if !verdict.isCompatible { return SpacesDeviceOverviewResolution(overview: nil, daemonStatus: status, compatibility: verdict) }
            }
            throw error
        }
        if let status = payload.daemonStatus {
            // Steady state: the verdict rode inline on the overview, so no second round-trip is needed.
            let verdict = SpacesWireCompatibility.evaluate(daemonStatus: status)
            let overview = verdict.isCompatible ? SpacesDeviceOverview(device: device, overview: payload) : nil
            return SpacesDeviceOverviewResolution(overview: overview, daemonStatus: status, compatibility: verdict)
        }
        // Older daemon that predates the inline status: keep the overview already fetched and read the
        // verdict from the standalone frozen-core handshake.
        let status = try? daemonStatus(device: device, clientApp: clientApp, profile: profile, requestProvider: requestProvider)
        let verdict = status.map(SpacesWireCompatibility.evaluate(daemonStatus:))
        let overview = (verdict?.isCompatible ?? true) ? SpacesDeviceOverview(device: device, overview: payload) : nil
        return SpacesDeviceOverviewResolution(overview: overview, daemonStatus: status, compatibility: verdict)
    }

    /// Frozen-core restart request: asks the daemon to restart itself. The OS service manager
    /// (launchd `KeepAlive` / systemd `Restart=always`) respawns it from the updated binary.
    @discardableResult public static func requestDaemonRestart(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse { try request(.init(command: .requestDaemonRestart), device: device, clientApp: clientApp, profile: profile) }

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

    /// Loads a git repository's `spaces.yaml` (single file, no clone) to populate the add-project form,
    /// along with any managed directories a later Create would replace. The full clone happens at Create.
    public static func previewGitProject(
        gitURL: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceGitProjectPreview {
        let response = try request(.init(command: .previewGitProject(.init(gitURL: gitURL))), device: device, clientApp: clientApp, profile: profile)
        guard let preview = response.gitProjectPreview else { throw SpacesDeviceClientError.requestRejected(response.message) }
        return preview
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

    public static func renameTerminalSession(
        workspaceID: String, sessionID: String, title: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .renameTerminalSession(.init(workspaceID: workspaceID, sessionID: sessionID, title: title))), device: device,
            clientApp: clientApp, profile: profile)
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

    /// Reads a device's Device API credentials (pinned-TLS transport key and auth token), transparently
    /// re-bootstrapping the local device when *either* secret is missing. Both are checked together so a
    /// lost token alone still triggers recovery — otherwise the request would be sent unauthenticated and
    /// rejected with a 401 while the transport key looked healthy. A remote device cannot regenerate its
    /// own credentials, so a missing remote transport key surfaces as `missingTransportKey` (the client
    /// must re-pair); a remote token is returned as-is (possibly nil, the pre-existing behavior).
    public static func credentialsEnsuringLocalRecovery(device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile?)
        throws -> (transportKey: String, authToken: String?)
    {
        if device.id == SpacesPairedDeviceRecord.localDeviceID {
            let hasTransportKey = try SpacesDeviceCredentialStore.transportKey(deviceID: device.id, profile: profile) != nil
            let hasToken = try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: profile) != nil
            if !hasTransportKey || !hasToken { try ensureLocalDeviceCredentials(clientApp: clientApp, profile: profile) }
            guard let transportKey = try SpacesDeviceCredentialStore.transportKey(deviceID: device.id, profile: profile) else {
                throw SpacesDeviceClientError.missingTransportKey(deviceName: device.name, isLocal: true)
            }
            return (transportKey, try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: profile))
        }
        guard let transportKey = try SpacesDeviceCredentialStore.transportKey(deviceID: device.id, profile: profile) else {
            throw SpacesDeviceClientError.missingTransportKey(deviceName: device.name, isLocal: false)
        }
        return (transportKey, try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: profile))
    }

    public static func request(
        _ request: SpacesDeviceAPIRequest, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        #if canImport(Network)
            let (transportKey, authToken) = try credentialsEnsuringLocalRecovery(device: device, clientApp: clientApp, profile: profile)
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

    public static func defaultLocalBootstrapProvider(_ clientApp: SpacesDeviceClientApp, _ presentedToken: String?) throws
        -> SpacesDeviceAPIControlResponse
    { try SpacesDeviceAPIControlClient.bootstrapLocalClientEnsuringCurrentTerminalService(clientApp: clientApp, presentedToken: presentedToken) }

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
        case .createProject, .previewGitProject, .deleteProject, .importProject, .exportProject, .createWorkspace, .launchWorkspace, .stopWorkspace,
            .restartWorkspace, .archiveWorkspace, .runWorkspaceSetup, .openWorkspaceTerminal, .stopWorkspaceTerminal, .runWorkspaceProcess,
            .stopWorkspaceProcess, .restartWorkspaceProcess, .runCodingAgent, .stopCodingAgent, .restartCodingAgent:
            longRunningMutationTimeoutSeconds
        case .pair, .ping, .daemonStatus, .requestDaemonRestart, .overview, .previewProject, .listDirectories, .workspaceCreateOptions,
            .updateProjectConfig, .updateWorkspaceConfig, .updateWorkspaceMetadata, .renameTerminalSession, .state, .terminalControl,
            .terminalPasteImage, .resolveTerminalLink, .readTerminalLinkChunk, .subscribe, .subscribeDeviceOverview:
            defaultRequestTimeoutSeconds
        }
    }
}

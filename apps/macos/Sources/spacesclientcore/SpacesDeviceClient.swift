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
    case missingCertificateFingerprint(deviceName: String, isLocal: Bool)
    case requestRejected(message: String, code: SpacesDeviceErrorCode?)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingLocalBootstrap: "The local daemon did not return Device API credentials."
        case .missingOverview: "The device did not return project and workspace data."
        // The recovery differs by device: a remote device's pinned certificate fingerprint is only
        // obtainable by re-pairing, but the local device re-bootstraps itself on launch, so "remove
        // and re-pair" is wrong for this Mac (you cannot un-pair your own device). Guide the local
        // case to a restart, which re-establishes the fingerprint. This is only reached when the
        // in-app self-heal (`ensureLocalDeviceCredentials`) could not re-bootstrap — typically the
        // local daemon being unreachable — so a relaunch (which relaunches the daemon) is the
        // actionable next step.
        case .missingCertificateFingerprint(let deviceName, let isLocal):
            isLocal
                ? "Missing secure device identity for \(deviceName). Restart Spaces to reconnect this device."
                : "Missing secure device identity for \(deviceName). Remove this device and pair it again."
        case .requestRejected(let message, _): message
        case .unavailable(let message): message
        }
    }
}

extension SpacesDeviceClientError: SpacesDeviceErrorCodeProviding {
    public var spacesDeviceErrorCode: SpacesDeviceErrorCode? {
        if case .requestRejected(_, let code) = self { return code }
        return nil
    }
}

public enum SpacesDeviceClient {
    public typealias LocalBootstrapProvider = @Sendable (SpacesDeviceClientApp, _ presentedToken: String?) throws -> SpacesDeviceAPIControlResponse
    typealias DeviceRequestProvider =
        @Sendable (SpacesDeviceAPIRequest, SpacesPairedDeviceRecord, SpacesDeviceClientApp, SpacesProfile?) throws -> SpacesDeviceAPIResponse
    static let defaultRequestTimeoutSeconds: TimeInterval = 10
    static let agentHooksStatusRequestTimeoutSeconds: TimeInterval = 20
    static let longRunningMutationTimeoutSeconds: TimeInterval = 60
    /// A transcript response can carry up to the full scrollback budget (10MB, ~13MB as base64 JSON),
    /// which needs more than the default timeout on slow remote links.
    static let terminalTranscriptRequestTimeoutSeconds: TimeInterval = 60

    public static func macOSClientApp(
        installationID: String = SpacesDevicePairingClient.localMacClientInstallationID(), deviceName: String = Host.current().localizedName ?? "Mac",
        appVersion: String? = nil
    ) -> SpacesDeviceClientApp {
        SpacesDeviceClientApp(
            installationID: installationID, bundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, platform: "macos", deviceName: deviceName,
            appVersion: appVersion)
    }

    /// Serializes local bootstraps within this process so read-presented-token → daemon round-trip →
    /// save-returned-token runs as one atomic section. The daemon mints a replacement token for every
    /// stale presentation, so two interleaved bootstraps that both read a stale stored token would mint
    /// competing tokens — the second revoking the first's — and their out-of-order saves could persist
    /// a non-current token. Serialized, the second bootstrap reads the token the first just persisted,
    /// presents it, and the daemon keeps it. Held across a blocking daemon round-trip deliberately;
    /// callers already run off the main actor, and correctness needs the whole section.
    private static let localBootstrapLock = NSLock()

    @discardableResult public static func bootstrapLocalDevice(
        database providedDatabase: SpacesClientDatabase? = nil, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
        now: Date = Date(), bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalBootstrapProvider
    ) throws -> SpacesPairedDeviceRecord {
        let database = try providedDatabase ?? SpacesClientDatabase.defaultDatabase()
        return try localBootstrapLock.withLock {
            // Present the token we already hold so the daemon keeps it instead of rotating it: the local
            // device re-bootstraps on every sidebar reload, and a rotated token would invalidate the
            // tokens held by live Device API connections (terminal streams and control requests).
            let presentedToken = (try? SpacesDeviceCredentialStore.token(deviceID: SpacesPairedDeviceRecord.localDeviceID, profile: profile)) ?? nil
            let response = try bootstrap(clientApp, presentedToken)
            // The local control socket's response carries no error code; pairing-related rejections
            // from it are classified by the message heuristics kept for uncoded errors.
            guard response.ok else { throw SpacesDeviceClientError.requestRejected(message: response.message, code: nil) }
            guard let bootstrap = response.localClientBootstrap else { throw SpacesDeviceClientError.missingLocalBootstrap }
            let timestamp = ISO8601DateFormatter().string(from: now)
            let existingCreatedAt = (try? database.pairedDevice(id: bootstrap.deviceID)?.createdAt) ?? timestamp
            let record = SpacesPairedDeviceRecord(
                id: bootstrap.deviceID, name: bootstrap.name, platform: bootstrap.platform, hosts: [bootstrap.host], port: bootstrap.port,
                certificateFingerprint: bootstrap.certificateFingerprint, createdAt: existingCreatedAt, updatedAt: timestamp,
                lastSelectedAt: timestamp)
            try database.upsert(device: record)
            try SpacesDeviceCredentialStore.saveToken(bootstrap.authToken, deviceID: record.id, profile: profile)
            return record
        }
    }

    /// Ensures the local device's Device API auth token is present, re-bootstrapping to regenerate it
    /// when missing. Only the local device can self-heal this way: it is bootstrapped, not paired
    /// through a one-time window, so a fresh bootstrap re-establishes its credentials. A remote device
    /// with missing credentials genuinely needs to be removed and re-paired, so callers must not route
    /// remote devices here. Cheap when the token already exists (one secret-file existence check, no
    /// daemon round-trip).
    @discardableResult public static func ensureLocalDeviceCredentials(
        database providedDatabase: SpacesClientDatabase? = nil, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
        bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalBootstrapProvider
    ) throws -> SpacesPairedDeviceRecord? {
        let localDeviceID = SpacesPairedDeviceRecord.localDeviceID
        let hasCredentials = (try? SpacesDeviceCredentialStore.hasToken(deviceID: localDeviceID, profile: profile)) ?? false
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
        if isDeviceAPITransportFailure(error) { return true }
        #if os(macOS)
            // The terminal service couldn't bring spacesd up at all — it timed out starting, or no daemon
            // binary this profile may launch exists — so the local daemon is down, the same offline state
            // as an unreachable socket. These cases exist only in the macOS TerminalService, which is where
            // local bootstrap runs.
            if let terminalError = error as? TerminalServiceError {
                switch terminalError {
                case .serviceStartupTimedOut, .daemonNotFound: return true
                case .daemonWireIncompatible, .requestFailed: return false
                }
            }
        #endif
        if case SpacesDeviceClientError.requestRejected(let message, _) = error {
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
            guard isDeviceAPITransportFailure(error) else { throw error }
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

    /// Opens a live device-overview subscription: the paired daemon pushes a
    /// fresh overview whenever its database changes, so the client stays current
    /// without polling. The returned client must be retained and `stop()`ped.
    public static func subscribeOverview(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
        onOverview: @escaping @Sendable (SpacesDeviceOverview) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws -> SpacesDeviceAPIOverviewStreamClient {
        let (certificateFingerprint, authToken) = try credentialsEnsuringLocalRecovery(device: device, clientApp: clientApp, profile: profile)
        // The record this subscription publishes with, carried across deliveries. A stream outlives many
        // overviews, and only the delivery that actually widens the candidates gets a merged record back;
        // without carrying it, every later delivery would republish the record captured at subscribe time
        // and walk the learned address back out of the caller's state.
        let publishedRecord = PairedDeviceRecordBox(device)
        let client = try SpacesDeviceAPIOverviewStreamClient(
            authToken: authToken, clientApp: clientApp,
            resolver: SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: certificateFingerprint),
            onOverview: { payload in
                // Every delivery is the daemon's own current view of where it is reachable, so this is
                // where a pushed overview widens the device's candidate addresses. Once per delivery, not
                // per render: the sidebar repaints from the published section, not from here.
                let current = publishedRecord.value
                if let merged = mergeAdvertisedHosts(device: current, status: payload.daemonStatus) { publishedRecord.value = merged }
                onOverview(SpacesDeviceOverview(device: publishedRecord.value, overview: payload))
            }, onDisconnect: onDisconnect)
        try client.start()
        return client
    }

    /// Folds the addresses a daemon reports for itself (`TerminalServiceDaemonStatus.deviceAPIAddresses`)
    /// into the device's stored candidates and the live resolver, so an address this client has never
    /// seen — the tailnet address of a Mac that gained Tailscale after pairing — becomes dialable without
    /// re-pairing. An empty list means the daemon reported nothing, so it changes nothing, and an
    /// unchanged union writes nothing.
    ///
    /// Skipped for the local device: this Mac's own daemon is reached over loopback and re-resolves
    /// itself through the control socket (`recoveredLocalResolution`), so folding in its outward-facing
    /// LAN and tailnet addresses would make every local connect race addresses that are never the right
    /// way to reach it.
    ///
    /// Returns the record as stored after the merge, or nil when nothing was written. Callers publish
    /// that record rather than the one they passed in: the caller's copy was read before this widened
    /// the candidates, and a client that keeps holding it hands the narrower list back to
    /// `SpacesDeviceEndpointRegistry.resolver(for:certificateFingerprint:)`, whose reconcile would then
    /// strip the address this merge just learned right back out of the live resolver.
    @discardableResult static func mergeAdvertisedHosts(
        device: SpacesPairedDeviceRecord, status: TerminalServiceDaemonStatus?, database providedDatabase: SpacesClientDatabase? = nil
    ) -> SpacesPairedDeviceRecord? {
        guard device.id != SpacesPairedDeviceRecord.localDeviceID, let advertised = status?.deviceAPIAddresses, !advertised.isEmpty else {
            return nil
        }
        let resolver = SpacesDeviceEndpointRegistry.resolver(
            for: device, certificateFingerprint: device.certificateFingerprint, database: providedDatabase)
        // The steady state — the daemon reporting the addresses this client already knows — is decided
        // in memory against the live resolver's list, which the stored record's list is kept equal to.
        // A subscription delivers an overview on every daemon database change, and opening a write
        // transaction on the client database that often, only to persist nothing, would put this on a
        // path it has no business being on.
        let candidates = resolver.candidateHosts
        guard SpacesClientDatabase.mergedHostCandidates(stored: candidates, advertised: advertised) != candidates else { return nil }
        guard let database = try? providedDatabase ?? SpacesClientDatabase.defaultDatabase(),
            let merged = try? database.mergeAdvertisedHosts(deviceID: device.id, advertised: advertised)
        else { return nil }
        SpacesDeviceEndpointRegistry.refresh(record: merged)
        return merged
    }

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
        guard let status = response.daemonStatus else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return status
    }

    /// Reports availability + Spaces hook-install status for supported coding agents on `device`
    /// (local or remote). Read-only.
    public static func agentHooksStatus(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> [AgentHookStatus] {
        let response = try request(.init(command: .agentHooksStatus), device: device, clientApp: clientApp, profile: profile)
        guard let payload = response.agentHooksStatus else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return payload.agents
    }

    /// Idempotently installs Spaces lifecycle hooks for `kinds` on `device` (local or remote). Returns
    /// fresh status for every supported agent plus one failure entry per requested agent that could not
    /// be installed — an install lands partially, so a non-empty `failures` does not mean nothing
    /// happened. Throws only when the request itself fails.
    @discardableResult public static func installAgentHooks(
        _ kinds: [CodingAgent], device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> AgentHookInstallOutcome {
        let response = try request(.init(command: .installAgentHooks(.init(kinds: kinds))), device: device, clientApp: clientApp, profile: profile)
        guard let payload = response.agentHooksInstall else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return payload
    }

    /// Refreshes a device, reading its compatibility verdict from the overview's inline frozen-core
    /// status so the common compatible case costs a single round-trip. The standalone `daemonStatus`
    /// handshake is issued only as a fallback when the overview itself fails to decode — a
    /// wire-incompatible daemon (a separate macOS/Linux install pair, not this build). For the local
    /// device a transport failure re-resolves the daemon's current endpoint and retries once, since a
    /// stored local port is not durable. This is the per-refresh hot path; see
    /// `docs/implementation.md` (device compatibility handshake).
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
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile?, requestProvider: DeviceRequestProvider,
        database providedDatabase: SpacesClientDatabase? = nil,
        bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalRecoveryBootstrapProvider
    ) throws -> SpacesDeviceOverviewResolution {
        do {
            return try resolutionFromInlineStatus(
                device: device, clientApp: clientApp, profile: profile, requestProvider: requestProvider, database: providedDatabase)
        } catch {
            // The local daemon's Device API endpoint is not durable: it can idle-shut-down, be restarted,
            // or be relaunched on a freshly assigned port, so the port in the caller's `paired_devices`
            // record goes stale without anything invalidating it. A transport failure against the local
            // device is therefore first read as "this Mac's endpoint needs re-resolving", not "the device
            // is gone". Only the local device needs that step: a remote device's candidate addresses are
            // already re-walked inside the connect itself (`SpacesDeviceEndpointResolver`), so a transport
            // failure there means every address it knows was tried and none answered.
            guard device.id == SpacesPairedDeviceRecord.localDeviceID, isDeviceAPITransportFailure(error) else {
                return try resolutionFromHandshake(
                    device: device, clientApp: clientApp, profile: profile, requestProvider: requestProvider, overviewError: error)
            }
            return try recoveredLocalResolution(
                device: device, clientApp: clientApp, profile: profile, requestProvider: requestProvider, database: providedDatabase,
                bootstrap: bootstrap)
        }
    }

    /// The local device's bounded endpoint recovery: re-resolve this Mac's daemon and resolve once more
    /// against it. Two steps, each taken at most once — a bootstrap that starts the daemon if it is down
    /// and waits out a Device API listener still coming up (`defaultLocalRecoveryBootstrapProvider`), then
    /// a single overview retry against the refreshed record. There is no loop here: a recovery that does
    /// not succeed reports the failure rather than trying again.
    ///
    /// Both outcomes are logged as `terminal_device_local_endpoint_recovery`, because a recovery that
    /// silently fails to produce an overview is indistinguishable — from the app log alone — from a
    /// session that was never resolvable, which is what makes this failure mode expensive to diagnose.
    private static func recoveredLocalResolution(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile?, requestProvider: DeviceRequestProvider,
        database providedDatabase: SpacesClientDatabase?, bootstrap: LocalBootstrapProvider
    ) throws -> SpacesDeviceOverviewResolution {
        let startedAt = Date()
        let refreshed: SpacesPairedDeviceRecord
        do {
            let database = try providedDatabase ?? SpacesClientDatabase.defaultDatabase()
            refreshed = try bootstrapLocalDevice(database: database, clientApp: clientApp, profile: profile, bootstrap: bootstrap)
        } catch {
            // The daemon could not be started or would not answer its control socket, so there is no
            // current endpoint to retry against. `isLocalDaemonUnreachableError` classifies this for the
            // caller, which degrades to an offline local section.
            logLocalEndpointRecoveryMetric(device: device, refreshedPort: nil, startedAt: startedAt, success: false, stage: "bootstrap")
            throw error
        }
        do {
            let resolution = try resolutionFromInlineStatus(
                device: refreshed, clientApp: clientApp, profile: profile, requestProvider: requestProvider)
            logLocalEndpointRecoveryMetric(device: device, refreshedPort: refreshed.port, startedAt: startedAt, success: true, stage: "overview")
            return resolution
        } catch {
            logLocalEndpointRecoveryMetric(device: device, refreshedPort: refreshed.port, startedAt: startedAt, success: false, stage: "overview")
            return try resolutionFromHandshake(
                device: refreshed, clientApp: clientApp, profile: profile, requestProvider: requestProvider, overviewError: error)
        }
    }

    private static func logLocalEndpointRecoveryMetric(
        device: SpacesPairedDeviceRecord, refreshedPort: Int?, startedAt: Date, success: Bool, stage: String
    ) {
        TerminalPerformance.logMetric(
            "terminal_device_local_endpoint_recovery", target: "device=\(device.id)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: success, detail: "stage=\(stage) stale_port=\(device.port) live_port=\(refreshedPort.map(String.init) ?? "nil")")
    }

    /// One overview round-trip, resolved through the compatibility verdict the overview carries inline —
    /// so the compatible steady state needs no second round-trip.
    private static func resolutionFromInlineStatus(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile?, requestProvider: DeviceRequestProvider,
        database providedDatabase: SpacesClientDatabase? = nil
    ) throws -> SpacesDeviceOverviewResolution {
        let payload = try overview(device: device, clientApp: clientApp, profile: profile, requestProvider: requestProvider).overview
        let status = payload.daemonStatus
        // The pull path's once-per-refresh point, matching the subscription's once-per-delivery point.
        // The resolution carries the merged record, so the caller adopts the widened candidates instead
        // of holding the copy it read before this call.
        let resolved = mergeAdvertisedHosts(device: device, status: status, database: providedDatabase) ?? device
        let verdict = SpacesWireCompatibility.evaluate(daemonStatus: status)
        let overview = verdict.isCompatible ? SpacesDeviceOverview(device: resolved, overview: payload) : nil
        return SpacesDeviceOverviewResolution(overview: overview, daemonStatus: status, compatibility: verdict)
    }

    /// The overview did not decode (a wire-incompatible daemon's payload) or the device is unreachable.
    /// Ask the frozen core, which stays decodable across versions: an incompatible verdict means
    /// "blocked" (render the block, no overview); anything else rethrows `overviewError` as a genuine
    /// connection error to surface.
    private static func resolutionFromHandshake(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile?, requestProvider: DeviceRequestProvider,
        overviewError: any Error
    ) throws -> SpacesDeviceOverviewResolution {
        if let status = try? daemonStatus(device: device, clientApp: clientApp, profile: profile, requestProvider: requestProvider) {
            let verdict = SpacesWireCompatibility.evaluate(daemonStatus: status)
            if !verdict.isCompatible { return SpacesDeviceOverviewResolution(overview: nil, daemonStatus: status, compatibility: verdict) }
        }
        throw overviewError
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
            throw SpacesDeviceClientError.requestRejected(message: "The device did not return workspace create options.", code: nil)
        }
        return options
    }

    public static func previewProject(
        dir: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceProjectPreview {
        let response = try request(.init(command: .previewProject(.init(dir: dir))), device: device, clientApp: clientApp, profile: profile)
        guard let preview = response.projectPreview else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
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
        guard let preview = response.gitProjectPreview else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
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

    public static func updateProjectMetadata(
        projectID: String, isHidden: Bool, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .updateProjectMetadata(.init(projectID: projectID, isHidden: isHidden, updatesHidden: true))), device: device,
            clientApp: clientApp, profile: profile)
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

    /// Asks the owning daemon to stop an ad hoc terminal the user closed, which it does only when the
    /// terminal is idle at a bare shell prompt with no surviving owner attachment. The response's
    /// `terminatedTerminalSession` reports whether it did.
    public static func stopWorkspaceTerminalIfBareShell(
        workspaceID: String, sessionID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .stopWorkspaceTerminalIfBareShell(.init(workspaceID: workspaceID, sessionID: sessionID))), device: device,
            clientApp: clientApp, profile: profile)
    }

    public static func renameTerminalSession(
        workspaceID: String, sessionID: String, title: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .renameTerminalSession(.init(workspaceID: workspaceID, sessionID: sessionID, title: title))), device: device,
            clientApp: clientApp, profile: profile)
    }

    /// Renames a coding-agent row. An empty title clears the rename, restoring the name the agent reports
    /// for itself.
    public static func renameAgentSession(
        workspaceID: String, agentID: String, title: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .renameAgentSession(.init(workspaceID: workspaceID, agentID: agentID, title: title))), device: device,
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

    public static func stopCodingAgent(
        workspaceID: String, agentID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .stopCodingAgent(.init(workspaceID: workspaceID, agentID: agentID))), device: device, clientApp: clientApp,
            profile: profile)
    }

    /// Agent-facing one-shot terminal input on a paired device (`spaces terminal send text/bytes --device`).
    @discardableResult public static func sendTerminalInput(
        sessionID: String, text: String? = nil, bytes: Data? = nil, appendNewline: Bool = false, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .sendTerminalInput(.init(sessionID: sessionID, text: text, bytes: bytes, appendNewline: appendNewline))), device: device,
            clientApp: clientApp, profile: profile)
    }

    /// Rendered plain-text tail of a terminal session on a paired device (`spaces terminal tail --device`).
    public static func tailTerminalOutput(
        sessionID: String, lines: Int? = nil, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> String {
        let response = try request(
            .init(command: .tailTerminalOutput(.init(sessionID: sessionID, lines: lines))), device: device, clientApp: clientApp, profile: profile)
        guard let output = response.terminalOutput else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return output
    }

    /// Spawns a coding agent on a paired device (`spaces agent spawn --device`). Returns the created
    /// session id (via the mutation result) so the caller polls readiness with `listAgentSessions`; the
    /// daemon runs the same supported-agent hook gate as the local spawn before creating the session.
    @discardableResult public static func spawnAgentSession(
        workspaceID: String, command: String, title: String? = nil, automationRunID: String? = nil, device: SpacesPairedDeviceRecord,
        clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .spawnAgentSession(.init(workspaceID: workspaceID, command: command, title: title, automationRunID: automationRunID))),
            device: device, clientApp: clientApp, profile: profile)
    }

    /// Coding-agent sessions on a paired device (`spaces agent list/status --device`), also used for
    /// remote spawn-readiness polling. `workspaceID`/`sessionID` narrow the listing; both optional.
    public static func listAgentSessions(
        workspaceID: String? = nil, sessionID: String? = nil, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> [SpacesDeviceAgentSessionRow] {
        let response = try request(
            .init(command: .listAgentSessions(.init(workspaceID: workspaceID, sessionID: sessionID))), device: device, clientApp: clientApp,
            profile: profile)
        return response.agentSessions ?? []
    }

    /// Sets (or clears, with an empty note) a coding-agent session's note on a paired device
    /// (`spaces agent annotate --device`). Returns the updated row.
    @discardableResult public static func annotateAgentSession(
        sessionID: String, note: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> [SpacesDeviceAgentSessionRow] {
        let response = try request(
            .init(command: .annotateAgentSession(.init(sessionID: sessionID, note: note))), device: device, clientApp: clientApp, profile: profile)
        return response.agentSessions ?? []
    }

    /// Kills a coding-agent session on a paired device by its child terminal session id (`spaces agent
    /// kill --device`). The daemon routes through its `killAgentSession` flow, which handles both a
    /// hook-signaled child (its subscribers told it exited before the row is deleted) and a
    /// not-yet-signaled `.agent`-kind session (terminated), so the client makes one call for both cases.
    @discardableResult public static func killAgentSession(
        sessionID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .killAgentSession(.init(sessionID: sessionID))), device: device, clientApp: clientApp, profile: profile)
    }

    // MARK: - Automations

    /// Creates an automation on a paired device. The daemon validates the draft (non-empty fields, a
    /// parseable cron for a cron trigger) and returns the created automation as a one-element list.
    @discardableResult public static func createAutomation(
        _ fields: TerminalServiceAutomationFields, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> [TerminalServiceAutomationSummary] {
        try request(.init(command: .createAutomation(fields)), device: device, clientApp: clientApp, profile: profile).automations ?? []
    }

    /// Applies a full-field update (including enable/disable) to an automation on a paired device. Returns
    /// the updated automation as a one-element list.
    @discardableResult public static func updateAutomation(
        id: String, fields: TerminalServiceAutomationFields, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> [TerminalServiceAutomationSummary] {
        try request(.init(command: .updateAutomation(.init(id: id, fields: fields))), device: device, clientApp: clientApp, profile: profile)
            .automations ?? []
    }

    /// Deletes an automation on a paired device (cancelling any running run and cleaning up its artifacts).
    @discardableResult public static func deleteAutomation(
        id: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .deleteAutomation(.init(id: id))), device: device, clientApp: clientApp, profile: profile)
    }

    /// Lists the automations configured on a paired device.
    public static func listAutomations(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> [TerminalServiceAutomationSummary] {
        try request(.init(command: .listAutomations), device: device, clientApp: clientApp, profile: profile).automations ?? []
    }

    /// Lists automation runs on a paired device, newest first; `automationID` narrows to one automation.
    public static func listAutomationRuns(
        automationID: String? = nil, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> [TerminalServiceAutomationRunSummary] {
        try request(.init(command: .listAutomationRuns(.init(automationID: automationID))), device: device, clientApp: clientApp, profile: profile)
            .automationRuns ?? []
    }

    /// Manually triggers an automation on a paired device, returning the started run as a one-element list.
    @discardableResult public static func triggerAutomation(
        id: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> [TerminalServiceAutomationRunSummary] {
        try request(.init(command: .triggerAutomation(.init(id: id))), device: device, clientApp: clientApp, profile: profile).automationRuns ?? []
    }

    /// Cancels an automation run on a paired device, returning the canceled run as a one-element list.
    @discardableResult public static func cancelAutomationRun(
        runID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> [TerminalServiceAutomationRunSummary] {
        try request(.init(command: .cancelAutomationRun(.init(runID: runID))), device: device, clientApp: clientApp, profile: profile).automationRuns
            ?? []
    }

    /// Ends the still-live coding-agent sessions attributed to a terminal automation run on a paired device,
    /// returning the run (its status unchanged) as a one-element list. Used to reap an `agent`-kind run's
    /// session that was left open after the agent signalled done.
    @discardableResult public static func endAutomationAgents(
        runID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> [TerminalServiceAutomationRunSummary] {
        try request(.init(command: .endAutomationAgents(.init(runID: runID))), device: device, clientApp: clientApp, profile: profile).automationRuns
            ?? []
    }

    /// Terminal sessions on a paired device, read from the overview (`spaces terminal list --device`).
    public static func terminalSessions(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> [SpacesDeviceTerminalSessionSummary] { try overview(device: device, clientApp: clientApp, profile: profile).overview.sessions }

    /// Projects on a paired device, read from the overview (`spaces project list --device`). Reuses the
    /// overview the sidebar already loads rather than a dedicated listing command.
    public static func projects(device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil)
        throws -> [SpacesDeviceProjectSummary]
    { try overview(device: device, clientApp: clientApp, profile: profile).overview.projects }

    /// Workspaces on a paired device, read from the overview (`spaces workspace list --device`).
    public static func workspaces(
        device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil
    ) throws -> [SpacesDeviceWorkspaceSummary] { try overview(device: device, clientApp: clientApp, profile: profile).overview.workspaces }

    /// Reads a device's Device API credentials (pinned TLS certificate fingerprint and auth token),
    /// transparently re-bootstrapping the local device when its token is missing; the re-bootstrap also
    /// refreshes the local record's fingerprint, so a rotated daemon identity is picked up in the same
    /// recovery. The fingerprint is non-secret paired-device record data, not a stored secret. A remote
    /// device cannot regenerate its own identity, so a missing remote fingerprint surfaces as
    /// `missingCertificateFingerprint` (the client must re-pair); a remote token is returned as-is
    /// (possibly nil, the pre-existing behavior).
    public static func credentialsEnsuringLocalRecovery(device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, profile: SpacesProfile?)
        throws -> (certificateFingerprint: String, authToken: String?)
    {
        if device.id == SpacesPairedDeviceRecord.localDeviceID {
            var record = device
            if try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: profile) == nil,
                let refreshed = try ensureLocalDeviceCredentials(clientApp: clientApp, profile: profile)
            {
                record = refreshed
            }
            guard let fingerprint = normalizedFingerprint(record.certificateFingerprint) else {
                throw SpacesDeviceClientError.missingCertificateFingerprint(deviceName: device.name, isLocal: true)
            }
            return (fingerprint, try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: profile))
        }
        guard let fingerprint = normalizedFingerprint(device.certificateFingerprint) else {
            throw SpacesDeviceClientError.missingCertificateFingerprint(deviceName: device.name, isLocal: false)
        }
        return (fingerprint, try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: profile))
    }

    private static func normalizedFingerprint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func request(
        _ request: SpacesDeviceAPIRequest, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp = macOSClientApp(),
        profile: SpacesProfile? = nil
    ) throws -> SpacesDeviceAPIResponse {
        let (certificateFingerprint, authToken) = try credentialsEnsuringLocalRecovery(device: device, clientApp: clientApp, profile: profile)
        let client = try SpacesDeviceAPIRequestClient(
            resolver: SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: certificateFingerprint),
            timeoutSeconds: requestTimeoutSeconds(for: request.command))
        let response = try client.request(authenticated(request, authToken: authToken, clientApp: clientApp))
        guard response.ok else { throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode) }
        return response
    }

    private static func authenticated(_ request: SpacesDeviceAPIRequest, authToken: String?, clientApp: SpacesDeviceClientApp)
        -> SpacesDeviceAPIRequest
    { SpacesDeviceAPIRequest(command: request.command, authToken: authToken, clientApp: clientApp) }

    public static func defaultLocalBootstrapProvider(_ clientApp: SpacesDeviceClientApp, _ presentedToken: String?) throws
        -> SpacesDeviceAPIControlResponse
    { try SpacesDeviceAPIControlClient.bootstrapLocalClientEnsuringCurrentTerminalService(clientApp: clientApp, presentedToken: presentedToken) }

    /// The bootstrap used when a Device API request has already failed to reach this Mac's daemon, so the
    /// daemon may be down entirely and about to be started here. It waits out a just-started daemon whose
    /// Device API listener is not bound yet instead of reporting that as a failure — which the ordinary
    /// bootstrap does whenever the daemon hosts sessions, since its own recovery for it is a relaunch it
    /// must not aim at live sessions. Recovery is the only caller: a first bootstrap has no reason to
    /// spend time waiting on a listener, and reporting a not-running Device API promptly is what lets the
    /// sidebar degrade to offline quickly.
    public static func defaultLocalRecoveryBootstrapProvider(_ clientApp: SpacesDeviceClientApp, _ presentedToken: String?) throws
        -> SpacesDeviceAPIControlResponse
    { try SpacesDeviceAPIControlClient.bootstrapLocalClientAwaitingDeviceAPI(clientApp: clientApp, presentedToken: presentedToken) }

    /// True when a Device API failure is the transport failing to reach the daemon at all, rather than a
    /// reachable daemon's answer. Device-neutral: the pinned-TLS request path is identical for the local
    /// daemon and a paired remote, so callers that need to know "did this request even arrive" — the
    /// local-reachability degrade above, and a pane deciding whether a failed terminal send is evidence
    /// its link is gone — read the same classification.
    ///
    /// A coded rejection is deliberately excluded: the daemon answered, so it is reachable, and callers
    /// that need to recover a rejection branch on its code. So is a certificate pin mismatch, where the
    /// daemon is reachable but presents the wrong identity.
    public static func isDeviceAPITransportFailure(_ error: any Error) -> Bool {
        if let requestError = error as? SpacesDeviceAPIRequestClientError {
            switch requestError {
            case .timeout, .emptyResponse, .connectionFailed: return true
            case .invalidPort: return false
            // A coded rejection means the daemon answered — it is reachable — so this is not a
            // reachability failure. Callers that need to recover a rejection (e.g. re-authenticate on
            // `.unauthorized`) branch on the code itself; treating it as retryable here would wrongly
            // degrade a reachable daemon to the offline path.
            case .requestRejected: return false
            }
        }
        // Every candidate address the device knows was raced and none answered, so the device is
        // unreachable from here right now — retryable, exactly like the single-address timeout it
        // replaces. A pinned-identity failure on one of those candidates is reported as an
        // authentication error instead and never reaches this case.
        if case SpacesDeviceEndpointResolverError.allCandidatesUnreachable = error { return true }
        // The pinned-TLS transport's reachability failures (timeout/refused/closed). A certificate
        // pin mismatch is deliberately not retryable: the daemon is reachable but presents the wrong
        // identity, which must surface as a real error.
        if let pinnedTLSError = error as? SpacesPinnedTLSConnectionError {
            switch pinnedTLSError {
            case .timeout, .connectionFailed, .connectionClosed: return true
            case .invalidPort, .receiveLoopActive: return false
            }
        }
        #if canImport(Network)
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

    /// True when a Device API transport failure (`isDeviceAPITransportFailure(error)` must already be
    /// true) is a bare REQUEST TIMEOUT — the deadline elapsed with no answer — rather than a
    /// connection-level failure (refused, closed, or every candidate address unreachable).
    ///
    /// The two look identical to most callers ("the request did not get an answer"), but they are not
    /// the same evidence about the link. A connection-level failure means the transport itself gave up:
    /// the daemon refused the connection, an open one was closed under it, or every known address was
    /// raced and none answered — conclusive that the link is down right now. A timeout only means this
    /// one round trip did not complete inside its deadline, and on the hot per-keystroke path that
    /// deadline is tight enough (`DeviceTerminalSessionStateModel.interactiveControlRequestTimeoutSeconds`,
    /// 5s) that a live, merely congested link can miss it too: the send itself never touches the main
    /// actor (`TerminalInputSerialQueue.enqueue` hands off to a detached task that calls the pinned-TLS
    /// connection directly). Interactive sends and the `.state` resync fetch share one per-session
    /// request client (`SpacesDeviceAPIRequestSessionClient`), and `send` acquires that client's request
    /// lock before starting the per-operation deadline inside `sendOnceLocked` — so a keystroke queued
    /// behind a grid-sized resync fetch is not charged for the wait, it gets a fresh 5s window the moment
    /// its turn comes. What actually costs it that window: `SpacesPinnedTLSConnection.readLine(timeout:)`
    /// throws `.timeout` whenever the ANSWER itself is late, and under heavy streaming the daemon's own
    /// serial terminal-engine queue — effectively one core wide — is saturated, so a keystroke's response
    /// can genuinely run behind schedule with the link itself never having done anything wrong. A silent
    /// link death (a connect that never reaches ready, or a request nothing answers) produces the
    /// identical timeout, so a timeout alone does not prove the link is fine either — it is inconclusive
    /// in both directions. A caller that needs to tell those two apart (see
    /// `DeviceTerminalSessionStateModel.reportFailedInputSend`, which decides from it whether a failed
    /// keystroke send is grounds to tear the pane's state subscription down, raise the "connection lost"
    /// notice, and discard every other queued keystroke) calls this in addition to
    /// `isDeviceAPITransportFailure`. A `true` answer here is a verdict deferred, not a verdict reached:
    /// that caller resolves it by probing the daemon with a `.ping` — a request the daemon answers without
    /// touching its database or its terminal-engine queue, so it separates a saturated daemon from a dead
    /// link — and acts on the probe's outcome instead of on the timeout. That probe dials its own one-shot
    /// connection rather than sharing the session client above, whose lock the still-draining input backlog
    /// holds for a full deadline per queued send.
    ///
    /// Only the two shapes a timeout actually arrives as qualify: `SpacesDeviceAPIRequestClientError.timeout`
    /// and `SpacesPinnedTLSConnectionError.timeout` — the latter is what `sendLine`/`readLine` throw
    /// directly on the production request path, since neither `SpacesDeviceAPIRequestClient` nor
    /// `SpacesDeviceAPIRequestSessionClient` wraps it into the former. Every other transport failure
    /// (`.emptyResponse`, `.connectionFailed`, `.connectionClosed`, `allCandidatesUnreachable`, the raw
    /// POSIX/`NWError` codes) is connection-level and answers `false` here.
    public static func isDeviceAPIRequestTimeout(_ error: any Error) -> Bool {
        if case SpacesDeviceAPIRequestClientError.timeout = error { return true }
        if case SpacesPinnedTLSConnectionError.timeout = error { return true }
        return false
    }

    public static func requestTimeoutSeconds(for command: SpacesDeviceAPICommand) -> TimeInterval {
        switch command {
        case .createProject, .previewGitProject, .deleteProject, .importProject, .exportProject, .createWorkspace, .launchWorkspace, .stopWorkspace,
            .restartWorkspace, .archiveWorkspace, .runWorkspaceSetup, .openWorkspaceTerminal, .stopWorkspaceTerminal,
            .stopWorkspaceTerminalIfBareShell, .runWorkspaceProcess, .stopWorkspaceProcess, .restartWorkspaceProcess, .stopCodingAgent,
            .installAgentHooks, .spawnAgentSession, .killAgentSession, .createAutomation, .updateAutomation, .deleteAutomation, .triggerAutomation,
            .cancelAutomationRun, .endAutomationAgents:
            longRunningMutationTimeoutSeconds
        case .agentHooksStatus: agentHooksStatusRequestTimeoutSeconds
        case .terminalTranscript: terminalTranscriptRequestTimeoutSeconds
        case .pair, .ping, .daemonStatus, .requestDaemonRestart, .overview, .previewProject, .listDirectories, .workspaceCreateOptions,
            .updateProjectConfig, .updateProjectMetadata, .updateWorkspaceConfig, .updateWorkspaceMetadata, .renameTerminalSession,
            .renameAgentSession, .state, .terminalControl, .terminalPasteImage, .sendTerminalInput, .tailTerminalOutput, .resolveTerminalLink,
            .readTerminalLinkChunk, .subscribe, .subscribeDeviceOverview, .openServiceTunnel, .listAgentSessions, .annotateAgentSession,
            .listAutomations, .listAutomationRuns:
            defaultRequestTimeoutSeconds
        }
    }
}

/// The paired-device record a long-lived overview subscription publishes with, held across the
/// stream's deliveries. Needed because the subscription's callback is `@Sendable` and outlives the
/// call that built it, while the record it publishes has to move forward as the daemon teaches this
/// client new addresses.
private final class PairedDeviceRecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: SpacesPairedDeviceRecord

    init(_ value: SpacesPairedDeviceRecord) { storage = value }

    var value: SpacesPairedDeviceRecord {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

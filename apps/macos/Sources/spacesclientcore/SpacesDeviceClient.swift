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
    typealias DeviceRequestProvider = @Sendable (SpacesDeviceAPIRequest, DeviceRequestContext) throws -> SpacesDeviceAPIResponse
    static let defaultRequestTimeoutSeconds: TimeInterval = 10
    static let agentHooksStatusRequestTimeoutSeconds: TimeInterval = 20
    static let longRunningMutationTimeoutSeconds: TimeInterval = 60
    /// A response carrying a large embedded payload — a transcript up to the full scrollback budget
    /// (10MB, ~13MB as base64 JSON), a workspace file read/write (`workspaceFileMaxBytes`, also base64),
    /// or one bounded workspace-diff patch range — needs more than the default timeout on slow remote links.
    static let largePayloadRequestTimeoutSeconds: TimeInterval = 60

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
            // Present the token we already hold so the daemon keeps it instead of rotating it: launch
            // and genuine recovery bootstraps can overlap live Device API connections, and a rotated
            // token would invalidate the credentials those connections already hold.
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
            // Skip the credential write when the daemon kept the token we presented. `saveToken` is an
            // atomic file replace (temp write, rename, chmod), so rewriting identical credentials during
            // launch or recovery would dirty a page for no state change. Guarded on the device id too,
            // because the value comparison is only meaningful when the token would be written back to the
            // same file it was read from.
            let tokenIsUnchanged = bootstrap.deviceID == SpacesPairedDeviceRecord.localDeviceID && bootstrap.authToken == presentedToken
            if !tokenIsUnchanged { try SpacesDeviceCredentialStore.saveToken(bootstrap.authToken, deviceID: record.id, profile: profile) }
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

    /// Resolves This Mac for a routine sidebar refresh without re-establishing identity on every load.
    /// The paired-device row and token written by launch are the steady-state source; only a genuine
    /// credential miss takes the bootstrap recovery path. A present token with no paired-device row is
    /// inconsistent local state rather than permission to invent another recovery route, so it fails
    /// loudly and lets the caller surface the load failure.
    public static func localDeviceForSidebarRefresh(
        database providedDatabase: SpacesClientDatabase? = nil, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
        bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalBootstrapProvider
    ) throws -> SpacesPairedDeviceRecord {
        let database = try providedDatabase ?? SpacesClientDatabase.defaultDatabase()
        if let recovered = try ensureLocalDeviceCredentials(database: database, clientApp: clientApp, profile: profile, bootstrap: bootstrap) {
            return recovered
        }
        guard let stored = try database.pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID) else {
            throw SpacesDeviceClientError.missingLocalBootstrap
        }
        return stored
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
            requestProvider: { request, context in try SpacesDeviceClient.request(request, context: context) })
    }

    static func localOverview(
        database providedDatabase: SpacesClientDatabase? = nil, clientApp: SpacesDeviceClientApp = macOSClientApp(), profile: SpacesProfile? = nil,
        bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalBootstrapProvider, requestProvider: DeviceRequestProvider
    ) throws -> SpacesDeviceOverview {
        let database = try providedDatabase ?? SpacesClientDatabase.defaultDatabase()
        let device = try bootstrapLocalDevice(database: database, clientApp: clientApp, profile: profile, bootstrap: bootstrap)
        let context = DeviceRequestContext(device: device, clientApp: clientApp, profile: profile)
        do { return try overview(context: context, requestProvider: requestProvider) } catch {
            guard isDeviceAPITransportFailure(error) else { throw error }
            let refreshedDevice = try bootstrapLocalDevice(database: database, clientApp: clientApp, profile: profile, bootstrap: bootstrap)
            let refreshedContext = DeviceRequestContext(device: refreshedDevice, clientApp: clientApp, profile: profile)
            return try overview(context: refreshedContext, requestProvider: requestProvider)
        }
    }

    /// Fetches the overview for a specific paired device, independent of which device is currently active.
    /// Used to populate the multi-device sidebar where every paired device is shown at once.
    public static func overview(context: DeviceRequestContext) throws -> SpacesDeviceOverview {
        try overview(context: context, requestProvider: { request, context in try SpacesDeviceClient.request(request, context: context) })
    }

    private static func overview(context: DeviceRequestContext, requestProvider: DeviceRequestProvider) throws -> SpacesDeviceOverview {
        let response = try requestProvider(.init(command: .overview), context)
        guard let overview = response.overview else { throw SpacesDeviceClientError.missingOverview }
        return SpacesDeviceOverview(device: context.device, overview: overview)
    }

    /// Opens a live device-overview subscription: the paired daemon pushes a
    /// fresh overview whenever its database changes, so the client stays current
    /// without polling. The returned client must be retained and `stop()`ped.
    public static func subscribeOverview(
        context: DeviceRequestContext, onOverview: @escaping @Sendable (SpacesDeviceOverview) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws -> SpacesDeviceAPIOverviewStreamClient {
        let (certificateFingerprint, authToken) = try credentialsEnsuringLocalRecovery(context: context)
        // The record this subscription publishes with, carried across deliveries. A stream outlives many
        // overviews, and only the delivery that actually widens the candidates gets a merged record back;
        // without carrying it, every later delivery would republish the record captured at subscribe time
        // and walk the learned address back out of the caller's state.
        let publishedRecord = PairedDeviceRecordBox(context.device)
        let client = try SpacesDeviceAPIOverviewStreamClient(
            authToken: authToken, clientApp: context.clientApp,
            resolver: SpacesDeviceEndpointRegistry.resolver(for: context.device, certificateFingerprint: certificateFingerprint),
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
    ///
    /// Takes a bare `device:` rather than a `DeviceRequestContext`: this merge has nothing to do with
    /// which client app or profile is asking, only with the device record being widened, so it is not
    /// part of the request-identity tail the context bundles.
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
    public static func daemonStatus(context: DeviceRequestContext) throws -> TerminalServiceDaemonStatus {
        try daemonStatus(context: context, requestProvider: { request, context in try SpacesDeviceClient.request(request, context: context) })
    }

    private static func daemonStatus(context: DeviceRequestContext, requestProvider: DeviceRequestProvider) throws -> TerminalServiceDaemonStatus {
        let response = try requestProvider(.init(command: .daemonStatus), context)
        guard let status = response.daemonStatus else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return status
    }

    /// Reports availability + Spaces hook-install status for supported coding agents on `context`'s device
    /// (local or remote). Read-only.
    public static func agentHooksStatus(context: DeviceRequestContext) throws -> [AgentHookStatus] {
        let response = try request(.init(command: .agentHooksStatus), context: context)
        guard let payload = response.agentHooksStatus else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return payload.agents
    }

    /// Idempotently installs Spaces lifecycle hooks for `kinds` on `context`'s device (local or remote).
    /// Returns fresh status for every supported agent plus one failure entry per requested agent that could
    /// not be installed — an install lands partially, so a non-empty `failures` does not mean nothing
    /// happened. Throws only when the request itself fails.
    @discardableResult public static func installAgentHooks(_ kinds: [CodingAgent], context: DeviceRequestContext) throws -> AgentHookInstallOutcome {
        let response = try request(.init(command: .installAgentHooks(.init(kinds: kinds))), context: context)
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
    /// stored local port is not durable. A pinned-identity failure or unauthorized response similarly
    /// refreshes the stored certificate or token and retries once. This is the per-refresh hot path; see
    /// `docs/implementation.md` (device compatibility handshake).
    public static func resolveOverview(context: DeviceRequestContext) throws -> SpacesDeviceOverviewResolution {
        try resolveOverview(context: context, requestProvider: { request, context in try SpacesDeviceClient.request(request, context: context) })
    }

    static func resolveOverview(
        context: DeviceRequestContext, requestProvider: DeviceRequestProvider, database providedDatabase: SpacesClientDatabase? = nil,
        bootstrap: LocalBootstrapProvider = SpacesDeviceClient.defaultLocalRecoveryBootstrapProvider
    ) throws -> SpacesDeviceOverviewResolution {
        do {
            return try resolutionFromInlineStatus(context: context, requestProvider: requestProvider, database: providedDatabase)
        } catch {
            // The local daemon's Device API endpoint is not durable: it can idle-shut-down, be restarted,
            // or be relaunched on a freshly assigned port, so the port in the caller's `paired_devices`
            // record goes stale without anything invalidating it. A transport failure against the local
            // device is therefore first read as "this Mac's endpoint needs re-resolving", not "the device
            // is gone". Only the local device needs that step: a remote device's candidate addresses are
            // already re-walked inside the connect itself (`SpacesDeviceEndpointResolver`), so a transport
            // failure there means every address it knows was tried and none answered.
            guard context.device.id == SpacesPairedDeviceRecord.localDeviceID else {
                return try resolutionFromHandshake(context: context, requestProvider: requestProvider, overviewError: error)
            }
            if isDeviceAPITransportFailure(error) {
                return try recoveredLocalResolution(
                    context: context, requestProvider: requestProvider, database: providedDatabase, bootstrap: bootstrap,
                    metricName: "terminal_device_local_endpoint_recovery")
            }
            // The daemon can retain its port while rotating its TLS identity. A local bootstrap is the
            // trusted authority for that identity, so refresh the stored fingerprint and retry once.
            // This remains local-only: a remote device with the same failure must be re-paired.
            if SpacesDeviceAPIAuthentication.isTransportAuthenticationFailure(error) {
                return try recoveredLocalResolution(
                    context: context, requestProvider: requestProvider, database: providedDatabase, bootstrap: bootstrap,
                    metricName: "terminal_device_local_identity_recovery")
            }
            // Routine sidebar refreshes trust the stored token so their steady state has no bootstrap
            // round-trip. If the daemon reset its pairing state while remaining reachable, the overview
            // is the first place that stale token can be detected; recover it once and retry rather than
            // turning the optimization into a permanent authorization failure.
            if case SpacesDeviceClientError.requestRejected(_, .unauthorized) = error {
                return try recoveredLocalResolution(
                    context: context, requestProvider: requestProvider, database: providedDatabase, bootstrap: bootstrap,
                    metricName: "terminal_device_local_authorization_recovery")
            }
            return try resolutionFromHandshake(context: context, requestProvider: requestProvider, overviewError: error)
        }
    }

    /// The local device's bounded identity recovery: re-bootstrap This Mac and resolve once more against
    /// the returned record. Two steps, each taken at most once — a bootstrap that refreshes the endpoint
    /// and credentials, then a single overview retry. There is no loop here: a recovery that does not
    /// succeed reports the failure rather than trying again.
    ///
    /// Both outcomes use the recovery-kind-specific metric supplied by the caller, because a recovery
    /// that silently fails to produce an overview is otherwise indistinguishable in the app log from a
    /// session that was never resolvable.
    private static func recoveredLocalResolution(
        context: DeviceRequestContext, requestProvider: DeviceRequestProvider, database providedDatabase: SpacesClientDatabase?,
        bootstrap: LocalBootstrapProvider, metricName: String
    ) throws -> SpacesDeviceOverviewResolution {
        let startedAt = Date()
        let refreshed: SpacesPairedDeviceRecord
        do {
            let database = try providedDatabase ?? SpacesClientDatabase.defaultDatabase()
            refreshed = try bootstrapLocalDevice(database: database, clientApp: context.clientApp, profile: context.profile, bootstrap: bootstrap)
        } catch {
            // The daemon could not be started or would not answer its control socket, so there is no
            // current endpoint to retry against. `isLocalDaemonUnreachableError` classifies this for the
            // caller, which degrades to an offline local section.
            logLocalRecoveryMetric(
                metricName: metricName, device: context.device, refreshedPort: nil, startedAt: startedAt, success: false, stage: "bootstrap")
            throw error
        }
        let refreshedContext = DeviceRequestContext(device: refreshed, clientApp: context.clientApp, profile: context.profile)
        do {
            let resolution = try resolutionFromInlineStatus(context: refreshedContext, requestProvider: requestProvider)
            logLocalRecoveryMetric(
                metricName: metricName, device: context.device, refreshedPort: refreshed.port, startedAt: startedAt, success: true, stage: "overview")
            return resolution
        } catch {
            logLocalRecoveryMetric(
                metricName: metricName, device: context.device, refreshedPort: refreshed.port, startedAt: startedAt, success: false, stage: "overview")
            return try resolutionFromHandshake(context: refreshedContext, requestProvider: requestProvider, overviewError: error)
        }
    }

    private static func logLocalRecoveryMetric(
        metricName: String, device: SpacesPairedDeviceRecord, refreshedPort: Int?, startedAt: Date, success: Bool, stage: String
    ) {
        TerminalPerformance.logMetric(
            metricName, target: "device=\(device.id)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: success,
            detail: "stage=\(stage) stale_port=\(device.port) live_port=\(refreshedPort.map(String.init) ?? "nil")")
    }

    /// One overview round-trip, resolved through the compatibility verdict the overview carries inline —
    /// so the compatible steady state needs no second round-trip.
    private static func resolutionFromInlineStatus(
        context: DeviceRequestContext, requestProvider: DeviceRequestProvider, database providedDatabase: SpacesClientDatabase? = nil
    ) throws -> SpacesDeviceOverviewResolution {
        let payload = try overview(context: context, requestProvider: requestProvider).overview
        let status = payload.daemonStatus
        // The pull path's once-per-refresh point, matching the subscription's once-per-delivery point.
        // The resolution carries the merged record, so the caller adopts the widened candidates instead
        // of holding the copy it read before this call.
        let resolved = mergeAdvertisedHosts(device: context.device, status: status, database: providedDatabase) ?? context.device
        let verdict = SpacesWireCompatibility.evaluate(daemonStatus: status)
        let overview = verdict.isCompatible ? SpacesDeviceOverview(device: resolved, overview: payload) : nil
        return SpacesDeviceOverviewResolution(overview: overview, daemonStatus: status, compatibility: verdict)
    }

    /// The overview did not decode (a wire-incompatible daemon's payload) or the device is unreachable.
    /// Ask the frozen core, which stays decodable across versions: an incompatible verdict means
    /// "blocked" (render the block, no overview); anything else rethrows `overviewError` as a genuine
    /// connection error to surface.
    private static func resolutionFromHandshake(
        context: DeviceRequestContext, requestProvider: DeviceRequestProvider, overviewError: any Error
    ) throws -> SpacesDeviceOverviewResolution {
        if let status = try? daemonStatus(context: context, requestProvider: requestProvider) {
            let verdict = SpacesWireCompatibility.evaluate(daemonStatus: status)
            if !verdict.isCompatible { return SpacesDeviceOverviewResolution(overview: nil, daemonStatus: status, compatibility: verdict) }
        }
        throw overviewError
    }

    /// Frozen-core restart request: asks the daemon to restart itself. The OS service manager
    /// (launchd `KeepAlive` / systemd `Restart=always`) respawns it from the updated binary.
    @discardableResult public static func requestDaemonRestart(context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .requestDaemonRestart), context: context)
    }

    public static func workspaceCreateOptions(selectedProjectID: String?, context: DeviceRequestContext) throws -> SpacesDeviceWorkspaceCreateOptions
    {
        let response = try request(.init(command: .workspaceCreateOptions(.init(projectID: selectedProjectID))), context: context)
        guard let options = response.workspaceCreateOptions else {
            throw SpacesDeviceClientError.requestRejected(message: "The device did not return workspace create options.", code: nil)
        }
        return options
    }

    public static func previewProject(dir: String, context: DeviceRequestContext) throws -> SpacesDeviceProjectPreview {
        let response = try request(.init(command: .previewProject(.init(dir: dir))), context: context)
        guard let preview = response.projectPreview else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return preview
    }

    public static func listDirectories(path: String, context: DeviceRequestContext) throws -> [String] {
        let response = try request(.init(command: .listDirectories(.init(path: path))), context: context)
        return response.directorySuggestions?.paths ?? []
    }

    public static func createProject(projectDir: String?, gitURL: String?, config: SpacesDeviceProjectConfig? = nil, context: DeviceRequestContext)
        throws -> SpacesDeviceAPIResponse
    { try request(.init(command: .createProject(.init(projectDir: projectDir, gitURL: gitURL, config: config))), context: context) }

    /// Loads a git repository's `spaces.yaml` (single file, no clone) to populate the add-project form,
    /// along with any managed directories a later Create would replace. The full clone happens at Create.
    public static func previewGitProject(gitURL: String, context: DeviceRequestContext) throws -> SpacesDeviceGitProjectPreview {
        let response = try request(.init(command: .previewGitProject(.init(gitURL: gitURL))), context: context)
        guard let preview = response.gitProjectPreview else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return preview
    }

    public static func deleteProject(projectID: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .deleteProject(.init(projectID: projectID))), context: context)
    }

    public static func importProjectSpacesYAML(projectID: String, updateAllWorkspaces: Bool = false, context: DeviceRequestContext) throws
        -> SpacesDeviceAPIResponse
    { try request(.init(command: .importProject(.init(projectID: projectID, updateAllWorkspaces: updateAllWorkspaces))), context: context) }

    public static func exportProjectSpacesYAML(projectID: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .exportProject(.init(projectID: projectID))), context: context)
    }

    public static func createWorkspace(
        projectID: String, branch: String?, baseBranch: String?, directoryName: String? = nil, notes: String? = nil,
        allowExistingBranchReuse: Bool = false, context: DeviceRequestContext
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .createWorkspace(
                    .init(
                        projectID: projectID, branch: branch, baseBranch: baseBranch, directoryName: directoryName, notes: notes,
                        allowExistingBranchReuse: allowExistingBranchReuse))), context: context)
    }

    public static func launchWorkspace(workspaceID: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .launchWorkspace(.init(workspaceID: workspaceID))), context: context)
    }

    public static func stopWorkspace(workspaceID: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .stopWorkspace(.init(workspaceID: workspaceID))), context: context)
    }

    public static func restartWorkspace(workspaceID: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .restartWorkspace(.init(workspaceID: workspaceID))), context: context)
    }

    public static func archiveWorkspace(
        workspaceID: String, deleteLocalBranch: Bool = false, deleteRemoteBranch: Bool = false, context: DeviceRequestContext
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .archiveWorkspace(.init(workspaceID: workspaceID, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch))
            ), context: context)
    }

    public static func runWorkspaceSetup(workspaceID: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .runWorkspaceSetup(.init(workspaceID: workspaceID))), context: context)
    }

    public static func updateProjectConfig(
        projectID: String, config: SpacesDeviceProjectConfig, updateAllWorkspaces: Bool = false, context: DeviceRequestContext
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .updateProjectConfig(.init(projectID: projectID, config: config, updateAllWorkspaces: updateAllWorkspaces))),
            context: context)
    }

    public static func updateProjectMetadata(projectID: String, isHidden: Bool, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .updateProjectMetadata(.init(projectID: projectID, isHidden: isHidden, updatesHidden: true))), context: context)
    }

    public static func updateWorkspaceConfig(workspaceID: String, config: SpacesDeviceWorkspaceConfig, context: DeviceRequestContext) throws
        -> SpacesDeviceAPIResponse
    { try request(.init(command: .updateWorkspaceConfig(.init(workspaceID: workspaceID, config: config))), context: context) }

    public static func updateWorkspaceMetadata(
        workspaceID: String, branch: String? = nil, notes: String? = nil, updatesBranch: Bool = false, updatesNotes: Bool = false,
        isHidden: Bool? = nil, updatesHidden: Bool = false, context: DeviceRequestContext
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .updateWorkspaceMetadata(
                    .init(
                        workspaceID: workspaceID, branch: branch, notes: notes, updatesBranch: updatesBranch, updatesNotes: updatesNotes,
                        isHidden: isHidden, updatesHidden: updatesHidden))), context: context)
    }

    /// Reads one file inside a workspace's checkout on a paired device (capped at 10 MiB on the daemon
    /// side; see `SpacesDeviceAPIServer.workspaceFileMaxBytes`).
    public static func workspaceFileRead(
        workspaceID: String, relativePath: String, comparisonBaseRevision: String? = nil, oldPath: String? = nil, requiresDirectPath: Bool = false,
        context: DeviceRequestContext
    ) throws -> SpacesDeviceWorkspaceFileReadResult {
        let response = try request(
            .init(
                command: .workspaceFileRead(
                    .init(
                        workspaceID: workspaceID, relativePath: relativePath, comparisonBaseRevision: comparisonBaseRevision, oldPath: oldPath,
                        requiresDirectPath: requiresDirectPath))), context: context)
        guard let result = response.workspaceFileRead else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return result
    }

    /// Verifies one immutable Last Commit target against its checkout and returns its first-parent
    /// comparison side after Git's configured checkout filters.
    public static func workspaceRevisionFileRead(
        workspaceID: String, revision: String, relativePath: String, oldPath: String? = nil, context: DeviceRequestContext
    ) throws -> SpacesDeviceWorkspaceRevisionFileReadResult {
        let response = try request(
            .init(command: .workspaceRevisionFileRead(.init(workspaceID: workspaceID, revision: revision, relativePath: relativePath, oldPath: oldPath))),
            context: context)
        guard let result = response.workspaceRevisionFileRead else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return result
    }

    /// Compare-and-swap write to one file inside a workspace's checkout on a paired device. `expectedSHA256`
    /// should be the hash last read via `workspaceFileRead`, or `nil` to assert the file must not exist yet.
    /// A mismatch is not thrown as an error: `didWrite` is `false` and the result carries the disk content
    /// the caller can merge against.
    public static func workspaceFileWrite(
        workspaceID: String, relativePath: String, base64Data: String, expectedSHA256: String? = nil, requiresDirectPath: Bool = false,
        context: DeviceRequestContext
    ) throws -> SpacesDeviceWorkspaceFileWriteResult {
        let response = try request(
            .init(
                command: .workspaceFileWrite(
                    .init(
                        workspaceID: workspaceID, relativePath: relativePath, base64Data: base64Data, expectedSHA256: expectedSHA256,
                        requiresDirectPath: requiresDirectPath))), context: context)
        guard let result = response.workspaceFileWrite else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return result
    }

    /// Reads one bounded changed-file metadata chunk before the Editor begins fetching patch bodies.
    public static func workspaceDiffManifestChunk(
        workspaceID: String, refName: String? = nil, lastCommit: Bool = false, manifestID: String? = nil, fileIndex: Int,
        context: DeviceRequestContext
    ) throws -> SpacesDeviceWorkspaceDiffManifestChunkResult {
        let response = try request(
            .init(
                command: .workspaceDiffManifestChunk(
                    .init(workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, fileIndex: fileIndex))),
            context: context)
        guard let result = response.workspaceDiffManifestChunk else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return result
    }

    /// Reads one bounded patch range from a daemon-owned transfer. Pass `transferID` returned by the initial
    /// range unchanged for every later offset.
    public static func workspaceDiffFileChunk(
        workspaceID: String, refName: String? = nil, lastCommit: Bool = false, manifestID: String, relativePath: String, byteOffset: Int,
        transferID: String? = nil, context: DeviceRequestContext
    ) throws -> SpacesDeviceWorkspaceDiffFileChunkResult {
        let response = try request(
            .init(
                command: .workspaceDiffFileChunk(
                    .init(
                        workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, relativePath: relativePath,
                        byteOffset: byteOffset, transferID: transferID))), context: context)
        guard let result = response.workspaceDiffFileChunk else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return result
    }

    /// Releases an incomplete diff patch transfer. It is separate from `workspaceDiffFileChunk`'s typed
    /// read result because cancellation succeeds without a patch payload and is safe to repeat after an
    /// ambiguous connection failure.
    public static func cancelWorkspaceDiffFileChunk(
        workspaceID: String, refName: String? = nil, lastCommit: Bool = false, manifestID: String, relativePath: String, byteOffset: Int,
        transferID: String, context: DeviceRequestContext
    ) throws {
        let response = try request(
            .init(
                command: .workspaceDiffFileChunk(
                    .init(
                        workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, relativePath: relativePath,
                        byteOffset: byteOffset, transferID: transferID, cancel: true))), context: context)
        guard response.ok else { throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode) }
    }

    /// Releases a manifest plan and every patch transfer it owns. Call this when a progressive
    /// Editor generation is superseded or has consumed all of the patches it needs; daemon TTL reaps an
    /// abandoned generation.
    public static func cancelWorkspaceDiffManifest(
        workspaceID: String, refName: String? = nil, lastCommit: Bool = false, manifestID: String, context: DeviceRequestContext
    ) throws {
        let response = try request(
            .init(command: .workspaceDiffManifestRelease(.init(workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID))),
            context: context)
        guard response.ok else { throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode) }
    }

    /// Lists every path in a workspace's checkout on a paired device, for the Editor pane's file tree and
    /// quick-open (see `SpacesDeviceWorkspaceFileListRequest`).
    public static func workspaceFileList(workspaceID: String, context: DeviceRequestContext) throws -> SpacesDeviceWorkspaceFileListResult {
        let response = try request(.init(command: .workspaceFileList(.init(workspaceID: workspaceID))), context: context)
        guard let result = response.workspaceFileList else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return result
    }

    /// Lists the branches and recent commits the Compare dialog's ref search offers, on a paired device
    /// (see `SpacesDeviceWorkspaceRefListRequest`).
    public static func workspaceRefList(workspaceID: String, context: DeviceRequestContext) throws -> SpacesDeviceWorkspaceRefListResult {
        let response = try request(.init(command: .workspaceRefList(.init(workspaceID: workspaceID))), context: context)
        guard let result = response.workspaceRefList else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return result
    }

    /// Draft review comments for a workspace's code pane, on a paired device. Sent-and-archived comments
    /// are never included — v1 has no archive-browsing UI (see docs/spec.md).
    public static func workspaceReviewCommentList(workspaceID: String, context: DeviceRequestContext) throws -> [SpacesDeviceReviewComment] {
        let response = try request(.init(command: .workspaceReviewCommentList(.init(workspaceID: workspaceID))), context: context)
        guard let result = response.workspaceReviewCommentList else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return result.comments
    }

    /// Creates a review-comment draft when `id` is nil, or updates an existing one's body/anchor when it
    /// names one this workspace owns and has not yet sent (see `SpacesDeviceWorkspaceReviewCommentUpsertRequest`).
    public static func workspaceReviewCommentUpsert(
        workspaceID: String, id: String? = nil, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String,
        body: String, context: DeviceRequestContext
    ) throws -> SpacesDeviceReviewComment {
        let response = try request(
            .init(
                command: .workspaceReviewCommentUpsert(
                    .init(workspaceID: workspaceID, id: id, filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText, body: body))),
            context: context)
        guard let result = response.workspaceReviewCommentUpsert else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return result.comment
    }

    /// Deletes one review-comment draft on a paired device.
    @discardableResult public static func workspaceReviewCommentDelete(workspaceID: String, id: String, context: DeviceRequestContext) throws
        -> SpacesDeviceAPIResponse
    { try request(.init(command: .workspaceReviewCommentDelete(.init(workspaceID: workspaceID, id: id))), context: context) }

    /// Writes `text` to `sessionID`'s terminal input, then archives every comment in `comments` (id plus
    /// the caller's last-seen `revision`, for the daemon's stale-version check), on a paired device — see
    /// `SpacesDeviceWorkspaceReviewCommentsSendRequest` for why this is one call rather than a client-side
    /// send-then-archive, and the ordering guarantee it does (and does not) give. A write failure or a
    /// version mismatch leaves every named comment as an untouched draft.
    @discardableResult public static func workspaceReviewCommentsSend(
        workspaceID: String, sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry], context: DeviceRequestContext
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .workspaceReviewCommentsSend(.init(workspaceID: workspaceID, sessionID: sessionID, text: text, comments: comments))),
            context: context)
    }

    /// Opens a live per-(workspace, ref, lastCommit)-scope diff-signature subscription: the paired daemon
    /// pushes a frame whenever the scope's `scopeSignature` changes (notify-then-pull; the daemon polls, see
    /// `SpacesDeviceAPIServer` for why), and the caller re-fetches `workspaceDiffManifestChunk` (with the same `refName`
    /// and `lastCommit`) on delivery rather than trust any payload carried on the frame. `refName` and
    /// `lastCommit` select the same scope the manifest would; pass the same values to both so their
    /// subscription and results agree. The returned client must be retained and `stop()`ped.
    public static func subscribeWorkspaceDiffSignature(
        workspaceID: String, refName: String? = nil, lastCommit: Bool = false, context: DeviceRequestContext,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws -> SpacesDeviceWorkspaceDiffSignatureStreamClient {
        let (certificateFingerprint, authToken) = try credentialsEnsuringLocalRecovery(context: context)
        let client = try SpacesDeviceWorkspaceDiffSignatureStreamClient(
            workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, authToken: authToken, clientApp: context.clientApp,
            resolver: SpacesDeviceEndpointRegistry.resolver(for: context.device, certificateFingerprint: certificateFingerprint), onFrame: onFrame,
            onDisconnect: onDisconnect)
        try client.start()
        return client
    }

    /// Opens a live per-(workspace, path)-scope file-signature subscription: the paired daemon pushes a
    /// frame whenever the file's `sha256`/`missing` state changes (notify-then-pull, mirroring
    /// `subscribeWorkspaceDiffSignature` exactly), and the caller re-fetches `workspaceFileRead` (with the
    /// same `relativePath`) on delivery rather than trust any content carried on the frame. The returned
    /// client must be retained and `stop()`ped.
    public static func subscribeWorkspaceFileSignature(
        workspaceID: String, relativePath: String, context: DeviceRequestContext,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws -> SpacesDeviceWorkspaceFileSignatureStreamClient {
        let (certificateFingerprint, authToken) = try credentialsEnsuringLocalRecovery(context: context)
        let client = try SpacesDeviceWorkspaceFileSignatureStreamClient(
            workspaceID: workspaceID, path: relativePath, authToken: authToken, clientApp: context.clientApp,
            resolver: SpacesDeviceEndpointRegistry.resolver(for: context.device, certificateFingerprint: certificateFingerprint), onFrame: onFrame,
            onDisconnect: onDisconnect)
        try client.start()
        return client
    }

    /// Opens a live per-workspace file-list-signature subscription: the paired daemon pushes a frame
    /// whenever the authoritative `workspaceFileList` result changes, and the caller re-fetches
    /// `workspaceFileList` on delivery rather than trusting any listing payload on the frame.
    public static func subscribeWorkspaceFileListSignature(
        workspaceID: String, context: DeviceRequestContext,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileListSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws -> SpacesDeviceWorkspaceFileListSignatureStreamClient {
        let (certificateFingerprint, authToken) = try credentialsEnsuringLocalRecovery(context: context)
        let client = try SpacesDeviceWorkspaceFileListSignatureStreamClient(
            workspaceID: workspaceID, authToken: authToken, clientApp: context.clientApp,
            resolver: SpacesDeviceEndpointRegistry.resolver(for: context.device, certificateFingerprint: certificateFingerprint), onFrame: onFrame,
            onDisconnect: onDisconnect)
        try client.start()
        return client
    }

    public static func openWorkspaceTerminal(workspaceID: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .openWorkspaceTerminal(.init(workspaceID: workspaceID))), context: context)
    }

    public static func stopWorkspaceTerminal(workspaceID: String, sessionID: String, context: DeviceRequestContext) throws
        -> SpacesDeviceAPIResponse
    { try request(.init(command: .stopWorkspaceTerminal(.init(workspaceID: workspaceID, sessionID: sessionID))), context: context) }

    /// Asks the owning daemon to stop an ad hoc terminal the user closed, which it does only when the
    /// terminal is idle at a bare shell prompt with no surviving owner attachment. The response's
    /// `terminatedTerminalSession` reports whether it did.
    public static func stopWorkspaceTerminalIfBareShell(workspaceID: String, sessionID: String, context: DeviceRequestContext) throws
        -> SpacesDeviceAPIResponse
    { try request(.init(command: .stopWorkspaceTerminalIfBareShell(.init(workspaceID: workspaceID, sessionID: sessionID))), context: context) }

    public static func renameTerminalSession(workspaceID: String, sessionID: String, title: String, context: DeviceRequestContext) throws
        -> SpacesDeviceAPIResponse
    { try request(.init(command: .renameTerminalSession(.init(workspaceID: workspaceID, sessionID: sessionID, title: title))), context: context) }

    /// Renames a coding-agent row. An empty title clears the rename, restoring the name the agent reports
    /// for itself.
    public static func renameAgentSession(workspaceID: String, agentID: String, title: String, context: DeviceRequestContext) throws
        -> SpacesDeviceAPIResponse
    { try request(.init(command: .renameAgentSession(.init(workspaceID: workspaceID, agentID: agentID, title: title))), context: context) }

    public static func runWorkspaceProcess(workspaceID: String, processKey: String, processTemplateID: String?, context: DeviceRequestContext)
        throws -> SpacesDeviceAPIResponse
    {
        try request(
            .init(command: .runWorkspaceProcess(.init(workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID))),
            context: context)
    }

    public static func stopWorkspaceProcess(
        workspaceID: String, processID: String?, processKey: String?, processTemplateID: String?, context: DeviceRequestContext
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .stopWorkspaceProcess(
                    .init(workspaceID: workspaceID, processID: processID, processKey: processKey, processTemplateID: processTemplateID))),
            context: context)
    }

    public static func restartWorkspaceProcess(
        workspaceID: String, processID: String?, processKey: String?, processTemplateID: String?, context: DeviceRequestContext
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(
                command: .restartWorkspaceProcess(
                    .init(workspaceID: workspaceID, processID: processID, processKey: processKey, processTemplateID: processTemplateID))),
            context: context)
    }

    public static func stopCodingAgent(workspaceID: String, agentID: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .stopCodingAgent(.init(workspaceID: workspaceID, agentID: agentID))), context: context)
    }

    /// Agent-facing one-shot terminal input on a paired device (`spaces terminal send text/bytes --device`).
    @discardableResult public static func sendTerminalInput(
        sessionID: String, text: String? = nil, bytes: Data? = nil, appendNewline: Bool = false, context: DeviceRequestContext
    ) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .sendTerminalInput(.init(sessionID: sessionID, text: text, bytes: bytes, appendNewline: appendNewline))), context: context)
    }

    /// Rendered plain-text tail of a terminal session on a paired device (`spaces terminal tail --device`).
    public static func tailTerminalOutput(sessionID: String, lines: Int? = nil, context: DeviceRequestContext) throws -> String {
        let response = try request(.init(command: .tailTerminalOutput(.init(sessionID: sessionID, lines: lines))), context: context)
        guard let output = response.terminalOutput else {
            throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
        }
        return output
    }

    /// Starts an arbitrary command in a new workspace terminal on a paired device. The daemon runs it
    /// through the workspace's interactive login shell; a supported coding agent becomes selectable only
    /// after the regular foreground detector observes it.
    @discardableResult public static func startWorkspaceCommandSession(workspaceID: String, command: String, context: DeviceRequestContext) throws
        -> SpacesDeviceAPIResponse
    { try request(.init(command: .startWorkspaceCommandSession(.init(workspaceID: workspaceID, command: command))), context: context) }

    /// Spawns a coding agent on a paired device (`spaces agent spawn --device`). Returns the created
    /// session id (via the mutation result) so the caller polls readiness with `listAgentSessions`; the
    /// daemon runs the same supported-agent hook gate as the local spawn before creating the session.
    @discardableResult public static func spawnAgentSession(
        workspaceID: String, command: String, title: String? = nil, automationRunID: String? = nil, context: DeviceRequestContext
    ) throws -> SpacesDeviceAPIResponse {
        try request(
            .init(command: .spawnAgentSession(.init(workspaceID: workspaceID, command: command, title: title, automationRunID: automationRunID))),
            context: context)
    }

    /// Coding-agent sessions on a paired device (`spaces agent list/status --device`), also used for
    /// remote spawn-readiness polling. `workspaceID`/`sessionID` narrow the listing; both optional.
    public static func listAgentSessions(workspaceID: String? = nil, sessionID: String? = nil, context: DeviceRequestContext) throws
        -> [SpacesDeviceAgentSessionRow]
    {
        let response = try request(.init(command: .listAgentSessions(.init(workspaceID: workspaceID, sessionID: sessionID))), context: context)
        return response.agentSessions ?? []
    }

    /// Sets (or clears, with an empty note) a coding-agent session's note on a paired device
    /// (`spaces agent annotate --device`). Returns the updated row.
    @discardableResult public static func annotateAgentSession(sessionID: String, note: String, context: DeviceRequestContext) throws
        -> [SpacesDeviceAgentSessionRow]
    {
        let response = try request(.init(command: .annotateAgentSession(.init(sessionID: sessionID, note: note))), context: context)
        return response.agentSessions ?? []
    }

    /// Kills a coding-agent session on a paired device by its child terminal session id (`spaces agent
    /// kill --device`). The daemon routes through its `killAgentSession` flow, which handles both a
    /// hook-signaled child (its subscribers told it exited before the row is deleted) and a
    /// not-yet-signaled `.agent`-kind session (terminated), so the client makes one call for both cases.
    @discardableResult public static func killAgentSession(sessionID: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .killAgentSession(.init(sessionID: sessionID))), context: context)
    }

    // MARK: - Automations

    /// Creates an automation on a paired device. The daemon validates the draft (non-empty fields, a
    /// parseable cron for a cron trigger) and returns the created automation as a one-element list.
    @discardableResult public static func createAutomation(_ fields: TerminalServiceAutomationFields, context: DeviceRequestContext) throws
        -> [TerminalServiceAutomationSummary]
    { try request(.init(command: .createAutomation(fields)), context: context).automations ?? [] }

    /// Applies a full-field update (including enable/disable) to an automation on a paired device. Returns
    /// the updated automation as a one-element list.
    @discardableResult public static func updateAutomation(id: String, fields: TerminalServiceAutomationFields, context: DeviceRequestContext) throws
        -> [TerminalServiceAutomationSummary]
    { try request(.init(command: .updateAutomation(.init(id: id, fields: fields))), context: context).automations ?? [] }

    /// Overrides an automation's next occurrence on a paired device with `nextRunTime`. The daemon validates
    /// the instant (future, on an enabled automation) and returns the updated automation as a one-element
    /// list; the cron schedule resumes after the overridden run fires.
    @discardableResult public static func setAutomationNextRun(id: String, nextRunTime: Date, context: DeviceRequestContext) throws
        -> [TerminalServiceAutomationSummary]
    {
        try request(
            .init(command: .setAutomationNextRun(.init(id: id, nextRunTime: TerminalSessionTimestamp.fractionalString(from: nextRunTime)))),
            context: context
        ).automations ?? []
    }

    /// Deletes an automation on a paired device (cancelling any running run and cleaning up its artifacts).
    @discardableResult public static func deleteAutomation(id: String, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        try request(.init(command: .deleteAutomation(.init(id: id))), context: context)
    }

    /// Lists the automations configured on a paired device.
    public static func listAutomations(context: DeviceRequestContext) throws -> [TerminalServiceAutomationSummary] {
        try request(.init(command: .listAutomations), context: context).automations ?? []
    }

    /// Lists automation runs on a paired device, newest first; `automationID` narrows to one automation.
    public static func listAutomationRuns(automationID: String? = nil, context: DeviceRequestContext) throws
        -> [TerminalServiceAutomationRunSummary]
    { try request(.init(command: .listAutomationRuns(.init(automationID: automationID))), context: context).automationRuns ?? [] }

    /// Manually triggers an automation on a paired device, returning the started run as a one-element list.
    @discardableResult public static func triggerAutomation(id: String, context: DeviceRequestContext) throws
        -> [TerminalServiceAutomationRunSummary]
    { try request(.init(command: .triggerAutomation(.init(id: id))), context: context).automationRuns ?? [] }

    /// Cancels an automation run on a paired device, returning the canceled run as a one-element list.
    @discardableResult public static func cancelAutomationRun(runID: String, context: DeviceRequestContext) throws
        -> [TerminalServiceAutomationRunSummary]
    { try request(.init(command: .cancelAutomationRun(.init(runID: runID))), context: context).automationRuns ?? [] }

    /// Ends the still-live coding-agent sessions attributed to a terminal automation run on a paired device,
    /// returning the run (its status unchanged) as a one-element list. Used to reap an `agent`-kind run's
    /// session that was left open after the agent signalled done.
    @discardableResult public static func endAutomationAgents(runID: String, context: DeviceRequestContext) throws
        -> [TerminalServiceAutomationRunSummary]
    { try request(.init(command: .endAutomationAgents(.init(runID: runID))), context: context).automationRuns ?? [] }

    /// Terminal sessions on a paired device, read from the overview (`spaces terminal list --device`).
    public static func terminalSessions(context: DeviceRequestContext) throws -> [SpacesDeviceTerminalSessionSummary] {
        try overview(context: context).overview.sessions
    }

    /// Projects on a paired device, read from the overview (`spaces project list --device`). Reuses the
    /// overview the sidebar already loads rather than a dedicated listing command.
    public static func projects(context: DeviceRequestContext) throws -> [SpacesDeviceProjectSummary] { try overview(context: context).overview.projects }

    /// Workspaces on a paired device, read from the overview (`spaces workspace list --device`).
    public static func workspaces(context: DeviceRequestContext) throws -> [SpacesDeviceWorkspaceSummary] {
        try overview(context: context).overview.workspaces
    }

    /// Reads a device's Device API credentials (pinned TLS certificate fingerprint and auth token),
    /// transparently re-bootstrapping the local device when its token is missing; the re-bootstrap also
    /// refreshes the local record's fingerprint, so a rotated daemon identity is picked up in the same
    /// recovery. The fingerprint is non-secret paired-device record data, not a stored secret. A remote
    /// device cannot regenerate its own identity, so a missing remote fingerprint surfaces as
    /// `missingCertificateFingerprint` (the client must re-pair); a remote token is returned as-is
    /// (possibly nil, the pre-existing behavior).
    public static func credentialsEnsuringLocalRecovery(context: DeviceRequestContext) throws -> (certificateFingerprint: String, authToken: String?)
    {
        let device = context.device
        if device.id == SpacesPairedDeviceRecord.localDeviceID {
            var record = device
            if try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: context.profile) == nil,
                let refreshed = try ensureLocalDeviceCredentials(clientApp: context.clientApp, profile: context.profile)
            {
                record = refreshed
            }
            guard let fingerprint = normalizedFingerprint(record.certificateFingerprint) else {
                throw SpacesDeviceClientError.missingCertificateFingerprint(deviceName: device.name, isLocal: true)
            }
            return (fingerprint, try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: context.profile))
        }
        guard let fingerprint = normalizedFingerprint(device.certificateFingerprint) else {
            throw SpacesDeviceClientError.missingCertificateFingerprint(deviceName: device.name, isLocal: false)
        }
        return (fingerprint, try SpacesDeviceCredentialStore.token(deviceID: device.id, profile: context.profile))
    }

    private static func normalizedFingerprint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func request(_ request: SpacesDeviceAPIRequest, context: DeviceRequestContext) throws -> SpacesDeviceAPIResponse {
        let (certificateFingerprint, authToken) = try credentialsEnsuringLocalRecovery(context: context)
        let client = try SpacesDeviceAPIRequestClient(
            resolver: SpacesDeviceEndpointRegistry.resolver(for: context.device, certificateFingerprint: certificateFingerprint),
            timeoutSeconds: requestTimeoutSeconds(for: request.command))
        let response = try client.request(authenticated(request, authToken: authToken, clientApp: context.clientApp))
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
            // A stalled stream is the transport dying under a connection that still looks open: the
            // daemon's keepalives stopped arriving, so nothing reached this client. Same disposition as a
            // timeout — the link is gone and the caller should reconnect.
            case .timeout, .emptyResponse, .connectionFailed, .streamStalled: return true
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

    /// Delegates to `SpacesDeviceAPICommandDescriptor.timeoutSeconds`, the exhaustive per-command switch
    /// pinned in `spacesdevicecore`. `defaultRequestTimeoutSeconds`/`agentHooksStatusRequestTimeoutSeconds`/
    /// `longRunningMutationTimeoutSeconds`/`largePayloadRequestTimeoutSeconds` above stay in this type
    /// (rather than moving into the descriptor) because they are also asserted against directly by
    /// `SpacesDeviceOverviewViewModelTests`; the descriptor's own switch pins the same four values as
    /// literals so the two cannot silently drift without a test on one side or the other catching it.
    public static func requestTimeoutSeconds(for command: SpacesDeviceAPICommand) -> TimeInterval { command.descriptor.timeoutSeconds }
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

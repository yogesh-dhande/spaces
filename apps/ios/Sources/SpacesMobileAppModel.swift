import Foundation
import Observation
import spacesdevicecore
import spacesterminalcore

private enum SpacesMobileSettingsStore {
    static let settingsKey = "spaces.mobile.connection-settings"

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> SpacesMobileConnectionSettings {
        let storedSettings: SpacesMobileConnectionSettings
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(SpacesMobileConnectionSettings.self, from: data)
        {
            storedSettings = decoded
        } else {
            storedSettings = SpacesMobileConnectionSettings()
        }

        return appliedTestOverrides(to: storedSettings.migratedToCurrentDefaults(), environment: environment)
    }

    static func save(_ settings: SpacesMobileConnectionSettings) {
        var stored = settings
        stored.authToken = ""
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    private static func appliedTestOverrides(
        to settings: SpacesMobileConnectionSettings,
        environment: [String: String]
    ) -> SpacesMobileConnectionSettings {
        var resolved = settings

        if let host = trimmed(environment["SPACES_MOBILE_TEST_HOST"]) {
            resolved.host = host
        }
        if let port = trimmed(environment["SPACES_MOBILE_TEST_PORT"]).flatMap(Int.init), (1...65535).contains(port) {
            resolved.port = port
        }
        if let authToken = trimmed(environment["SPACES_MOBILE_TEST_AUTH_TOKEN"]) {
            resolved.authToken = authToken
        }
        if let certificateFingerprint = trimmed(environment["SPACES_MOBILE_TEST_CERTIFICATE_FINGERPRINT"]) {
            resolved.certificateFingerprint = certificateFingerprint
        }
        if let installationID = trimmed(environment["SPACES_MOBILE_TEST_INSTALLATION_ID"]) {
            resolved.installationID = installationID
        }

        return resolved
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct SpacesMobileE2EConfig {
    static var shared: Self { Self(environment: ProcessInfo.processInfo.environment) }

    let targetSessionID: String?
    let secondarySessionID: String?
    let renderDumpPath: String?
    let eventLogPath: String?

    init(environment: [String: String]) {
        let fileConfig = Self.loadFileConfig(environment: environment)
        targetSessionID = Self.trimmed(environment["SPACES_MOBILE_E2E_TARGET_SESSION_ID"]) ?? fileConfig?.sessionID
        secondarySessionID = Self.trimmed(environment["SPACES_MOBILE_E2E_SECONDARY_SESSION_ID"]) ?? fileConfig?.secondarySessionID
        renderDumpPath = Self.trimmed(environment["SPACES_MOBILE_E2E_RENDER_DUMP_PATH"]) ?? fileConfig?.renderDumpPath
        eventLogPath = Self.trimmed(environment["SPACES_MOBILE_E2E_EVENT_LOG_PATH"]) ?? fileConfig?.eventLogPath
    }

    var isEnabled: Bool { targetSessionID != nil || secondarySessionID != nil || renderDumpPath != nil || eventLogPath != nil }

    func matches(sessionID: String) -> Bool {
        if let targetSessionID, targetSessionID == sessionID { return true }
        if let secondarySessionID, secondarySessionID == sessionID { return true }
        return targetSessionID == nil && secondarySessionID == nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func loadFileConfig(environment: [String: String]) -> FileConfig? {
        guard let configPath = uiTestConfigPath(environment: environment) else { return nil }
        let url = URL(fileURLWithPath: configPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FileConfig.self, from: data)
    }

    private static func uiTestConfigPath(environment: [String: String]) -> String? {
        if let explicitPath = trimmed(environment["SPACES_MOBILE_UI_TEST_CONFIG_PATH"]) {
            return explicitPath
        }
        let defaultPath = "/tmp/spaces-mobile-ui-test-config.json"
        return FileManager.default.fileExists(atPath: defaultPath) ? defaultPath : nil
    }

    private struct FileConfig: Decodable {
        let sessionID: String?
        let secondarySessionID: String?
        let renderDumpPath: String?
        let eventLogPath: String?
    }

}

struct SpacesMobileE2ERenderDump: Codable, Equatable {
    let sessionID: String
    let title: String
    let renderMode: String
    let isOwner: Bool
    let showsTerminalSurface: Bool
    let isConnecting: Bool
    let isBusy: Bool
    let isOwnershipSynchronizationScheduled: Bool
    let isSynchronizingOwnership: Bool
    let isPreparingInput: Bool
    let isInputSurfaceReady: Bool
    let viewportColumns: Int?
    let viewportRows: Int?
    let lastSentResizeColumns: Int?
    let lastSentResizeRows: Int?
    let runtimeColumns: Int?
    let runtimeRows: Int?
    let snapshotColumns: Int?
    let snapshotRows: Int?
    let snapshotText: String?
    let errorMessage: String?
    let isPreparingLinkPreview: Bool
    let linkPreviewTitle: String?
    let linkPreviewMediaKind: SpacesDeviceTerminalLinkMediaKind?
    let linkPreviewErrorMessage: String?
    let visibleText: String
    let renderedText: String
    let renderStateKey: String
    let emittedAt: String
}

struct SpacesMobileE2EEvent: Codable, Equatable {
    let sessionID: String
    let kind: String
    let detail: String?
    let emittedAt: String
}

enum SpacesMobileE2EDumpWriter {
    static func writeCurrentDump(_ dump: SpacesMobileE2ERenderDump, config: SpacesMobileE2EConfig = .shared) {
        if let renderDumpPath = config.renderDumpPath { writeJSON(dump, to: renderDumpPath) }
        if let eventLogPath = config.eventLogPath { appendJSONLine(dump, to: eventLogPath) }
    }

    static func appendEvent(_ event: SpacesMobileE2EEvent, config: SpacesMobileE2EConfig = .shared) {
        guard let eventLogPath = config.eventLogPath else { return }
        appendJSONLine(event, to: eventLogPath)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {}
    }

    private static func appendJSONLine<T: Encodable>(_ value: T, to path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            var data = try encoder.encode(value)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: [.atomic])
            }
        } catch {}
    }
}

struct SpacesMobileTerminalWorkspaceGroup: Identifiable {
    let id: String
    let projectName: String
    let workspaceTitle: String
    let workspaceDirectory: String
    let sessions: [SpacesDeviceTerminalSessionSummary]
}

enum SpacesMobileWorkspaceRowType: String, CaseIterable, Identifiable, Hashable {
    case processes
    case codingAgents
    case workspaceTerminals
    case browserSessions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .processes: "Processes"
        case .codingAgents: "Coding Agents"
        case .workspaceTerminals: "Workspace Terminals"
        case .browserSessions: "Browser Sessions"
        }
    }

    var iconName: String {
        switch self {
        case .processes: "terminal"
        case .codingAgents: "cpu"
        case .workspaceTerminals: "terminal.fill"
        case .browserSessions: "globe"
        }
    }
}

extension SpacesDeviceRunState {
    var mobileLabel: String {
        switch self {
        case .notStarted: "Not Started"
        case .running: "Running"
        case .exited: "Exited"
        }
    }
}

/// A workspace's browser-session URL resolved to a live runtime route (see
/// `SpacesDeviceBrowserSessionRoute`). Unlike processes/agents/terminals this row has no run state or
/// mutation actions of its own — it is a navigable link into the on-device browser proxy — so it is
/// modeled as its own row payload rather than another `SpacesDeviceWorkspace*Row` case.
struct SpacesMobileBrowserSessionRow: Identifiable, Sendable, Equatable {
    let id: String
    let workspaceID: String
    let title: String
    /// Short host(+port)+path summary of the resolved session URL, e.g. `"localhost:3000/dashboard"`.
    let detail: String
    let route: SpacesDeviceBrowserSessionRoute

    /// `index` disambiguates two resolved sessions that match the same service (same `id` would
    /// otherwise collide) while keeping ids stable across a refresh that reorders nothing else.
    init(workspaceID: String, index: Int, route: SpacesDeviceBrowserSessionRoute) {
        self.workspaceID = workspaceID
        self.id = "browser:\(workspaceID):\(route.serviceName):\(index)"
        self.title = route.sessionName ?? route.serviceName
        self.detail = Self.detail(originalURL: route.originalURL)
        self.route = route
    }

    private static func detail(originalURL: String) -> String {
        guard let components = URLComponents(string: originalURL), let host = components.host else { return originalURL }
        let portSuffix = components.port.map { ":\($0)" } ?? ""
        return "\(host)\(portSuffix)\(components.path)"
    }
}

struct SpacesMobileWorkspaceRuntimeRow: Identifiable, Sendable {
    enum Source: Sendable {
        case process(SpacesDeviceWorkspaceProcessRow)
        case codingAgent(SpacesDeviceWorkspaceCodingAgentRow)
        case terminal(SpacesDeviceWorkspaceTerminalRow)
        case browserSession(SpacesMobileBrowserSessionRow)
    }

    let source: Source

    var id: String {
        switch source {
        case .process(let row): "process:\(row.id)"
        case .codingAgent(let row): "agent:\(row.id)"
        case .terminal(let row): "terminal:\(row.id)"
        case .browserSession(let row): row.id
        }
    }

    var workspaceID: String {
        switch source {
        case .process(let row): row.workspaceID
        case .codingAgent(let row): row.workspaceID
        case .terminal(let row): row.workspaceID
        case .browserSession(let row): row.workspaceID
        }
    }

    var type: SpacesMobileWorkspaceRowType {
        switch source {
        case .process: .processes
        case .codingAgent: .codingAgents
        case .terminal: .workspaceTerminals
        case .browserSession: .browserSessions
        }
    }

    var title: String {
        switch source {
        case .process(let row): row.name
        case .codingAgent(let row): row.name
        case .terminal(let row): row.title
        case .browserSession(let row): row.title
        }
    }

    var detail: String {
        switch source {
        case .process(let row): row.command
        case .codingAgent(let row): row.command
        case .terminal(let row): row.workingDirectory
        case .browserSession(let row): row.detail
        }
    }

    var sessionID: String? {
        switch source {
        case .process(let row): row.sessionID
        case .codingAgent(let row): row.sessionID
        case .terminal(let row): row.sessionID
        case .browserSession: nil
        }
    }

    /// Browser session rows carry no run state of their own; `.notStarted` is an unused filler
    /// (the UI never renders it — `rowMatchesFilters` also bypasses the run-state filter for these rows).
    var runState: SpacesDeviceRunState {
        switch source {
        case .process(let row): row.runState
        case .codingAgent(let row): row.runState
        case .terminal(let row): row.runState
        case .browserSession: .notStarted
        }
    }

    var canRun: Bool {
        switch source {
        case .process(let row): row.canRun
        case .codingAgent(let row): row.canRun
        case .terminal: false
        case .browserSession: false
        }
    }

    var canStop: Bool {
        switch source {
        case .process(let row): row.canStop
        case .codingAgent(let row): row.canStop
        case .terminal(let row): row.canStop
        case .browserSession: false
        }
    }

    var canRestart: Bool {
        switch source {
        case .process(let row): row.canRestart
        case .codingAgent(let row): row.canRestart
        case .terminal: false
        case .browserSession: false
        }
    }

    var canStopFromTerminalDetail: Bool {
        switch source {
        case .process(let row):
            row.processID != nil && row.sessionID != nil
        case .codingAgent(let row):
            row.agentID != nil && row.sessionID != nil
        case .terminal(let row):
            row.canStop
        case .browserSession:
            false
        }
    }

    var canRestartFromTerminalDetail: Bool {
        switch source {
        case .process(let row):
            row.processID != nil && row.templateID != nil && row.sessionID != nil
        case .codingAgent(let row):
            row.agentID != nil && (row.isConfigured || row.launcherID != nil) && row.sessionID != nil
        case .terminal:
            false
        case .browserSession:
            false
        }
    }

    var hasTerminalDetailActions: Bool { canRun || canStopFromTerminalDetail || canRestartFromTerminalDetail }
}

struct SpacesMobileWorkspaceGroup: Identifiable {
    let workspace: SpacesDeviceWorkspaceSummary
    let rows: [SpacesMobileWorkspaceRuntimeRow]

    var id: String { workspace.id }
}

private enum SpacesMobileMutationTimeoutRecovery {
    case acceptCachedOverview
    case requireFreshOverview(previousSessionID: String?)

    var acceptsCachedOverview: Bool {
        switch self {
        case .acceptCachedOverview: true
        case .requireFreshOverview: false
        }
    }

    func acceptsFreshSession(_ session: SpacesDeviceTerminalSessionSummary?) -> SpacesDeviceTerminalSessionSummary? {
        guard let session else { return nil }
        switch self {
        case .acceptCachedOverview:
            return session
        case .requireFreshOverview(let previousSessionID):
            return session.id == previousSessionID ? nil : session
        }
    }
}

@MainActor @Observable final class SpacesMobileAppModel {
    var settings: SpacesMobileConnectionSettings
    var pairedDevices: [SpacesMobilePairedDeviceRecord]
    var activeDeviceID: String?
    var overview: SpacesDeviceOverviewPayload?
    /// Wire-protocol status of the active device, read on each successful refresh. `nil` until the
    /// first handshake. Drives the compatibility banner and blocks incompatible interaction.
    var daemonStatus: TerminalServiceDaemonStatus?
    var compatibility: SpacesWireCompatibility?
    var isLoading = false
    var isMutating = false
    var isShowingConnectionSettings = false
    var isShowingWorkspaceCreateSheet = false
    var connectionNotice: String?
    var pendingPairingLink: SpacesDevicePairingLink?
    var errorMessage: String?
    var searchText = ""
    var visibleRowTypes: Set<SpacesMobileWorkspaceRowType> = Set(SpacesMobileWorkspaceRowType.allCases)
    var visibleRunStates: Set<SpacesDeviceRunState> = Set([.notStarted, .running, .exited])
    var workspaceCreateOptions: SpacesDeviceWorkspaceCreateOptions?
    @ObservationIgnored private var bridgeClient: SpacesDeviceAPIClient
    @ObservationIgnored private var commandChannel: SpacesDeviceAPICommandChannel
    /// On-device loopback reverse proxy WKWebView browser sessions load through. Owned for the app's
    /// lifetime (its installation identity is stable across device switches), started/stopped by
    /// `ContentView`'s scene-phase observation.
    @ObservationIgnored private let browserProxy: SpacesMobileBrowserProxy
    /// Routing table refreshed from accepted active-device overviews, and pruned when a device is unpaired.
    /// Kept on the model (rather than rebuilt from scratch each time) so `removeDevice` can drop just
    /// that device's routes via `BrowserProxyRoutingTable.removeDevice`.
    @ObservationIgnored private var browserRoutingTable = BrowserProxyRoutingTable()
    /// In-memory holding spot for a screenshot staged for paste into a terminal session, shared across
    /// the app so the staging flow and the terminal viewer can both reach the same pending image.
    let stagedScreenshots = StagedScreenshotStore()

    init() {
        #if DEBUG
            SpacesMobileDeviceStore.applyDebugSeed()
        #endif
        let loadedSettings = SpacesMobileSettingsStore.load()
        let deviceState = SpacesMobileDeviceStore.load(fallbackSettings: loadedSettings)
        let bridgeClient = SpacesDeviceAPIClient(settings: deviceState.settings)
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        self.bridgeClient = bridgeClient
        commandChannel = bridgeClient.makeCommandChannel()
        browserProxy = SpacesMobileBrowserProxy(installationID: deviceState.settings.installationID)
        SpacesMobileSettingsStore.save(deviceState.settings)
    }

    init(
        settings: SpacesMobileConnectionSettings,
        bridgeClient: SpacesDeviceAPIClient,
        browserProxy: SpacesMobileBrowserProxy? = nil
    ) {
        self.settings = settings
        pairedDevices = []
        activeDeviceID = nil
        self.bridgeClient = bridgeClient
        commandChannel = bridgeClient.makeCommandChannel()
        self.browserProxy = browserProxy ?? SpacesMobileBrowserProxy(installationID: settings.installationID)
    }

    var workspaceGroups: [SpacesMobileWorkspaceGroup] {
        let allFiltersSelected =
            visibleRowTypes.count == SpacesMobileWorkspaceRowType.allCases.count
            && visibleRunStates.count == 3
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (overview?.workspaces ?? []).filter { !$0.isArchived }.compactMap { workspace in
            let allRows = workspaceRuntimeRows(for: workspace)
            let filteredRows = allRows.filter { row in rowMatchesFilters(row, workspace: workspace, query: query) }
            if allFiltersSelected { return SpacesMobileWorkspaceGroup(workspace: workspace, rows: allRows) }
            if workspaceMatchesSearch(workspace, query: query), visibleRowTypes.count == SpacesMobileWorkspaceRowType.allCases.count {
                return SpacesMobileWorkspaceGroup(workspace: workspace, rows: filteredRows)
            }
            guard !filteredRows.isEmpty else { return nil }
            return SpacesMobileWorkspaceGroup(workspace: workspace, rows: filteredRows)
        }
    }

    var terminalGroups: [SpacesMobileTerminalWorkspaceGroup] {
        let workspaces = overview?.workspaces ?? []
        let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let representedSessionIDs = Set(workspaces.flatMap { workspaceRuntimeRows(for: $0).compactMap(\.sessionID) })
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessions = (overview?.sessions ?? []).filter { session in
            !representedSessionIDs.contains(session.id) && terminalSessionMatchesFilters(session, query: query)
        }
        let grouped = Dictionary(grouping: sessions) { $0.workspaceID }

        return grouped.values.compactMap { sessions in
            guard let firstSession = sessions.first else { return nil }
            let workspace = workspaceByID[firstSession.workspaceID]
            let projectName = workspace?.projectName ?? firstSession.projectName ?? "Unassigned"
            let workspaceTitle = workspace?.displayName ?? firstSession.workspaceTitle ?? "Unassigned"
            let workspaceDirectory = workspace?.dir ?? firstSession.workingDirectory
            let orderedSessions = sessions.sorted(by: sessionSort)

            return SpacesMobileTerminalWorkspaceGroup(
                id: firstSession.workspaceID,
                projectName: projectName,
                workspaceTitle: workspaceTitle,
                workspaceDirectory: workspaceDirectory,
                sessions: orderedSessions
            )
        }
        .sorted(by: groupSort)
    }

    /// The active device cannot be used until its daemon is restarted/updated or this app updates.
    var isActiveDeviceBlocked: Bool {
        guard let compatibility else { return false }
        return !compatibility.isCompatible
    }

    /// Compatible, but the daemon reports an older app version than this client — a non-blocking hint
    /// that a daemon update is pending and will apply on the next restart.
    var daemonUpdatePending: Bool {
        guard compatibility == .compatible, let status = daemonStatus else { return false }
        return SpacesWireProtocol.isVersion(status.version, olderThan: SpacesMobileAppModel.clientAppVersion)
    }

    static let clientAppVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    var connectionSummary: String {
        if let activeDeviceName { return activeDeviceName }
        return "\(settings.trimmedHost):\(settings.port)"
    }

    var activeDeviceName: String? {
        guard let activeDeviceID else { return nil }
        return pairedDevices.first(where: { $0.id == activeDeviceID })?.name
    }

    func toggleRowTypeFilter(_ type: SpacesMobileWorkspaceRowType) {
        if visibleRowTypes.contains(type) {
            guard visibleRowTypes.count > 1 else { return }
            visibleRowTypes.remove(type)
        } else {
            visibleRowTypes.insert(type)
        }
    }

    func toggleRunStateFilter(_ state: SpacesDeviceRunState) {
        if visibleRunStates.contains(state) {
            guard visibleRunStates.count > 1 else { return }
            visibleRunStates.remove(state)
        } else {
            visibleRunStates.insert(state)
        }
    }

    /// Current bind status of the on-device browser proxy, so the UI can surface a bind failure.
    var browserProxyStatus: BrowserProxyStatus { browserProxy.runtimeState.status }

    /// Starts the loopback browser proxy. Idempotent; call when the app becomes active.
    func browserProxyStart() {
        Task { await browserProxy.start() }
    }

    /// Stops the loopback browser proxy and all live tunnels. Call when the app enters the background.
    func browserProxyStop() {
        Task { await browserProxy.stop() }
    }

    /// The URL a `WKWebView` should load for a browser session row, rebuilt against the proxy's fixed
    /// loopback port. `nil` only if the route's identity host somehow fails to form a valid URL.
    func browserSessionProxyURL(for row: SpacesMobileBrowserSessionRow) -> URL? {
        row.route.proxyURL(proxyPort: Int(SpacesMobileBrowserProxy.fixedPort))
    }

    /// Authenticated request details for the embedded browser. The proxy rejects requests that do not
    /// carry the route's in-memory cookie, so local loopback clients cannot dial daemon service tunnels
    /// just by guessing a routed `.localhost` host.
    func browserSessionProxyRequest(for row: SpacesMobileBrowserSessionRow) -> BrowserProxyRequest? {
        guard let target = browserRoutingTable.target(forHost: row.route.identityHost),
              let url = browserSessionProxyURL(for: row)
        else { return nil }
        return BrowserProxyRequest(url: url, authToken: target.proxyAuthToken)
    }

    /// Merges an accepted active-device overview into the browser proxy's routing table and pushes the
    /// updated table to the proxy actor before the overview is published to SwiftUI. Workspace
    /// browser-session rows are read straight back out of `overview` by `workspaceRuntimeRows(for:)`,
    /// but the proxy needs its own copy of the host->target mapping to route requests independently of
    /// the SwiftUI refresh cycle.
    private func updateBrowserRoutes(overview: SpacesDeviceOverviewPayload) async {
        guard let activeDeviceID else { return }
        browserRoutingTable.merge(
            deviceID: activeDeviceID,
            deviceName: activeDeviceName ?? settings.trimmedHost,
            host: settings.trimmedHost,
            port: settings.port,
            certificateFingerprint: settings.certificateFingerprint,
            overview: overview
        )
        let table = browserRoutingTable
        await browserProxy.updateRoutes(table)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Read compatibility from the overview's inline frozen-core status so the compatible steady
            // state costs a single round-trip. Only a refresh that fails entirely falls back to the
            // standalone frozen-core handshake below.
            let overview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
            applyCompatibility(overview.daemonStatus)
            // A decodable overview whose daemon nonetheless reports an incompatible protocol is blocked;
            // show the restart/update block, not its stale workspace data.
            let acceptedOverview = isActiveDeviceBlocked ? nil : overview
            if let acceptedOverview {
                await updateBrowserRoutes(overview: acceptedOverview)
            }
            self.overview = acceptedOverview
            connectionNotice = nil
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            // The overview did not decode (a wire-incompatible daemon) or the device is unreachable. The
            // frozen-core handshake stays decodable across versions, so use it to tell those apart: an
            // incompatible verdict shows the block; otherwise surface the original connection error.
            await refreshCompatibility()
            if isActiveDeviceBlocked {
                overview = nil
                connectionNotice = nil
                errorMessage = nil
                return
            }
            if let recoveryMessage = SpacesDeviceAPIAuthentication.recoveryMessage(for: error) {
                handleAuthenticationFailure(message: recoveryMessage)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Requests a restart of the active device's daemon. The caller should already have confirmed the
    /// restart impact with the user. After the daemon respawns, the next refresh re-runs the handshake.
    func requestDaemonRestart() async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await bridgeClient.requestDaemonRestart(commandChannel: commandChannel)
            connectionNotice = "Restarting the daemon…"
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyCompatibility(_ status: TerminalServiceDaemonStatus) {
        daemonStatus = status
        compatibility = SpacesWireCompatibility.evaluate(daemonStatus: status)
    }

    /// Standalone frozen-core handshake, used only as a fallback when the overview cannot carry the
    /// inline status (an older daemon) or could not be fetched/decoded at all (incompatible/offline).
    private func refreshCompatibility() async {
        do {
            let status = try await bridgeClient.fetchDaemonStatus(commandChannel: commandChannel)
            applyCompatibility(status)
        } catch is CancellationError {
            return
        } catch {
            // Could not read the handshake; leave compatibility unknown rather than blocking.
            daemonStatus = nil
            compatibility = nil
        }
    }

    func applyConnectionSettings(_ settings: SpacesMobileConnectionSettings, deviceName: String? = nil) {
        let previousCommandChannel = commandChannel
        let deviceState =
            settings.isPaired
            ? SpacesMobileDeviceStore.upsert(settings: settings, name: deviceName ?? settings.trimmedHost)
            : SpacesMobileDeviceStore.load(fallbackSettings: settings)
        self.settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        bridgeClient = SpacesDeviceAPIClient(settings: deviceState.settings)
        commandChannel = bridgeClient.makeCommandChannel()
        SpacesMobileSettingsStore.save(deviceState.settings)
        overview = nil
        daemonStatus = nil
        compatibility = nil
        workspaceCreateOptions = nil
        connectionNotice = nil
        pendingPairingLink = nil
        Task { await previousCommandChannel.close() }
    }

    func selectDevice(id: String) {
        guard let deviceState = SpacesMobileDeviceStore.select(deviceID: id, installationID: settings.installationID) else { return }
        let previousCommandChannel = commandChannel
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        bridgeClient = SpacesDeviceAPIClient(settings: settings)
        commandChannel = bridgeClient.makeCommandChannel()
        SpacesMobileSettingsStore.save(settings)
        overview = nil
        daemonStatus = nil
        compatibility = nil
        workspaceCreateOptions = nil
        connectionNotice = nil
        errorMessage = nil
        Task { await previousCommandChannel.close() }
    }

    func removeDevice(id: String) {
        let previousCommandChannel = commandChannel
        let deviceState = SpacesMobileDeviceStore.remove(deviceID: id, fallbackSettings: settings)
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        bridgeClient = SpacesDeviceAPIClient(settings: settings)
        commandChannel = bridgeClient.makeCommandChannel()
        SpacesMobileSettingsStore.save(settings)
        overview = nil
        daemonStatus = nil
        compatibility = nil
        workspaceCreateOptions = nil
        connectionNotice = nil
        browserRoutingTable.removeDevice(deviceID: id)
        let table = browserRoutingTable
        Task { await browserProxy.updateRoutes(table) }
        Task { await previousCommandChannel.close() }
    }

    func renameDevice(id: String, name: String) {
        let deviceState = SpacesMobileDeviceStore.rename(deviceID: id, name: name, fallbackSettings: settings)
        pairedDevices = deviceState.devices
    }

    func dismissError() { errorMessage = nil }

    func clearPendingPairingLink() { pendingPairingLink = nil }

    func handleAuthenticationFailure(message: String) {
        let previousCommandChannel = commandChannel
        settings.authToken = ""
        bridgeClient = SpacesDeviceAPIClient(settings: settings)
        commandChannel = bridgeClient.makeCommandChannel()
        SpacesMobileSettingsStore.save(settings)
        overview = nil
        workspaceCreateOptions = nil
        connectionNotice = message
        pendingPairingLink = nil
        errorMessage = nil
        isShowingConnectionSettings = true
        Task { await previousCommandChannel.close() }
    }

    func preparePairingLink(_ url: URL) {
        do {
            pendingPairingLink = try SpacesDevicePairingLink.parse(url)
            connectionNotice = nil
            errorMessage = nil
            isShowingConnectionSettings = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadWorkspaceCreateOptions(projectID: String? = nil) async {
        do {
            workspaceCreateOptions = try await bridgeClient.fetchWorkspaceCreateOptions(projectID: projectID, commandChannel: commandChannel)
        } catch {
            handleBridgeError(error)
        }
    }

    func createWorkspace(
        projectID: String,
        branch: String?,
        baseBranch: String?,
        directoryName: String?,
        allowExistingBranchReuse: Bool
    ) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let response = try await bridgeClient.createWorkspace(
                projectID: projectID, branch: branch, baseBranch: baseBranch, directoryName: directoryName,
                allowExistingBranchReuse: allowExistingBranchReuse, commandChannel: commandChannel)
            await applyMutationResponse(response)
            isShowingWorkspaceCreateSheet = false
        } catch {
            handleBridgeError(error)
        }
    }

    func openWorkspaceTerminal(workspaceID: String) async -> SpacesDeviceTerminalSessionSummary? {
        await performMutationReturningSession {
            try await bridgeClient.openWorkspaceTerminal(workspaceID: workspaceID, commandChannel: commandChannel)
        }
    }

    func run(row: SpacesMobileWorkspaceRuntimeRow) async -> SpacesDeviceTerminalSessionSummary? {
        let timeoutRecovery = SpacesMobileMutationTimeoutRecovery.requireFreshOverview(previousSessionID: row.sessionID)
        switch row.source {
        case .process(let process):
            guard process.canRun else { return nil }
            return await performMutationReturningSession(fallbackRowID: row.id, timeoutRecovery: timeoutRecovery) {
                try await bridgeClient.runWorkspaceProcess(
                    workspaceID: process.workspaceID, processKey: process.name, processTemplateID: process.templateID ?? process.id,
                    commandChannel: commandChannel)
            }
        case .codingAgent(let agent):
            guard agent.canRun else { return nil }
            return await performMutationReturningSession(fallbackRowID: row.id, timeoutRecovery: timeoutRecovery) {
                try await bridgeClient.runCodingAgent(
                    workspaceID: agent.workspaceID, agentName: agent.name, agentLauncherID: agent.launcherID, commandChannel: commandChannel)
            }
        case .terminal, .browserSession:
            return nil
        }
    }

    func performPrimaryAction(for row: SpacesMobileWorkspaceRuntimeRow) async -> SpacesDeviceTerminalSessionSummary? {
        if let session = terminalSession(for: row) { return session }
        return await run(row: row)
    }

    func stop(row: SpacesMobileWorkspaceRuntimeRow) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let response: SpacesDeviceAPIResponse
            switch row.source {
            case .process(let process):
                guard let processID = process.processID else { return }
                response = try await bridgeClient.stopWorkspaceProcess(
                    workspaceID: process.workspaceID, processID: processID, processKey: process.name, commandChannel: commandChannel)
            case .codingAgent(let agent):
                guard let agentID = agent.agentID else { return }
                response = try await bridgeClient.stopCodingAgent(
                    workspaceID: agent.workspaceID, agentID: agentID, agentName: agent.name, commandChannel: commandChannel)
            case .terminal(let terminal):
                guard let sessionID = terminal.sessionID else { return }
                response = try await bridgeClient.stopWorkspaceTerminal(
                    workspaceID: terminal.workspaceID, sessionID: sessionID, commandChannel: commandChannel)
            case .browserSession:
                return
            }
            await applyMutationResponse(response)
        } catch {
            handleBridgeError(error)
        }
    }

    func restart(row: SpacesMobileWorkspaceRuntimeRow) async -> SpacesDeviceTerminalSessionSummary? {
        let timeoutRecovery = SpacesMobileMutationTimeoutRecovery.requireFreshOverview(previousSessionID: row.sessionID)
        switch row.source {
        case .process(let process):
            guard let processID = process.processID else { return nil }
            return await performMutationReturningSession(fallbackRowID: row.id, timeoutRecovery: timeoutRecovery) {
                try await bridgeClient.restartWorkspaceProcess(
                    workspaceID: process.workspaceID, processID: processID, processKey: process.name, commandChannel: commandChannel)
            }
        case .codingAgent(let agent):
            guard let agentID = agent.agentID else { return nil }
            return await performMutationReturningSession(fallbackRowID: row.id, timeoutRecovery: timeoutRecovery) {
                try await bridgeClient.restartCodingAgent(
                    workspaceID: agent.workspaceID, agentID: agentID, agentName: agent.name, commandChannel: commandChannel)
            }
        case .terminal, .browserSession:
            return nil
        }
    }

    private func groupSort(_ lhs: SpacesMobileTerminalWorkspaceGroup, _ rhs: SpacesMobileTerminalWorkspaceGroup) -> Bool {
        if lhs.projectName.localizedStandardCompare(rhs.projectName) != .orderedSame {
            return lhs.projectName.localizedStandardCompare(rhs.projectName) == .orderedAscending
        }
        return lhs.workspaceTitle.localizedStandardCompare(rhs.workspaceTitle) == .orderedAscending
    }

    private func sessionSort(_ lhs: SpacesDeviceTerminalSessionSummary, _ rhs: SpacesDeviceTerminalSessionSummary) -> Bool {
        if lhs.state != rhs.state {
            return lhs.state == .running && rhs.state != .running
        }
        if lhs.title.localizedStandardCompare(rhs.title) != .orderedSame {
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return lhs.createdAt < rhs.createdAt
    }

    private func workspaceRuntimeRows(for workspace: SpacesDeviceWorkspaceSummary) -> [SpacesMobileWorkspaceRuntimeRow] {
        let browserRoutes = SpacesDeviceBrowserSessionRoute.routes(
            resolvedBrowserSessions: workspace.config.resolvedBrowserSessions, assignedPorts: workspace.assignedPorts)
        return workspace.processRows.map { .init(source: .process($0)) }
            + workspace.codingAgentRows.map { .init(source: .codingAgent($0)) }
            + workspace.terminalRows.map { .init(source: .terminal($0)) }
            + browserRoutes.enumerated().map { index, route in
                .init(source: .browserSession(SpacesMobileBrowserSessionRow(workspaceID: workspace.id, index: index, route: route)))
            }
    }

    private func rowMatchesFilters(_ row: SpacesMobileWorkspaceRuntimeRow, workspace: SpacesDeviceWorkspaceSummary, query: String) -> Bool {
        guard visibleRowTypes.contains(row.type) else { return false }
        // Browser session rows carry no run state (see `SpacesMobileWorkspaceRuntimeRow.runState`), so
        // the run-state filter only applies to rows that actually have one.
        if case .browserSession = row.source {} else {
            guard visibleRunStates.contains(row.runState) else { return false }
        }
        guard !query.isEmpty else { return true }
        return [workspace.projectName, workspace.displayName, workspace.dir, row.title, row.detail].contains { value in
            value.localizedStandardContains(query)
        }
    }

    private func workspaceMatchesSearch(_ workspace: SpacesDeviceWorkspaceSummary, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [workspace.projectName, workspace.displayName, workspace.dir].contains { $0.localizedStandardContains(query) }
    }

    private func terminalSessionMatchesFilters(_ session: SpacesDeviceTerminalSessionSummary, query: String) -> Bool {
        guard session.rowKind == .liveSession else { return false }
        guard visibleRowTypes.contains(.workspaceTerminals), visibleRunStates.contains(runState(for: session.state)) else { return false }
        guard !query.isEmpty else { return true }
        return [session.projectName, session.workspaceTitle, session.workingDirectory, session.title].compactMap(\.self).contains {
            $0.localizedStandardContains(query)
        }
    }

    private func runState(for state: TerminalSessionState) -> SpacesDeviceRunState {
        switch state {
        case .starting, .running: .running
        case .exited, .failed: .exited
        }
    }

    func terminalSession(for row: SpacesMobileWorkspaceRuntimeRow) -> SpacesDeviceTerminalSessionSummary? {
        guard let sessionID = row.sessionID else { return nil }
        if let session = overview?.sessions.first(where: { $0.id == sessionID }) { return session }
        guard case .terminal(let terminalRow) = row.source else { return nil }
        return terminalSession(from: terminalRow)
    }

    func runtimeRow(forSessionID sessionID: String) -> SpacesMobileWorkspaceRuntimeRow? {
        overview?.workspaces.flatMap(workspaceRuntimeRows(for:)).first { $0.sessionID == sessionID }
    }

    func refreshedSession(forRowID rowID: String) -> SpacesDeviceTerminalSessionSummary? {
        overview?.workspaces.flatMap(workspaceRuntimeRows(for:)).first(where: { $0.id == rowID }).flatMap(terminalSession(for:))
    }

    private func terminalSession(from row: SpacesDeviceWorkspaceTerminalRow) -> SpacesDeviceTerminalSessionSummary? {
        guard let sessionID = row.sessionID else { return nil }
        let workspace = overview?.workspaces.first { $0.id == row.workspaceID }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return SpacesDeviceTerminalSessionSummary(
            id: sessionID,
            title: row.title,
            workingDirectory: row.workingDirectory,
            shell: "",
            command: nil,
            state: terminalSessionState(for: row.runState),
            backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent,
            servicePID: 0,
            childPID: nil,
            workspaceID: row.workspaceID,
            workspaceTitle: workspace?.displayName,
            projectID: workspace?.projectID,
            projectName: workspace?.projectName,
            createdAt: timestamp,
            updatedAt: timestamp,
            isControlAvailable: row.runState == .running,
            isSubscriptionAvailable: row.runState == .running,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            rowKind: .liveSession,
            rowSourceID: row.id,
            hasFinalRender: false
        )
    }

    private func terminalSessionState(for runState: SpacesDeviceRunState) -> TerminalSessionState {
        switch runState {
        case .notStarted: .starting
        case .running: .running
        case .exited: .exited
        }
    }

    private func performMutationReturningSession(
        fallbackRowID: String? = nil,
        timeoutRecovery: SpacesMobileMutationTimeoutRecovery = .acceptCachedOverview,
        _ operation: () async throws -> SpacesDeviceAPIResponse
    ) async -> SpacesDeviceTerminalSessionSummary? {
        guard !isMutating else { return nil }
        isMutating = true
        defer { isMutating = false }
        do {
            let response = try await operation()
            await applyMutationResponse(response)
            if let sessionID = response.sessionID {
                return overview?.sessions.first(where: { $0.id == sessionID })
            }
            if let fallbackRowID {
                return refreshedSession(forRowID: fallbackRowID)
            }
            return nil
        } catch {
            if let fallbackRowID,
                isMutationTimeout(error),
                let session = await reconciledSessionAfterMutationTimeout(rowID: fallbackRowID, timeoutRecovery: timeoutRecovery)
            {
                return session
            }
            handleBridgeError(error)
            return nil
        }
    }

    private func applyMutationResponse(_ response: SpacesDeviceAPIResponse) async {
        if let overview = response.overview {
            await updateBrowserRoutes(overview: overview)
            self.overview = overview
            connectionNotice = nil
            errorMessage = nil
        }
    }

    private func handleBridgeError(_ error: Error) {
        if error is CancellationError {
            return
        }
        if let recoveryMessage = SpacesDeviceAPIAuthentication.recoveryMessage(for: error) {
            handleAuthenticationFailure(message: recoveryMessage)
            return
        }
        errorMessage = error.localizedDescription
    }

    private func reconciledSessionAfterMutationTimeout(
        rowID: String,
        timeoutRecovery: SpacesMobileMutationTimeoutRecovery
    ) async -> SpacesDeviceTerminalSessionSummary? {
        if timeoutRecovery.acceptsCachedOverview, let session = refreshedSession(forRowID: rowID) {
            errorMessage = nil
            connectionNotice = nil
            return session
        }
        do {
            let refreshedOverview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
            await updateBrowserRoutes(overview: refreshedOverview)
            overview = refreshedOverview
            errorMessage = nil
            connectionNotice = nil
            return timeoutRecovery.acceptsFreshSession(refreshedSession(forRowID: rowID))
        } catch {
            return nil
        }
    }

    private func isMutationTimeout(_ error: Error) -> Bool {
        switch error {
        case SpacesDeviceAPIClientError.requestTimedOut:
            return true
        case SpacesDeviceAPIClientError.requestFailed(let message, _),
            SpacesDeviceAPIClientError.streamFailed(let message, _):
            return message.localizedStandardContains("timed out")
        default:
            return false
        }
    }
}

import Foundation
import Observation
import UIKit
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

    private static func appliedTestOverrides(to settings: SpacesMobileConnectionSettings, environment: [String: String])
        -> SpacesMobileConnectionSettings
    {
        var resolved = settings

        if let host = trimmed(environment["SPACES_MOBILE_TEST_HOST"]) { resolved.host = host }
        if let port = trimmed(environment["SPACES_MOBILE_TEST_PORT"]).flatMap(Int.init), (1...65535).contains(port) { resolved.port = port }
        if let authToken = trimmed(environment["SPACES_MOBILE_TEST_AUTH_TOKEN"]) { resolved.authToken = authToken }
        if let certificateFingerprint = trimmed(environment["SPACES_MOBILE_TEST_CERTIFICATE_FINGERPRINT"]) {
            resolved.certificateFingerprint = certificateFingerprint
        }
        if let installationID = trimmed(environment["SPACES_MOBILE_TEST_INSTALLATION_ID"]) { resolved.installationID = installationID }

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
        if let explicitPath = trimmed(environment["SPACES_MOBILE_UI_TEST_CONFIG_PATH"]) { return explicitPath }
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
    let linkPreviewArtifactKind: SpacesDeviceTerminalLinkArtifactKind?
    let linkPreviewContentKind: String?
    let linkPreviewErrorMessage: String?
    let linkNotice: String?
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

/// Bottom tab bar destinations. Selection lives on the app model so non-tab surfaces
/// (the not-paired state, pairing links, auth recovery) can switch tabs programmatically.
enum SpacesMobileTab: String, Hashable, Sendable {
    case alerts
    case spaces
    case agents
    case settings
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

    /// A browser session is a URL, not a process: it has no run state, no lifecycle actions, and its
    /// row opens a web view instead of a terminal, so several UI rules key off this.
    var isBrowserSession: Bool {
        if case .browserSession = source { return true }
        return false
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
        case .process(let row): row.processID != nil && row.sessionID != nil
        case .codingAgent(let row): row.agentID != nil && row.sessionID != nil
        case .terminal(let row): row.canStop
        case .browserSession: false
        }
    }

    var canRestartFromTerminalDetail: Bool {
        switch source {
        case .process(let row): row.processID != nil && row.templateID != nil && row.sessionID != nil
        case .codingAgent(let row): row.agentID != nil && (row.isConfigured || row.launcherID != nil) && row.sessionID != nil
        case .terminal: false
        case .browserSession: false
        }
    }

    var hasTerminalDetailActions: Bool { canRun || canStopFromTerminalDetail || canRestartFromTerminalDetail }
}

extension SpacesDeviceWorkspaceSummary {
    /// Git workspaces are branch-backed; non-git workspaces are the project directory itself.
    var isGitWorkspace: Bool {
        guard let branch else { return false }
        return !branch.isEmpty
    }
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
        case .acceptCachedOverview: return session
        case .requireFreshOverview(let previousSessionID): return session.id == previousSessionID ? nil : session
        }
    }
}

@MainActor @Observable final class SpacesMobileAppModel {
    var settings: SpacesMobileConnectionSettings
    var pairedDevices: [SpacesMobilePairedDeviceRecord]
    var activeDeviceID: String?
    /// Whether Demo Mode is on. While on, the device list shows only the synthetic Demo Mac and the
    /// active client is backed by the in-memory `DemoDeviceBackend`; the real paired devices are parked
    /// in memory and left untouched on disk. Persisted across launches via `DemoModeStore`.
    private(set) var isDemoModeEnabled: Bool
    var overview: SpacesDeviceOverviewPayload?
    /// Wire-protocol status of the active device, read on each successful refresh. `nil` until the
    /// first handshake. Drives the compatibility banner and blocks incompatible interaction.
    var daemonStatus: TerminalServiceDaemonStatus?
    var compatibility: SpacesWireCompatibility?
    var isLoading = false
    var isMutating = false
    /// True while a requested daemon update has been sent and this app is polling the device for the
    /// update to land (see `requestDaemonUpdate()`). Kept separate from `isMutating`: that flag gates
    /// one-shot mutations and is released as soon as their single RPC returns, but the update poll runs
    /// for up to `daemonUpdateTimeout`, and holding `isMutating` for that whole window would freeze
    /// every other mutating control in the app. Only the Update Daemon button reads this flag.
    var isApplyingDaemonUpdate = false
    var isShowingConnectionSettings = false
    var isShowingWorkspaceCreateSheet = false
    var connectionNotice: String?
    var pendingPairingLink: SpacesDevicePairingLink?
    /// A terminal session a `spaces://terminal/…` deep link asks to focus. The Spaces tab observes
    /// this, pushes the session's detail route, and clears it. Model-driven (rather than a tab-local
    /// binding) so a link handled at the app shell can navigate whichever tab is on screen.
    var pendingTerminalDeepLinkSession: SpacesDeviceTerminalSessionSummary?
    var errorMessage: String?
    var searchText = ""
    var visibleRowTypes: Set<SpacesMobileWorkspaceRowType> = Set(SpacesMobileWorkspaceRowType.allCases)
    var visibleRunStates: Set<SpacesDeviceRunState> = Set([.notStarted, .running, .exited])
    var workspaceCreateOptions: SpacesDeviceWorkspaceCreateOptions?
    var selectedTab: SpacesMobileTab = .spaces
    /// Workspaces whose runtime rows are collapsed on the Spaces tab. In-memory only; a fresh
    /// launch starts fully expanded.
    var collapsedWorkspaceIDs: Set<String> = []
    /// Attention events the user cleared. In-memory only; identities are stable per source+kind+date
    /// so a cleared event stays cleared across refreshes until the source changes state again.
    var dismissedAlertIDs: Set<String> = []
    @ObservationIgnored private var bridgeClient: SpacesDeviceAPIClient
    @ObservationIgnored private var commandChannel: SpacesDeviceAPICommandChannel
    /// The real device-store state (records, active id, settings) parked in memory when Demo Mode is
    /// enabled, so turning it off restores exactly what was on screen. `nil` when Demo Mode is off, or
    /// when the app launched straight into Demo Mode — in that case turning it off reloads the real
    /// state from `SpacesMobileDeviceStore` instead. Never written to disk.
    @ObservationIgnored private var parkedRealDeviceState: SpacesMobileDeviceStoreState?
    /// Shown when a device-management action is attempted while Demo Mode is on.
    private static let demoModeGuardNotice = "Turn off Demo Mode to pair or switch devices."
    /// The client bound to the active device, exposed so screens that open their own request/stream
    /// paths (e.g. `TerminalViewerModel`) reuse the same backend instead of building a parallel client
    /// from `settings`. Reflects the current device after a switch.
    var deviceClient: SpacesDeviceAPIClient { bridgeClient }
    /// Monotonic identity of the connection the published overview belongs to. Bumped whenever the
    /// active connection changes (device switch or removal, new settings, auth reset) so an overview
    /// fetch begun against the previous connection can neither publish its stale payload nor satisfy
    /// a `refresh()` caller waiting on the new one.
    @ObservationIgnored private var overviewIdentity = 0
    /// The in-flight overview fetch, tagged with the identity it serves. `refresh()` joins it when
    /// the identity still matches, and re-fetches after it completes when the identity moved on.
    @ObservationIgnored private var refreshInFlight: (identity: Int, task: Task<Void, Never>)?
    /// When the current run of failed overview fetches began, gating the connection-error alert (see
    /// `refreshFailureAlertDelay`). Tagged with the connection identity it was gathered against, so any
    /// change of connection restarts the run without every reset site having to clear it. `nil` once a
    /// refresh succeeds.
    @ObservationIgnored private var refreshFailureStreak: (identity: Int, startedAt: ContinuousClock.Instant)?
    /// Bumped every time the app enters the background. A refresh attempt captures it at the start and
    /// records nothing about failure timing if it changed, because an attempt that spans suspension has
    /// no meaningful duration: `ContinuousClock` keeps advancing while the process is frozen, so most of
    /// what it measured is time the app spent not watching the connection at all.
    @ObservationIgnored private var appBackgroundGeneration = 0
    /// On-device loopback reverse proxy WKWebView browser sessions load through. Owned for the app's
    /// lifetime (its installation identity is stable across device switches), started/stopped by
    /// `RootTabView`'s scene-phase observation.
    @ObservationIgnored private let browserProxy: SpacesMobileBrowserProxy
    /// Routing table refreshed from accepted active-device overviews, and pruned when a device is unpaired.
    /// Kept on the model (rather than rebuilt from scratch each time) so `removeDevice` can drop just
    /// that device's routes via `BrowserProxyRoutingTable.removeDevice`.
    @ObservationIgnored private var browserRoutingTable = BrowserProxyRoutingTable()
    /// In-memory holding spot for a screenshot staged for paste into a terminal session, shared across
    /// the app so the staging flow and the terminal viewer can both reach the same pending image.
    let stagedScreenshots = StagedScreenshotStore()
    /// Interval between daemon-status polls in `requestDaemonUpdate()`. Injectable so tests can shrink
    /// it instead of sleeping through the production wait.
    @ObservationIgnored private let daemonUpdatePollInterval: Duration
    /// Bumped by each `requestDaemonUpdate()` call so an invocation can tell whether it still owns
    /// `isApplyingDaemonUpdate` when it exits. See that method's ownership comment.
    @ObservationIgnored private var daemonUpdateGeneration = 0
    /// Wall-clock budget `requestDaemonUpdate()` polls for before giving up (production default 30s).
    /// Expressed as time rather than an attempt count because each attempt's own request timeout
    /// (`fetchDaemonStatus`'s 8s) means the two are not proportional — a fixed attempt count against an
    /// unreachable device would cost attempts × (interval + request timeout), several times the stated
    /// budget. Injectable so tests can shrink it instead of sleeping through the production wait.
    @ObservationIgnored private let daemonUpdateTimeout: Duration
    /// How long overview fetches must keep failing before the connection-error alert is raised (production
    /// default 5s). Long enough to cover a blip and the poll's retry two seconds later, short enough that
    /// a device that is actually unreachable is reported promptly. Injectable so tests can shrink it
    /// instead of sleeping through the production wait.
    @ObservationIgnored private let refreshFailureAlertDelay: Duration

    init() {
        #if DEBUG
            SpacesMobileDeviceStore.applyDebugSeed()
        #endif
        let loadedSettings = SpacesMobileSettingsStore.load()
        let deviceState = SpacesMobileDeviceStore.load(fallbackSettings: loadedSettings)
        // Captured here, on the main actor, rather than read lazily off `ProcessInfo.processInfo.hostName`:
        // that call does a blocking reverse-DNS lookup and previously ran on this init's main thread,
        // tripping the launch watchdog on every fresh install.
        let deviceName = UIDevice.current.name
        browserProxy = SpacesMobileBrowserProxy(installationID: deviceState.settings.installationID, deviceName: deviceName)
        daemonUpdatePollInterval = .seconds(3)
        daemonUpdateTimeout = .seconds(30)
        refreshFailureAlertDelay = .seconds(5)
        // The real settings are persisted regardless of Demo Mode; the demo device is never written to
        // disk, so a launch that lands in Demo Mode still keeps the real records and settings intact.
        SpacesMobileSettingsStore.save(deviceState.settings)

        // When the persisted flag is on, construct the demo state directly and leave the real records
        // parked on disk (parkedRealDeviceState stays nil, so disabling reloads them from the store).
        if DemoModeStore.load(), let backend = try? DemoDeviceBackend.makeDefault() {
            let demoSettings = SpacesMobileDemoDevice.settings(installationID: deviceState.settings.installationID)
            let bridgeClient = SpacesDeviceAPIClient(settings: demoSettings, deviceName: deviceName, backend: backend)
            settings = demoSettings
            pairedDevices = [SpacesMobileDemoDevice.record()]
            activeDeviceID = SpacesMobileDemoDevice.id
            isDemoModeEnabled = true
            self.bridgeClient = bridgeClient
            commandChannel = bridgeClient.makeCommandChannel()
            return
        }

        let bridgeClient = SpacesDeviceAPIClient(settings: deviceState.settings, deviceName: deviceName)
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        isDemoModeEnabled = false
        self.bridgeClient = bridgeClient
        commandChannel = bridgeClient.makeCommandChannel()
    }

    init(
        settings: SpacesMobileConnectionSettings, bridgeClient: SpacesDeviceAPIClient, browserProxy: SpacesMobileBrowserProxy? = nil,
        daemonUpdatePollInterval: Duration = .seconds(3), daemonUpdateTimeout: Duration = .seconds(30),
        refreshFailureAlertDelay: Duration = .seconds(5)
    ) {
        self.settings = settings
        pairedDevices = []
        activeDeviceID = nil
        isDemoModeEnabled = false
        self.bridgeClient = bridgeClient
        commandChannel = bridgeClient.makeCommandChannel()
        self.browserProxy = browserProxy ?? SpacesMobileBrowserProxy(installationID: settings.installationID)
        self.daemonUpdatePollInterval = daemonUpdatePollInterval
        self.daemonUpdateTimeout = daemonUpdateTimeout
        self.refreshFailureAlertDelay = refreshFailureAlertDelay
    }

    /// The workspaces this client lists: neither archived nor hidden, matching the Mac sidebar's
    /// `isVisibleWorkspace` rule. `isHidden` is daemon-owned workspace state, so a workspace hidden
    /// from the Mac's Workspace Visibility dialog is hidden here too.
    private var visibleWorkspaces: [SpacesDeviceWorkspaceSummary] { (overview?.workspaces ?? []).filter { !$0.isArchived && !$0.isHidden } }

    var workspaceGroups: [SpacesMobileWorkspaceGroup] {
        let allFiltersSelected =
            visibleRowTypes.count == SpacesMobileWorkspaceRowType.allCases.count && visibleRunStates.count == 3
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleWorkspaces.compactMap { workspace in
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
        let workspaces = visibleWorkspaces
        let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let representedSessionIDs = Set(workspaces.flatMap { workspaceRuntimeRows(for: $0).compactMap(\.sessionID) })
        // A hidden workspace's loose sessions are hidden with it; otherwise hiding a workspace would just
        // move its terminals into a loose group instead of removing them from the list.
        let hiddenWorkspaceIDs = Set((overview?.workspaces ?? []).filter(\.isHidden).map(\.id))
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessions = (overview?.sessions ?? []).filter { session in
            !hiddenWorkspaceIDs.contains(session.workspaceID) && !representedSessionIDs.contains(session.id)
                && terminalSessionMatchesFilters(session, query: query)
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
                id: firstSession.workspaceID, projectName: projectName, workspaceTitle: workspaceTitle, workspaceDirectory: workspaceDirectory,
                sessions: orderedSessions)
        }.sorted(by: groupSort)
    }

    /// Attention-event groups for the Alerts tab, derived client-side from the overview payload
    /// with the user's cleared events filtered out.
    var attentionGroups: [SpacesMobileAttentionGroup] {
        guard let overview else { return [] }
        return SpacesMobileAttention.groups(in: overview, dismissedEventIDs: dismissedAlertIDs)
    }

    /// Undismissed attention-event count, shown as the Alerts tab badge.
    var undismissedAlertCount: Int { attentionGroups.reduce(0) { $0 + $1.events.count } }

    /// Marks every currently derived attention event dismissed.
    func clearAlerts() {
        guard let overview else { return }
        dismissedAlertIDs.formUnion(SpacesMobileAttention.events(in: overview).map(\.id))
    }

    /// Coding-agent rows across all workspaces grouped by activity for the Agents tab.
    var agentGroups: [SpacesMobileAgentGroup] {
        guard let overview else { return [] }
        return SpacesMobileAgentGrouping.groups(in: overview)
    }

    func toggleWorkspaceCollapsed(_ workspaceID: String) {
        if collapsedWorkspaceIDs.contains(workspaceID) {
            collapsedWorkspaceIDs.remove(workspaceID)
        } else {
            collapsedWorkspaceIDs.insert(workspaceID)
        }
    }

    /// Resolves a session summary for navigation, including sessions synthesized from
    /// workspace terminal rows that are not in the overview's session list.
    func session(forSessionID sessionID: String) -> SpacesDeviceTerminalSessionSummary? {
        if let session = overview?.sessions.first(where: { $0.id == sessionID }) { return session }
        return runtimeRow(forSessionID: sessionID).flatMap(terminalSession(for:))
    }

    /// The active device cannot be used until its daemon is restarted/updated or this app updates.
    /// Stays keyed on wire compatibility rather than `daemonUpdateRemedy`: `.applyStagedUpdate` covers
    /// both a blocking (`daemonTooOld`) and a non-blocking (`compatible`) case, so only compatibility —
    /// not the remedy alone — can tell them apart.
    var isActiveDeviceBlocked: Bool {
        guard let compatibility else { return false }
        return !compatibility.isCompatible
    }

    /// The action a client should offer about the active device's daemon, computed once via the shared
    /// `DaemonUpdateRemedy` rule so this app never re-derives the decision from raw compatibility or
    /// version fields itself. `nil` until the first successful handshake, mirroring `daemonStatus`.
    var daemonUpdateRemedy: DaemonUpdateRemedy? {
        guard let daemonStatus else { return nil }
        return DaemonUpdateRemedy.remedy(for: daemonStatus)
    }

    /// Compatible, but a newer Spaces is installed on the active device than the build its daemon is
    /// running — the non-blocking shape of `.applyStagedUpdate` (see `isActiveDeviceBlocked`'s doc). A
    /// restart applies the update; the daemon reports this about its own device, so no version
    /// comparison happens on this client.
    var daemonUpdatePending: Bool {
        guard case .applyStagedUpdate = daemonUpdateRemedy else { return false }
        return !isActiveDeviceBlocked
    }

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
    func browserProxyStart() { Task { await browserProxy.start() } }

    /// Stops the loopback browser proxy and all live tunnels. Call when the app enters the background.
    func browserProxyStop() { Task { await browserProxy.stop() } }

    /// Ends the current run of failed refreshes because the app stopped watching the connection. The
    /// alert gate reads wall-clock time between failures, and a backgrounded app polls nothing, so a
    /// failure recorded before the app left and one recorded after it returns are minutes apart with no
    /// evidence of anything in between. Without this, that pair reads as a long-running outage and the
    /// first blip on the way back raises the alert — the very interruption the gate exists to prevent.
    /// Attempts already in flight are covered too: they resume with a start time from before the app
    /// left, so `performRefresh` drops their failure timing rather than letting it rebuild the run the
    /// reset just ended.
    func noteAppEnteredBackground() {
        refreshFailureStreak = nil
        appBackgroundGeneration += 1
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
        guard let target = browserRoutingTable.target(forHost: row.route.identityHost), let url = browserSessionProxyURL(for: row) else { return nil }
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
            deviceID: activeDeviceID, deviceName: activeDeviceName ?? settings.trimmedHost, host: settings.trimmedHost, port: settings.port,
            certificateFingerprint: settings.certificateFingerprint, overview: overview)
        let table = browserRoutingTable
        await browserProxy.updateRoutes(table)
    }

    /// Fetches and publishes the active device's overview. Reentrant: a call while a fetch for the
    /// same connection is in flight joins that fetch instead of silently dropping (a deep link
    /// arriving mid-poll still resolves), and a call made after the connection identity changed
    /// waits out the stale fetch — whose result is discarded — and then fetches fresh, so every
    /// awaited `refresh()` returns having attempted an overview for the current connection.
    func refresh() async {
        while let inFlight = refreshInFlight {
            let identity = overviewIdentity
            await inFlight.task.value
            if inFlight.identity == identity, overviewIdentity == identity { return }
        }
        let identity = overviewIdentity
        let task = Task { await self.performRefresh(identity: identity) }
        refreshInFlight = (identity: identity, task: task)
        await task.value
    }

    /// One overview fetch on behalf of connection `identity`. Publishes nothing when the identity
    /// moved on mid-fetch: the payload — or error — belongs to the previous connection and would
    /// overwrite the reset state the identity change just established.
    private func performRefresh(identity: Int) async {
        isLoading = true
        // When this attempt began, not when it failed: a request that burns its whole timeout against an
        // unreachable device has already been failing for that long by the time it throws. Paired with
        // the background generation it was measured in, since the two are only comparable within one
        // foreground stretch.
        let attemptStartedAt = ContinuousClock.now
        let backgroundGeneration = appBackgroundGeneration
        defer {
            isLoading = false
            refreshInFlight = nil
        }
        do {
            // Read compatibility from the overview's inline frozen-core status so the compatible steady
            // state costs a single round-trip. Only a refresh that fails entirely falls back to the
            // standalone frozen-core handshake below.
            let overview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
            guard identity == overviewIdentity else { return }
            applyCompatibility(overview.daemonStatus)
            // A decodable overview whose daemon nonetheless reports an incompatible protocol is blocked;
            // show the restart/update block, not its stale workspace data.
            let acceptedOverview = isActiveDeviceBlocked ? nil : overview
            if let acceptedOverview { await updateBrowserRoutes(overview: acceptedOverview) }
            guard identity == overviewIdentity else { return }
            self.overview = acceptedOverview
            connectionNotice = nil
            errorMessage = nil
            refreshFailureStreak = nil
        } catch is CancellationError { return } catch {
            guard identity == overviewIdentity else { return }
            // The overview did not decode (a wire-incompatible daemon) or the device is unreachable. The
            // frozen-core handshake stays decodable across versions, so use it to tell those apart: an
            // incompatible verdict shows the block; otherwise surface the original connection error.
            await refreshCompatibility(identity: identity)
            // The user may have switched or removed the active device while the fallback handshake was
            // in flight; a stale verdict must not clear the new connection's state.
            guard identity == overviewIdentity else { return }
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
            // A requested daemon update takes the device offline on purpose, and `requestDaemonUpdate()`
            // is already watching across that outage. Pausing the overview poll keeps most refreshes out
            // of the window, but not one already awaiting its overview when the user taps Update, nor a
            // pull-to-refresh during it — so the suppression has to live here, where the failure lands,
            // rather than only at the call sites that start a refresh. An authentication failure above
            // still surfaces: that is not an outage and does not resolve itself when the daemon returns.
            guard !isApplyingDaemonUpdate else { return }
            // A single failed round trip is routinely recoverable — a Wi-Fi blip, or a socket the OS
            // dropped out from under the app while it was suspended — and the poll retries every two
            // seconds, so raising the modal alert on the first one interrupts the user for something that
            // heals itself before they can read it. The alert instead waits until failures have persisted
            // for `refreshFailureAlertDelay`.
            //
            // Measured in wall-clock time rather than failure count because the two kinds of failure are
            // not comparable in duration: a dead socket throws immediately, while an unreachable host
            // burns the request's full eight-second timeout (twice, counting the compatibility handshake
            // above) before it throws even once. Counting attempts would report the fast case in a few
            // seconds and the slow case only after a minute; timing the run reports both within one
            // window. User-initiated work (mutations, deep links) does not come through here — it still
            // reports on its first failure.
            // This attempt started before the app last backgrounded, so its elapsed time is mostly time
            // spent suspended. It cannot start or extend a run — that would resurrect, with a start time
            // from before the app left, exactly the run `noteAppEnteredBackground` ended.
            guard backgroundGeneration == appBackgroundGeneration else { return }
            let streakStartedAt = refreshFailureStreak?.identity == identity ? refreshFailureStreak?.startedAt : nil
            let startedAt = streakStartedAt ?? attemptStartedAt
            refreshFailureStreak = (identity: identity, startedAt: startedAt)
            guard ContinuousClock.now - startedAt >= refreshFailureAlertDelay else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Requests the active device's daemon exec-in-place handoff: it quiesces sessions, applies any
    /// staged update, and re-execs at the same pid, so running terminals, agents, and processes survive.
    /// Polls the device's frozen-core status afterward until it reports the update applied, so the
    /// compatibility banner clears itself instead of sitting on "Updating…" forever if nothing else
    /// looks back. The daemon is expected to be briefly unreachable mid-handoff, so fetch failures
    /// during the poll are swallowed rather than surfaced as a connection error — they just mean "not
    /// back yet."
    ///
    /// The poll is bounded by `daemonUpdateTimeout`, checked against a `ContinuousClock` deadline before
    /// each attempt rather than a fixed attempt count — see `daemonUpdateTimeout`'s doc comment. That
    /// bound is not exact: one probe already in flight when the deadline passes still runs to
    /// completion (or its own request timeout), because the loop has no way to abandon a request it is
    /// already awaiting, so the wall-clock cost of a fully unreachable device can exceed the stated
    /// budget by up to one request's timeout.
    ///
    /// Every step is guarded against `overviewIdentity`, captured once up front: a device switch or
    /// removal mid-poll must not publish the old device's status onto whatever is now active.
    func requestDaemonUpdate() async {
        guard !isMutating, !isApplyingDaemonUpdate else { return }
        let identity = overviewIdentity
        // The in-flight flag is released before this invocation's final refresh (see the timeout path
        // below), so a retry can legitimately start while this one is still finishing. Claim a
        // generation and only surrender the flag while still holding it, or a slow predecessor's exit
        // would clear a live successor's state — re-enabling the button mid-update and resuming the
        // overview poll straight into the handoff this flag exists to protect.
        daemonUpdateGeneration += 1
        let generation = daemonUpdateGeneration
        isApplyingDaemonUpdate = true
        defer { if daemonUpdateGeneration == generation { isApplyingDaemonUpdate = false } }

        // This flow runs on its own command channel rather than the shared one. The shared channel
        // carries the overview poll and every user mutation, and the transport does not serialize whole
        // request/response round trips (issue #248): two callers can interleave on its single connection
        // and consume each other's responses. The mutation gate below covers the restart RPC, but the
        // polling phase deliberately runs with mutations enabled for up to `daemonUpdateTimeout`, so a
        // shared channel would put a half-minute stream of probes alongside whatever the user does next.
        // A private channel keeps that traffic on its own connection for the life of the update.
        let updateChannel = bridgeClient.makeCommandChannel()
        defer { Task { await updateChannel.close() } }

        // The restart RPC holds the app-wide mutation gate like every other one-shot mutation, so another
        // mutation cannot be sent into the daemon while it is being told to quiesce and re-exec. The gate
        // is released before the polling phase: that runs for up to `daemonUpdateTimeout`, and holding it
        // there would freeze every mutating control in the app for the whole wait.
        isMutating = true
        let restartError: Error?
        do {
            try await bridgeClient.requestDaemonRestart(commandChannel: updateChannel)
            restartError = nil
        } catch { restartError = error }
        isMutating = false
        if let restartError {
            if restartError is CancellationError { return }
            guard identity == overviewIdentity else { return }
            errorMessage = restartError.localizedDescription
            return
        }
        guard identity == overviewIdentity else { return }
        connectionNotice = "Updating the daemon…"

        let clock = ContinuousClock()
        let deadline = clock.now + daemonUpdateTimeout
        while clock.now < deadline {
            // Cancellation exits the poll rather than being swallowed like a fetch failure: a cancelled
            // sleep would otherwise let every remaining attempt run back-to-back with no wait, spinning
            // the whole budget in one turn of the loop.
            do { try await Task.sleep(for: daemonUpdatePollInterval) } catch { return }
            // The deadline can pass during that sleep. Re-check before probing: launching a request here
            // would add its whole timeout on top of the budget, on top of the sleep that just overran it.
            guard clock.now < deadline else { break }
            guard identity == overviewIdentity else { return }
            guard let status = try? await bridgeClient.fetchDaemonStatus(commandChannel: updateChannel) else { continue }
            guard identity == overviewIdentity else { return }
            if case .applyStagedUpdate = DaemonUpdateRemedy.remedy(for: status) { continue }
            // The device no longer reports a staged update: publish the fresh status, then let a full
            // refresh repopulate the overview before clearing the notice.
            applyCompatibility(status)
            await refresh()
            guard identity == overviewIdentity else { return }
            connectionNotice = nil
            return
        }

        // Timed out. Drop the progress notice and re-enable the action, leaving the banner showing the
        // last thing the device actually said — a slow restart and a refused handoff look identical from
        // here, and neither is worth inventing a failure message for.
        //
        // Deliberately does not reconcile with a refresh. Against a device that is still down, that
        // fetch would take the ordinary failure path — clearing the status the banner renders from and
        // raising a connection error — which is the opposite of leaving the warning in place. It cannot
        // run under the expected-outage suppression either, because that keys off the same flag this
        // path has to release to re-enable the button. Releasing the flag resumes the overview poll,
        // which reconciles on its own cadence and reports a genuinely unreachable device the ordinary
        // way, so nothing is left stale.
        guard identity == overviewIdentity else { return }
        connectionNotice = nil
        isApplyingDaemonUpdate = false
    }

    private func applyCompatibility(_ status: TerminalServiceDaemonStatus) {
        daemonStatus = status
        compatibility = SpacesWireCompatibility.evaluate(daemonStatus: status)
    }

    /// Standalone frozen-core handshake, used only as a fallback when the overview cannot carry the
    /// inline status (an older daemon) or could not be fetched/decoded at all (incompatible/offline).
    /// Takes the caller's connection `identity` and re-checks it after the await: this fallback only
    /// runs once an overview fetch has already failed, so by the time it resolves the user may have
    /// switched or removed the active device, and a stale handshake must not publish for the new one.
    private func refreshCompatibility(identity: Int) async {
        do {
            let status = try await bridgeClient.fetchDaemonStatus(commandChannel: commandChannel)
            guard identity == overviewIdentity else { return }
            applyCompatibility(status)
        } catch is CancellationError { return } catch {
            guard identity == overviewIdentity else { return }
            // A requested update takes the device offline on purpose. Clearing the status there would
            // drop the banner (it renders off `daemonStatus`) and unblock the device (blocking reads
            // `compatibility`), flashing stale workspace controls back mid-update; keep the last known
            // facts until the poll learns otherwise.
            guard !isApplyingDaemonUpdate else { return }
            // Could not read the handshake; leave compatibility unknown rather than blocking.
            daemonStatus = nil
            compatibility = nil
        }
    }

    func applyConnectionSettings(_ settings: SpacesMobileConnectionSettings, deviceName: String? = nil) {
        guard !isDemoModeEnabled else {
            connectionNotice = Self.demoModeGuardNotice
            return
        }
        let previousCommandChannel = commandChannel
        let deviceState =
            settings.isPaired
            ? SpacesMobileDeviceStore.upsert(settings: settings, name: deviceName ?? settings.trimmedHost)
            : SpacesMobileDeviceStore.load(fallbackSettings: settings)
        self.settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        bridgeClient = SpacesDeviceAPIClient(settings: deviceState.settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
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
        guard !isDemoModeEnabled else {
            connectionNotice = Self.demoModeGuardNotice
            return
        }
        guard let deviceState = SpacesMobileDeviceStore.select(deviceID: id, installationID: settings.installationID) else { return }
        let previousCommandChannel = commandChannel
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        bridgeClient = SpacesDeviceAPIClient(settings: settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
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
        // The demo device is not a stored device; "removing" it means leaving Demo Mode.
        if id == SpacesMobileDemoDevice.id {
            setDemoMode(false)
            return
        }
        guard !isDemoModeEnabled else {
            connectionNotice = Self.demoModeGuardNotice
            return
        }
        let previousCommandChannel = commandChannel
        let deviceState = SpacesMobileDeviceStore.remove(deviceID: id, fallbackSettings: settings)
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        bridgeClient = SpacesDeviceAPIClient(settings: settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
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
        // The rename path reloads the on-disk device list, which would replace the synthetic
        // Demo Mac with the parked real records mid-demo.
        if isDemoModeEnabled {
            connectionNotice = Self.demoModeGuardNotice
            return
        }
        let deviceState = SpacesMobileDeviceStore.rename(deviceID: id, name: name, fallbackSettings: settings)
        pairedDevices = deviceState.devices
    }

    /// Turns Demo Mode on or off, swapping the active client the same way a device switch does (close and
    /// rebuild the client and command channel, bump `overviewIdentity`, and clear the published overview,
    /// status, and notices). Turning it on parks the real device-store state in memory and swaps in the
    /// synthetic Demo Mac backed by `DemoDeviceBackend`, writing nothing to the device store or Keychain;
    /// turning it off restores the parked state (or reloads it from the store when the app launched
    /// straight into Demo Mode). The enabled flag itself is persisted via `DemoModeStore`.
    func setDemoMode(_ enabled: Bool) {
        guard enabled != isDemoModeEnabled else { return }
        if enabled { enableDemoMode() } else { disableDemoMode() }
    }

    private func enableDemoMode() {
        let backend: DemoDeviceBackend
        do { backend = try DemoDeviceBackend.makeDefault() } catch {
            // The recording could not load; leave the real connection exactly as it was.
            errorMessage = error.localizedDescription
            return
        }
        parkedRealDeviceState = SpacesMobileDeviceStoreState(devices: pairedDevices, activeDeviceID: activeDeviceID, settings: settings)
        let previousCommandChannel = commandChannel
        let demoSettings = SpacesMobileDemoDevice.settings(installationID: settings.installationID)
        settings = demoSettings
        pairedDevices = [SpacesMobileDemoDevice.record()]
        activeDeviceID = SpacesMobileDemoDevice.id
        isDemoModeEnabled = true
        bridgeClient = SpacesDeviceAPIClient(settings: demoSettings, deviceName: UIDevice.current.name, backend: backend)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
        DemoModeStore.save(true)
        clearActiveConnectionState()
        Task { await previousCommandChannel.close() }
    }

    private func disableDemoMode() {
        let restored = parkedRealDeviceState ?? SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileSettingsStore.load())
        parkedRealDeviceState = nil
        let previousCommandChannel = commandChannel
        settings = restored.settings
        pairedDevices = restored.devices
        activeDeviceID = restored.activeDeviceID
        isDemoModeEnabled = false
        bridgeClient = SpacesDeviceAPIClient(settings: restored.settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
        DemoModeStore.save(false)
        clearActiveConnectionState()
        Task { await previousCommandChannel.close() }
    }

    /// Clears every piece of published state tied to the previous active connection, matching what a
    /// device switch resets so no stale overview, status, or notice bleeds across the swap.
    private func clearActiveConnectionState() {
        overview = nil
        daemonStatus = nil
        compatibility = nil
        workspaceCreateOptions = nil
        connectionNotice = nil
        errorMessage = nil
    }

    func dismissError() { errorMessage = nil }

    func clearPendingPairingLink() { pendingPairingLink = nil }

    func handleAuthenticationFailure(message: String) {
        let previousCommandChannel = commandChannel
        settings.authToken = ""
        bridgeClient = SpacesDeviceAPIClient(settings: settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
        SpacesMobileSettingsStore.save(settings)
        overview = nil
        workspaceCreateOptions = nil
        connectionNotice = message
        pendingPairingLink = nil
        errorMessage = nil
        isShowingConnectionSettings = true
        Task { await previousCommandChannel.close() }
    }

    func preparePairingLink(_ url: URL) { stagePairingLink { try SpacesDevicePairingLink.parse(url) } }

    /// A QR payload scanned from the Spaces tab's not-paired empty state rides the same
    /// confirm-and-pair flow as a `spaces://pair` deep link: stage the link and raise the
    /// connection-settings surface, which presents the pairing confirmation.
    func prepareScannedPairingLink(_ payload: String) { stagePairingLink { try SpacesDevicePairingLink.parse(payload) } }

    private func stagePairingLink(_ parse: () throws -> SpacesDevicePairingLink) {
        guard !isDemoModeEnabled else {
            connectionNotice = Self.demoModeGuardNotice
            return
        }
        do {
            pendingPairingLink = try parse()
            connectionNotice = nil
            errorMessage = nil
            isShowingConnectionSettings = true
        } catch { errorMessage = error.localizedDescription }
    }

    /// Focuses the terminal session named by a `spaces://terminal/…` deep link. When the link is
    /// device-qualified for a different paired device, switches to that device first; a device that
    /// isn't paired, or a session that can't be found, surfaces a user-visible error. On success it
    /// selects the Spaces tab and stages the session for that tab to navigate to.
    func openTerminalDeepLink(_ link: SpacesTerminalDeepLink) async {
        if let deviceID = link.deviceID, deviceID != activeDeviceID {
            guard pairedDevices.contains(where: { $0.id == deviceID }) else {
                errorMessage = "This link points to a device that isn't paired with this app."
                return
            }
            selectDevice(id: deviceID)
        }
        // The cached overview may predate the linked session: polling pauses while a terminal
        // detail view is open — exactly where agent-notification links are tapped — and a device
        // switch just cleared it. A lookup miss refreshes once before the link is declared dead.
        if session(forSessionID: link.sessionID) == nil { await refresh() }
        guard let session = session(forSessionID: link.sessionID) else {
            errorMessage = "Couldn't find terminal session “\(link.sessionID)” on \(connectionSummary)."
            return
        }
        selectedTab = .spaces
        pendingTerminalDeepLinkSession = session
    }

    func loadWorkspaceCreateOptions(projectID: String? = nil) async {
        do { workspaceCreateOptions = try await bridgeClient.fetchWorkspaceCreateOptions(projectID: projectID, commandChannel: commandChannel) } catch
        { handleBridgeError(error) }
    }

    func createWorkspace(projectID: String, branch: String?, baseBranch: String?, directoryName: String?, allowExistingBranchReuse: Bool) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        let identity = overviewIdentity
        do {
            let response = try await bridgeClient.createWorkspace(
                projectID: projectID, branch: branch, baseBranch: baseBranch, directoryName: directoryName,
                allowExistingBranchReuse: allowExistingBranchReuse, commandChannel: commandChannel)
            await applyMutationResponse(response, identity: identity)
            guard identity == overviewIdentity else { return }
            isShowingWorkspaceCreateSheet = false
        } catch {
            guard identity == overviewIdentity else { return }
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
        case .terminal, .browserSession: return nil
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
        let identity = overviewIdentity
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
            case .browserSession: return
            }
            await applyMutationResponse(response, identity: identity)
        } catch {
            guard identity == overviewIdentity else { return }
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
        case .terminal, .browserSession: return nil
        }
    }

    // MARK: - Workspace-level actions

    /// Starts the whole workspace: every configured process and coding agent. The daemon opens no browser
    /// session or ad hoc terminal, so those rows are untouched.
    func launchWorkspace(_ workspace: SpacesDeviceWorkspaceSummary) async {
        await performWorkspaceMutation { try await bridgeClient.launchWorkspace(workspaceID: workspace.id, commandChannel: commandChannel) }
    }

    func stopWorkspace(_ workspace: SpacesDeviceWorkspaceSummary) async {
        await performWorkspaceMutation { try await bridgeClient.stopWorkspace(workspaceID: workspace.id, commandChannel: commandChannel) }
    }

    func restartWorkspace(_ workspace: SpacesDeviceWorkspaceSummary) async {
        await performWorkspaceMutation { try await bridgeClient.restartWorkspace(workspaceID: workspace.id, commandChannel: commandChannel) }
    }

    /// Hides the workspace, stopping it first when it is running — matching the Mac's Hide, which never
    /// leaves a hidden workspace running with no row left to stop it from.
    func hideWorkspace(_ workspace: SpacesDeviceWorkspaceSummary) async {
        await performWorkspaceMutation {
            let currentOverview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
            guard let currentWorkspace = currentOverview.workspaces.first(where: { $0.id == workspace.id }) else {
                throw SpacesDeviceAPIClientError.requestFailed("This workspace is no longer available.")
            }
            if currentWorkspace.isRunning { _ = try await bridgeClient.stopWorkspace(workspaceID: workspace.id, commandChannel: commandChannel) }
            return try await bridgeClient.setWorkspaceHidden(workspaceID: workspace.id, isHidden: true, commandChannel: commandChannel)
        }
    }

    private func performWorkspaceMutation(_ operation: () async throws -> SpacesDeviceAPIResponse) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        let identity = overviewIdentity
        do { await applyMutationResponse(try await operation(), identity: identity) } catch {
            guard identity == overviewIdentity else { return }
            handleBridgeError(error)
        }
    }

    // MARK: - Renaming runtime rows

    /// Where a runtime row's name lives, and so how a rename reaches the daemon: an ad hoc terminal owns its
    /// session title, while a configured process, coding agent, or browser session owns an entry in the
    /// workspace config. Configured entries carry stable identity so the mutation can resolve them against a
    /// fresh config instead of replacing concurrent edits with the overview's cached snapshot.
    private enum RuntimeRowRename {
        case terminalSession(sessionID: String)
        case workspaceConfig(entry: ConfigEntry)

        enum ConfigEntry {
            case process(id: String)
            case agentLauncher(id: String)
            case browserSession(name: String)
        }
    }

    /// Whether the row has a name the daemon can rename. A process or coding agent running without a
    /// configured entry has no name to edit — its name comes from the running process — and a terminal row
    /// whose session has ended has no session to rename, so those rows offer no Rename. Demo Mode's backend
    /// rejects config edits, so no row is renamable while it is on.
    func canRename(row: SpacesMobileWorkspaceRuntimeRow) -> Bool {
        guard !isDemoModeEnabled else { return false }
        return renameTarget(for: row) != nil
    }

    /// Renames a runtime row. Renaming a configured process, coding agent, or browser session edits its
    /// workspace-config entry, so a running process keeps its current name until it is restarted — the same
    /// rule the Mac sidebar's rename follows.
    func rename(row: SpacesMobileWorkspaceRuntimeRow, to newTitle: String) async {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != row.title, let target = renameTarget(for: row) else { return }
        await performWorkspaceMutation {
            switch target {
            case .terminalSession(let sessionID):
                return try await bridgeClient.renameTerminalSession(
                    workspaceID: row.workspaceID, sessionID: sessionID, title: title, commandChannel: commandChannel)
            case .workspaceConfig(let entry):
                let currentOverview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
                guard let config = currentOverview.workspaces.first(where: { $0.id == row.workspaceID })?.config else {
                    throw SpacesDeviceAPIClientError.requestFailed("This workspace is no longer available.")
                }
                return try await bridgeClient.updateWorkspaceConfig(
                    workspaceID: row.workspaceID, config: try renamedConfig(config, entry: entry, to: title), commandChannel: commandChannel)
            }
        }
    }

    private func renameTarget(for row: SpacesMobileWorkspaceRuntimeRow) -> RuntimeRowRename? {
        switch row.source {
        case .terminal(let terminal):
            guard let sessionID = terminal.sessionID else { return nil }
            return .terminalSession(sessionID: sessionID)
        case .process(let process):
            guard let config = workspaceConfig(for: row.workspaceID), let templateID = process.templateID,
                config.processes.contains(where: { $0.id == templateID })
            else { return nil }
            return .workspaceConfig(entry: .process(id: templateID))
        case .codingAgent(let agent):
            guard let config = workspaceConfig(for: row.workspaceID), let launcherID = agent.launcherID,
                config.agentLaunchers.contains(where: { $0.id == launcherID })
            else { return nil }
            return .workspaceConfig(entry: .agentLauncher(id: launcherID))
        case .browserSession(let browser):
            // Configured browser sessions carry no id, but the daemon requires their names to be present and
            // unique within the workspace, and resolution preserves the configured name, so the name is the
            // entry's identity — the URL is not, since resolution expands environment variables in it.
            guard let config = workspaceConfig(for: row.workspaceID), let name = browser.route.sessionName,
                config.browserSessions.contains(where: { $0.name == name })
            else { return nil }
            return .workspaceConfig(entry: .browserSession(name: name))
        }
    }

    /// A copy of `config` with one entry renamed. Config fields are immutable and the daemon replaces the
    /// workspace's whole config, so a rename echoes every other field back unchanged.
    private func renamedConfig(_ config: SpacesDeviceWorkspaceConfig, entry: RuntimeRowRename.ConfigEntry, to name: String) throws
        -> SpacesDeviceWorkspaceConfig
    {
        var processes = config.processes
        var agentLaunchers = config.agentLaunchers
        var browserSessions = config.browserSessions
        switch entry {
        case .process(let id):
            guard let index = processes.firstIndex(where: { $0.id == id }) else {
                throw SpacesDeviceAPIClientError.requestFailed("This process is no longer configured.")
            }
            let process = processes[index]
            processes[index] = SpacesDeviceProcessTemplate(
                id: process.id, name: name, command: process.command, kind: process.kind, onExit: process.onExit)
        case .agentLauncher(let id):
            guard let index = agentLaunchers.firstIndex(where: { $0.id == id }) else {
                throw SpacesDeviceAPIClientError.requestFailed("This coding agent is no longer configured.")
            }
            let launcher = agentLaunchers[index]
            agentLaunchers[index] = SpacesDeviceAgentLauncher(id: launcher.id, name: name, command: launcher.command)
        case .browserSession(let currentName):
            guard let index = browserSessions.firstIndex(where: { $0.name == currentName }) else {
                throw SpacesDeviceAPIClientError.requestFailed("This browser session is no longer configured.")
            }
            browserSessions[index] = SpacesDeviceBrowserSession(name: name, url: browserSessions[index].url)
        }
        return SpacesDeviceWorkspaceConfig(
            stopScript: config.stopScript, ports: config.ports, processes: processes, browserSessions: browserSessions,
            resolvedBrowserSessions: config.resolvedBrowserSessions, agentLaunchers: agentLaunchers)
    }

    private func workspaceConfig(for workspaceID: String) -> SpacesDeviceWorkspaceConfig? {
        overview?.workspaces.first { $0.id == workspaceID }?.config
    }

    private func groupSort(_ lhs: SpacesMobileTerminalWorkspaceGroup, _ rhs: SpacesMobileTerminalWorkspaceGroup) -> Bool {
        if lhs.projectName.localizedStandardCompare(rhs.projectName) != .orderedSame {
            return lhs.projectName.localizedStandardCompare(rhs.projectName) == .orderedAscending
        }
        return lhs.workspaceTitle.localizedStandardCompare(rhs.workspaceTitle) == .orderedAscending
    }

    private func sessionSort(_ lhs: SpacesDeviceTerminalSessionSummary, _ rhs: SpacesDeviceTerminalSessionSummary) -> Bool {
        if lhs.state != rhs.state { return lhs.state == .running && rhs.state != .running }
        if lhs.title.localizedStandardCompare(rhs.title) != .orderedSame { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
        return lhs.createdAt < rhs.createdAt
    }

    /// Runtime rows group by family in the same order the Mac sidebar uses: browser sessions, configured
    /// processes, coding agents, then ad hoc terminals.
    private func workspaceRuntimeRows(for workspace: SpacesDeviceWorkspaceSummary) -> [SpacesMobileWorkspaceRuntimeRow] {
        let browserRoutes = SpacesDeviceBrowserSessionRoute.routes(
            resolvedBrowserSessions: workspace.config.resolvedBrowserSessions, assignedPorts: workspace.assignedPorts)
        return browserRoutes.enumerated().map { index, route in
            .init(source: .browserSession(SpacesMobileBrowserSessionRow(workspaceID: workspace.id, index: index, route: route)))
        } + workspace.processRows.map { .init(source: .process($0)) } + workspace.codingAgentRows.map { .init(source: .codingAgent($0)) }
            + workspace.terminalRows.map { .init(source: .terminal($0)) }
    }

    private func rowMatchesFilters(_ row: SpacesMobileWorkspaceRuntimeRow, workspace: SpacesDeviceWorkspaceSummary, query: String) -> Bool {
        guard visibleRowTypes.contains(row.type) else { return false }
        // Browser session rows carry no run state (see `SpacesMobileWorkspaceRuntimeRow.runState`), so
        // the run-state filter only applies to rows that actually have one.
        if !row.isBrowserSession { guard visibleRunStates.contains(row.runState) else { return false } }
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
            id: sessionID, title: row.title, workingDirectory: row.workingDirectory, shell: "", command: nil,
            state: terminalSessionState(for: row.runState), backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 0, childPID: nil,
            workspaceID: row.workspaceID, workspaceTitle: workspace?.displayName, projectID: workspace?.projectID,
            projectName: workspace?.projectName, createdAt: timestamp, updatedAt: timestamp, isControlAvailable: row.runState == .running,
            isSubscriptionAvailable: row.runState == .running, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .liveSession,
            rowSourceID: row.id, hasFinalRender: false)
    }

    private func terminalSessionState(for runState: SpacesDeviceRunState) -> TerminalSessionState {
        switch runState {
        case .notStarted: .starting
        case .running: .running
        case .exited: .exited
        }
    }

    private func performMutationReturningSession(
        fallbackRowID: String? = nil, timeoutRecovery: SpacesMobileMutationTimeoutRecovery = .acceptCachedOverview,
        _ operation: () async throws -> SpacesDeviceAPIResponse
    ) async -> SpacesDeviceTerminalSessionSummary? {
        guard !isMutating else { return nil }
        isMutating = true
        defer { isMutating = false }
        let identity = overviewIdentity
        do {
            let response = try await operation()
            await applyMutationResponse(response, identity: identity)
            // The connection changed while the mutation was in flight: the published overview belongs to
            // the previous backend, so resolving a session from it would hand back the wrong device's row.
            guard identity == overviewIdentity else { return nil }
            if let sessionID = response.sessionID { return overview?.sessions.first(where: { $0.id == sessionID }) }
            if let fallbackRowID { return refreshedSession(forRowID: fallbackRowID) }
            return nil
        } catch {
            guard identity == overviewIdentity else { return nil }
            if let fallbackRowID, isMutationTimeout(error),
                let session = await reconciledSessionAfterMutationTimeout(rowID: fallbackRowID, timeoutRecovery: timeoutRecovery, identity: identity)
            {
                return session
            }
            guard identity == overviewIdentity else { return nil }
            handleBridgeError(error)
            return nil
        }
    }

    /// Publishes a mutation's refreshed overview, but only while the connection it was issued against is
    /// still active. `identity` is captured before the mutation's await; a device switch, removal, auth
    /// reset, or Demo Mode toggle bumps `overviewIdentity`, so a mutation that lands after one of those
    /// must not overwrite the new connection's state with the previous backend's overview.
    private func applyMutationResponse(_ response: SpacesDeviceAPIResponse, identity: Int) async {
        guard let overview = response.overview, identity == overviewIdentity else { return }
        await updateBrowserRoutes(overview: overview)
        guard identity == overviewIdentity else { return }
        self.overview = overview
        connectionNotice = nil
        errorMessage = nil
        // A mutation's refreshed overview is proof the device answered, so it ends any run of failed
        // refreshes exactly as a successful poll does. Otherwise a run interrupted by a successful
        // mutation keeps its original start time, and the next isolated failure alerts on the strength
        // of an outage that demonstrably ended.
        refreshFailureStreak = nil
    }

    private func handleBridgeError(_ error: Error) {
        if error is CancellationError { return }
        if let recoveryMessage = SpacesDeviceAPIAuthentication.recoveryMessage(for: error) {
            handleAuthenticationFailure(message: recoveryMessage)
            return
        }
        errorMessage = error.localizedDescription
    }

    private func reconciledSessionAfterMutationTimeout(rowID: String, timeoutRecovery: SpacesMobileMutationTimeoutRecovery, identity: Int) async
        -> SpacesDeviceTerminalSessionSummary?
    {
        if timeoutRecovery.acceptsCachedOverview, let session = refreshedSession(forRowID: rowID) {
            errorMessage = nil
            connectionNotice = nil
            return session
        }
        do {
            let refreshedOverview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
            // The connection changed while reconciling: this overview is the previous backend's, so it must
            // not be published as the current connection's state.
            guard identity == overviewIdentity else { return nil }
            await updateBrowserRoutes(overview: refreshedOverview)
            guard identity == overviewIdentity else { return nil }
            overview = refreshedOverview
            errorMessage = nil
            connectionNotice = nil
            refreshFailureStreak = nil
            return timeoutRecovery.acceptsFreshSession(refreshedSession(forRowID: rowID))
        } catch { return nil }
    }

    private func isMutationTimeout(_ error: Error) -> Bool {
        switch error {
        case SpacesDeviceAPIClientError.requestTimedOut: return true
        case SpacesDeviceAPIClientError.requestFailed(let message, _), SpacesDeviceAPIClientError.streamFailed(let message, _):
            return message.localizedStandardContains("timed out")
        default: return false
        }
    }
}

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

        if let host = trimmed(environment["SPACES_MOBILE_TEST_HOST"]) { resolved.hosts = [host] }
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
    case automations
    case settings
}

/// A band of terminal sessions that belong to a workspace but are not among its runtime rows, listed
/// after the projects on the Spaces tab.
struct SpacesMobileTerminalWorkspaceGroup: Identifiable {
    let workspaceID: String
    let projectName: String
    let workspaceTitle: String
    let workspaceDirectory: String
    let sessions: [SpacesDeviceTerminalSessionSummary]

    /// Deliberately not the workspace id. A workspace with loose sessions is listed twice on the Spaces
    /// tab — once as its own band among the projects, once as this band — and both rows live in the same
    /// list section, so identifying this one by the workspace id would give two different rows the same
    /// identity. The list then diffs a state with fewer distinct identities than it has rows, and every
    /// batch update it performs is one item short of the count its data source reports, which is an
    /// inconsistent update and crashes the collection view.
    var id: String { "loose:\(workspaceID)" }
}

enum SpacesMobileWorkspaceRowType: String, Hashable {
    case processes
    case codingAgents
    case workspaceTerminals
    case browserSessions

    var iconName: String {
        switch self {
        case .processes: "terminal"
        case .codingAgents: "cpu"
        case .workspaceTerminals: "terminal.fill"
        case .browserSessions: "globe"
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

    /// The row's secondary text, matching the Mac sidebar: a process row shows what it runs, a coding
    /// agent shows its terminal's detail text, an ad hoc shell shows the title its program reported
    /// (nothing until it reports one).
    var detail: String {
        switch source {
        case .process, .codingAgent: command
        case .terminal(let row): row.liveTitle ?? ""
        case .browserSession(let row): row.detail
        }
    }

    /// What this row runs. Only configured processes are launched from a row; a coding agent's command
    /// is the display text behind `detail`, an ad hoc shell already exists, and a browser session opens
    /// a URL, so the rest have none.
    var command: String {
        switch source {
        case .process(let row): row.command
        case .codingAgent(let row): row.command
        case .terminal, .browserSession: ""
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

    /// Only a configured process can be started from a row: a coding agent exists only as a live
    /// session the user started by running its command in a terminal.
    var canRun: Bool {
        switch source {
        case .process(let row): row.canRun
        case .codingAgent: false
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
        case .codingAgent: false
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
        case .codingAgent: false
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
    /// In flight for every mutation that rides the shared `commandChannel` — create, rename, hide/unhide,
    /// launch/stop/restart, run — the same connection the overview poll uses. That connection does not
    /// serialize whole request/response round trips (issue #248), so two of these in flight at once can
    /// interleave and consume each other's responses; this flag is the app-wide gate that keeps them one
    /// at a time. `deleteWorkspace` does not set it: a delete runs on its own private channel created for
    /// that one call (see the comment above `deleteChannel`), so it never shares a connection with another
    /// mutation and needs no slot in this queue. A delete's own concurrency rule — refusing a second delete
    /// of the *same* workspace while the first is unresolved — is `isWorkspacePendingDeletion` instead, so
    /// one workspace's delete never blocks a mutation, including another delete, on a different one (#450).
    var isMutating = false
    /// True while a requested daemon update has been sent and this app is polling the device for the
    /// update to land (see `requestDaemonUpdate()`). Kept separate from `isMutating`: that flag gates
    /// one-shot mutations and is released as soon as their single RPC returns, but the update poll runs
    /// for up to `daemonUpdateTimeout`, and holding `isMutating` for that whole window would freeze
    /// every other mutating control in the app. Only the Update Daemon actions read this flag, and it
    /// covers an apply this app started on its own the same way it covers one the user asked for.
    var isApplyingDaemonUpdate = false
    /// The one thing the automatic staged-apply flow ever reports: the device is still running its old
    /// build some time after this app asked it to apply the one installed on it. `nil` whenever there is
    /// nothing to report, which is every other moment of that flow — a staged update that lands is shown
    /// nowhere, because the device passes through the ordinary reconnect and comes back.
    var stagedApplyDidNotLandAlert: StagedApplyDidNotLandAlert?
    /// Attempts whose apply the device did not report as landed within the poll's budget. Gates the
    /// blocked device's hero and its Try Again (see `stagedApplyDidNotLand`), and is retired the moment
    /// the device's own facts stop justifying it.
    private var stagedApplyDidNotLandAttempts: Set<DaemonStagedApplyAttempt> = []
    var isShowingConnectionSettings = false
    var isShowingWorkspaceCreateSheet = false
    var connectionNotice: String?
    var pendingPairingLink: SpacesDevicePairingLink?
    /// A terminal session a `spaces://terminal/…` deep link asks to focus. The Spaces tab observes
    /// this, pushes the session's detail route, and clears it. Model-driven (rather than a tab-local
    /// binding) so a link handled at the app shell can navigate whichever tab is on screen.
    var pendingTerminalDeepLinkSession: SpacesDeviceTerminalSessionSummary?
    var errorMessage: String?
    /// The branch-deletion report a completed workspace delete came back with, shown once and cleared.
    /// Only a delete that asked for a branch to be deleted produces one, so a plain delete stays silent.
    var deletedWorkspaceNotice: String?
    var searchText = ""
    var workspaceCreateOptions: SpacesDeviceWorkspaceCreateOptions?
    var selectedTab: SpacesMobileTab = .spaces
    /// Workspaces whose runtime rows are collapsed on the Spaces tab. In-memory only; a fresh
    /// launch starts fully expanded.
    var collapsedWorkspaceIDs: Set<String> = []
    /// Workspaces whose delete mutation is in flight. The daemon takes seconds to stop the workspace and
    /// remove its worktree, and every overview published in that window still lists it, so the Spaces tab
    /// marks the workspace as deleting instead of leaving it looking untouched (see
    /// `isWorkspacePendingDeletion`). In-memory and per-run, like `collapsedWorkspaceIDs`: the device is
    /// authoritative about whether a delete landed, and a relaunch reads it fresh.
    private var workspaceIDsPendingDeletion: Set<String> = []
    /// Deletes whose outcome no overview has been able to confirm yet: the archive's response was lost and
    /// every reconciliation refetch failed too, so nothing has proved whether the workspace is gone. The
    /// row stays marked and the error stays unsurfaced until an overview does get published, which is the
    /// first thing that can answer. In-memory and per-run like `workspaceIDsPendingDeletion`: a relaunch
    /// refetches reality rather than restoring a verdict that was never reached.
    private var workspaceDeletionsAwaitingOverview: [String: DeferredWorkspaceDeletion] = [:]
    /// Tails of this client's per-daemon delete queues, keyed by the `overviewIdentity` snapshot the
    /// delete was issued against: each `deleteWorkspace` call chains its work behind whatever task is
    /// stored under its own key, then replaces that entry with its own, so at most one `archiveWorkspace`
    /// request is ever in flight from this client to a given daemon at a time.
    ///
    /// This exists for a false-failure race, not wire safety — `deleteChannel` already isolates each
    /// delete's own connection. The daemon runs every `archiveWorkspace`/`deleteProject` request off one
    /// serial per-daemon queue and only marks a workspace as tearing down once that request is dequeued
    /// (`workspaceTeardownQueue` / `withTeardownRegistered` on the daemon side). Two such requests issued
    /// back to back from this client can therefore both be waiting on that one queue at once; if the
    /// first is still occupying it past this client's 30s request timeout, the second — still queued,
    /// still unregistered — times out too, and `reconcileWorkspaceDeletionOutcome` sees its workspace
    /// listed with no teardown registered, which reads as a genuine failure. The daemon then dequeues and
    /// deletes it anyway: the row would go back to normal and vanish moments later, having been reported
    /// as a failed delete. Chaining closes the window by construction, since this client never has two
    /// `archiveWorkspace` requests on the same daemon's queue at once to begin with (#450 review round 2).
    ///
    /// Keyed rather than a single tail (#450 review round 3): daemons are independent, each with its own
    /// teardown queue, so a delete against device B has no business waiting out a delete against device
    /// A's still-running reconciliation. `overviewIdentity` already is this model's notion of "which
    /// connection a caller was talking to when it started," bumped on every device switch and reused
    /// as-is here rather than introducing a second one; it is not quite "device" (switching away from and
    /// back to the same device mid-delete mints two different keys for what is really one daemon), but
    /// that narrower case is a rarer version of the same residual race already accepted below, not a new
    /// one this keying introduces.
    ///
    /// A chain's own entry is not removed once its task completes — the dictionary is small (one entry
    /// per device switch this run, not per delete) and, like `workspaceIDsPendingDeletion`, is in-memory
    /// and per-run.
    ///
    /// Release on `.unknown`, and the residual race that leaves open: when a timed-out delete's
    /// reconciliation (see `reconcileWorkspaceDeletionOutcome`) lands on `.unknown` — the daemon still
    /// working, no verdict reached — this chain's task for it completes anyway, releasing the next queued
    /// delete to send its own request even though the first workspace's teardown may still be occupying
    /// the daemon's queue. A successor queued behind it can then hit the identical false-failure shape
    /// this chain otherwise closes. This is deliberate, not an oversight: waiting the successor out until
    /// the deferred delete resolves (`workspaceDeletionsAwaitingOverview`, itself unbounded) would block
    /// every later delete on this daemon for as long as the daemon takes, which is worse than the race it
    /// would close. The window it leaves needs a single teardown to run past two stacked 30s request
    /// timeouts — one client-side hop over 60s wall-clock — plus a second delete queued right behind the
    /// first, and even then it converges on its own: the workspace's teardown finishes either way, and the
    /// row's false failure report corrects itself the moment the next overview stops listing it. It is the
    /// same shape the daemon-side `withTeardownRegistered` comment already accepts for a delete issued
    /// from a *different* client — no client can exclude another from its daemon's one queue either — just
    /// reachable here from this client's own queued successor instead of a stranger's.
    @ObservationIgnored private var pendingDeleteChains: [Int: Task<Void, Never>] = [:]
    /// Attention events the user dismissed on the active device, one at a time or with Clear. Identities
    /// are stable per source+kind+date, so a dismissed event stays dismissed until its source changes
    /// state again. Persisted per device via `SpacesMobileDismissedAlertsStore` and pruned against that
    /// device's overview on every refresh; reloaded from the newly active device's bucket whenever
    /// `activeDeviceID` changes, so this always describes the device whose overview is being published.
    var dismissedAlertIDs: Set<String> = []
    /// The session whose terminal detail is on screen, or nil when no terminal detail is open. Set by
    /// the terminal navigation flow as its selected session changes. Having the route open is not the
    /// same as watching it — see `watchedTerminalSessionID`.
    private(set) var activeTerminalSessionID: String?
    /// When the current watch of `activeTerminalSessionID` began, or nil when nothing is being watched.
    /// A watch runs while the detail route is open *and* the app is in the foreground: the route alone
    /// says nothing about whether the user can see it.
    @ObservationIgnored private var activeTerminalWatchStartedAt: Date?
    /// The session the user is actually looking at, which is what bell suppression keys on.
    var watchedTerminalSessionID: String? { activeTerminalWatchStartedAt == nil ? nil : activeTerminalSessionID }
    /// The user's recent watches of each recently watched session's terminal detail, oldest first.
    /// Overview polling is paused while a detail is open, so a bell rung during a watch is only seen
    /// after it ends; these windows suppress it then. In-memory only, like `dismissedAlertIDs`.
    ///
    /// A list rather than one window per session because a single visit to a terminal produces several:
    /// backgrounding the app ends one and returning starts the next, and the bell rung before the app
    /// went away is only seen after the user finally leaves the detail — by which time a
    /// keep-the-latest-only rule would have dropped the window that covers it. The windows are
    /// deliberately never merged: the gap between them is the stretch the user could not see, and
    /// closing it would re-suppress exactly the bells this is meant to surface.
    private(set) var terminalWatchWindowsBySessionID: [String: [SpacesMobileTerminalWatchWindow]] = [:]
    /// Upper bound on remembered watch windows per session. Each window only has to survive from its
    /// watch ending to the next overview refresh, so a handful covers even repeated backgrounding within
    /// one visit; past the bound the oldest window is dropped.
    private static let maxRememberedWatchesPerSession = 8
    /// Upper bound on sessions with remembered watches, dropping the one whose watching ended longest
    /// ago, so rapid session hopping cannot grow the map without bound.
    private static let maxRememberedWatchedSessions = 16
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
    /// Bumped every time a mutation's result is applied. A poll's overview is a snapshot of the moment its
    /// fetch was issued, so one that started before a mutation and lands after it carries pre-mutation
    /// state: publishing it would put a deleted workspace, or a stopped process, back on screen as an
    /// ordinary actionable row until the next poll two seconds later. A refresh captures this value when
    /// its fetch begins and discards its result if it moved — the same discard-don't-publish rule
    /// `overviewIdentity` applies to connection changes, for staleness in time rather than in connection.
    @ObservationIgnored private var mutationGeneration = 0
    /// When the current run of failed overview fetches began, gating the connection-error alert (see
    /// `refreshFailureAlertDelay`). Tagged with the connection identity it was gathered against, so any
    /// change of connection restarts the run without every reset site having to clear it. `nil` once a
    /// refresh succeeds.
    @ObservationIgnored private var refreshFailureStreak: (identity: Int, startedAt: ContinuousClock.Instant)?
    /// Bumped every time the app stops watching this connection (see `noteConnectionMonitoringPaused`).
    /// A refresh attempt captures it at the start and records nothing about failure timing if it changed,
    /// because an attempt spanning a pause has no meaningful duration: the clock keeps advancing while
    /// the app is suspended or idle, so most of what it measured is time nothing was being watched.
    @ObservationIgnored private var connectionMonitoringGeneration = 0
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
    /// Staged applies this app fired on its own, one per (device, staged build) per app run, so a status
    /// the device keeps reporting every couple of seconds cannot re-request a handoff already on its way.
    /// Try Again deliberately bypasses this: the user asking again is new information.
    @ObservationIgnored private var autoStagedApplyAttempts: Set<DaemonStagedApplyAttempt> = []
    /// How long overview fetches must keep failing before the connection-error alert is raised (production
    /// default 5s). Long enough to cover a blip and the poll's retry two seconds later, short enough that
    /// a device that is actually unreachable is reported promptly. Injectable so tests can shrink it
    /// instead of sleeping through the production wait.
    @ObservationIgnored private let refreshFailureAlertDelay: Duration
    /// Wait between the overview refetches that reconcile an indeterminate workspace delete (production
    /// default 2s, matching the ordinary poll cadence). Injectable so tests exercise the reconciliation
    /// loop without sleeping through it.
    @ObservationIgnored private let workspaceDeletionReconciliationInterval: Duration
    /// Source of "now" for the refresh-failure streak's start time and elapsed-time check. The streak is
    /// pure bookkeeping against a clock — no real waiting happens between reading it twice — so tests
    /// inject a fake that advances on command instead of sleeping past `refreshFailureAlertDelay` in
    /// real time. Production always uses the real clock.
    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant
    /// Wall-clock source for terminal watch windows, which are compared against daemon-stamped bell
    /// timestamps and so cannot use the monotonic clock above. Tests inject a fake to place a bell inside
    /// or outside a watch window exactly, instead of racing the real clock's sub-millisecond gaps against
    /// the comparison's skew tolerance. Production always uses the real clock.
    @ObservationIgnored private let wallClock: @Sendable () -> Date

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
        workspaceDeletionReconciliationInterval = .seconds(2)
        now = { ContinuousClock.now }
        wallClock = { Date() }
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
            loadDismissedAlertIDsForActiveDevice()
            return
        }

        let bridgeClient = SpacesDeviceAPIClient(settings: deviceState.settings, deviceName: deviceName)
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        isDemoModeEnabled = false
        self.bridgeClient = bridgeClient
        commandChannel = bridgeClient.makeCommandChannel()
        loadDismissedAlertIDsForActiveDevice()
        pruneDismissedAlertsForUnknownDevices()
    }

    init(
        settings: SpacesMobileConnectionSettings, bridgeClient: SpacesDeviceAPIClient, browserProxy: SpacesMobileBrowserProxy? = nil,
        daemonUpdatePollInterval: Duration = .seconds(3), daemonUpdateTimeout: Duration = .seconds(30),
        refreshFailureAlertDelay: Duration = .seconds(5), workspaceDeletionReconciliationInterval: Duration = .seconds(2),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }, wallClock: @escaping @Sendable () -> Date = { Date() }
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
        self.workspaceDeletionReconciliationInterval = workspaceDeletionReconciliationInterval
        self.now = now
        self.wallClock = wallClock
    }

    /// The workspaces this client lists: neither archived, hidden, nor under a hidden project, matching
    /// the Mac sidebar's `isVisibleWorkspace` rule. See `SpacesDeviceOverviewPayload.isWorkspaceVisible`
    /// for the shared rule every visible-surface filter (this, `terminalGroups`, the Agents tab, the
    /// Alerts tab) applies.
    private var visibleWorkspaces: [SpacesDeviceWorkspaceSummary] {
        guard let overview else { return [] }
        return overview.workspaces.filter { overview.isWorkspaceVisible($0) }
    }

    /// The Workspaces sheet's project -> workspace outline for the active device, filtered by the sheet's
    /// own query. Built from the same shared tree the Mac's Workspaces dialog builds, so both clients list
    /// the same rows, counts, and dimming. Unlike every other list here it reads the raw overview rather
    /// than `visibleWorkspaces`: it is the surface hidden rows are recovered from, so it must list them.
    func workspaceVisibilityProjects(query: String) -> [WorkspaceVisibilityProjectNode] {
        guard let overview else { return [] }
        return WorkspaceVisibilityTree.projectNodes(overview: overview, query: query)
    }

    var workspaceGroups: [SpacesMobileWorkspaceGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleWorkspaces.map { SpacesMobileWorkspaceGroup(workspace: $0, rows: workspaceRuntimeRows(for: $0)) } }
        return visibleWorkspaces.compactMap { workspace in
            // A workspace whose own name, project, or directory matches keeps all of its rows: the user
            // asked for the workspace, not for a subset of what runs in it. Otherwise it survives only as
            // the band over its own matching rows.
            let rows = workspaceRuntimeRows(for: workspace)
            if workspaceMatchesSearch(workspace, query: query) { return SpacesMobileWorkspaceGroup(workspace: workspace, rows: rows) }
            let matchingRows = rows.filter { rowMatchesSearch($0, workspace: workspace, query: query) }
            guard !matchingRows.isEmpty else { return nil }
            return SpacesMobileWorkspaceGroup(workspace: workspace, rows: matchingRows)
        }
    }

    var terminalGroups: [SpacesMobileTerminalWorkspaceGroup] {
        let workspaces = visibleWorkspaces
        let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let representedSessionIDs = Set(workspaces.flatMap { workspaceRuntimeRows(for: $0).compactMap(\.sessionID) })
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A loose group is a band belonging to a workspace this list is showing, so only that workspace's
        // sessions can form one. That drops a hidden workspace's sessions — hidden by its own flag or by
        // its project's, `visibleWorkspaces` makes no distinction — (otherwise hiding it would just move
        // its terminals into a loose group instead of removing them from the list) and sessions whose
        // workspace record the overview no longer carries at all — a deleted workspace's ended sessions
        // linger for a refresh or two, and they must not raise a band named for a workspace that no longer
        // exists beside the band being removed.
        let sessions = (overview?.sessions ?? []).filter { session in
            workspaceByID[session.workspaceID] != nil && !representedSessionIDs.contains(session.id)
                && terminalSessionMatchesSearch(session, query: query)
        }
        let grouped = Dictionary(grouping: sessions) { $0.workspaceID }

        return grouped.values.compactMap { sessions -> SpacesMobileTerminalWorkspaceGroup? in
            // Both lookups hold by construction: the group's key came from a session that passed the
            // `workspaceByID` filter above.
            guard let firstSession = sessions.first, let workspace = workspaceByID[firstSession.workspaceID] else { return nil }
            return SpacesMobileTerminalWorkspaceGroup(
                workspaceID: workspace.id, projectName: workspace.projectName, workspaceTitle: workspace.displayName,
                workspaceDirectory: workspace.dir, sessions: sessions.sorted(by: sessionSort))
        }.sorted(by: groupSort)
    }

    /// Attention-event groups for the Alerts tab, derived client-side from the overview payload
    /// with the user's cleared events filtered out.
    var attentionGroups: [SpacesMobileAttentionGroup] {
        guard let overview else { return [] }
        return SpacesMobileAttention.groups(
            in: overview, dismissedEventIDs: dismissedAlertIDs, focusedSessionID: watchedTerminalSessionID,
            watchWindowsBySessionID: terminalWatchWindowsBySessionID)
    }

    /// Points bell suppression at the terminal detail now on screen, or nil once none is. Leaving a
    /// detail (closing it, or switching straight to another session) closes the outgoing session's watch
    /// window, so the bell it rang while the user was watching does not alert once polling resumes.
    func setActiveTerminalSession(_ sessionID: String?) {
        guard sessionID != activeTerminalSessionID else { return }
        endActiveTerminalWatch()
        activeTerminalSessionID = sessionID
        if sessionID != nil { activeTerminalWatchStartedAt = wallClock() }
    }

    /// Ends the watch when the app leaves the foreground. The detail route survives backgrounding
    /// untouched, so without this the app would keep counting a session the user cannot see as watched
    /// and swallow the bells it rang while away.
    func suspendTerminalWatch() { endActiveTerminalWatch() }

    /// Ends the watch on `sessionID` because its terminal detail left the screen — including the ways that
    /// never route through `setActiveTerminalSession`, such as a device switch tearing the whole
    /// navigation stack down. A no-op unless that session is still the one being watched, so a teardown
    /// arriving after another session's detail has taken over leaves the new watch alone, and the ordinary
    /// back-out (which ends the watch through `setActiveTerminalSession(nil)` first) records one window
    /// rather than two.
    func endTerminalWatch(forSessionID sessionID: String) {
        guard activeTerminalSessionID == sessionID else { return }
        setActiveTerminalSession(nil)
    }

    /// Resumes watching the still-open detail route on return to the foreground. The new watch starts
    /// now, so the stretch spent in the background stays outside every recorded window and a bell rung
    /// in it alerts.
    func resumeTerminalWatch() {
        guard activeTerminalSessionID != nil, activeTerminalWatchStartedAt == nil else { return }
        activeTerminalWatchStartedAt = wallClock()
    }

    private func endActiveTerminalWatch() {
        guard let sessionID = activeTerminalSessionID, let startedAt = activeTerminalWatchStartedAt else { return }
        activeTerminalWatchStartedAt = nil
        var windows = terminalWatchWindowsBySessionID[sessionID] ?? []
        windows.append(SpacesMobileTerminalWatchWindow(startedAt: startedAt, endedAt: wallClock()))
        if windows.count > Self.maxRememberedWatchesPerSession { windows.removeFirst(windows.count - Self.maxRememberedWatchesPerSession) }
        terminalWatchWindowsBySessionID[sessionID] = windows
        if terminalWatchWindowsBySessionID.count > Self.maxRememberedWatchedSessions,
            let stalest = terminalWatchWindowsBySessionID.min(by: {
                ($0.value.last?.endedAt ?? .distantPast) < ($1.value.last?.endedAt ?? .distantPast)
            })?.key
        {
            terminalWatchWindowsBySessionID.removeValue(forKey: stalest)
        }
    }

    /// Failed/timed-out automation-run alert entries for the Alerts tab, with cleared entries filtered
    /// out. Automation runs are workspace-less, so these are derived and rendered separately from
    /// `attentionGroups` — see `SpacesMobileAutomationAlerts`.
    var automationAlerts: [SpacesMobileAutomationAlertEntry] {
        guard let overview else { return [] }
        return SpacesMobileAutomationAlerts.entries(runs: overview.automationRuns).filter { !dismissedAlertIDs.contains($0.id) }
    }

    /// Undismissed attention-event count, shown as the Alerts tab badge.
    var undismissedAlertCount: Int { attentionGroups.reduce(0) { $0 + $1.events.count } + automationAlerts.count }

    /// Marks every currently derived attention event dismissed.
    func clearAlerts() {
        guard let overview else { return }
        dismissedAlertIDs.formUnion(
            SpacesMobileAttention.events(
                in: overview, focusedSessionID: watchedTerminalSessionID, watchWindowsBySessionID: terminalWatchWindowsBySessionID
            ).map(\.id))
        dismissedAlertIDs.formUnion(SpacesMobileAutomationAlerts.entries(runs: overview.automationRuns).map(\.id))
        saveDismissedAlertIDs()
    }

    /// Dismisses one attention event, leaving the rest of its band in place.
    func dismissAlert(_ event: SpacesMobileAttentionEvent) {
        dismissedAlertIDs.insert(event.id)
        saveDismissedAlertIDs()
    }

    /// `row`'s own currently undismissed attention events — its exited/waiting/finished event (if any)
    /// plus any bell on its session — derived via the same focus/watch-window bell suppression the Alerts
    /// tab uses (`SpacesMobileAttention.events`), so a bell rung while its terminal viewer was open or
    /// inside a watch window never offers "Dismiss Alert" for something the user already saw live. Hidden
    /// workspaces stay included: that filter only serves the Alerts tab's band grouping, not row-level
    /// dismissal. Backs both the row's "Dismiss Alert" menu item's visibility and what it dismisses.
    func undismissedAlerts(for row: SpacesMobileWorkspaceRuntimeRow) -> [SpacesMobileAttentionEvent] {
        guard let overview else { return [] }
        return SpacesMobileAttention.events(
            in: overview, focusedSessionID: watchedTerminalSessionID, watchWindowsBySessionID: terminalWatchWindowsBySessionID,
            includingHiddenWorkspaces: true
        ).filter { row.matches($0) && !dismissedAlertIDs.contains($0.id) }
    }

    /// Whether `row` has anything its long-press "Dismiss Alert" menu item could dismiss.
    func hasUndismissedAlerts(for row: SpacesMobileWorkspaceRuntimeRow) -> Bool { !undismissedAlerts(for: row).isEmpty }

    /// Dismisses every one of `row`'s currently undismissed attention events in one action — identical in
    /// effect to dismissing each individually from the Alerts tab: same `dismissedAlertIDs`, same badge.
    func dismissAlerts(for row: SpacesMobileWorkspaceRuntimeRow) {
        let events = undismissedAlerts(for: row)
        guard !events.isEmpty else { return }
        dismissedAlertIDs.formUnion(events.map(\.id))
        saveDismissedAlertIDs()
    }

    /// Whether `row`'s own exited-process event, if it has one right now, is already dismissed — the
    /// signal that turns its dot from failed red to the unstarted stroke (see
    /// `SpacesMobileWorkspaceRuntimeRow.statusDotKind(exitAcknowledged:)`). Only a `.process` row can have
    /// one: every other row family's dot keeps tracking live state regardless of dismissal.
    func isExitAcknowledged(_ row: SpacesMobileWorkspaceRuntimeRow) -> Bool {
        guard case .process = row.source, let overview else { return false }
        guard let event = SpacesMobileAttention.allEvents(in: overview).first(where: { row.matches($0) && $0.kind == .exited }) else { return false }
        return dismissedAlertIDs.contains(event.id)
    }

    /// Dismisses one failed/timed-out automation run, leaving the rest of the Automations band in place.
    func dismissAutomationAlert(_ entry: SpacesMobileAutomationAlertEntry) {
        dismissedAlertIDs.insert(entry.id)
        saveDismissedAlertIDs()
    }

    /// Drops stored dismissals whose event this overview no longer produces, so the persisted set stays
    /// bounded by what the device currently reports rather than growing for the life of the install.
    private func pruneDismissedAlertIDs(against overview: SpacesDeviceOverviewPayload) {
        // Automation-run alerts share the dismissal set but derive from `automationRuns`, not attention
        // events, so retain their dismissals separately or a prune would resurface dismissed run alerts.
        let retained = SpacesMobileAttention.retainedDismissedEventIDs(dismissedAlertIDs, in: overview).union(
            dismissedAlertIDs.intersection(Set(SpacesMobileAutomationAlerts.entries(runs: overview.automationRuns).map(\.id))))
        guard retained != dismissedAlertIDs else { return }
        dismissedAlertIDs = retained
        saveDismissedAlertIDs()
    }

    /// Loads the persisted dismissal bucket for `activeDeviceID` into the in-memory set, discarding
    /// whatever the previous active device's bucket held. Called at every chokepoint that changes the
    /// active device — init, a device switch or removal, and Demo Mode enable/disable — so
    /// `dismissedAlertIDs` always belongs to the device whose overview is about to be published, never a
    /// leftover from the connection this model just switched away from.
    private func loadDismissedAlertIDsForActiveDevice() {
        dismissedAlertIDs = activeDeviceID.map { SpacesMobileDismissedAlertsStore.load(deviceID: $0) } ?? []
        // Unconfirmed deletes belong to the connection they were issued against: another device's overview
        // cannot answer whether this one's workspace was deleted, and leaving an entry behind would let the
        // next published overview resolve it against the wrong device. Dropped with the marking, silently —
        // the delete may well have landed, and there is no longer anyone to report a verdict to.
        workspaceDeletionsAwaitingOverview.removeAll()
        workspaceIDsPendingDeletion.removeAll()
    }

    /// Persists `dismissedAlertIDs` into the active device's bucket. A `nil` `activeDeviceID` (no device
    /// selected yet) has nothing to attribute the dismissals to, so it's a no-op rather than a shared
    /// bucket that would leak across whichever device pairs first.
    private func saveDismissedAlertIDs() {
        guard let activeDeviceID else { return }
        SpacesMobileDismissedAlertsStore.save(dismissedAlertIDs, deviceID: activeDeviceID)
    }

    /// Drops persisted dismissal buckets for devices no longer known: the paired devices plus the demo
    /// device, which always keeps its own bucket since Demo Mode is available regardless of pairing
    /// state. Skipped while Demo Mode is on, because `pairedDevices` is swapped down to just the
    /// synthetic Demo Mac then — running this against that narrowed list would read as every real device
    /// having been unpaired and wipe their dismissals. That leaves the real buckets untouched by a Demo
    /// Mode round trip and prunes only when `pairedDevices` genuinely reflects the paired list.
    private func pruneDismissedAlertsForUnknownDevices() {
        guard !isDemoModeEnabled else { return }
        SpacesMobileDismissedAlertsStore.retainDevices(Set(pairedDevices.map(\.id)).union([SpacesMobileDemoDevice.id]))
    }

    /// Coding-agent rows across all workspaces grouped by activity for the Agents tab.
    var agentGroups: [SpacesMobileAgentGroup] {
        guard let overview else { return [] }
        return SpacesMobileAgentGrouping.groups(in: overview)
    }

    /// Automation rows for the Automations tab, derived from the active device's overview.
    var automationRows: [SpacesMobileAutomationRow] {
        guard let overview else { return [] }
        return SpacesMobileAutomations.rows(automations: overview.automations, runs: overview.automationRuns)
    }

    /// Currently-running automation-run count on the active device — the Automations tab's badge.
    /// Failed/timed-out runs already badge Alerts (see `automationAlerts`), so this counts only
    /// in-flight runs, giving the tab a live "something is executing right now" pulse.
    var automationRunningRunCount: Int {
        guard let overview else { return 0 }
        return SpacesMobileAutomations.runningCount(overview.automationRuns)
    }

    /// Manually fires an automation, respecting the daemon's concurrency gate. There is no separate
    /// confirmation or toast for the started/queued/skipped outcome: the automation row's status dot
    /// reflects it once the refreshed overview lands, mirroring how the Mac's Automations pane surfaces
    /// this (a reload, not an optimistic local merge — automation mutation responses carry no overview).
    func triggerAutomation(id: String) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        let identity = overviewIdentity
        do {
            _ = try await bridgeClient.triggerAutomation(id: id, commandChannel: commandChannel)
            guard identity == overviewIdentity else { return }
            await refresh()
        } catch {
            guard identity == overviewIdentity else { return }
            handleBridgeError(error)
        }
    }

    /// Sets a one-time next run for an automation, overriding only its next occurrence. Refreshes the
    /// overview on success exactly like `triggerAutomation`, since the response carries no overview and
    /// the automation's next fire time is what changed.
    ///
    /// Returns nil once the daemon accepts the time, or the rejection text to show. The next-run sheet
    /// prints that beside its picker instead of routing it to the app-wide error banner: the user is
    /// looking at the control that caused it and stays there to correct it.
    func setAutomationNextRun(id: String, nextRunTime: Date) async -> String? {
        // The sheet's Schedule button is already disabled while a mutation is in flight, so reaching this
        // means nothing was sent; reporting it keeps the sheet open rather than closing as though the time
        // had been accepted.
        guard !isMutating else { return "Another action is still in progress." }
        isMutating = true
        defer { isMutating = false }
        let identity = overviewIdentity
        do {
            _ = try await bridgeClient.setAutomationNextRun(id: id, nextRunTime: nextRunTime, commandChannel: commandChannel)
            guard identity == overviewIdentity else { return nil }
            await refresh()
            return nil
        } catch {
            guard identity == overviewIdentity else { return nil }
            return error.localizedDescription
        }
    }

    /// Cancels a running (or queued) automation run.
    func cancelAutomationRun(runID: String) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        let identity = overviewIdentity
        do {
            _ = try await bridgeClient.cancelAutomationRun(runID: runID, commandChannel: commandChannel)
            guard identity == overviewIdentity else { return }
            await refresh()
        } catch {
            guard identity == overviewIdentity else { return }
            handleBridgeError(error)
        }
    }

    /// Ends a finished run's still-live attributed coding agents. There is no optimistic local merge,
    /// mirroring `cancelAutomationRun`: the run row's agent chips reflect the outcome once the refreshed
    /// overview lands.
    func endAutomationAgents(runID: String) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        let identity = overviewIdentity
        do {
            _ = try await bridgeClient.endAutomationAgents(runID: runID, commandChannel: commandChannel)
            guard identity == overviewIdentity else { return }
            await refresh()
        } catch {
            guard identity == overviewIdentity else { return }
            handleBridgeError(error)
        }
    }

    /// Fetches one automation's retained run history directly from the daemon for the per-automation "View
    /// Runs" screen, so it reads the daemon's kept-per-automation rows instead of the overview's global
    /// recent-runs window (which a chatty automation can fill, leaving a quiet automation's history empty).
    /// Returns nil on error, and the caller keeps whatever it was already showing. Not a mutation, so it
    /// does not touch `isMutating` or trigger an overview refresh.
    func fetchAutomationRuns(automationID: String) async -> [TerminalServiceAutomationRunSummary]? {
        let identity = overviewIdentity
        do {
            let runs = try await bridgeClient.listAutomationRuns(automationID: automationID, commandChannel: commandChannel)
            guard identity == overviewIdentity else { return nil }
            return runs
        } catch {
            guard identity == overviewIdentity else { return nil }
            handleBridgeError(error)
            return nil
        }
    }

    /// Whether this workspace's delete is in flight. The Spaces tab dims its band and rows, puts a spinner
    /// where the band's collapse chevron goes, and stops accepting anything on them — the feedback for a
    /// delete the daemon takes seconds to complete.
    ///
    /// The union of the deletes this app issued (`workspaceIDsPendingDeletion`) and the teardowns the
    /// daemon reports running (`workspaceIDsWithTeardownInFlight`), so a delete started on the Mac — or a
    /// project delete taking its workspaces with it — marks the row here too rather than leaving it
    /// looking ordinary and actionable while its worktree is being removed.
    func isWorkspacePendingDeletion(_ workspaceID: String) -> Bool {
        workspaceIDsPendingDeletion.contains(workspaceID) || overview?.workspaceIDsWithTeardownInFlight.contains(workspaceID) == true
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
        return runtimeRow(forSessionID: sessionID).flatMap { terminalSession(for: $0) }
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

    /// What the device screen shows about the active device's daemon version, if anything: nothing, the
    /// quiet pending card, or the hero that replaces the screen. All of the decision lives in
    /// `DaemonCompatibilityPresentation.presentation`, which is pure and unit-tested; this only feeds it
    /// the facts. `nil` status means no handshake has landed yet, which is not a version state at all.
    var daemonCompatibilityPresentation: DaemonCompatibilityPresentation {
        guard let daemonStatus, let daemonUpdateRemedy else { return .none }
        return DaemonCompatibilityPresentation.presentation(
            remedy: daemonUpdateRemedy, status: daemonStatus, isBlocked: isActiveDeviceBlocked, stagedApplyDidNotLand: stagedApplyDidNotLand,
            deviceName: connectionSummary, clientVersion: MobileAppVersion.current)
    }

    var connectionSummary: String {
        if let activeDeviceName { return activeDeviceName }
        return "\(settings.primaryHost):\(settings.port)"
    }

    var activeDeviceName: String? {
        guard let activeDeviceID else { return nil }
        return pairedDevices.first(where: { $0.id == activeDeviceID })?.name
    }

    /// Current bind status of the on-device browser proxy, so the UI can surface a bind failure.
    var browserProxyStatus: BrowserProxyStatus { browserProxy.runtimeState.status }

    /// Starts the loopback browser proxy. Idempotent; call when the app becomes active.
    func browserProxyStart() { Task { await browserProxy.start() } }

    /// Stops the loopback browser proxy and all live tunnels. Call when the app enters the background.
    func browserProxyStop() { Task { await browserProxy.stop() } }

    /// Ends the current run of failed refreshes because the app stopped watching this connection — it
    /// backgrounded, or the overview poll paused (a terminal or browser detail opened, another tab took
    /// over, the device became unpaired). The alert gate reads wall-clock time between failures, and
    /// nothing polls during a pause, so a failure recorded before it and one recorded after are far apart
    /// with no evidence of anything in between. Without this, that pair reads as a long-running outage
    /// and the first blip on the way back raises the alert — the very interruption the gate exists to
    /// prevent. Attempts already in flight are covered too: they resume with a start time from before the
    /// pause, so `performRefresh` drops their failure timing rather than letting it rebuild the run this
    /// just ended.
    func noteConnectionMonitoringPaused() {
        refreshFailureStreak = nil
        connectionMonitoringGeneration += 1
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
    ///
    /// `identity` and `mutationGeneration` are the caller's `overviewIdentity`/`mutationGeneration`
    /// snapshot from immediately before its own fetch (or, for a caller with no separate fetch, from
    /// immediately before this call) — not a courtesy for the caller's own later guard, but this
    /// method's own precondition: it mutates `browserRoutingTable`, the browser proxy, and potentially
    /// `pairedDevices` itself, every one of them before the caller's downstream guard ever runs, so it
    /// has to hold the invariant on its own. Re-checked before each of those mutations, not only once on
    /// entry: this method awaits twice (the resolver read below, then the proxy update), and either the
    /// active connection or a fresher overview-derived operation (another mutation response, a
    /// reconciliation fetch, a session-timeout recovery) can land during either wait (#450 review round
    /// 5) — applying this call's now-stale data at that point would mean overwriting a fresher fact with
    /// an older one.
    private func updateBrowserRoutes(overview: SpacesDeviceOverviewPayload, identity: Int, mutationGeneration fetchGeneration: Int) async {
        guard let activeDeviceID else { return }
        // The raw-byte service tunnel has to reach the daemon over the path the command channel that just
        // fetched `overview` actually proved reachable, so ask the live client's resolver directly rather
        // than trusting the persisted record: `pairedDevices` is an in-memory snapshot that can lag the
        // resolver by a beat — e.g. immediately after a LAN→Tailscale failover, before `recordActiveHost`
        // gets around to persisting the new winner — and handing the proxy a stale LAN address here would
        // dial an endpoint the command channel just proved unreachable. Fall back to the paired device
        // record's `activeHost`, then `settings.primaryHost`, only for a device with no live-resolved
        // address yet (freshly paired, no request issued through this client).
        let activeDeviceRecord = pairedDevices.first(where: { $0.id == activeDeviceID })
        let liveResolvedHost = await bridgeClient.currentResolvedHost()
        // The user can switch or remove the active device while that await is suspended, or a fresher
        // overview-derived fact can land and publish. Everything captured above belongs to the previous
        // moment, while `settings` and `activeDeviceName` below already read the current one — merging
        // that mixture would register routes keyed to the old device carrying the new device's port and
        // fingerprint, resurrect routes for a device just removed, or overwrite a fresher route table
        // with this now-stale one.
        guard isOverviewFetchCurrent(identity: identity, mutationGeneration: fetchGeneration) else { return }
        let resolvedHost = liveResolvedHost ?? activeDeviceRecord?.activeHost ?? settings.primaryHost
        browserRoutingTable.merge(
            deviceID: activeDeviceID, deviceName: activeDeviceName ?? settings.primaryHost, host: resolvedHost, port: settings.port,
            certificateFingerprint: settings.certificateFingerprint, overview: overview)
        let table = browserRoutingTable
        await browserProxy.updateRoutes(table)
        // Keeps `ConnectionSettingsView`'s "Local network"/"Tailscale" address label in sync with the
        // address the live client is actually using. `recordActiveHost` (called by the resolver once
        // its cached winner changes) writes straight to `UserDefaults`; `pairedDevices` is a separate
        // in-memory snapshot the view reads and nothing else refreshes it after a failover, so without
        // this the label would keep showing the pre-failover address for the rest of the session. Only
        // a real, resolver-confirmed address (`liveResolvedHost`, not the `resolvedHost` fallback chain
        // above) counts as a change worth reloading for; cheap in the common case since a reload only
        // happens when that address actually differs from what `pairedDevices` currently holds, and the
        // re-check keeps a stale refresh from publishing into a connection — or over a fresher fact — the
        // app has since moved past.
        if let liveResolvedHost, activeDeviceRecord?.activeHost != liveResolvedHost,
            isOverviewFetchCurrent(identity: identity, mutationGeneration: fetchGeneration)
        {
            pairedDevices = SpacesMobileDeviceStore.load(fallbackSettings: settings).devices
        }
    }

    /// Whether an overview-derived fetch or mutation application that began against `identity` when
    /// `mutationGeneration` was `fetchGeneration` is still safe to act on. Both halves are hard-bail
    /// invalidations of equal weight here: a changed connection identity means a different daemon
    /// entirely, and a moved `mutationGeneration` means some other overview-derived operation (a
    /// mutation response, a reconciliation fetch, a session-timeout recovery) already landed and is
    /// fresher — either way, whatever this fetch produced must not be published, merged into the
    /// browser routing table, or used to restore session state. Some callers instead need to treat the
    /// two halves differently (`reconcileWorkspaceDeletionOutcome` keeps evaluating a stale fetch's own
    /// evidence about its delete rather than discarding a whole reconciliation attempt over an unrelated
    /// mutation) and check `mutationGeneration` on its own for that narrower "skip this one side effect"
    /// case instead of using this.
    private func isOverviewFetchCurrent(identity: Int, mutationGeneration fetchGeneration: Int) -> Bool {
        identity == overviewIdentity && mutationGeneration == fetchGeneration
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
        // the monitoring generation it was measured in, since durations are only comparable within one
        // uninterrupted stretch of watching the connection.
        let attemptStartedAt = now()
        let monitoringGeneration = connectionMonitoringGeneration
        // Captured before the fetch is issued: this overview describes the daemon as of now, so a mutation
        // applied while it is in flight makes it stale and it must be dropped rather than published.
        let mutationGenerationAtFetch = mutationGeneration
        defer {
            isLoading = false
            refreshInFlight = nil
        }
        do {
            // Read compatibility from the overview's inline frozen-core status so the compatible steady
            // state costs a single round-trip. Only a refresh that fails entirely falls back to the
            // standalone frozen-core handshake below.
            let overview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
            guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtFetch) else { return }
            applyCompatibility(overview.daemonStatus)
            // The daemon reports the addresses it is currently reachable at on every connection. This is
            // how a device paired before its Mac ever had Tailscale silently gains the tailnet fallback
            // the moment the Mac gets one — no rescan needed, unlike the pre-existing QR-rescan path.
            let hostsChanged = SpacesMobileDeviceStore.mergeAdvertisedHosts(
                overview.daemonStatus.deviceAPIAddresses, certificateFingerprint: settings.certificateFingerprint)
            // A decodable overview whose daemon nonetheless reports an incompatible protocol is blocked;
            // show the restart/update block, not its stale workspace data.
            let acceptedOverview = isActiveDeviceBlocked ? nil : overview
            if let acceptedOverview {
                await updateBrowserRoutes(overview: acceptedOverview, identity: identity, mutationGeneration: mutationGenerationAtFetch)
            }
            // Re-checked after the await above, not just at fetch return: a mutation applying while the
            // route update was suspended makes this poll's payload pre-mutation state.
            guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtFetch) else { return }
            // Cleared before publishing, not after: the device answered, so any stale connection error is
            // over — but publishing is also what settles a deferred delete, and that may raise an error of
            // its own (`resolveDeferredWorkspaceDeletions`). Clearing afterwards would wipe it.
            connectionNotice = nil
            errorMessage = nil
            refreshFailureStreak = nil
            publishOverview(acceptedOverview)
            // Rebuilds the live client only after the overview above is already published, deliberately:
            // this runs mid-refresh, and racing the rebuild against the `overviewIdentity` guards earlier
            // in this method could drop the very overview the user is waiting for. Publishing first means
            // there is nothing left in this refresh for a rebuild to corrupt — the identity guard just
            // above already confirmed no device switch happened in between.
            if hostsChanged { rebuildLiveClientAfterHostsBackfill() }
        } catch is CancellationError { return } catch {
            // A mutation that landed while this poll was failing has already published the device's real
            // state and cleared any error; a stale failure must not overwrite that with an outage report.
            guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtFetch) else { return }
            // The overview did not decode (a wire-incompatible daemon) or the device is unreachable. The
            // frozen-core handshake stays decodable across versions, so use it to tell those apart: an
            // incompatible verdict shows the block; otherwise surface the original connection error.
            await refreshCompatibility(identity: identity)
            // The user may have switched or removed the active device — or a mutation may have published
            // fresher state — while the fallback handshake was in flight; a stale verdict must not
            // overwrite either.
            guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtFetch) else { return }
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
            // This attempt started before the app last stopped watching, so its elapsed time is mostly
            // time nothing was polling. It cannot start or extend a run — that would resurrect, dated
            // before the pause, exactly the run `noteConnectionMonitoringPaused` ended.
            guard monitoringGeneration == connectionMonitoringGeneration else { return }
            let streakStartedAt = refreshFailureStreak?.identity == identity ? refreshFailureStreak?.startedAt : nil
            let startedAt = streakStartedAt ?? attemptStartedAt
            refreshFailureStreak = (identity: identity, startedAt: startedAt)
            guard now() - startedAt >= refreshFailureAlertDelay else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// The Update Daemon action on the pending card: the user asking for a staged update to be applied
    /// now. A refused request is reported on the spot, since the user is watching a control they just
    /// used; nothing else about the run is, because a device offering this card still works either way.
    func requestDaemonUpdate() async { _ = await performDaemonUpdate(trigger: .userAction) }

    /// Who asked for a daemon update, which decides one thing only: who reports a refused request.
    private enum DaemonUpdateTrigger {
        /// The user pressed Update Daemon, so a request the device refuses is news and is surfaced.
        case userAction
        /// Spaces applied a staged build by itself. The request's own outcome is never the verdict here
        /// — a refused request and a daemon already mid-handoff look identical — so the poll runs either
        /// way and the device's own facts decide what, if anything, gets reported.
        case automatic
    }

    /// How a daemon update ended, in terms of what the device reported about itself.
    private enum DaemonUpdateOutcome {
        /// The device stopped reporting a staged build: the update is on.
        case applied
        /// The budget ran out with the device still reporting `stagedVersion` installed and
        /// `runningVersion` running — the device's own account of an apply that has not happened.
        case stillStaged(stagedVersion: String, runningVersion: String)
        /// Nothing to report: the request was refused (and reported already, for a user action), the run
        /// was cancelled, the active connection changed under it, or the budget ran out without the
        /// device answering at all. An unreachable device is reported the ordinary way by the overview
        /// poll; it is not evidence about an update.
        case unresolved
    }

    /// Requests the active device's daemon exec-in-place handoff: it quiesces sessions, applies any
    /// staged update, and re-execs at the same pid, so running terminals, agents, and processes survive.
    /// Polls the device's frozen-core status afterward until it reports the update applied, so the
    /// screen clears itself instead of sitting on "Updating…" forever if nothing else looks back. The
    /// daemon is expected to be briefly unreachable mid-handoff, so fetch failures during the poll are
    /// swallowed rather than surfaced as a connection error — they just mean "not back yet."
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
    private func performDaemonUpdate(trigger: DaemonUpdateTrigger) async -> DaemonUpdateOutcome {
        guard !isMutating, !isApplyingDaemonUpdate else { return .unresolved }
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
            if restartError is CancellationError { return .unresolved }
            guard identity == overviewIdentity else { return .unresolved }
            // Only a user action reports the refusal. An automatic apply falls through to the poll
            // instead: the device's own facts, not this request's fate, decide whether anything is wrong.
            if case .userAction = trigger {
                errorMessage = restartError.localizedDescription
                return .unresolved
            }
        }
        guard identity == overviewIdentity else { return .unresolved }
        connectionNotice = "Updating the daemon…"

        let clock = ContinuousClock()
        let deadline = clock.now + daemonUpdateTimeout
        // The last thing the device said about itself during the poll, which is the only evidence this
        // run's verdict may rest on. Stays nil for a device that never answered — silence is what a
        // daemon mid-handoff and an unreachable device both look like, so it proves nothing.
        //
        // A failed probe clears it, so the verdict can only rest on an observation that is still current
        // when the budget runs out. Without that, a device that answered once early in the poll and then
        // went quiet for the rest of it — exactly what a daemon mid-handoff replaying its sessions looks
        // like — would be judged from that first, long-superseded report and told the update did not
        // land. A tail of failures is silence, and silence gets no verdict.
        var lastReportedStatus: TerminalServiceDaemonStatus?
        while clock.now < deadline {
            // Cancellation exits the poll rather than being swallowed like a fetch failure: a cancelled
            // sleep would otherwise let every remaining attempt run back-to-back with no wait, spinning
            // the whole budget in one turn of the loop.
            do { try await Task.sleep(for: daemonUpdatePollInterval) } catch { return .unresolved }
            // The deadline can pass during that sleep. Re-check before probing: launching a request here
            // would add its whole timeout on top of the budget, on top of the sleep that just overran it.
            guard clock.now < deadline else { break }
            guard identity == overviewIdentity else { return .unresolved }
            guard let status = try? await bridgeClient.fetchDaemonStatus(commandChannel: updateChannel) else {
                lastReportedStatus = nil
                continue
            }
            guard identity == overviewIdentity else { return .unresolved }
            lastReportedStatus = status
            if case .applyStagedUpdate = DaemonUpdateRemedy.remedy(for: status) { continue }
            // The device no longer reports a staged update: publish the fresh status, then let a full
            // refresh repopulate the overview before clearing the notice.
            applyCompatibility(status)
            await refresh()
            guard identity == overviewIdentity else { return .unresolved }
            connectionNotice = nil
            return .applied
        }

        // Timed out. Drop the progress notice and re-enable the action, leaving the screen showing the
        // last thing the device actually said — a slow restart and a refused handoff look identical from
        // here, and neither is worth inventing a failure message for.
        //
        // Deliberately does not reconcile with a refresh. Against a device that is still down, that
        // fetch would take the ordinary failure path — clearing the status the screen renders from and
        // raising a connection error — which is the opposite of leaving the warning in place. It cannot
        // run under the expected-outage suppression either, because that keys off the same flag this
        // path has to release to re-enable the button. Releasing the flag resumes the overview poll,
        // which reconciles on its own cadence and reports a genuinely unreachable device the ordinary
        // way, so nothing is left stale.
        guard identity == overviewIdentity else { return .unresolved }
        connectionNotice = nil
        isApplyingDaemonUpdate = false
        guard let lastReportedStatus, let stagedVersion = Self.stagedApplyVersion(status: lastReportedStatus) else { return .unresolved }
        return .stillStaged(stagedVersion: stagedVersion, runningVersion: lastReportedStatus.version)
    }

    private func applyCompatibility(_ status: TerminalServiceDaemonStatus) {
        daemonStatus = status
        compatibility = SpacesWireCompatibility.evaluate(daemonStatus: status)
        // Every path that lands a fresh status goes through here, so this is where staged-apply state is
        // reconciled against what the device now says about itself — first retiring what its facts no
        // longer justify, then firing an apply for a staged build that is keeping it blocked.
        retireStagedApplyState(currentStagedVersion: Self.stagedApplyVersion(status: status))
        maybeApplyStagedUpdateAutomatically()
    }

    // MARK: - Applying a staged update to a blocked device

    /// One requested apply of one staged build on one device: the identity every staged-apply mark is
    /// keyed on, so a status the device repeats cannot re-fire an attempt already on its way, and a mark
    /// left by one build can never describe another. `deviceID` is nil for a connection with no paired
    /// record of its own, which is one connection like any other device.
    struct DaemonStagedApplyAttempt: Hashable {
        let deviceID: String?
        let stagedVersion: String
    }

    /// The dialog raised when an apply this app requested did not land. Holds the facts rather than a
    /// rendered view so the copy is testable and the presentation belongs to the app shell.
    struct StagedApplyDidNotLandAlert: Equatable {
        /// The build the report is about, so the report retires with the state that produced it.
        let stagedVersion: String
        let title: String
        let message: String
    }

    /// The staged build `status`'s device is asking to have applied, or nil when it is not waiting on
    /// one. Defers entirely to `DaemonUpdateRemedy`, so what this app does on its own and what its
    /// screens say can never disagree.
    private static func stagedApplyVersion(status: TerminalServiceDaemonStatus?) -> String? {
        guard let status, case .applyStagedUpdate(let stagedVersion) = DaemonUpdateRemedy.remedy(for: status) else { return nil }
        return stagedVersion
    }

    /// Whether the staged apply the active device is waiting on has already been reported as not landed.
    /// The blocked device's hero and its Try Again both hang off this: before it, the apply is under way
    /// and there is nothing for the user to do.
    private var stagedApplyDidNotLand: Bool {
        guard let stagedVersion = Self.stagedApplyVersion(status: daemonStatus) else { return false }
        return stagedApplyDidNotLandAttempts.contains(DaemonStagedApplyAttempt(deviceID: activeDeviceID, stagedVersion: stagedVersion))
    }

    /// Applies a staged build to a device this app cannot otherwise use, without asking: the restart RPC
    /// rides the frozen wire core, so it crosses the version gap, and applying the staged build is
    /// precisely what closes it — leaving that device to a button would make the user tap through what
    /// the app can already do. A device that still works keeps its explicit action instead (the pending
    /// card), since nothing about it is urgent and this phone may be the only client running.
    ///
    /// Fires once per (device, staged build) per app run, so the status the device repeats every couple
    /// of seconds cannot re-request a handoff already on its way.
    private func maybeApplyStagedUpdateAutomatically() {
        guard isActiveDeviceBlocked, let stagedVersion = Self.stagedApplyVersion(status: daemonStatus) else { return }
        let attempt = DaemonStagedApplyAttempt(deviceID: activeDeviceID, stagedVersion: stagedVersion)
        guard !autoStagedApplyAttempts.contains(attempt) else { return }
        autoStagedApplyAttempts.insert(attempt)
        Task { await applyStagedUpdateReportingFailure(attempt: attempt) }
    }

    /// Runs an apply whose only surface is failure. Success is shown nowhere: the device passes through
    /// the ordinary seconds-long reconnect and comes back on the new build. The verdict comes from what
    /// the device reports about itself — never from the RPC's result, since a refused request and a
    /// daemon already mid-handoff look identical from here.
    private func applyStagedUpdateReportingFailure(attempt: DaemonStagedApplyAttempt) async {
        let outcome = await performDaemonUpdate(trigger: .automatic)
        // The once-per-build rule exists to stop the status the device repeats every couple of seconds
        // from re-requesting an apply, and it is spent by an outcome: the build landed, or the device's
        // own report says it did not and the mark below carries that from here. An undecided run decides
        // nothing — the connection changed under it, the run was cancelled, or the device stopped
        // answering — so it hands the once-only back. Otherwise the attempt would stay consumed with no
        // mark to show for it: the device would sit blocked on that same staged build with the automatic
        // apply deduped away and nothing on screen for the user to act on, until the app was relaunched.
        // A re-fire needs the device to report itself blocked and staged all over again, so this cannot
        // spin; it just lets the next such report be acted on.
        guard case .stillStaged(let stagedVersion, let runningVersion) = outcome else {
            if case .unresolved = outcome { autoStagedApplyAttempts.remove(attempt) }
            return
        }
        // A device that has since staged a different build was never asked to apply this one, so what it
        // reports now says nothing about the attempt being judged. The newer build gets its own attempt.
        guard stagedVersion == attempt.stagedVersion else { return }
        stagedApplyDidNotLandAttempts.insert(attempt)
        stagedApplyDidNotLandAlert = StagedApplyDidNotLandAlert(
            stagedVersion: stagedVersion, title: "Update didn't land",
            message: "Spaces \(stagedVersion) is installed on \(connectionSummary), but its daemon is still running \(runningVersion). "
                + "Nothing running on it was interrupted.")
    }

    /// Try Again, from the dialog or from the blocked device's hero: asks the device again for whatever
    /// it currently reports staged and reports itself the same way if that request also goes unanswered.
    /// It bypasses the once-per-build rule on purpose — the user asking again is new information, a
    /// repeated status report is not — and clears the failure mark, which takes the hero down while the
    /// device is applying an update again.
    func retryStagedApply() async {
        stagedApplyDidNotLandAlert = nil
        guard let stagedVersion = Self.stagedApplyVersion(status: daemonStatus) else { return }
        let attempt = DaemonStagedApplyAttempt(deviceID: activeDeviceID, stagedVersion: stagedVersion)
        autoStagedApplyAttempts.insert(attempt)
        stagedApplyDidNotLandAttempts.remove(attempt)
        await applyStagedUpdateReportingFailure(attempt: attempt)
    }

    /// Not Now: the report is made, and the blocked device's hero carries the retry from here.
    func dismissStagedApplyDidNotLandAlert() { stagedApplyDidNotLandAlert = nil }

    /// Drops staged-apply state the active device's own facts no longer justify: everything when it is
    /// not waiting on a staged build at all, and everything but the current attempt when it is waiting
    /// on a different one. Called wherever a fresh status lands, so a landed or superseded apply can
    /// never pin a hero or leave a report standing. Other devices' marks are left alone; they describe
    /// devices this status says nothing about.
    private func retireStagedApplyState(currentStagedVersion: String?) {
        stagedApplyDidNotLandAttempts = stagedApplyDidNotLandAttempts.filter {
            $0.deviceID != activeDeviceID || $0.stagedVersion == currentStagedVersion
        }
        if let alert = stagedApplyDidNotLandAlert, alert.stagedVersion != currentStagedVersion { stagedApplyDidNotLandAlert = nil }
    }

    /// Drops every staged-apply mark for a device the app is about to stop tracking, so a later pairing
    /// of the same device cannot inherit a failure mark, or a suppressed re-fire, from a run nothing is
    /// watching any more.
    private func forgetStagedApplyState(deviceID: String) {
        autoStagedApplyAttempts = autoStagedApplyAttempts.filter { $0.deviceID != deviceID }
        stagedApplyDidNotLandAttempts = stagedApplyDidNotLandAttempts.filter { $0.deviceID != deviceID }
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
            ? SpacesMobileDeviceStore.upsert(settings: settings, name: deviceName ?? settings.primaryHost)
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
        stagedApplyDidNotLandAlert = nil
        workspaceCreateOptions = nil
        connectionNotice = nil
        pendingPairingLink = nil
        loadDismissedAlertIDsForActiveDevice()
        pruneDismissedAlertsForUnknownDevices()
        Task { await previousCommandChannel.close() }
    }

    /// Rebuilds the live client and command channel after `mergeAdvertisedHosts` backfills a newly
    /// learned address into the active device's `hosts` — most commonly a Mac paired before it had
    /// Tailscale gaining the tailnet candidate the moment its daemon starts advertising one. Reloads
    /// settings from the device store, which now carries the widened `hosts` list, and swaps in a fresh
    /// client so the resolver embedded in it races the new candidate list starting on this refresh
    /// instead of waiting for the app to relaunch or the device to be reselected.
    ///
    /// Deliberately does not touch `overview`, `daemonStatus`, `compatibility`, or `overviewIdentity` the
    /// way a device switch does: the payload this same refresh just published is still current — the
    /// daemon did not change, only the addresses it can be reached at did — so nothing about the
    /// already-accepted result needs to be discarded or invalidated.
    private func rebuildLiveClientAfterHostsBackfill() {
        let deviceState = SpacesMobileDeviceStore.load(fallbackSettings: settings)
        // The caller already re-checked `overviewIdentity` right before this runs, so the active device
        // should still be this one; this is an extra guard in case the store's active device moved on for
        // some other reason in between, so a rebuild can never point this model at a different device.
        guard deviceState.activeDeviceID == activeDeviceID else { return }
        let previousCommandChannel = commandChannel
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        bridgeClient = SpacesDeviceAPIClient(settings: deviceState.settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        Task { await previousCommandChannel.close() }
    }

    /// Foreground re-preference for the active connection: clears the live resolver's cached winner and
    /// closes the shared command channel's current connection, so the very next overview poll or
    /// mutation re-races every candidate address — preferring the LAN address again when this device is
    /// back on it — instead of continuing on whatever address it settled on while away. Reuses
    /// `SpacesDeviceAPICommandChannel.close()` rather than a parallel teardown path.
    ///
    /// Deliberately touches only this app-wide command channel, never a `TerminalViewerModel`'s own
    /// channel or its live session stream: a working terminal session must not be interrupted just to
    /// re-prefer a lower-latency path. An open viewer keeps its stream, which re-races on its own the next
    /// time it actually disconnects (see `SpacesDeviceNetworkBackend.openSessionStream`'s disconnect
    /// handling).
    ///
    /// Accepted race: a connect already suspended inside `connectIfNeeded` when this runs can install its
    /// connection and repopulate the resolver's cache afterwards, leaving the app on the address it had
    /// rather than re-preferring the LAN one. The overview poll runs every couple of seconds, so the
    /// window is real but the consequence is only staying on a path that already works, and the next
    /// foreground clears it again. Not worth generation-stamping every connect to close.
    func resetActiveConnectionEndpoint() {
        let client = bridgeClient
        let channel = commandChannel
        Task {
            await client.resetEndpointResolution()
            await channel.close()
        }
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
        // The report names the device it was raised for, so it goes with that device rather than being
        // read as a statement about the one just switched to. Its mark survives: the device it describes
        // still has that build staged and unapplied, and switching back must not re-fire the apply.
        stagedApplyDidNotLandAlert = nil
        workspaceCreateOptions = nil
        connectionNotice = nil
        errorMessage = nil
        loadDismissedAlertIDsForActiveDevice()
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
        stagedApplyDidNotLandAlert = nil
        forgetStagedApplyState(deviceID: id)
        workspaceCreateOptions = nil
        connectionNotice = nil
        loadDismissedAlertIDsForActiveDevice()
        pruneDismissedAlertsForUnknownDevices()
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
        loadDismissedAlertIDsForActiveDevice()
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
        loadDismissedAlertIDsForActiveDevice()
        pruneDismissedAlertsForUnknownDevices()
        Task { await previousCommandChannel.close() }
    }

    /// Clears every piece of published state tied to the previous active connection, matching what a
    /// device switch resets so no stale overview, status, or notice bleeds across the swap.
    private func clearActiveConnectionState() {
        overview = nil
        daemonStatus = nil
        compatibility = nil
        stagedApplyDidNotLandAlert = nil
        workspaceCreateOptions = nil
        connectionNotice = nil
        errorMessage = nil
    }

    func dismissError() { errorMessage = nil }

    func clearPendingPairingLink() { pendingPairingLink = nil }

    /// Raises the re-pair recovery surface for a request the daemon would not authenticate: drops the
    /// stale overview, publishes `message` as the connection notice, and pushes Paired Devices.
    ///
    /// The credential deliberately survives. It is the same token the Keychain still holds, so clearing
    /// it destroyed the only in-memory copy of something still on disk and, because the overview poll is
    /// gated on `settings.isPaired`, left the app permanently "unpaired" for the rest of the process with
    /// no retry that could ever prove otherwise. Keeping it means a failure that was really transport
    /// trouble self-heals on the next poll, while a genuinely revoked device simply fails the next
    /// request and lands back on this same screen. The connection itself is still reset, since the
    /// address and socket that just failed are not worth trusting and the next request should re-race
    /// every candidate. The client is not rebuilt: with the credential unchanged a rebuild would produce
    /// an identical client and throw away the resolver state the recovery is about to use.
    ///
    /// Re-entrant by design: with the poll still running, a device that keeps rejecting this token calls
    /// here every couple of seconds. `connectionNotice` is the episode marker, cleared by a successful
    /// refresh, so the recovery surface is raised once per episode rather than pulling the user back to
    /// Paired Devices every time they navigate away from it.
    func handleAuthenticationFailure(message: String) {
        guard connectionNotice != message else { return }
        overviewIdentity += 1
        overview = nil
        workspaceCreateOptions = nil
        connectionNotice = message
        pendingPairingLink = nil
        errorMessage = nil
        isShowingConnectionSettings = true
        resetActiveConnectionEndpoint()
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
        case .codingAgent, .terminal, .browserSession: return nil
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
                // Automation agents share the workspace terminal stop route: the daemon first cancels an
                // active automation run, then stops the registered or pre-signal session. The server still
                // recognizes ordinary configured-process agent rows on this route.
                if let sessionID = agent.sessionID {
                    response = try await bridgeClient.stopWorkspaceTerminal(
                        workspaceID: agent.workspaceID, sessionID: sessionID, commandChannel: commandChannel)
                } else if let agentID = agent.agentID {
                    response = try await bridgeClient.stopCodingAgent(
                        workspaceID: agent.workspaceID, agentID: agentID, commandChannel: commandChannel)
                } else {
                    return
                }
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
        case .codingAgent, .terminal, .browserSession: return nil
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

    /// Sets one workspace's visibility. Hiding stops the workspace first when it is running — matching the
    /// Mac, which never leaves a hidden workspace running with no row left to stop it from. Unhiding
    /// starts nothing: a hidden workspace was already stopped on the way in, so recovery is purely a
    /// visibility change back to normal.
    ///
    /// The stop is decided from a freshly fetched overview rather than the polled snapshot this app is
    /// showing, so a workspace someone started since the last poll is still stopped before it is hidden.
    /// The caller's confirmation is decided from the cached state (that is all a prompt can read), so the
    /// two can disagree in the seconds between; the fresh read is what governs what actually happens.
    func setWorkspaceHidden(workspaceID: String, isHidden: Bool) async {
        // Hiding a workspace whose delete is still unresolved would act on a row that is already leaving.
        // `performWorkspaceMutation` below still gates on `isMutating`, since this rides the shared
        // `commandChannel`, but that alone would not catch this: an unresolved delete leaves `isMutating`
        // false (see `deleteWorkspace`), so this needs its own check of the pending-deletion mark. The
        // marked predicate, not the local set: a delete started on another client is just as much a row
        // on its way out.
        guard !isWorkspacePendingDeletion(workspaceID) else { return }
        await performWorkspaceMutation {
            if isHidden {
                let currentOverview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
                guard let currentWorkspace = currentOverview.workspaces.first(where: { $0.id == workspaceID }) else {
                    throw SpacesDeviceAPIClientError.requestFailed("This workspace is no longer available.")
                }
                if currentWorkspace.isRunning { _ = try await bridgeClient.stopWorkspace(workspaceID: workspaceID, commandChannel: commandChannel) }
            }
            return try await bridgeClient.setWorkspaceHidden(workspaceID: workspaceID, isHidden: isHidden, commandChannel: commandChannel)
        }
    }

    /// Sets a project's visibility, stopping every running workspace under it before hiding it, for the
    /// same reason a workspace hide stops the workspace.
    ///
    /// The project flag is independent of each workspace's, so this never writes a child's flag: unhiding
    /// the project brings back exactly the workspaces that were shown before it was hidden.
    func setProjectHidden(projectID: String, isHidden: Bool) async {
        await performWorkspaceMutation {
            if isHidden {
                let currentOverview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
                for workspace in currentOverview.workspaces where workspace.projectID == projectID && workspace.isRunning {
                    // A workspace that will not stop leaves the project visible: hiding it now would
                    // strand that workspace out of view still running.
                    _ = try await bridgeClient.stopWorkspace(workspaceID: workspace.id, commandChannel: commandChannel)
                }
            }
            return try await bridgeClient.setProjectHidden(projectID: projectID, isHidden: isHidden, commandChannel: commandChannel)
        }
    }

    /// Names of the running workspaces a project hide would stop, from the currently published overview —
    /// what the confirmation prompt names.
    func runningWorkspaceNames(inProjectID projectID: String) -> [String] {
        (overview?.workspaces ?? []).filter { $0.projectID == projectID && $0.isRunning }.map(\.displayName)
    }

    func isWorkspaceRunning(workspaceID: String) -> Bool { overview?.workspaces.first(where: { $0.id == workspaceID })?.isRunning == true }

    /// Reconciliation attempts after an indeterminate `archiveWorkspace` failure (see `deleteWorkspace`
    /// and `isIndeterminateDeleteOutcome`). The daemon
    /// runs the delete on its own teardown queue and can keep going well past this request's timeout, so
    /// refetching the overview a few times gives a delete that is still finishing a chance to resolve to
    /// success instead of a spurious error. Five attempts at `workspaceDeletionReconciliationInterval`
    /// give the daemon a settle window on the order of the poll cadence rather than an instant verdict.
    static let workspaceDeletionReconciliationAttempts = 5

    /// Deletes the workspace, optionally deleting the branch it was created on locally and/or on the
    /// remote. The daemon stops the workspace, removes its worktree, and drops the record and its
    /// settings; branch deletion is the one part that can partly fail, so its report is surfaced.
    func deleteWorkspace(_ workspace: SpacesDeviceWorkspaceSummary, deleteLocalBranch: Bool, deleteRemoteBranch: Bool) async {
        // A workspace already on its way out takes no further action — refused here, not only suppressed
        // in the Spaces tab, so the rule holds even against a view that forgets to ask. The marked
        // predicate, not the local set: a workspace the daemon reports it is already tearing down (a
        // delete issued from another client) must not be deleted a second time from here either. This is
        // the only in-flight check a delete needs: it does not also gate on `isMutating`, because a
        // delete runs on its own private channel (`deleteChannel` in `performDeleteWorkspace`) rather than
        // the shared `commandChannel`, so one workspace's delete can never collide on the wire with a
        // mutation running against a different workspace (#450) — including another workspace's delete,
        // which is not rejected here either; it is chained instead (`pendingDeleteChains`).
        //
        // Accepted overlap: a delete issued while this same workspace's Start/Stop/Restart/Hide is still
        // in flight is not blocked here. The daemon's per-workspace lifecycle gate arbitrates that race
        // and refuses one side with "Workspace action is already in progress."; the refusal surfaces as
        // this delete's error and lifts the pending mark, so a retry works. Client-side tracking of which
        // workspace the shared-channel mutation targets would buy only an earlier copy of that message.
        guard !isWorkspacePendingDeletion(workspace.id) else { return }
        let identity = overviewIdentity
        // Marked for the whole mutation, immediately — including whatever time this delete spends queued
        // behind a predecessor below, so the band reads as deleting the instant this is called rather than
        // once its request actually goes out. On success the mark is lifted only after the refreshed
        // overview (which no longer carries the workspace) is published, so the band never flicks back to
        // looking untouched on its way out; on a definitive failure lifting it restores the ordinary band
        // beside the error. A timeout is neither of those — see the catch block below — so the mark's
        // removal is handled explicitly per outcome instead of by an unconditional `defer`.
        workspaceIDsPendingDeletion.insert(workspace.id)

        // Chained behind whatever delete this daemon (keyed by `identity`) already has queued or in
        // flight — see `pendingDeleteChains`'s declaration for why it is keyed rather than a single tail.
        // Queuing costs nothing visible: the mark above already put this workspace's band into its
        // deleting state.
        let predecessor = pendingDeleteChains[identity]
        let task = Task {
            await predecessor?.value
            await self.performDeleteWorkspace(
                workspace, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch, identity: identity)
        }
        pendingDeleteChains[identity] = task
        await task.value
    }

    /// The body of one queued delete, run once `deleteWorkspace` has chained it behind any predecessor on
    /// the same daemon (see `pendingDeleteChains`). `identity` is the caller's `overviewIdentity` snapshot
    /// from before it queued, not from when this actually starts: a device switch during the wait is
    /// exactly the kind of change the `identity == overviewIdentity` guard below, and every other one in
    /// this function, exists to catch. Without it a queued delete would resume against whatever device is
    /// active by then and send this workspace's id — which may not even exist there — to the wrong daemon.
    private func performDeleteWorkspace(_ workspace: SpacesDeviceWorkspaceSummary, deleteLocalBranch: Bool, deleteRemoteBranch: Bool, identity: Int)
        async
    {
        guard identity == overviewIdentity else {
            // This delete was never sent to any daemon: the request below is the first thing that talks
            // to the network, and the identity mismatch means the active device changed while this was
            // still queued. A delete is only ever issued against the active device — running it in the
            // background against the device the user switched away from would mean suppressing that
            // device's reconciliation and publishes against whatever is now active, for a case that needs
            // a device switch to land mid-queue. Cancelling audibly, instead, means a confirmed
            // destructive action the user asked for is never silently skipped: they see it did not
            // happen and can repeat it from the device that owns the workspace.
            //
            // Accepted overlap: the mark removed here is keyed by workspace id alone, so if the user
            // switched away AND back (a fresh identity) and re-confirmed this same workspace's delete
            // before this cancelled task ran, this removal clears the retry's mark and the error below
            // misreports it. That needs a queued delete, two device switches, and a same-workspace
            // retry inside one chain's lifetime; the retry itself still runs, and its own outcome (or
            // the next overview reporting the daemon-side teardown) restores the row's true state.
            // Per-attempt mark ownership is what fixing it would take, and it is not worth carrying
            // for that window.
            workspaceIDsPendingDeletion.remove(workspace.id)
            errorMessage =
                "\"\(workspace.displayName)\" wasn't deleted: the active device changed before its delete could be sent. Delete it again from that device."
            return
        }
        // Sent on a dedicated command channel rather than the shared one the overview poll also uses.
        // The daemon runs a delete's teardown (stop, worktree removal, record drop) on its own queue, so
        // it can take many seconds — far longer than the 8s the poll allows itself. The transport does
        // not serialize whole request/response round trips on a connection (issue #248): the poll and
        // this request can interleave on one connection, and when the poll's own request times out,
        // `SpacesDeviceNetworkRequestTransport.send` closes the shared connection out from under whatever
        // else is using it, aborting this request client-side while the daemon keeps deleting regardless.
        // A private channel, created for this mutation and closed after it — mirroring
        // `requestDaemonUpdate` above — keeps the delete off the shared connection for its whole life,
        // including the reconciliation reads below.
        let deleteChannel = bridgeClient.makeCommandChannel()
        defer { Task { await deleteChannel.close() } }

        // `deletedWorkspaceNotice` and `errorMessage`, set below and in `handleBridgeError`, are single
        // slots, not queues: whichever delete's outcome lands last wins, silently replacing whatever an
        // earlier delete left on screen if the user has not dismissed it yet. Accepted — deletes from this
        // client are chained per daemon (`pendingDeleteChains`), so a same-client overlap here is already narrow (this
        // one landing while a queued predecessor's notice is still up), and a lost notice for a delete that
        // still succeeded is low stakes next to the complexity of queuing them for display.
        do {
            let response = try await bridgeClient.archiveWorkspace(
                workspaceID: workspace.id, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch, commandChannel: deleteChannel
            )
            // Lifted only after the refreshed overview (which no longer carries the workspace) is
            // published, so the band never flicks back to looking untouched on its way out.
            defer { workspaceIDsPendingDeletion.remove(workspace.id) }
            await applyMutationResponse(response, identity: identity)
            guard identity == overviewIdentity else { return }
            if let notice = response.mutationNotice, !notice.isEmpty { deletedWorkspaceNotice = notice }
        } catch {
            guard identity == overviewIdentity else {
                // The connection changed under the delete. The mark is keyed by workspace id rather than
                // by connection, so clearing it is always safe — and leaving it behind would dim that row
                // for the rest of the run if the user ever switched back to this device.
                workspaceIDsPendingDeletion.remove(workspace.id)
                return
            }
            guard isIndeterminateDeleteOutcome(error) else {
                // The daemon answered and refused: the workspace was never touched, so un-mark it
                // immediately and surface the error like any other failed mutation.
                workspaceIDsPendingDeletion.remove(workspace.id)
                handleBridgeError(error)
                return
            }
            // The delete's fate is unknown — the daemon may still be tearing the workspace down (see the
            // channel comment above). Un-marking and reporting failure here would let the user retry-delete
            // a workspace that is already doomed. Reconcile against fresh overviews instead: if the
            // workspace stops appearing, treat the delete as successful and surface no error; only report
            // the failure once the reconciliation budget is spent and the workspace is still listed.
            let outcome = await reconcileWorkspaceDeletionOutcome(workspaceID: workspace.id, identity: identity, commandChannel: deleteChannel)
            guard identity == overviewIdentity else {
                workspaceIDsPendingDeletion.remove(workspace.id)
                return
            }
            let requestedBranchDeletion = deleteLocalBranch || deleteRemoteBranch
            switch outcome {
            case .present:
                workspaceIDsPendingDeletion.remove(workspace.id)
                handleBridgeError(error)
            case .gone:
                workspaceIDsPendingDeletion.remove(workspace.id)
                // The delete landed, but the branch-deletion report existed only in the response that was
                // lost — reconciliation can prove the workspace is gone, not what happened to branches the
                // user explicitly asked to delete. Say so rather than silently succeeding.
                if requestedBranchDeletion { deletedWorkspaceNotice = Self.unknownBranchOutcomeNotice }
            case .unknown:
                // No genuine verdict was reached: either every refetch failed, or every refetch that
                // succeeded found the workspace listed with its teardown still reported in flight — the
                // daemon still working, not a failure. Clearing the marking and reporting failure here
                // would be a verdict the client never reached — the row would go back to looking ordinary
                // and offering Delete again, for a workspace the daemon may still finish deleting. The
                // marking stays and the error is held until an overview can answer (see
                // `resolveDeferredWorkspaceDeletions`). This delete never touched `isMutating`, so only
                // this row stays inert — every other workspace's controls were never affected.
                workspaceDeletionsAwaitingOverview[workspace.id] = DeferredWorkspaceDeletion(
                    error: error, requestedBranchDeletion: requestedBranchDeletion)
            }
        }
    }

    /// Whether a failed delete leaves the workspace's fate unknown, so it has to be reconciled against
    /// fresh overviews instead of being reported as a failure.
    ///
    /// Only a refusal from the daemon is definitive, and it takes two things to prove one. First a Device
    /// API error code, which `SpacesDeviceAPIClient` attaches exactly where it turns an `ok: false`
    /// response into an error: every other failure the request can throw carries none — a client-side
    /// timeout, an unreachable host, or the socket being closed under it when the app was backgrounded,
    /// which arrives as an ordinary `requestFailed` — and none of those says anything about whether the
    /// daemon accepted the delete. The transport cannot even report whether a failure happened before or
    /// after the request went out, so every codeless failure reconciles; that costs nothing when it was
    /// pre-send, since the first refetch finds the workspace still listed and the error surfaces then.
    ///
    /// Second, the code has to be a verdict on the request (`SpacesDeviceErrorCode.isRequestVerdict`)
    /// rather than a report of something going wrong. A delete that succeeded and then failed while
    /// building its refreshed overview answers with a coded `internalError`, and reading that as a refusal
    /// would put the deleted workspace back as an ordinary actionable row.
    private func isIndeterminateDeleteOutcome(_ error: Error) -> Bool {
        guard let code = (error as? any SpacesDeviceErrorCodeProviding)?.spacesDeviceErrorCode else { return true }
        return !code.isRequestVerdict
    }

    /// What reconciliation was able to establish about a delete whose response was lost.
    ///
    /// `unknown` is not a synonym for `present`: it means no overview ever resolved with a genuine verdict
    /// either way. That covers both a fetch that never resolved and one that resolved but found the
    /// workspace still listed with its teardown reported in flight (`workspaceIDsWithTeardownInFlight`) on
    /// every attempt — the daemon saying it is still working, not that the delete failed. Reporting either
    /// as `present` would be a fabricated verdict — the client would put the cached pre-delete row back and
    /// call the delete failed while the daemon may well complete it moments later — so both defer instead,
    /// to the first overview that can actually answer.
    private enum WorkspaceDeletionReconciliation {
        case gone
        case present
        case unknown
    }

    /// A delete parked in `workspaceDeletionsAwaitingOverview`, holding what the client owes the user once
    /// an overview finally settles the question.
    private struct DeferredWorkspaceDeletion {
        /// Surfaced only if the workspace turns out to still be there.
        let error: any Error
        /// Whether the user asked for branches to be deleted, which decides if the unknown-branch-outcome
        /// notice is owed when the workspace turns out to be gone.
        let requestedBranchDeletion: Bool
    }

    /// Shown when a delete is confirmed complete but its response — the only thing that carried the
    /// branch-deletion report — never arrived.
    static let unknownBranchOutcomeNotice =
        "Deleted the workspace, but the connection dropped before the branch-deletion result arrived. Check the branch in the repository."

    /// Refetches the overview a bounded number of times after an indeterminate delete, looking for
    /// the workspace to stop being listed. Returns whether the workspace is still present once the
    /// budget is spent (or a fetch never resolves) — `false` means the delete is confirmed complete.
    /// Every accepted overview is published exactly like an ordinary refresh, guarded by `identity`
    /// throughout: a device switch mid-reconciliation must not publish the old backend's state. Each
    /// fetch is also guarded by `mutationGeneration`, the same way `applyMutationResponse` guards its own
    /// publish: a concurrent shared-channel mutation's response can land and publish first, and this
    /// fetch — already superseded — must not overwrite it.
    ///
    /// A refetch that still lists the workspace is not automatically evidence of failure: the daemon runs
    /// the delete's teardown on its own queue and reports which workspaces are still on it via
    /// `workspaceIDsWithTeardownInFlight`. While the workspace's id is in that set, its continued presence
    /// only means the daemon has not finished landing the delete yet, so those attempts do not count toward
    /// `.present` — only a listing with no teardown queued behind it is a genuine sign the delete never
    /// happened. If every attempt in the budget is spent this way the outcome is `.unknown`, deferring to
    /// `resolveDeferredWorkspaceDeletions` instead of reporting a guessed failure.
    private func reconcileWorkspaceDeletionOutcome(workspaceID: String, identity: Int, commandChannel: SpacesDeviceAPICommandChannel) async
        -> WorkspaceDeletionReconciliation
    {
        // These fetches are issued after the delete was sent, so each one is newer than any poll already in
        // flight; publishing one retires those polls the same way applying a mutation's own overview does.
        mutationGeneration &+= 1
        var resolvedAtLeastOnce = false
        for attempt in 0..<Self.workspaceDeletionReconciliationAttempts {
            guard identity == overviewIdentity else { return .unknown }
            // Captured immediately before the fetch below, not after it returns: a concurrent
            // overview-derived operation (another mutation response, a different reconciliation, a
            // session-timeout recovery) that bumps `mutationGeneration` while the fetch itself is still
            // in flight must still be caught. Capturing after the fetch returns would already reflect
            // that bump as if it were this attempt's own baseline, passing a staleness check it should
            // fail (#450 review round 5).
            let mutationGenerationAtFetch = mutationGeneration
            guard let refreshedOverview = try? await bridgeClient.fetchOverview(commandChannel: commandChannel) else {
                if attempt + 1 < Self.workspaceDeletionReconciliationAttempts { try? await Task.sleep(for: workspaceDeletionReconciliationInterval) }
                continue
            }
            guard identity == overviewIdentity else { return .unknown }
            // `updateBrowserRoutes` re-checks this same generation itself before it merges routes or
            // updates the proxy, so a fresher fact landing during either of its own awaits skips those
            // mutations too, not only the publish below.
            await updateBrowserRoutes(overview: refreshedOverview, identity: identity, mutationGeneration: mutationGenerationAtFetch)
            guard identity == overviewIdentity else { return .unknown }
            // A generation mismatch here means a fresher overview-derived fact landed while this
            // attempt's fetch or route update was suspended — not that this attempt's own read of the
            // delete's outcome is wrong. Skip the publish, but keep evaluating this fetch's evidence
            // below regardless, so an unrelated mutation racing this reconciliation does not cost it a
            // whole attempt.
            if mutationGeneration == mutationGenerationAtFetch { publishOverview(refreshedOverview) }
            guard refreshedOverview.workspaces.contains(where: { $0.id == workspaceID }) else {
                errorMessage = nil
                connectionNotice = nil
                refreshFailureStreak = nil
                return .gone
            }
            // Still listed, but that alone is not proof the delete failed — see the doc comment above.
            // Only count this attempt toward `.present` when the daemon is not still working on it.
            if !refreshedOverview.workspaceIDsWithTeardownInFlight.contains(workspaceID) { resolvedAtLeastOnce = true }
            if attempt + 1 < Self.workspaceDeletionReconciliationAttempts { try? await Task.sleep(for: workspaceDeletionReconciliationInterval) }
        }
        return resolvedAtLeastOnce ? .present : .unknown
    }

    func dismissDeletedWorkspaceNotice() { deletedWorkspaceNotice = nil }

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

    /// Where a runtime row's name lives, and so how a rename reaches the daemon: an ad hoc terminal and a
    /// coding agent own their session's name, while a configured process or browser session owns an entry in
    /// the workspace config. Configured entries carry stable identity so the mutation can resolve them
    /// against a fresh config instead of replacing concurrent edits with the overview's cached snapshot.
    private enum RuntimeRowRename {
        case terminalSession(sessionID: String)
        case agentSession(agentID: String)
        case workspaceConfig(entry: ConfigEntry)

        enum ConfigEntry {
            case process(id: String)
            case browserSession(name: String)
        }
    }

    /// Whether the row has a name the daemon can rename. A process running without a configured entry has
    /// no name to edit — its name comes from the running process — and a terminal row whose session has
    /// ended has no session to rename, so those rows offer no Rename. An agent row names its session and
    /// stays renamable as long as the row exists. Demo Mode's backend rejects config edits, so no row is
    /// renamable while it is on.
    func canRename(row: SpacesMobileWorkspaceRuntimeRow) -> Bool {
        guard !isDemoModeEnabled else { return false }
        return renameTarget(for: row) != nil
    }

    /// Renames a runtime row. Renaming a configured process or browser session edits its workspace-config
    /// entry, so a running process keeps its current name until it is restarted — the same rule the Mac
    /// sidebar's rename follows.
    ///
    /// Submitting an empty name clears an ad hoc terminal's or an agent's rename, restoring the name
    /// underneath it. A config entry must keep a name, so an empty submission there is discarded.
    func rename(row: SpacesMobileWorkspaceRuntimeRow, to newTitle: String) async {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != row.title, let target = renameTarget(for: row) else { return }
        if title.isEmpty, case .workspaceConfig = target { return }
        await performWorkspaceMutation {
            switch target {
            case .terminalSession(let sessionID):
                return try await bridgeClient.renameTerminalSession(
                    workspaceID: row.workspaceID, sessionID: sessionID, title: title, commandChannel: commandChannel)
            case .agentSession(let agentID):
                return try await bridgeClient.renameAgentSession(
                    workspaceID: row.workspaceID, agentID: agentID, title: title, commandChannel: commandChannel)
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
            guard let agentID = agent.agentID else { return nil }
            return .agentSession(agentID: agentID)
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
        var browserSessions = config.browserSessions
        switch entry {
        case .process(let id):
            guard let index = processes.firstIndex(where: { $0.id == id }) else {
                throw SpacesDeviceAPIClientError.requestFailed("This process is no longer configured.")
            }
            let process = processes[index]
            processes[index] = SpacesDeviceProcessTemplate(
                id: process.id, name: name, command: process.command, kind: process.kind, onExit: process.onExit)
        case .browserSession(let currentName):
            guard let index = browserSessions.firstIndex(where: { $0.name == currentName }) else {
                throw SpacesDeviceAPIClientError.requestFailed("This browser session is no longer configured.")
            }
            browserSessions[index] = SpacesDeviceBrowserSession(name: name, url: browserSessions[index].url)
        }
        return SpacesDeviceWorkspaceConfig(
            stopScript: config.stopScript, ports: config.ports, processes: processes, browserSessions: browserSessions,
            resolvedBrowserSessions: config.resolvedBrowserSessions)
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

    /// The Spaces tab's live search, over every field a row is identified by. Fuzzy — the same matcher the
    /// Workspaces sheet and the Mac's command palette use — so a few characters of a name find it without
    /// the user typing a contiguous substring of it.
    ///
    /// Membership only, never order: the list stays in its own project/workspace order while the search
    /// narrows it, rather than reshuffling under the user as they type.
    private func matchesSearch(query: String, fields: [String]) -> Bool {
        guard !query.isEmpty else { return true }
        return FuzzyTextSearch.match(query: query, fields: fields.map { FuzzyTextSearch.Field(text: $0) }) != nil
    }

    private func rowMatchesSearch(_ row: SpacesMobileWorkspaceRuntimeRow, workspace: SpacesDeviceWorkspaceSummary, query: String) -> Bool {
        matchesSearch(query: query, fields: [workspace.projectName, workspace.displayName, workspace.dir, row.title, row.detail])
    }

    private func workspaceMatchesSearch(_ workspace: SpacesDeviceWorkspaceSummary, query: String) -> Bool {
        matchesSearch(query: query, fields: [workspace.projectName, workspace.displayName, workspace.dir])
    }

    private func terminalSessionMatchesSearch(_ session: SpacesDeviceTerminalSessionSummary, query: String) -> Bool {
        guard session.rowKind == .liveSession else { return false }
        return matchesSearch(
            query: query,
            fields: [session.projectName, session.workspaceTitle, session.workingDirectory, session.title, session.liveTitle].compactMap(\.self))
    }

    /// Reads the model's currently published `overview` — the right data for every UI-facing caller,
    /// which wants to know what the *app* currently shows. See `terminalSession(for:in:)` for a caller
    /// that instead needs a specific fetch or mutation response's own evidence.
    func terminalSession(for row: SpacesMobileWorkspaceRuntimeRow) -> SpacesDeviceTerminalSessionSummary? { terminalSession(for: row, in: overview) }

    /// A caller answering someone from a specific fetch or mutation response it already holds in hand —
    /// evidence of what the daemon just did for that one caller's own action, independent of whether
    /// this model's shared, published state happened to win its own ordering race (#450 review round 7)
    /// — passes `searchOverview` explicitly instead of going through `terminalSession(for:)`.
    func terminalSession(for row: SpacesMobileWorkspaceRuntimeRow, in searchOverview: SpacesDeviceOverviewPayload?)
        -> SpacesDeviceTerminalSessionSummary?
    {
        guard let sessionID = row.sessionID else { return nil }
        if let session = searchOverview?.sessions.first(where: { $0.id == sessionID }) { return session }
        guard case .terminal(let terminalRow) = row.source else { return nil }
        return terminalSession(from: terminalRow, in: searchOverview)
    }

    func runtimeRow(forSessionID sessionID: String) -> SpacesMobileWorkspaceRuntimeRow? {
        overview?.workspaces.flatMap(workspaceRuntimeRows(for:)).first { $0.sessionID == sessionID }
    }

    /// See `terminalSession(for:)`/`terminalSession(for:in:)`: reads the published `overview`.
    func refreshedSession(forRowID rowID: String) -> SpacesDeviceTerminalSessionSummary? { refreshedSession(forRowID: rowID, in: overview) }

    /// See `terminalSession(for:in:)`: a caller reading its own fetch or mutation response's evidence
    /// passes that overview explicitly instead of going through `refreshedSession(forRowID:)`.
    func refreshedSession(forRowID rowID: String, in searchOverview: SpacesDeviceOverviewPayload?) -> SpacesDeviceTerminalSessionSummary? {
        searchOverview?.workspaces.flatMap(workspaceRuntimeRows(for:)).first(where: { $0.id == rowID }).flatMap {
            terminalSession(for: $0, in: searchOverview)
        }
    }

    private func terminalSession(from row: SpacesDeviceWorkspaceTerminalRow, in searchOverview: SpacesDeviceOverviewPayload?)
        -> SpacesDeviceTerminalSessionSummary?
    {
        guard let sessionID = row.sessionID else { return nil }
        let workspace = searchOverview?.workspaces.first { $0.id == row.workspaceID }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return SpacesDeviceTerminalSessionSummary(
            id: sessionID, title: row.title, liveTitle: row.liveTitle, workingDirectory: row.workingDirectory, shell: "", command: nil,
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
            // The connection changed while the mutation was in flight: the response describes the
            // previous backend, so resolving a session from it would hand back the wrong device's row.
            guard identity == overviewIdentity else { return nil }
            // Resolved from `response.overview` — this mutation's own evidence of what it just did — not
            // from the model's published `overview`. `applyMutationResponse` above gates its publish on
            // `isOverviewFetchCurrent`, which answers a different question ("is this the freshest
            // overview-derived fact right now") than the one this call owes its own caller ("did my own
            // action produce a session"): a fresher, unrelated fetch (another mutation, a delete
            // reconciliation, a timeout recovery) can bump `mutationGeneration` while this mutation's own
            // `updateBrowserRoutes` await is suspended and make its publish lose that race even though
            // the mutation itself fully succeeded. Reading `self.overview` here would then report a
            // successful Run/Restart/Terminal as a failure — self-healing on the next poll, but only
            // after the launch flow already showed the wrong answer (#450 review round 7).
            if let sessionID = response.sessionID { return response.overview?.sessions.first(where: { $0.id == sessionID }) }
            if let fallbackRowID { return refreshedSession(forRowID: fallbackRowID, in: response.overview) }
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
        // The identity check comes first: a mutation that outlived its connection describes a backend this
        // model no longer shows, and letting it bump the generation would make the NEW device's in-flight
        // refresh discard a perfectly current overview.
        guard identity == overviewIdentity else { return }
        // Bumped for every applied mutation, including one that carried no overview: the daemon's state
        // changed either way, so any poll already in flight is describing the world before it. Captured
        // right after bumping, and re-checked once this call resumes from the await below: a delete's
        // private channel no longer excludes a shared-channel mutation from running at the same time
        // (#450), so two responses can now be applying concurrently, and there is no guarantee the one
        // that started first is the one that resumes first. If some other call's response already bumped
        // and published while this one was suspended, this one is the stale side of that race.
        mutationGeneration &+= 1
        let mutationGenerationAtApply = mutationGeneration
        guard let overview = response.overview else { return }
        await updateBrowserRoutes(overview: overview, identity: identity, mutationGeneration: mutationGenerationAtApply)
        // Skip rather than republish: a newer mutation's response already landed and published its
        // overview while this one was suspended above, so this one is describing a moment the app has
        // already moved past.
        //
        // Accepted bound of this ordering: "newer" is apply-start order on this client, not daemon
        // snapshot order. Responses arriving on independent connections can invert — an older lifecycle
        // response bumping the generation after a newer delete response started applying discards the
        // delete's overview — because nothing in the wire carries a daemon-side revision to totally
        // order snapshots by. A misordered pair leaves stale rows for at most one poll interval and the
        // next overview corrects it; a daemon revision (a wire change) is what fixing it would take.
        guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtApply) else { return }
        // Cleared before publishing, for the same reason as in `performRefresh`.
        connectionNotice = nil
        errorMessage = nil
        publishOverview(overview)
        // A mutation's refreshed overview is proof the device answered, so it ends any run of failed
        // refreshes exactly as a successful poll does. Otherwise a run interrupted by a successful
        // mutation keeps its original start time, and the next isolated failure alerts on the strength
        // of an outage that demonstrably ended.
        refreshFailureStreak = nil
    }

    /// Publishes an accepted overview and trims stale alert dismissals against it. Every path that
    /// publishes a fetched overview goes through here, so the persisted dismissal set is pruned exactly
    /// once per refresh. Clearing the overview (a device switch, a block) deliberately does not prune:
    /// there is nothing to prune against, and pruning against nothing would discard every dismissal.
    /// Settles deletes whose outcome nothing could confirm when they finished (see the `.unknown` case in
    /// `deleteWorkspace`). Every published overview is a chance to answer, whichever path produced it —
    /// the ordinary poll, a later mutation, or a reconciliation — so the resolution lives here, at the one
    /// place an overview becomes the app's state.
    ///
    /// Absent means the delete landed: the marking is dropped silently, and the unknown-branch-outcome
    /// notice is owed if the user had asked for branches to go too. Listed with no teardown queued behind
    /// it means the delete did not land: the marking is dropped and the error the client held back is
    /// surfaced now, against a row the user can act on again. Listed WITH its id in
    /// `workspaceIDsWithTeardownInFlight` is not a verdict at all — the daemon is still tearing it down —
    /// so that entry is left in place for a later overview to answer instead of being consumed here.
    /// Otherwise the entry is consumed, so an overview only ever answers it once.
    private func resolveDeferredWorkspaceDeletions(against payload: SpacesDeviceOverviewPayload) {
        guard !workspaceDeletionsAwaitingOverview.isEmpty else { return }
        let listedWorkspaceIDs = Set(payload.workspaces.map(\.id))
        let teardownInFlightWorkspaceIDs = Set(payload.workspaceIDsWithTeardownInFlight)
        for (workspaceID, deferred) in workspaceDeletionsAwaitingOverview {
            if listedWorkspaceIDs.contains(workspaceID), teardownInFlightWorkspaceIDs.contains(workspaceID) {
                // Still listed, but the daemon reports its teardown still running — not a verdict. Leave
                // the deferral in place for a later overview to settle.
                continue
            }
            workspaceDeletionsAwaitingOverview.removeValue(forKey: workspaceID)
            workspaceIDsPendingDeletion.remove(workspaceID)
            if listedWorkspaceIDs.contains(workspaceID) {
                handleBridgeError(deferred.error)
            } else if deferred.requestedBranchDeletion {
                deletedWorkspaceNotice = Self.unknownBranchOutcomeNotice
            }
        }
    }

    private func publishOverview(_ payload: SpacesDeviceOverviewPayload?) {
        overview = payload
        if let payload {
            pruneDismissedAlertIDs(against: payload)
            resolveDeferredWorkspaceDeletions(against: payload)
        }
    }

    private func handleBridgeError(_ error: Error) {
        if error is CancellationError { return }
        if let recoveryMessage = SpacesDeviceAPIAuthentication.recoveryMessage(for: error) {
            handleAuthenticationFailure(message: recoveryMessage)
            return
        }
        errorMessage = error.localizedDescription
    }

    /// Reconciles a row's session after `run`/`restart` timed out, by refetching the overview and
    /// looking for a fresh session in it. Guarded exactly like every other overview-derived fetch (#450
    /// review round 5): `identity` catches a connection change, and `mutationGenerationAtFetch` — bumped
    /// and captured immediately before the fetch, the same order `applyMutationResponse` uses — catches
    /// a fresher overview-derived fact (another mutation response, a reconciliation fetch) landing while
    /// this fetch or its route update is in flight. A generation mismatch alone skips only the publish
    /// (and `updateBrowserRoutes` skips its own route-table merge and proxy update the same way); the
    /// session lookup below still runs against whatever is currently published either way, which is the
    /// fresher of the two overviews regardless of which one this call fetched.
    private func reconciledSessionAfterMutationTimeout(rowID: String, timeoutRecovery: SpacesMobileMutationTimeoutRecovery, identity: Int) async
        -> SpacesDeviceTerminalSessionSummary?
    {
        if timeoutRecovery.acceptsCachedOverview, let session = refreshedSession(forRowID: rowID) {
            errorMessage = nil
            connectionNotice = nil
            return session
        }
        do {
            // Fetched after the mutation was sent, so it supersedes any poll already in flight. Captured
            // right after bumping, before the fetch — not after it returns, or a fresher fact landing
            // during the fetch itself would already be reflected in the "baseline" this compares against.
            mutationGeneration &+= 1
            let mutationGenerationAtFetch = mutationGeneration
            let refreshedOverview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
            // The connection changed while reconciling: this overview is the previous backend's, so it must
            // not be published as the current connection's state.
            guard identity == overviewIdentity else { return nil }
            await updateBrowserRoutes(overview: refreshedOverview, identity: identity, mutationGeneration: mutationGenerationAtFetch)
            guard identity == overviewIdentity else { return nil }
            if mutationGeneration == mutationGenerationAtFetch {
                errorMessage = nil
                connectionNotice = nil
                refreshFailureStreak = nil
                publishOverview(refreshedOverview)
            }
            // Resolved from `refreshedOverview` — this fetch's own evidence — not from the model's
            // published `overview`, for the same reason `performMutationReturningSession` reads its
            // `response.overview`: a fresher, unrelated overview-derived fact can win the publish race
            // above even though this fetch genuinely found the session, and reading published state here
            // would then report the timeout recovery as failed when it actually succeeded (#450 review
            // round 7).
            return timeoutRecovery.acceptsFreshSession(refreshedSession(forRowID: rowID, in: refreshedOverview))
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

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
    /// The columns/rows of the frame actually fed to the terminal's paint path (the native mirror's
    /// `ownerEpoch.bootstrapSnapshot`), as opposed to `snapshotColumns`/`snapshotRows` above, which track
    /// the model's last-applied render snapshot regardless of whether it was painted. The open hold defers
    /// only the paint: an `.initial` bootstrap payload still updates the model's render snapshot
    /// immediately (it is a state-transition reason, not screen content), so `snapshotColumns` can read a
    /// wider, unpainted grid while the hold is active. This pair tracks `holdsFirstPaint`'s gate instead
    /// (see `TerminalViewerModel.applyReducedState`), so it is nil until the hold actually releases a
    /// frame to paint.
    let appliedFrameColumns: Int?
    let appliedFrameRows: Int?
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
    /// The rendered grid's row height and the offset of its first row from the terminal host view's own
    /// top, both in points (`GhosttyRemoteTerminalViewport.renderedRowGeometry`). A UI test uses these to
    /// tap the row `renderedText` says a target is on, rather than proportioning a normalized offset over
    /// the whole host element's frame: while the software keyboard is up, the rendered rows are a crop
    /// that no longer spans that frame, so a proportional tap lands on the wrong row.
    let renderRowPitchPoints: Double
    let renderTopOffsetPoints: Double
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

    /// The markdown brief the row's coding agent keeps for the user, or nil when it keeps none. Only a
    /// coding agent writes one, so every other row family has none.
    var brief: String? {
        guard case .codingAgent(let row) = source else { return nil }
        return row.brief
    }

    /// When the agent last wrote or cleared its brief (ISO-8601), nil when it never did.
    var briefUpdatedAt: String? {
        guard case .codingAgent(let row) = source else { return nil }
        return row.briefUpdatedAt
    }
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
    /// The device every published fact below is about. `didSet` re-derives the restore offer, because an
    /// offer names the device it was made for: the identity moving is what takes a question about the
    /// previous device off screen, and what lets the next device's own status raise its own.
    var activeDeviceID: String? { didSet { updateSessionRestoreOffer() } }
    /// Whether Demo Mode is on. While on, the device list shows only the synthetic Demo Mac and the
    /// active client is backed by the in-memory `DemoDeviceBackend`; the real paired devices are parked
    /// in memory and left untouched on disk. Persisted across launches via `DemoModeStore`.
    private(set) var isDemoModeEnabled: Bool
    /// `didSet` invalidates `cachedRuntimeRowIndex`: every assignment here (a fresh fetch, or one of the
    /// several resets to `nil`) replaces the runtime rows the index was built from, so a stale index must
    /// not survive it. It also re-derives the restore offer, whose group headings are the workspace names this
    /// payload carries: the first status of a launch or a reconnect can report a record before any
    /// overview has landed, and this is what puts the names above those groups as soon as they exist.
    var overview: SpacesDeviceOverviewPayload? {
        didSet {
            cachedRuntimeRowIndex = nil
            updateSessionRestoreOffer()
        }
    }
    /// The clock every relative-time label (automation next-fire, run started/duration, alert age) reads
    /// at render time instead of calling `Date()` directly. Advances in 30-second jumps
    /// (`advanceRelativeTimeReferenceIfDue`), driven by its own clock task while a device's overview
    /// stream is open (`startRelativeTimeReferenceClock`), and also by every `performRefresh`, matching
    /// the Mac's independent label-only beat (`AutomationsController.armRelativeTimeRefresh`) rather than
    /// on every overview push, which is the churn #540 reports. `@Observable` notifies on this property
    /// exactly like `overview`, so a view reading it re-renders on that cadence regardless of whether the
    /// fetched overview payload itself changed: the equality gate in `publishOverview` gates the overview
    /// payload only, not these labels.
    var relativeTimeReference: Date
    /// Wire-protocol status of the active device, read on each successful refresh. `nil` until the
    /// first handshake. Drives the compatibility banner and blocks incompatible interaction.
    ///
    /// `didSet` re-derives the restore offer: the device reports its restorable record here, so every
    /// path that lands a status (a stream push, an explicit refresh, the standalone handshake, a device
    /// switch, the resets that clear it) is a path that can raise or retire the offer, and deriving it
    /// from the setter means none of them has to remember to.
    var daemonStatus: TerminalServiceDaemonStatus? {
        didSet {
            daemonStatusDeviceID = activeDeviceID
            updateSessionRestoreOffer()
        }
    }
    /// The device `daemonStatus` was read from, stamped as it lands. A device switch replaces the
    /// identity, the overview, and the status in three separate assignments, and each of them re-derives
    /// the restore offer, so a derivation reading the status alone would, in between, pair the device
    /// just switched to with the sessions the previous one reported. Nothing reads this directly; it is
    /// what `activeDeviceDaemonStatus` checks.
    private var daemonStatusDeviceID: String?
    /// `daemonStatus`, but only while it is still a statement about the active device. Every
    /// restore-offer decision reads the status through here so a status can never be paired with another
    /// device's identity; the compatibility banner and the update surfaces keep reading `daemonStatus`
    /// itself, since they are rendered for whatever device last reported and are cleared by the same
    /// switch.
    private var activeDeviceDaemonStatus: TerminalServiceDaemonStatus? { daemonStatusDeviceID == activeDeviceID ? daemonStatus : nil }
    var compatibility: SpacesWireCompatibility?
    var isLoading = false
    /// In flight for every mutation that rides the shared `commandChannel` — create, rename, hide/unhide,
    /// launch/stop/restart, run: the same connection an explicit `refresh()` uses. That connection does not
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
    /// The coding agents the active device is offering to bring back, or nil when it is offering nothing
    /// this app has not already answered, which is the steady state. Derived (see
    /// `updateSessionRestoreOffer`), and the sheet the app shell raises is presented on it.
    ///
    /// Settable because that is what presenting a sheet on it takes; the model is its only deliberate
    /// writer. A dismissal that clears it without an answer loses nothing: the device still reports the
    /// record, so the next status re-derives the same offer and raises it again.
    var sessionRestoreOffer: SessionRestoreOffer?
    /// Which agents a Restore could not bring back, as one report to show. Non-nil only after a device
    /// accepted an answer and named rows it failed to relaunch: it clears its record either way, so this
    /// is the one word the user gets about those agents.
    var sessionRestoreFailureReport: String?
    /// True from the moment an answer is sent until the device has answered it. The offer is not
    /// re-derived while it is set: a device clears its record as it accepts the answer, so the status
    /// that lands mid-call would otherwise pull the sheet out from under the answer it is still making.
    private var isAnsweringSessionRestore = false
    /// The record this app has taken off screen without the device having accepted an answer, per
    /// device: one the device refused as stale, and one whose answer the device would not authenticate.
    ///
    /// Both arrive before any status saying the question is over: the app is holding the status the offer
    /// was built from, and the next one can be a stream push away, or an explicit refresh's away when
    /// nothing is streaming. Without this the same record would be derived again the moment the sheet
    /// closed, putting the user back in a question that has already gone one of those two ways. Held in
    /// memory for the run, keyed like the answered generations: a record that replaced a refused one carries a different
    /// generation, so it is offered as soon as a status reports it, and pairing again clears this
    /// entirely, which is what brings back a record whose answer failed to authenticate.
    private var retiredSessionRestoreGenerations: [String: String] = [:]
    var isShowingConnectionSettings = false
    var isShowingWorkspaceCreateSheet = false
    var connectionNotice: String?
    var pendingPairingLink: SpacesDevicePairingLink?
    /// The most recent time a non-selected paired device rejected this iPhone's credential
    /// (`handleAuthenticationFailure(message:deviceID:)`'s non-selected branch), or nil before the first
    /// one. `TerminalSessionNavigationModifier` (`TerminalFlow.swift`) watches this and closes any open
    /// terminal route for the rejecting device, per the product decision that a device which stops
    /// recognizing this iPhone should not go on showing a terminal for it, the same outcome an open
    /// terminal already reaches on its own when the rejection surfaces through its own request
    /// (`onAuthenticationRequired`). `token` is a counter rather than the event being a plain `Bool`
    /// flip: two rejections in a row for the same device (a stream retry racing a manual retry) must
    /// still both be observable as distinct occurrences, which a repeated identical value would not be.
    struct DeviceAuthenticationRejection: Equatable {
        let deviceID: String
        let token: UInt64
    }
    private(set) var nonSelectedDeviceAuthenticationRejection: DeviceAuthenticationRejection?
    @ObservationIgnored private var nextDeviceAuthenticationRejectionToken: UInt64 = 0
    /// A terminal session a `spaces://terminal/…` deep link asks to focus. The Spaces tab observes
    /// this, pushes the session's detail route, and clears it. Model-driven (rather than a tab-local
    /// binding) so a link handled at the app shell can navigate whichever tab is on screen.
    var pendingTerminalDeepLinkSession: SpacesDeviceTerminalSessionSummary?
    /// `didSet` rather than a dedicated setter wrapping every assignment site: this is set from many
    /// places (an explicit refresh's own failure path in `performRefresh`, a stream failure, mutation failures, deep-link misses,
    /// authentication recovery), and `RootTabView`'s "Connection Error" alert appears on exactly one
    /// transition (nil to non-nil), regardless of which call site caused it. Reporting any other
    /// transition (non-nil to a different message, or to nil) would log alert-adjacent bookkeeping the
    /// user never saw as a second alert.
    var errorMessage: String? {
        didSet {
            guard let errorMessage, oldValue == nil else { return }
            let streakSeconds = refreshFailureStreak.map { streak -> Double in
                let components = (now() - streak.startedAt).components
                return Double(components.seconds) + Double(components.attoseconds) / 1e18
            }
            DevicePerformanceLog.connectionErrorAlert(
                message: errorMessage, refreshFailureStreakSeconds: streakSeconds, openTerminal: activeTerminalSessionID != nil,
                hostCount: settings.hosts.count)
        }
    }
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
    /// Attention events and automation-run alerts the user dismissed, one at a time or with Clear, keyed
    /// by deviceID to that device's bucket of unprefixed event/run identities (see
    /// `SpacesMobileAttentionEvent.eventKey`). Kept for every paired device at once, not only the selected
    /// one, since the Alerts tab lists every paired device's rows together and dismissing or clearing a
    /// non-selected (including offline) device's rows has to take effect immediately.
    ///
    /// Each bucket is exactly what `SpacesMobileDismissedAlertsStore` persists on disk per device; loading
    /// every paired device's bucket into memory here does not change that persisted shape. Reloaded
    /// whenever the paired set can change (init, a device switch, pairing, removal, Demo Mode toggle: see
    /// `loadDismissedAlertIDsForPairedDevices`), and each device's bucket is pruned against its own
    /// freshly delivered overview independently (see `pruneDismissedAlertIDs`).
    private var dismissedAlertIDsByDevice: [String: Set<String>] = [:]
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
    /// The user's recent watches of each recently watched session's terminal detail, oldest first. A
    /// bell for the focused session is excluded live (see `SpacesMobileAttention.events`); once a
    /// session stops being focused, these windows keep excluding a bell that rang while it still was.
    /// In-memory only, like `dismissedAlertIDsByDevice`.
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
    /// Every paired device's most recently delivered overview, keyed by device id. Held for every paired
    /// device while streams are open, not only the selected one; this model reads the selected device's
    /// entry into `overview`, through the same publish path a refresh uses (see `applyFetchedOverview`).
    /// Populated by `handleDeviceStreamOverview` and drained of an entry for a device that stops being
    /// paired (`reconcileDeviceStreams`). An entry for a device that remains paired survives a
    /// backgrounding, so a returning foreground shows what was last known instead of flashing empty state
    /// while streams reopen. Whether each stream currently has a live connection is tracked entirely by
    /// `overviewStreamSubscriptions` (the coordinator); nothing here duplicates it.
    ///
    /// Not `@ObservationIgnored`: the Agents and Alerts tabs derive their rows from every paired device's
    /// entry here, not only the selected one's `overview`, so a non-selected device's delivery has to be
    /// observable too.
    private var deviceOverviews: [String: SpacesDeviceOverviewPayload] = [:]
    /// Paired devices whose overview stream has failed to connect or dropped since its last delivered
    /// overview. Set for any paired device's stream failure (see `handleDeviceStreamFailure`), cleared the
    /// moment that device's stream next delivers an overview (`handleDeviceStreamOverview`). Mirrors the
    /// Mac sidebar's offline rule (`SidebarController.applyRemoteDeviceSection`'s `.failure` branch): no
    /// grace period, and the device keeps its last-known agents/alerts, dimmed, until it recovers. Tracked
    /// explicitly, not derived from `overviewStreamSubscriptions.isLive`, so a device that has never yet
    /// connected (`.opening`) reads as not-offline instead of colliding with one that connected and dropped.
    private(set) var offlineDeviceIDs: Set<String> = []
    /// Non-selected paired devices a frozen-core probe (`classifyNonSelectedDeviceStreamFailure`) has
    /// found running a wire version this app cannot decode. Kept apart from `offlineDeviceIDs`: a blocked
    /// device is blocked, not offline, so `overview(forDeviceID:)` reads this set to drop its rows and
    /// badge count entirely rather than leaving them listed dimmed. Cleared by
    /// `invalidateNonSelectedDeviceConnection` (unpair, re-pair, and every role change route through it)
    /// and by the device's own next delivered compatible overview (`acceptNonSelectedDeviceOverview`).
    /// The active device has no entry here: its own block is `isActiveDeviceBlocked`, kept current by
    /// `applyCompatibility` from both the inline overview path and the standalone handshake fallback.
    /// Not `@ObservationIgnored`: `overview(forDeviceID:)` reads it, and that read has to be tracked so a
    /// probe's verdict refreshes the Agents/Alerts rows and badge count it drives.
    private var blockedNonSelectedDeviceIDs: Set<String> = []
    /// Test-only override: when a device id has an entry here, `overviewStreamClient(forDeviceID:)`
    /// returns it instead of building a client from that device's paired-device record and the real
    /// network backend, so a test can give a *non-selected* device a fake streaming backend. The active
    /// device always uses `bridgeClient` regardless, which is already how a test drives its stream, so
    /// production code (whose test-only init parameter defaults this empty) never consults it.
    @ObservationIgnored private let overviewStreamClientsForTesting: [String: SpacesDeviceAPIClient]
    /// The client built for a non-selected device's overview stream, keyed by device id and reused
    /// across attempts: `SpacesDeviceAPIClient` wraps a resolver that only remembers a proven host and a
    /// failed-host set across a *stable* instance, so rebuilding a fresh client on every reconnect (as
    /// `overviewStreamClient(forDeviceID:)` used to) throws that memory away and can leave a device whose
    /// preferred address is down redialing it forever instead of settling on its Tailscale address.
    /// Matches the Mac sidebar's own per-device resolver reuse (`SpacesDeviceEndpointRegistry`), scoped
    /// to this model instead of process-wide since iOS has one model, not many independent clients.
    /// Keyed alongside the settings the cached client was built from, so a record whose hosts, port,
    /// fingerprint, or token changed is detected on the next lookup and rebuilt rather than silently
    /// reused stale; a device that leaves the desired set is dropped in `reconcileDeviceStreams()`,
    /// alongside its cached overview.
    @ObservationIgnored private var nonActiveDeviceStreamClients:
        [String: (client: SpacesDeviceAPIClient, settings: SpacesMobileConnectionSettings)] = [:]
    /// A non-selected device's row-mutation identity, mirroring `overviewIdentity`'s role for the selected
    /// device: bumped by `invalidateNonSelectedDeviceConnection` whenever that device's connection actually
    /// changes (unpair, re-pair, Demo Mode toggle, reconcile removal), so a mutation response captured
    /// against the old one is recognized as stale. Not bumped by every cache drop:
    /// `rebuildNonSelectedDeviceConnectionForWidenedHosts` also drops the cached client and channel, for a
    /// host list widening that names the same daemon, and leaves this alone on purpose so a mutation whose
    /// own response is what revealed the wider list still reads as current. Missing key reads as 0, the
    /// value every device starts at.
    ///
    /// Also bumped on every role change, in `selectDevice`/`removeDevice`/`enableDemoMode`/
    /// `disableDemoMode`, for both the device losing selection and the device gaining it:
    /// `isCurrent(_:)` only re-checks this identity once a device is non-selected again, so a device that
    /// round-trips (non-selected, briefly selected, non-selected again) would otherwise let a mutation
    /// token captured in the first non-selected stint read as current again in the second, once
    /// `activeDeviceID` no longer names it either time.
    @ObservationIgnored private var nonSelectedDeviceIdentities: [String: Int] = [:]
    /// A non-selected device's delivery counter, mirroring `overviewDeliveryGeneration`'s role for the
    /// selected device: bumped by `acceptNonSelectedDeviceOverview` on every accepted overview for that
    /// device, whether delivered by its stream or by a row mutation's response. `classifyNonSelectedDeviceStreamFailure`
    /// captures this before its handshake probe and re-checks it after, so a verdict answered after a
    /// fresher overview already landed (the stream's own retry reconnected and delivered while the probe
    /// was still in flight) is dropped rather than overwriting state that delivery already settled.
    /// `isCurrent(_:)`'s identity check alone does not catch this: a role or pairing change bumps
    /// `nonSelectedDeviceIdentities`, but an ordinary reconnect-and-deliver on the same, still-non-selected
    /// connection does not, since nothing about the connection's identity changed, only what it last said.
    /// Missing key reads as 0, the value every device starts at.
    @ObservationIgnored private var nonSelectedDeviceDeliveryGenerations: [String: Int] = [:]
    /// A non-selected device's row-mutation command channel, created on first use and reused for later
    /// mutations against the same client; dropped and closed by `invalidateNonSelectedDeviceConnection`
    /// (or, for a widened host list, `rebuildNonSelectedDeviceConnectionForWidenedHosts`) alongside that
    /// device's cached stream client.
    @ObservationIgnored private var nonSelectedDeviceCommandChannels: [String: SpacesDeviceAPICommandChannel] = [:]
    /// The command-path reset `resetDeviceStreamEndpointsForForeground()` fires off for a non-selected
    /// device, kept so `waitForForegroundEndpointRefresh(client:deviceID:)` can await the same reset it
    /// started rather than racing it: that call is intentionally unawaited where it is fired (nothing
    /// there needs it to have landed), but a terminal viewer's own foreground redial does need it landed
    /// before it dials, or it can reach the stale pre-reset address. Cleared on the connection's own
    /// teardown (`invalidateNonSelectedDeviceConnection`), since a discarded client's in-flight reset is
    /// no longer any redial's concern.
    @ObservationIgnored private var nonSelectedDeviceForegroundResetTasks: [String: Task<Void, Never>] = [:]
    /// Owns retry pacing and connect/disconnect bookkeeping for every paired device's overview stream:
    /// the coordinator type the Mac sidebar uses for its own remote devices
    /// (`RemoteOverviewSubscriptionCoordinator` in `spacesdevicecore`). Implicitly-unwrapped because its
    /// `retryDelayPolicy` closure captures `self`, so it can only be built once every other stored
    /// property is initialized; every designated initializer below builds it as its last statement (see
    /// `makeOverviewStreamCoordinator()`).
    @ObservationIgnored private var overviewStreamSubscriptions: RemoteOverviewSubscriptionCoordinator<SpacesDeviceAPIStreamHandle>!
    /// Drives `relativeTimeReference`'s 30-second beat while streams are open; see `startDeviceStreams()`.
    @ObservationIgnored private var relativeTimeReferenceTask: Task<Void, Never>?
    /// The last screen each terminal session painted, kept here because `TerminalDetailView` owns its
    /// `TerminalViewerModel` as `@State` and the pop that closes a terminal destroys both (#674). A
    /// reopen paints from this before it asks the device anything; see `TerminalRetainedScreenStore`.
    @ObservationIgnored let retainedTerminalScreens = TerminalRetainedScreenStore()
    /// Which coding agents' brief sheets the user hid this run; see `AgentBriefVisibility`.
    let agentBriefVisibility = AgentBriefVisibility()
    /// Monotonic identity of the connection the published overview belongs to. Bumped whenever the
    /// active connection changes (device switch or removal, new settings, auth reset) so an overview
    /// fetch begun against the previous connection can neither publish its stale payload nor satisfy
    /// a `refresh()` caller waiting on the new one.
    @ObservationIgnored private var overviewIdentity = 0
    /// The in-flight overview fetch, tagged with the connection identity, the channel generation, and the
    /// mutation generation it was issued under. `refresh()` joins it only while all three still match, and
    /// re-fetches after it completes when any of them moved on.
    @ObservationIgnored private var refreshInFlight: (identity: Int, channelGeneration: Int, mutationGeneration: Int, task: Task<Void, Never>)?
    /// Monotonic generation of the shared command channel's connection, bumped every time
    /// `resetActiveConnectionEndpointAndWait` closes it. The connection identity does not move there (the
    /// device is the same one), but the close aborts whatever request was on that connection, so a fetch
    /// issued before it cannot answer for a caller asking after it: joining one would return without ever
    /// having reached the device, which is the whole point of the read a foreground resume asks for.
    @ObservationIgnored private var connectionChannelGeneration = 0
    /// Bumped every time a mutation's result is applied. An overview is a snapshot of the moment its
    /// fetch was issued, so one that started before a mutation and lands after it carries pre-mutation
    /// state: publishing it would put a deleted workspace, or a stopped process, back on screen as an
    /// ordinary actionable row until the stream's next push. A refresh captures this value when
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
    /// Bumped every time `applyFetchedOverview` accepts a payload (a stream push or a refresh success)
    /// and clears `refreshFailureStreak`. A failure whose compatibility handshake (`refreshCompatibility`)
    /// is held open can still be resolving after that newer success already landed and cleared the
    /// streak; `handleOverviewFailure` captures this at its own attempt's start (or, for a stream
    /// failure, at the moment the failure is observed) and re-checks it before touching
    /// `errorMessage`/`refreshFailureStreak`, so the old failure cannot report on top of the newer
    /// success once the handshake finally completes.
    @ObservationIgnored private var overviewDeliveryGeneration = 0
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
    /// default 5s). Long enough to cover a blip and the selected device's stream redialing two seconds
    /// later, short enough that a device that is actually unreachable is reported promptly. Injectable so
    /// tests can shrink it instead of sleeping through the production wait.
    @ObservationIgnored private let refreshFailureAlertDelay: Duration
    /// Wait between the overview refetches that reconcile an indeterminate workspace delete (production
    /// default 2s, matching the selected device's stream retry cadence). Injectable so tests exercise the
    /// reconciliation loop without sleeping through it.
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
    /// Kept alive for the model's lifetime so the on-device performance log's `thermal_state_change`
    /// subscription (see `DevicePerformanceLog.observeThermalStateChanges`) is not torn down the moment
    /// the token that owns it would otherwise be released.
    @ObservationIgnored private let thermalStateObserverToken: any NSObjectProtocol

    init() {
        // The earliest point in this app's own startup path: every other perf-log call site, on this
        // model and on every `TerminalViewerModel`, assumes the default path is already configured by the
        // time it runs. See `DevicePerformanceLog.configureLoggerAtLaunch` for why the path has to be
        // supplied from inside the app rather than read from the environment on a physical device.
        DevicePerformanceLog.configureLoggerAtLaunch()
        DevicePerformanceLog.appLaunch()
        thermalStateObserverToken = DevicePerformanceLog.observeThermalStateChanges()
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
        relativeTimeReference = wallClock()
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
            // Every stored property must be set before the `self` method calls below (definite
            // initialization); `makeOverviewStreamCoordinator()`'s captured closure is the one call that
            // legitimately needs `self` fully valid, so it alone stays last.
            overviewStreamClientsForTesting = [:]
            loadDismissedAlertIDsForPairedDevices()
            overviewStreamSubscriptions = makeOverviewStreamCoordinator()
            return
        }

        let bridgeClient = SpacesDeviceAPIClient(settings: deviceState.settings, deviceName: deviceName)
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        isDemoModeEnabled = false
        self.bridgeClient = bridgeClient
        commandChannel = bridgeClient.makeCommandChannel()
        // See the Demo Mode branch above: every stored property must be set before the `self` method
        // calls below.
        overviewStreamClientsForTesting = [:]
        loadDismissedAlertIDsForPairedDevices()
        pruneDismissedAlertsForUnknownDevices()
        overviewStreamSubscriptions = makeOverviewStreamCoordinator()
    }

    init(
        settings: SpacesMobileConnectionSettings, bridgeClient: SpacesDeviceAPIClient, browserProxy: SpacesMobileBrowserProxy? = nil,
        daemonUpdatePollInterval: Duration = .seconds(3), daemonUpdateTimeout: Duration = .seconds(30),
        refreshFailureAlertDelay: Duration = .seconds(5), workspaceDeletionReconciliationInterval: Duration = .seconds(2),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }, wallClock: @escaping @Sendable () -> Date = { Date() },
        overviewStreamClientsForTesting: [String: SpacesDeviceAPIClient] = [:]
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
        relativeTimeReference = wallClock()
        // Test-only construction path (every test in this suite goes through it): a real
        // `thermal_state_change` subscription is pointless here and would leak a `NotificationCenter`
        // observer per test instance across the whole run, so this carries an inert token instead.
        thermalStateObserverToken = DevicePerformanceLog.inertObserverToken()
        self.overviewStreamClientsForTesting = overviewStreamClientsForTesting
        overviewStreamSubscriptions = makeOverviewStreamCoordinator()
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

    /// `workspaceGroups`, stably partitioned so the device's home project's group (if visible) leads the
    /// list. The daemon orders projects by name and `~` sorts after every letter, but the home row's place
    /// at the top of the device's list is a presentation rule this client owns, not a fact about the
    /// account's projects the daemon needs to encode, so the reorder happens here rather than in the
    /// overview payload. A stable filter-and-concatenate rather than a sort: every other group keeps
    /// whatever order `workspaceGroups` (or a search) already gave it, home group(s) simply move first.
    var homeFirstWorkspaceGroups: [SpacesMobileWorkspaceGroup] {
        let groups = workspaceGroups
        let home = groups.filter { $0.workspace.projectKind == .home }
        guard !home.isEmpty else { return groups }
        return home + groups.filter { $0.workspace.projectKind != .home }
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

    /// Every paired device with a currently cached overview, paired with its display name and offline
    /// flag: the input the Agents and Alerts tabs' pure derivations need to span every paired device (see
    /// `SpacesMobileDeviceOverviewContext`). A freshly paired device still connecting for the first time
    /// has no cached overview yet, so it contributes nothing.
    private var deviceOverviewContexts: [SpacesMobileDeviceOverviewContext] {
        pairedDevices.compactMap { device in
            guard let deviceOverview = overview(forDeviceID: device.id) else { return nil }
            return SpacesMobileDeviceOverviewContext(
                deviceID: device.id, deviceName: device.name, overview: deviceOverview, isOffline: offlineDeviceIDs.contains(device.id))
        }
    }

    /// `deviceID`'s most recently delivered overview: `overview` itself for the selected device when it
    /// has one (the published fact every other active-device derivation reads, kept current by every path
    /// that can change it, and read ahead of the stream cache below so a fresher refresh or mutation
    /// response is never shadowed by a stream push that has not caught up yet), falling back to
    /// `deviceOverviews[deviceID]` when it does not; `deviceOverviews[deviceID]` alone for any other
    /// paired device. The fallback matters because `overview` goes nil at several points that leave the
    /// device otherwise fully paired and still streaming (a device switch away and back, an auth failure):
    /// `deviceOverviews[activeDeviceID]` is that same device's own stream-delivered data the whole time
    /// (`handleDeviceStreamOverview` writes it for the selected device too, not only for others), so
    /// Agents/Alerts can keep showing its rows instead of the device's data vanishing and reappearing.
    ///
    /// Nil for a blocked device, matching the Mac sidebar's empty section for the same case and spec.md's
    /// "a daemon too old for the app blocks only that device": a blocked device contributes no rows,
    /// badge count, or session lookup, whether it is selected or not. Checked once here, the one place
    /// every cross-device read goes through, rather than in each caller, so row lookups, session lookups,
    /// and row actions all agree. A blocked device is blocked, not offline: this folds it out of
    /// `deviceOverviewContexts` entirely rather than leaving it in with an offline marking.
    ///
    /// Blocked is decided two different ways depending on whether a fresh, decoded payload is in hand:
    /// - The active device: `isActiveDeviceBlocked`, not a re-derivation from the raw payload's own
    ///   `daemonStatus`. `isActiveDeviceBlocked` is kept current by `applyCompatibility` from *both* an
    ///   overview's inline status and the standalone handshake fallback `handleOverviewFailure` runs when
    ///   an overview cannot be fetched or decoded at all; the raw payload cached in `deviceOverviews`
    ///   cannot be, since a decode failure delivers nothing to cache. Re-deriving from that stale payload's
    ///   own (still-compatible) `daemonStatus` would miss exactly this case: a block discovered only
    ///   through the fallback handshake, with the last *compatible* overview still sitting in the cache.
    /// - Every other paired device: `blockedNonSelectedDeviceIDs`, set the same way by
    ///   `classifyNonSelectedDeviceStreamFailure`'s own fallback handshake (there is no per-device
    ///   `compatibility` state var to read for a device that is not selected), plus a plain read of the raw
    ///   cached payload's own `daemonStatus` for the case that payload decoded fine but reported
    ///   incompatible inline (no handshake needed to have discovered that one).
    func overview(forDeviceID deviceID: String) -> SpacesDeviceOverviewPayload? {
        if deviceID == activeDeviceID {
            guard !isActiveDeviceBlocked else { return nil }
            let raw = overview ?? deviceOverviews[deviceID]
            guard let raw, SpacesWireCompatibility.evaluate(daemonStatus: raw.daemonStatus).isCompatible else { return nil }
            return raw
        }
        guard !blockedNonSelectedDeviceIDs.contains(deviceID) else { return nil }
        guard let raw = deviceOverviews[deviceID], SpacesWireCompatibility.evaluate(daemonStatus: raw.daemonStatus).isCompatible else { return nil }
        return raw
    }

    /// Whether the "· device" segment should show on every Agents/Alerts row right now. A single global
    /// decision, not computed per tab: see `SpacesMobileDeviceDisplay.showsDeviceSegment`.
    private var showsDeviceSegment: Bool {
        SpacesMobileDeviceDisplay.showsDeviceSegment(
            pairedDeviceCount: pairedDevices.count, hasOfflineDevice: pairedDevices.contains { offlineDeviceIDs.contains($0.id) })
    }

    /// Attention events across every paired device with a cached overview, newest first, with the user's
    /// cleared events filtered out. Flat, not grouped by workspace: the Alerts tab shows one cross-device
    /// list (see `AlertsTabView`), and each event carries its own project/workspace/device text instead of
    /// a band header naming it.
    var attentionEvents: [SpacesMobileAttentionEvent] {
        let showsDeviceSegment = showsDeviceSegment
        return deviceOverviewContexts.flatMap { device -> [SpacesMobileAttentionEvent] in
            let deviceText = showsDeviceSegment ? SpacesMobileDeviceDisplay.text(name: device.deviceName, isOffline: device.isOffline) : nil
            let dismissed = dismissedAlertIDsByDevice[device.deviceID] ?? []
            return SpacesMobileAttention.events(
                deviceID: device.deviceID, deviceText: deviceText, in: device.overview, focusedSessionID: watchedTerminalSessionID,
                watchWindowsBySessionID: terminalWatchWindowsBySessionID, isDeviceOffline: device.isOffline
            ).filter { !dismissed.contains($0.eventKey) }
        }.sorted { $0.date > $1.date }
    }

    /// Points bell suppression at the terminal detail now on screen, or nil once none is. Leaving a
    /// detail (closing it, or switching straight to another session) closes the outgoing session's watch
    /// window, so the bell it rang while the user was watching does not alert when a later overview
    /// delivery reports it.
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

    /// Failed/timed-out automation-run alert entries across every paired device with a cached overview,
    /// newest first, with cleared entries filtered out. Automation runs are workspace-less, so these join
    /// `attentionEvents` in one flat Alerts list with "Automation" standing in for a project/workspace;
    /// see `SpacesMobileAutomationAlerts`.
    var automationAlerts: [SpacesMobileAutomationAlertEntry] {
        let showsDeviceSegment = showsDeviceSegment
        return deviceOverviewContexts.flatMap { device -> [SpacesMobileAutomationAlertEntry] in
            let deviceText = showsDeviceSegment ? SpacesMobileDeviceDisplay.text(name: device.deviceName, isOffline: device.isOffline) : nil
            let dismissed = dismissedAlertIDsByDevice[device.deviceID] ?? []
            return SpacesMobileAutomationAlerts.entries(
                deviceID: device.deviceID, deviceText: deviceText, runs: device.overview.automationRuns, isDeviceOffline: device.isOffline
            ).filter { !dismissed.contains($0.eventKey) }
        }.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case (let a?, let b?): return a > b
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }

    /// What the Alerts tab actually renders: `attentionEvents` and `automationAlerts` merged into one
    /// cross-device, newest-first list (see `SpacesMobileAlertItems.merge`).
    var alertItems: [SpacesMobileAlertItem] { SpacesMobileAlertItems.merge(events: attentionEvents, automationAlerts: automationAlerts) }

    /// Undismissed attention-event and automation-alert count, shown as the Alerts tab badge. Counts an
    /// offline device's own undismissed alerts too, the same as any other paired device's, so the badge
    /// always equals the number of rows the Alerts tab actually shows.
    var undismissedAlertCount: Int { attentionEvents.count + automationAlerts.count }

    /// Marks every currently derived attention event and automation alert dismissed, across every paired
    /// device with a cached overview.
    func clearAlerts() {
        for device in deviceOverviewContexts {
            var dismissed = dismissedAlertIDsByDevice[device.deviceID] ?? []
            dismissed.formUnion(
                SpacesMobileAttention.events(
                    deviceID: device.deviceID, deviceText: nil, in: device.overview, focusedSessionID: watchedTerminalSessionID,
                    watchWindowsBySessionID: terminalWatchWindowsBySessionID
                ).map(\.eventKey))
            dismissed.formUnion(
                SpacesMobileAutomationAlerts.entries(deviceID: device.deviceID, deviceText: nil, runs: device.overview.automationRuns).map(\.eventKey)
            )
            dismissedAlertIDsByDevice[device.deviceID] = dismissed
            saveDismissedAlertIDs(deviceID: device.deviceID)
        }
    }

    /// Dismisses one attention event, on whichever device it came from.
    func dismissAlert(_ event: SpacesMobileAttentionEvent) {
        dismissedAlertIDsByDevice[event.deviceID, default: []].insert(event.eventKey)
        saveDismissedAlertIDs(deviceID: event.deviceID)
    }

    /// `row`'s own currently undismissed attention events on `deviceID`: its exited/waiting/finished
    /// event (if any) plus any bell on its session, derived via the same focus/watch-window bell
    /// suppression the Alerts tab uses (`SpacesMobileAttention.events`), so a bell rung while its terminal
    /// viewer was open or inside a watch window never offers "Dismiss Alert" for something the user
    /// already saw live. Hidden workspaces stay included: that filter only serves the Alerts tab, not
    /// row-level dismissal. Backs both the row's "Dismiss Alert" menu item's visibility and what it
    /// dismisses.
    ///
    /// `deviceID` is explicit rather than always the selected device: the Spaces tab's own row menu only
    /// ever shows the selected device's rows and passes `activeDeviceID`, but the Agents tab lists every
    /// paired device's rows in one list and passes each row's own device.
    func undismissedAlerts(for row: SpacesMobileWorkspaceRuntimeRow, deviceID: String) -> [SpacesMobileAttentionEvent] {
        guard let overview = overview(forDeviceID: deviceID) else { return [] }
        let dismissed = dismissedAlertIDsByDevice[deviceID] ?? []
        // Same focus/watch-window inputs as `attentionEvents`, for every device: a watched session id is
        // unique across devices, so passing them regardless of `deviceID` costs nothing and a terminal
        // open on another device suppresses its own bell correctly instead of only the selected device's.
        return SpacesMobileAttention.events(
            deviceID: deviceID, deviceText: nil, in: overview, focusedSessionID: watchedTerminalSessionID,
            watchWindowsBySessionID: terminalWatchWindowsBySessionID, includingHiddenWorkspaces: true
        ).filter { row.matches($0) && !dismissed.contains($0.eventKey) }
    }

    /// Whether `row` has anything its long-press "Dismiss Alert" menu item could dismiss.
    func hasUndismissedAlerts(for row: SpacesMobileWorkspaceRuntimeRow, deviceID: String) -> Bool {
        !undismissedAlerts(for: row, deviceID: deviceID).isEmpty
    }

    /// Dismisses every one of `row`'s currently undismissed attention events in one action — identical in
    /// effect to dismissing each individually from the Alerts tab: same dismissal bucket, same badge.
    func dismissAlerts(for row: SpacesMobileWorkspaceRuntimeRow, deviceID: String) {
        let events = undismissedAlerts(for: row, deviceID: deviceID)
        guard !events.isEmpty else { return }
        dismissedAlertIDsByDevice[deviceID, default: []].formUnion(events.map(\.eventKey))
        saveDismissedAlertIDs(deviceID: deviceID)
    }

    /// Whether `row`'s own exited-process event, if it has one right now, is already dismissed: the
    /// signal that turns its dot from failed red to the unstarted stroke (see
    /// `SpacesMobileWorkspaceRuntimeRow.statusDotKind(exitAcknowledged:)`). Only a `.process` row can have
    /// one: every other row family's dot keeps tracking live state regardless of dismissal. Scoped to the
    /// selected device only, unlike `undismissedAlerts(for:deviceID:)`.
    func isExitAcknowledged(_ row: SpacesMobileWorkspaceRuntimeRow) -> Bool {
        guard case .process = row.source, let activeDeviceID, let overview else { return false }
        guard
            let event = SpacesMobileAttention.allEvents(deviceID: activeDeviceID, in: overview).first(where: { row.matches($0) && $0.kind == .exited }
            )
        else { return false }
        return (dismissedAlertIDsByDevice[activeDeviceID] ?? []).contains(event.eventKey)
    }

    /// Dismisses one failed/timed-out automation run, on whichever device it came from.
    func dismissAutomationAlert(_ entry: SpacesMobileAutomationAlertEntry) {
        dismissedAlertIDsByDevice[entry.deviceID, default: []].insert(entry.eventKey)
        saveDismissedAlertIDs(deviceID: entry.deviceID)
    }

    /// Drops `deviceID`'s stored dismissals whose event/run its overview no longer produces, so its
    /// persisted bucket stays bounded by what the device currently reports rather than growing for the
    /// life of the install.
    private func pruneDismissedAlertIDs(deviceID: String, against overview: SpacesDeviceOverviewPayload) {
        let bucket = dismissedAlertIDsByDevice[deviceID] ?? []
        // Automation-run alerts share the dismissal bucket but derive from `automationRuns`, not
        // attention events, so retain their dismissals separately or a prune would resurface dismissed run
        // alerts.
        let retained = SpacesMobileAttention.retainedDismissedEventIDs(bucket, deviceID: deviceID, in: overview).union(
            bucket.intersection(
                Set(SpacesMobileAutomationAlerts.entries(deviceID: deviceID, deviceText: nil, runs: overview.automationRuns).map(\.eventKey))))
        guard retained != bucket else { return }
        dismissedAlertIDsByDevice[deviceID] = retained
        saveDismissedAlertIDs(deviceID: deviceID)
    }

    /// Loads every paired device's persisted dismissal bucket into memory, discarding whatever was there
    /// before. Called at every chokepoint that can change the paired set (init, a device switch, pairing,
    /// removal, Demo Mode enable/disable) so `dismissedAlertIDsByDevice` always matches the devices whose
    /// overviews are about to be published, never a leftover from before the change. Each device's own
    /// bucket is still what is loaded and saved individually, so this changes nothing about what is on disk.
    private func loadDismissedAlertIDsForPairedDevices() {
        dismissedAlertIDsByDevice = Dictionary(
            uniqueKeysWithValues: pairedDevices.map { ($0.id, SpacesMobileDismissedAlertsStore.load(deviceID: $0.id)) })
        // Unconfirmed deletes belong to the connection they were issued against: another device's overview
        // cannot answer whether this one's workspace was deleted, and leaving an entry behind would let the
        // next published overview resolve it against the wrong device. Dropped with the marking, silently —
        // the delete may well have landed, and there is no longer anyone to report a verdict to.
        workspaceDeletionsAwaitingOverview.removeAll()
        workspaceIDsPendingDeletion.removeAll()
    }

    /// Persists `deviceID`'s in-memory bucket back into its own slot in the store.
    private func saveDismissedAlertIDs(deviceID: String) {
        SpacesMobileDismissedAlertsStore.save(dismissedAlertIDsByDevice[deviceID] ?? [], deviceID: deviceID)
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

    /// Coding-agent rows across every paired device with a cached overview, grouped by activity for the
    /// Agents tab.
    var agentGroups: [SpacesMobileAgentGroup] {
        SpacesMobileAgentGrouping.groups(devices: deviceOverviewContexts, showsDeviceSegment: showsDeviceSegment)
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
            // The command changed the device, so every overview fetch issued before it describes a
            // device without the change. Bumped like any other device-changing call so one of those in
            // flight is discarded rather than published, and so the read below issues its own request
            // instead of joining it.
            mutationGeneration &+= 1
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
            // Bumped before the read for the reason given in triggerAutomation.
            mutationGeneration &+= 1
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
            // Bumped before the read for the reason given in triggerAutomation.
            mutationGeneration &+= 1
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
            // Bumped before the read for the reason given in triggerAutomation.
            mutationGeneration &+= 1
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

    /// `session(forSessionID:)`, scoped to any paired device rather than only the selected one: resolves
    /// a session opened from a non-selected device's Agents/Alerts row.
    func session(forSessionID sessionID: String, deviceID: String) -> SpacesDeviceTerminalSessionSummary? {
        guard deviceID != activeDeviceID else { return session(forSessionID: sessionID) }
        let deviceOverview = overview(forDeviceID: deviceID)
        if let session = deviceOverview?.sessions.first(where: { $0.id == sessionID }) { return session }
        return runtimeRow(forSessionID: sessionID, deviceID: deviceID).flatMap { terminalSession(for: $0, in: deviceOverview) }
    }

    /// `runtimeRow(forSessionID:)`, scoped to any paired device. Not cached like the selected device's own
    /// `runtimeRowIndex`: this path is cold (a background device's terminal chrome, not the selected
    /// device's hot render loop), so a fresh scan each call is cheap enough to skip the cache's own
    /// invalidation bookkeeping.
    func runtimeRow(forSessionID sessionID: String, deviceID: String) -> SpacesMobileWorkspaceRuntimeRow? {
        guard deviceID != activeDeviceID else { return runtimeRow(forSessionID: sessionID) }
        return overview(forDeviceID: deviceID)?.workspaces.flatMap(workspaceRuntimeRows(for:)).first(where: { $0.sessionID == sessionID })
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

    /// Ends the current run of failed refreshes because nothing is watching this connection any more.
    /// `stopDeviceStreams()` calls this itself, since foreground streams are the thing that watches a
    /// connection; this stays callable on its own too for a pause that is not a stream stop (the
    /// `.background` scene-phase change already goes through `stopDeviceStreams()`, so it does not call
    /// this separately). The alert gate reads wall-clock time between failures, and nothing watches the
    /// connection while paused, so a failure recorded before this and one recorded after are far apart
    /// with no evidence of anything in between. Without this, that pair reads as a long-running outage
    /// and the first blip on the way back raises the alert: the very interruption the gate exists to
    /// prevent. Attempts already in flight are covered too: they resume with a start time from before
    /// the pause, so `performRefresh` drops their failure timing rather than letting it rebuild the run
    /// this just ended.
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
    ///
    /// `isStillCurrent` is the same additional check `applyFetchedOverview` runs on its own payload
    /// (its delivery generation, or, for a stream frame, whether it is still that device's latest one):
    /// every caller either has such a rule and passes it, or has none and passes `{ true }`, so this
    /// method's own merge honors whichever staleness rule the caller's payload is actually subject to
    /// instead of only the identity/mutation-generation check every caller shares.
    private func updateBrowserRoutes(
        overview: SpacesDeviceOverviewPayload, identity: Int, mutationGeneration fetchGeneration: Int, isStillCurrent: () -> Bool
    ) async {
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
        guard isOverviewFetchCurrent(identity: identity, mutationGeneration: fetchGeneration), isStillCurrent() else { return }
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

    // MARK: - Device overview streams

    /// Builds `overviewStreamSubscriptions` for a designated initializer's last statement, once every
    /// other stored property already has a value: `retryDelayPolicy` below captures `self`, so building
    /// the coordinator any earlier is a definite-initialization violation.
    private func makeOverviewStreamCoordinator() -> RemoteOverviewSubscriptionCoordinator<SpacesDeviceAPIStreamHandle> {
        let coordinator = RemoteOverviewSubscriptionCoordinator<SpacesDeviceAPIStreamHandle>(requestReconcile: { [weak self] in
            self?.reconcileDeviceStreams()
        })
        coordinator.retryDelayPolicy = { [weak self] deviceID, failures in
            // The device on screen redials at a fixed 2 s cadence so a brief outage recovers quickly; a
            // device merely paired and held in the background uses the coordinator's default growing
            // backoff, so every paired-but-unwatched device does not storm a remote that is genuinely down.
            guard let self, deviceID == self.activeDeviceID else {
                return RemoteConnectionBackoff.delay(
                    consecutiveFailures: failures, floor: .seconds(5), cap: .seconds(60), jitterFraction: Double.random(in: 0..<0.25))
            }
            return .seconds(2)
        }
        return coordinator
    }

    /// Opens every paired device's overview stream and starts the age-clock beat. Called when the scene
    /// becomes active. Idempotent: `reconcile` only opens a device with neither a live subscription nor a
    /// connect already in flight, so a redundant call (e.g. a device switch right after foreground) opens
    /// nothing twice.
    func startDeviceStreams() {
        overviewStreamSubscriptions.enable()
        startRelativeTimeReferenceClock()
        reconcileDeviceStreams()
    }

    /// Foreground re-preference for every paired device's overview stream: the streaming counterpart of
    /// `resetActiveConnectionEndpoint()`'s command-path reset. Called from the same foreground site
    /// (`RootTabView`'s `.active` branch), right after `SpacesMobileDeviceStore.clearActiveHosts()` and
    /// before `startDeviceStreams()` reopens every stream, so each one's next connect walks `hosts` from
    /// the top instead of going straight back to whatever address it proved reachable before
    /// backgrounding (e.g. a Tailscale address that still answers away from home).
    ///
    /// Resets every non-selected device's cached client in place rather than discarding it the way
    /// `invalidateNonSelectedDeviceConnection` does: a discard also bumps that device's mutation identity,
    /// which is reserved for a real connection change (unpair, re-pair, Demo Mode toggle, reconcile
    /// removal, see that method's doc comment), not a foreground re-preference of the same daemon. An
    /// open terminal viewer for a non-selected device holds this same client instance
    /// (`terminalContext(forDeviceID:)` reuses it), so resetting its resolvers in place, rather than
    /// swapping in a fresh client the viewer never sees, is what gives that viewer's own foreground redial
    /// the fresh top-of-hosts race too.
    ///
    /// Two kinds of reset per device, because a client's command-path resolver and its overview-stream
    /// resolver are reset through different means:
    /// - The overview-stream reset (`resetOverviewStreamEndpointResolution()`) is synchronous and
    ///   lock-based, so every device's reset below runs to completion before this function returns, and
    ///   the caller can call `startDeviceStreams()` immediately afterward with no risk of the reset racing
    ///   behind the reconnect it is supposed to precede.
    /// - The command-path reset (`resetEndpointResolution()`) and its cached channel's close are `async`,
    ///   the same shape `resetActiveConnectionEndpointAndWait()` awaits for the selected device. Fired off
    ///   here instead of awaited: nothing here needs it to have landed, only a later row mutation on that
    ///   device does, and one issued before the reset lands simply meets the resolver mid-reset, the same
    ///   accepted race `resetActiveConnectionEndpoint()` documents for the selected device.
    ///
    /// The selected device's stream runs through `bridgeClient`, which the app keeps and reuses for the
    /// whole session rather than rebuilding on every foreground, so its `overviewStreamResolver` keeps
    /// whatever winner (and failed-host set) it learned in memory regardless of what the persisted
    /// store now says. `clearActiveHosts()` alone never reaches it; it has to be told directly.
    ///
    /// Releases `nonSelectedForegroundResetWaiters` once every device's task above is recorded: see
    /// `isNonSelectedForegroundResetPending`'s doc comment for why a non-selected terminal's own
    /// foreground redial needs to wait for that, not just for the task it names.
    func resetDeviceStreamEndpointsForForeground() {
        for (deviceID, cached) in nonActiveDeviceStreamClients {
            cached.client.resetOverviewStreamEndpointResolution()
            let client = cached.client
            let channel = nonSelectedDeviceCommandChannels[deviceID]
            // Recorded so a terminal viewer's own foreground redial can await this exact reset instead
            // of racing it; see `nonSelectedDeviceForegroundResetTasks`'s doc comment.
            nonSelectedDeviceForegroundResetTasks[deviceID] = Task {
                await client.resetEndpointResolution()
                await channel?.close()
            }
        }
        bridgeClient.resetOverviewStreamEndpointResolution()
        releaseNonSelectedForegroundResetWaiters()
    }

    /// Closes every paired device's overview stream and stops the age-clock beat. Called when the scene
    /// backgrounds (streams are foreground-only, and a backgrounded device's alerts are APNs, not this
    /// stream) and from a StoreKit paywall swap while the scene stays active. Also ends the current
    /// failure-streak run (`noteConnectionMonitoringPaused()`): foreground streams are the thing that
    /// watches the connection, so closing them for either reason means nothing is watching it until they
    /// reopen, and a streak spanning the gap would otherwise count that whole interval as one continuous
    /// outage. Leaves `deviceOverviews` untouched, so a returning foreground shows each device's
    /// last-known overview while its stream reopens instead of flashing empty state.
    func stopDeviceStreams() {
        stopRelativeTimeReferenceClock()
        for handle in overviewStreamSubscriptions.disable() { handle.cancel() }
        noteConnectionMonitoringPaused()
    }

    /// Awaits any retry the coordinator has armed for a paired device's stream. Test-only: the retry
    /// timer runs on the real wall clock, not the model's injectable `now`, so a test proving the
    /// selected device's fixed 2 s redial cadence drains this instead of sleeping past it or polling
    /// under a ceiling. A no-op when nothing is armed.
    func drainPendingDeviceStreamRetryForTesting() async { await overviewStreamSubscriptions.drainPendingRetryForTesting() }

    /// Test-only: `overviewStreamClient(forDeviceID:)`'s result, directly callable so a test can prove
    /// `nonActiveDeviceStreamClients` reuses the same client across two lookups without driving a real
    /// connect/retry cycle to exercise it indirectly.
    func overviewStreamClientForTesting(deviceID: String) -> SpacesDeviceAPIClient? { overviewStreamClient(forDeviceID: deviceID) }

    /// Test-only: seeds `nonActiveDeviceStreamClients[deviceID]` directly with a caller-built client, so
    /// a test can make a controllable fake (e.g. a backend whose `resetEndpointResolution()` blocks on a
    /// gate) the one `resetDeviceStreamEndpointsForForeground()`/`isCurrentTerminalClient(_:forDeviceID:)`
    /// treat as current for a non-selected device. `overviewStreamClientsForTesting` cannot stand in for
    /// this: it is read and returned before `nonActiveDeviceStreamClients` is ever consulted, so nothing
    /// backed by it lands in the cache these two read.
    func setNonActiveDeviceStreamClientForTesting(_ client: SpacesDeviceAPIClient, settings: SpacesMobileConnectionSettings, deviceID: String) {
        nonActiveDeviceStreamClients[deviceID] = (client: client, settings: settings)
    }

    /// Test-only: the browser proxy's routing table, so a test can prove which of two racing
    /// `updateBrowserRoutes` merges (a stale one, or a fresher one) is the one actually reflected in it,
    /// which `model.overview` alone does not show.
    var browserRoutingTableForTesting: BrowserProxyRoutingTable { browserRoutingTable }

    /// Test-only: `deviceOverviews[deviceID]`, so a test can prove a device's cached delivery was
    /// dropped rather than merely not currently published through `overview`.
    func deviceOverviewForTesting(deviceID: String) -> SpacesDeviceOverviewPayload? { deviceOverviews[deviceID] }

    /// Test-only: seeds a non-selected paired device's cached overview directly, so a cross-device
    /// Agents/Alerts derivation can be exercised against two devices without driving a real stream
    /// connect/push through the fake backend `SpacesMobileDeviceOverviewStreamTests` uses.
    func setDeviceOverviewForTesting(_ overview: SpacesDeviceOverviewPayload, deviceID: String) { deviceOverviews[deviceID] = overview }

    /// Test-only: sets `deviceID`'s offline marking directly, mirroring what a real stream failure/
    /// delivery does inside `handleDeviceStreamFailure`/`handleDeviceStreamOverview`.
    func setOfflineForTesting(_ isOffline: Bool, deviceID: String) {
        if isOffline { offlineDeviceIDs.insert(deviceID) } else { offlineDeviceIDs.remove(deviceID) }
    }

    /// Test-only: `dismissedAlertIDsByDevice[deviceID]`, so a test can read or seed a device's in-memory
    /// dismissed set directly (e.g. simulating a dismissal already on file before a `refresh()` that
    /// should prune it) without going through the real paired-device store's persisted-load path.
    func dismissedAlertIDsForTesting(deviceID: String) -> Set<String> { dismissedAlertIDsByDevice[deviceID] ?? [] }
    func setDismissedAlertIDsForTesting(_ ids: Set<String>, deviceID: String) { dismissedAlertIDsByDevice[deviceID] = ids }

    /// Reconciles the coordinator's tracked devices to the current paired set and opens whatever it asks
    /// for. Called on every event that can change which devices should have a stream (foreground resume,
    /// pairing, device removal, device switch, Demo Mode toggle, and by the coordinator itself once an
    /// armed retry fires) as well as a no-op reconcile that mostly just confirms the invariant holds.
    private func reconcileDeviceStreams() {
        guard overviewStreamSubscriptions.isEnabled else { return }
        let desiredIDs = Set(pairedDevices.compactMap { isDeviceCredentialedForStreaming($0) ? $0.id : nil })
        let outcome = overviewStreamSubscriptions.reconcile(desiredIDs: desiredIDs)
        for (_, handle) in outcome.removed { handle.cancel() }
        // `outcome.removed` only reports a device the coordinator had a live client for; one still
        // `.opening` or waiting out an armed retry is dropped from the coordinator's tracking just the
        // same but hands back no client here. Prune every cached overview and cached client against
        // `desiredIDs` directly instead of against `outcome.removed`, so re-pairing the same device id
        // never republishes the overview left over from before it was removed, or reconnects through a
        // client built for a record that no longer applies. Read from both caches' own keys, not just
        // one: a device still `.opening` with no push yet has a cached client but no cached overview.
        let staleDeviceIDs = Set(deviceOverviews.keys).union(nonActiveDeviceStreamClients.keys).union(offlineDeviceIDs).subtracting(desiredIDs)
        for deviceID in staleDeviceIDs {
            deviceOverviews[deviceID] = nil
            invalidateNonSelectedDeviceConnection(deviceID: deviceID)
            offlineDeviceIDs.remove(deviceID)
        }
        // A dropped device's own overview above is not routed through `publishOverview`, so its retained
        // screens need this call spelled out here: this is also what drops them on a Demo Mode toggle,
        // since Demo Mode swaps the whole paired set and every real device becomes stale the same way.
        if !staleDeviceIDs.isEmpty { pruneRetainedTerminalScreens() }
        for (deviceID, attempt) in outcome.devicesToOpen { openDeviceStream(deviceID: deviceID, attempt: attempt) }
    }

    /// Drops `deviceID`'s cached stream client and row-mutation command channel and bumps its mutation
    /// identity, so a `MutationConnectionToken` captured before this call is recognized as stale rather
    /// than applying a response against a connection the app no longer dials. Called for every role change
    /// (select, deselect, Demo Mode) as well as an unpair or a re-pair, so this is also where a device's
    /// `blockedNonSelectedDeviceIDs` mark clears: a role change or a fresh pairing means a fresh
    /// connection, and the block a previous connection's probe found must not outlive it. A device that is
    /// genuinely still on an incompatible daemon re-earns the mark the next time its stream fails.
    private func invalidateNonSelectedDeviceConnection(deviceID: String) {
        if let channel = nonSelectedDeviceCommandChannels[deviceID] { Task { await channel.close() } }
        nonSelectedDeviceCommandChannels[deviceID] = nil
        nonActiveDeviceStreamClients[deviceID] = nil
        nonSelectedDeviceIdentities[deviceID, default: 0] &+= 1
        blockedNonSelectedDeviceIDs.remove(deviceID)
        // A reset still in flight for the discarded client is no longer anything a redial should wait
        // on; leaving it in place would let a *new* cached client for the same device id be awaited
        // against a task that reset a client already gone.
        nonSelectedDeviceForegroundResetTasks[deviceID] = nil
    }

    /// Drops `deviceID`'s cached stream client and row-mutation command channel, the same as
    /// `invalidateNonSelectedDeviceConnection`, but leaves its mutation identity untouched. Used when
    /// `deviceID`'s host list widens: the daemon on the other end has not changed, only the addresses it
    /// can be reached at, so the next lookup should rebuild against the fuller list, but a
    /// `MutationConnectionToken` already captured for an in-flight mutation must still read as current.
    /// Without this distinction, a Run/Restart whose own response is what revealed the wider host list
    /// would invalidate its own token before `performMutationReturningSession` re-checks it, and silently
    /// drop a session the mutation actually produced.
    private func rebuildNonSelectedDeviceConnectionForWidenedHosts(deviceID: String) {
        if let channel = nonSelectedDeviceCommandChannels[deviceID] { Task { await channel.close() } }
        nonSelectedDeviceCommandChannels[deviceID] = nil
        nonActiveDeviceStreamClients[deviceID] = nil
        // Same reasoning as `invalidateNonSelectedDeviceConnection`: a reset in flight for the discarded
        // client must not be awaited by a redial that ends up with the next-built client instead.
        nonSelectedDeviceForegroundResetTasks[deviceID] = nil
    }

    /// Whether `record` has what a stream needs to authenticate: a stored Keychain token and a
    /// certificate fingerprint. The active device is asked through its own live `settings` (the source
    /// of truth while it is selected, and possibly ahead of the Keychain-backed record right after a
    /// pairing completes in this session); every other paired device is checked by rebuilding its
    /// settings from its own record, the same construction `overviewStreamClient(forDeviceID:)` uses to
    /// open its stream. Mirrors the Mac sidebar's own filter
    /// (`AppKitController.pairedDeviceHasRequiredCredentials`): a device missing its token would
    /// otherwise redial unauthorized every retry forever, since the coordinator's backoff only paces a
    /// failing connect, it never stops retrying on its own.
    private func isDeviceCredentialedForStreaming(_ record: SpacesMobilePairedDeviceRecord) -> Bool {
        if record.id == activeDeviceID { return settings.isPaired }
        return SpacesMobileDeviceStore.settings(from: record, installationID: settings.installationID).isPaired
    }

    /// If the selected device already has a stream-delivered overview cached from before this call (it
    /// was already paired and streaming, just not selected, or streaming through an idle gap with nothing
    /// new to push), republishes it immediately instead of waiting on that stream's next push, which may
    /// be a long time away when nothing on the device is changing. A freshly paired or first-ever-launched
    /// device has nothing cached yet and is left to its stream's connect-time push, which the daemon
    /// sends immediately on every subscribe (see `relayOverviewSubscription` on the daemon side).
    private func republishCachedStreamOverviewIfSelected() {
        guard let deviceID = activeDeviceID, let overview = deviceOverviews[deviceID] else { return }
        let identity = overviewIdentity
        let mutationGenerationAtFetch = mutationGeneration
        // Captured here, at the call, not inside the `Task` below: this republish is racing the stream a
        // push can land on at any moment, and `applyFetchedOverview` must see this call's own generation,
        // not whatever the generation happens to be once the task actually runs.
        let deliveryGenerationAtFetch = overviewDeliveryGeneration
        Task {
            await applyFetchedOverview(
                overview, identity: identity, mutationGenerationAtFetch: mutationGenerationAtFetch,
                deliveryGenerationAtFetch: deliveryGenerationAtFetch, advancesDeliveryGeneration: false)
        }
    }

    /// Reconciles device streams to the current paired set and, if the device this call leaves selected
    /// already has a stream-delivered overview cached (it was already paired and streaming under its
    /// previous role), republishes it immediately. If that device is instead sitting in an armed retry
    /// (its last connect failed and it is waiting out a backoff), resets the retry first so the switch
    /// redials it at once: a non-selected device's backoff can run up to 60 s, and without this reset the
    /// user would see no Connection Error for up to a minute after switching to it. Called by every mutator
    /// that can move `activeDeviceID` or change which devices should be streaming (pairing, device switch,
    /// removal, Demo Mode toggle): `reconcile` alone only opens or closes streams for devices entering or
    /// leaving the paired set, and says nothing about which paired device just became selected.
    func reconcileDeviceStreamsAfterIdentityChange() {
        if let deviceID = activeDeviceID, overviewStreamSubscriptions.armedRetryDelay(deviceID: deviceID) != nil {
            overviewStreamSubscriptions.resetForUserRetry(deviceID: deviceID)?.cancel()
        }
        reconcileDeviceStreams()
        republishCachedStreamOverviewIfSelected()
    }

    /// The client `deviceID`'s stream subscribes through. The active device's stream reuses `bridgeClient`
    /// itself, whatever backend it wraps: the real network backend, the Demo backend (Demo Mode's one
    /// paired device is always the active one, so its stream lands in the same in-memory store every
    /// mutation commits to), or a test's fake backend, so a test that swaps in a streaming fake needs only
    /// the one client the model already builds. Every other paired device is served by
    /// `nonActiveDeviceStreamClients`, one client per device id reused across every open attempt for as
    /// long as its record stays unchanged (see that property's doc comment): each stream owns its
    /// endpoint resolution independently of `bridgeClient` (see `overviewStreamResolver` on the network
    /// backend), so becoming or ceasing to be the active device never has to rebuild an already-open
    /// stream's client, and a captured `bridgeClient` snapshot is never invalidated by a later rebuild:
    /// the same accepted residual `rebuildLiveClientAfterHostsBackfill` already documents for the command
    /// path applies here too, since an already-open stream keeps its resolver until its own next
    /// reconnect.
    private func overviewStreamClient(forDeviceID deviceID: String) -> SpacesDeviceAPIClient? {
        if deviceID == activeDeviceID { return bridgeClient }
        if let overridden = overviewStreamClientsForTesting[deviceID] { return overridden }
        guard let record = pairedDevices.first(where: { $0.id == deviceID }) else { return nil }
        let deviceSettings = SpacesMobileDeviceStore.settings(from: record, installationID: settings.installationID)
        if let cached = nonActiveDeviceStreamClients[deviceID], cached.settings == deviceSettings { return cached.client }
        invalidateNonSelectedDeviceConnection(deviceID: deviceID)
        let client = SpacesDeviceAPIClient(settings: deviceSettings, deviceName: UIDevice.current.name)
        nonActiveDeviceStreamClients[deviceID] = (client: client, settings: deviceSettings)
        return client
    }

    /// The client, settings, and identity a terminal viewer should use for one paired device: the selected
    /// device's is just one instance of this, not a separate path. Opening a terminal from a tapped
    /// Agents/Alerts row for another paired device resolves its context the same way that device's
    /// overview stream already does, so a viewer never juggles a second, independently-resolved client for
    /// the same device.
    struct DeviceTerminalContext {
        let deviceID: String
        let client: SpacesDeviceAPIClient
        let settings: SpacesMobileConnectionSettings
    }

    /// Builds `deviceID`'s terminal context, or nil when it is not (or no longer) a paired device.
    /// Reuses `overviewStreamClient(forDeviceID:)`'s cached client rather than building a second one: the
    /// same client already keeps that device's endpoint resolver warm for its overview stream, so a
    /// terminal opened on it starts from a proven address instead of re-racing every candidate host.
    func terminalContext(forDeviceID deviceID: String) -> DeviceTerminalContext? {
        guard let client = overviewStreamClient(forDeviceID: deviceID) else { return nil }
        guard deviceID != activeDeviceID else { return DeviceTerminalContext(deviceID: deviceID, client: client, settings: settings) }
        guard let record = pairedDevices.first(where: { $0.id == deviceID }) else { return nil }
        let deviceSettings = SpacesMobileDeviceStore.settings(from: record, installationID: settings.installationID)
        return DeviceTerminalContext(deviceID: deviceID, client: client, settings: deviceSettings)
    }

    /// A row mutation's connection and staleness token, resolved once at the start of `run`/`restart`/
    /// `stop` and reused for the request and its response.
    private struct MutationConnection {
        let client: SpacesDeviceAPIClient
        let channel: SpacesDeviceAPICommandChannel
        let token: MutationConnectionToken
    }

    /// Whether a device was selected plus a connection identity, captured before a row mutation's request
    /// goes out and compared again once it resumes. The selected device's identity is `overviewIdentity`;
    /// another device's is `nonSelectedDeviceIdentities[deviceID]`. `isCurrent(_:)` requires both the
    /// identity and the selected-ness to still match: if the device was made selected (or stopped being
    /// selected) while the mutation was in flight, its connection changed shape underneath it (from the
    /// per-device cached client to the shared `bridgeClient`, or back), so a response captured against the
    /// old shape is treated as stale, the same as an identity mismatch.
    private struct MutationConnectionToken: Equatable {
        let deviceID: String
        let isSelected: Bool
        let identity: Int
    }

    private func isCurrent(_ token: MutationConnectionToken) -> Bool {
        guard (token.deviceID == activeDeviceID) == token.isSelected else { return false }
        return token.isSelected ? overviewIdentity == token.identity : nonSelectedDeviceIdentities[token.deviceID, default: 0] == token.identity
    }

    /// Resolves `deviceID`'s connection for a row mutation. The selected device reuses the shared
    /// `bridgeClient`/`commandChannel`; any other paired device reuses `overviewStreamClient(forDeviceID:)`'s
    /// cached client with a command channel created on first use and cached in `nonSelectedDeviceCommandChannels`.
    /// Nil when `deviceID` is not (or no longer) paired.
    private func mutationConnection(forDeviceID deviceID: String) -> MutationConnection? {
        if deviceID == activeDeviceID {
            return MutationConnection(
                client: bridgeClient, channel: commandChannel,
                token: MutationConnectionToken(deviceID: deviceID, isSelected: true, identity: overviewIdentity))
        }
        guard let client = overviewStreamClient(forDeviceID: deviceID) else { return nil }
        let channel = nonSelectedDeviceCommandChannels[deviceID] ?? client.makeCommandChannel()
        nonSelectedDeviceCommandChannels[deviceID] = channel
        return MutationConnection(
            client: client, channel: channel,
            token: MutationConnectionToken(deviceID: deviceID, isSelected: false, identity: nonSelectedDeviceIdentities[deviceID, default: 0]))
    }

    /// Opens `deviceID`'s overview stream for the coordinator's `attempt`. `attempt` rides in both stream
    /// callbacks below so a disconnect belonging to an abandoned attempt is never mistaken for the state
    /// of the attempt that replaced it (see `RemoteOverviewSubscriptionCoordinator`'s own doc comment).
    private func openDeviceStream(deviceID: String, attempt: Int) {
        guard let client = overviewStreamClient(forDeviceID: deviceID) else {
            applyDeviceStreamConnectResult(deviceID: deviceID, attempt: attempt, handle: nil, connectError: nil)
            return
        }
        Task { @MainActor [weak self] in
            do {
                let handle = try await client.openOverviewStream(
                    // The main queue, not a `Task`, because it is strictly FIFO and is the main actor's
                    // executor: separate `Task { @MainActor in ... }`s created from the stream's single
                    // receive thread are not guaranteed to run on the main actor in creation order on
                    // every runtime this app supports, and `handleDeviceStreamOverview`'s latest-frame
                    // check depends on `deviceOverviews` being written in the order frames were received,
                    // not the order their tasks happened to resume. Both callbacks hop the same way so a
                    // disconnect can never overtake the frame before it.
                    onOverview: { [weak self] overview in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.handleDeviceStreamOverview(deviceID: deviceID, attempt: attempt, overview: overview) }
                        }
                    },
                    onDisconnect: { [weak self] error in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.handleDeviceStreamDisconnected(deviceID: deviceID, attempt: attempt, error: error) }
                        }
                    })
                self?.applyDeviceStreamConnectResult(deviceID: deviceID, attempt: attempt, handle: handle, connectError: nil)
            } catch { self?.applyDeviceStreamConnectResult(deviceID: deviceID, attempt: attempt, handle: nil, connectError: error) }
        }
    }

    private func applyDeviceStreamConnectResult(deviceID: String, attempt: Int, handle: SpacesDeviceAPIStreamHandle?, connectError: Error?) {
        switch overviewStreamSubscriptions.applyConnectResult(deviceID: deviceID, attempt: attempt, client: handle) {
        case .keep:
            // Accepted residual: a connected stream whose daemon cannot build its first overview stays
            // open and silent until the next database or terminal change (`DeviceOverviewStreamServer`),
            // so the selected device keeps its last overview until then or a pull-to-refresh. That
            // needs the daemon's own overview read to fail at connect time, which a fetch here would hit
            // just the same, so no follow-up fetch is scheduled; the Mac sidebar treats a loaded section
            // the same way.
            break
        case .discard:
            // This attempt simply stopped being wanted (unpaired, or superseded by a newer attempt),
            // which says nothing about reachability, so it must not overwrite a state a newer attempt
            // may own: an abandoned attempt's late connect failure must not report a Connection Error
            // or trigger re-pair while the replacement attempt's own stream is live.
            handle?.cancel()
        case .connectFailed:
            // The connect itself failed (an actual outage) for the attempt that is still current, so
            // `handle` is always nil here; nothing to cancel.
            if let connectError { handleDeviceStreamFailure(deviceID: deviceID, error: connectError) }
        case .discardDisconnected(let error):
            handle?.cancel()
            handleDeviceStreamFailure(deviceID: deviceID, error: error)
        }
    }

    private func handleDeviceStreamDisconnected(deviceID: String, attempt: Int, error: Error?) {
        switch overviewStreamSubscriptions.applyDisconnect(deviceID: deviceID, attempt: attempt, error: error) {
        case .ignore, .recordedWhileOpening: break
        case .markOffline(let handle):
            handle.cancel()
            handleDeviceStreamFailure(deviceID: deviceID, error: error)
        }
    }

    /// Routes one pushed overview from `deviceID`'s stream, at attempt `attempt`. Mirrors the Mac
    /// sidebar's own overview-push handler (`SidebarController.openRemoteOverviewSubscription`). A
    /// receive-loop line can already be mid-flight past a `cancel()` call, so a payload from an attempt
    /// `reconcile` has since abandoned (a fresh connect replaced it, e.g. across a quick
    /// background/foreground cycle) can still arrive after the replacement's own payload already landed.
    /// The daemon pushes only on change, so an unguarded stale payload would sit there indefinitely
    /// instead of self-correcting on the next push; checking `isCurrentAttempt` is what drops it.
    private func handleDeviceStreamOverview(deviceID: String, attempt: Int, overview: SpacesDeviceOverviewPayload) {
        // A queued payload can still arrive after `reconcile` already removed and cancelled this device's
        // subscription (unpaired, or Demo Mode toggled off); resurrecting a connection record for a device
        // no longer paired would leak state `reconcile` never has a reason to clean up again.
        guard pairedDevices.contains(where: { $0.id == deviceID }) else { return }
        guard overviewStreamSubscriptions.isCurrentAttempt(deviceID: deviceID, attempt: attempt) else { return }
        overviewStreamSubscriptions.noteOverviewDelivered(deviceID: deviceID, attempt: attempt)
        guard deviceID == activeDeviceID else {
            acceptNonSelectedDeviceOverview(overview, deviceID: deviceID)
            return
        }
        deviceOverviews[deviceID] = overview
        offlineDeviceIDs.remove(deviceID)
        let identity = overviewIdentity
        let mutationGenerationAtFetch = mutationGeneration
        // Each frame applies in its own task, suspended at `applyFetchedOverview`'s internal await; a
        // quick burst can let an older frame's task resume after a newer one already published. Passing
        // this rather than `deliveryGenerationAtFetch` (the refresh/republish guard): that counter only
        // moves on an *accepted* delivery, so two frames arriving before either is applied would still
        // read the same value and the guard would not catch a reorder between them. Comparing against
        // `deviceOverviews[deviceID]` does, because that entry is overwritten synchronously, in arrival
        // order, the instant each frame is received (above), before its task is even created.
        Task {
            await applyFetchedOverview(
                overview, identity: identity, mutationGenerationAtFetch: mutationGenerationAtFetch,
                isStillLatestFrame: { self.deviceOverviews[deviceID] == overview })
        }
    }

    /// Accepts one non-selected device's overview: writes it into `deviceOverviews`, clears its offline
    /// marking, prunes its dismissals and every device's retained screens against it, and merges any newly
    /// advertised hosts. Shared by a stream push (`handleDeviceStreamOverview`) and a row mutation's
    /// response for the same device (`applyMutationResponse(_:token:)`), so the Agents/Alerts tabs and the
    /// terminal detail read this device's state the same way regardless of which source produced it.
    private func acceptNonSelectedDeviceOverview(_ overview: SpacesDeviceOverviewPayload, deviceID: String) {
        deviceOverviews[deviceID] = overview
        offlineDeviceIDs.remove(deviceID)
        nonSelectedDeviceDeliveryGenerations[deviceID, default: 0] &+= 1
        // A decoded, delivered overview is the freshest word on the device: a compatible one clears any
        // block a previous stream failure's handshake found, the same way a fresh success clears the
        // active device's own `compatibility`. One that reports incompatible inline leaves the mark (it is
        // about to be recomputed as blocked anyway, by `overview(forDeviceID:)`'s own `raw.daemonStatus`
        // check just below the mark it reads), so this never briefly "unblocks" a device this same payload
        // still shows as incompatible.
        if SpacesWireCompatibility.evaluate(daemonStatus: overview.daemonStatus).isCompatible { blockedNonSelectedDeviceIDs.remove(deviceID) }
        // Pruned here for the same reason `publishOverview` prunes the selected device's own bucket and
        // retained screens: a non-selected device's overview is just as authoritative about what it still
        // lists, and the Agents/Alerts tabs read its dismissals and the terminal detail reads its retained
        // screens regardless of which device is selected.
        pruneDismissedAlertIDs(deviceID: deviceID, against: overview)
        pruneRetainedTerminalScreens()
        guard let record = pairedDevices.first(where: { $0.id == deviceID }) else { return }
        // Every paired device's stream pushes its daemon's reachable addresses on every connection, the
        // same way the Mac sidebar merges hosts for every device's subscription unconditionally
        // (`SpacesDeviceClient.subscribeOverview`), so a non-selected device that gains Tailscale need not
        // wait until it is selected to persist that address.
        let hostsMerged = SpacesMobileDeviceStore.mergeAdvertisedHosts(
            overview.daemonStatus.deviceAPIAddresses, certificateFingerprint: record.certificateFingerprint)
        let provenHostChanged = SpacesMobileDeviceStore.activeHost(certificateFingerprint: record.certificateFingerprint) != record.activeHost
        guard hostsMerged || provenHostChanged else { return }
        // `mergeAdvertisedHosts` and a proven-host update each only touch the persisted store; `pairedDevices`
        // is a separate in-memory snapshot that `ConnectionSettingsView` reads to show the address in use,
        // so either change needs this reload to actually reach the screen.
        pairedDevices = SpacesMobileDeviceStore.load(fallbackSettings: settings).devices
        // Only a widened host list rebuilds the cached client and channel: a proven host alone changes
        // nothing they need rebuilt for (the stream that just proved it is already open and already on
        // it), and `SpacesMobileConnectionSettings` excludes `activeHost` from its `Equatable` conformance,
        // so reloading `pairedDevices` above never trips the cache's own settings-changed check either.
        // The identity-preserving rebuild, not `invalidateNonSelectedDeviceConnection`: this same overview
        // can be a Run/Restart's own response, still in flight back to `performMutationReturningSession`,
        // and that caller re-checks `isCurrent(connection.token)` right after this call returns: bumping
        // the identity here would make a mutation invalidate its own token before its caller can read the
        // session it just produced.
        if hostsMerged { rebuildNonSelectedDeviceConnectionForWidenedHosts(deviceID: deviceID) }
    }

    /// Routes a stream failure for `deviceID`. The selected device's failure marks it offline immediately
    /// (`offlineDeviceIDs`), no grace period, matching the Mac sidebar's own offline rule, and runs the
    /// shared failure handler so it raises the same delayed Connection Error alert an explicit refresh
    /// failure did. A non-selected device's failure is classified first, by `classifyNonSelectedDeviceStreamFailure`,
    /// rather than marked offline on the spot: a decode failure from a daemon that has moved to a wire
    /// version this app cannot read looks the same at this call site as a genuinely unreachable device, and
    /// only the classifier's own frozen-core probe (decodable across versions) can tell them apart before
    /// either marking is applied.
    private func handleDeviceStreamFailure(deviceID: String, error: Error?) {
        guard deviceID == activeDeviceID else {
            classifyNonSelectedDeviceStreamFailure(deviceID: deviceID)
            return
        }
        offlineDeviceIDs.insert(deviceID)
        let identity = overviewIdentity
        let mutationGenerationAtFetch = mutationGeneration
        // Captured at the moment the failure is observed (a stream failure has no attempt start to
        // capture it at instead), so a success that already landed and bumped this before the failure was
        // even noticed is correctly seen as newer, not raced against.
        let deliveryGenerationAtFailure = overviewDeliveryGeneration
        let monitoringGeneration = connectionMonitoringGeneration
        // A stream failure has no request in flight to time from, so the failure streak's clock starts at
        // the instant the failure is observed here rather than at some inferred moment the daemon actually
        // went quiet.
        let attemptStartedAt = now()
        // A clean stop reports no error, but the device still stopped streaming unexpectedly (an
        // intentional stop on our side never reaches here: it goes through `reconcile`'s removed list or
        // `disable()`, both of which cancel the handle directly instead of routing through this method), so
        // failure handling still runs, with a generic error standing in for the missing one.
        let effectiveError = error ?? SpacesDeviceAPIClientError.requestFailed("The device closed its overview stream.")
        Task {
            _ = await handleOverviewFailure(
                identity: identity, mutationGenerationAtFetch: mutationGenerationAtFetch, deliveryGenerationAtAttempt: deliveryGenerationAtFailure,
                attemptStartedAt: attemptStartedAt, monitoringGeneration: monitoringGeneration, error: effectiveError)
        }
    }

    /// Classifies a non-selected device's stream failure with the same frozen-core handshake
    /// `refreshCompatibility` uses for the selected device (`bridgeClient.fetchDaemonStatus`), through
    /// `mutationConnection(forDeviceID:)` rather than a second client lookup: that is the same resolved
    /// client and channel a row mutation against this device would use, so the probe rides the connection
    /// the app already trusts for it. One probe per failure, no retry loop of its own: the stream
    /// coordinator's own reconnect backoff is what paces how soon a failure (and so a fresh probe) can
    /// recur.
    ///
    /// An incompatible verdict marks the device blocked (`blockedNonSelectedDeviceIDs`), which
    /// `overview(forDeviceID:)` reads to drop its rows and badge count with no offline marking, per spec:
    /// blocked, not offline. Anything else (unreachable, or compatible but the overview stream failed for
    /// some other reason) marks it offline instead, the ordinary way.
    ///
    /// The token captured before the probe's `await` is the same `MutationConnectionToken` a row mutation
    /// captures, and `isCurrent(_:)` is the same staleness check: if the device was selected, deselected,
    /// unpaired, or re-paired while the probe was in flight, its connection changed shape underneath it,
    /// and a verdict resolved against the old shape must not land, the same reasoning `mutationConnection`'s
    /// own doc comment gives for a mutation response.
    ///
    /// `isCurrent(_:)` alone is not enough: the connection's identity does not change just because the
    /// stream's own retry reconnected and delivered a fresh overview while this probe was still in flight
    /// (a slow handshake racing a quick reconnect is exactly the case a fixed, growing backoff cannot rule
    /// out), and a quiet device may never push again to correct a stale verdict applied on top of that
    /// fresher, already-settled state. `deliveryGenerationAtFailure`, captured before the probe starts and
    /// re-checked against `nonSelectedDeviceDeliveryGenerations[deviceID]` after, is what catches that: any
    /// overview accepted for this device in between (`acceptNonSelectedDeviceOverview`, from either its
    /// stream or a mutation response) has already said the last word, so this probe's own answer has
    /// nothing left to contribute and must not overwrite it.
    private func classifyNonSelectedDeviceStreamFailure(deviceID: String) {
        guard let connection = mutationConnection(forDeviceID: deviceID) else { return }
        let token = connection.token
        let deliveryGenerationAtFailure = nonSelectedDeviceDeliveryGenerations[deviceID, default: 0]
        let isStillCurrent = {
            self.isCurrent(token) && self.nonSelectedDeviceDeliveryGenerations[deviceID, default: 0] == deliveryGenerationAtFailure
        }
        Task {
            do {
                let status = try await connection.client.fetchDaemonStatus(commandChannel: connection.channel)
                guard isStillCurrent() else { return }
                if SpacesWireCompatibility.evaluate(daemonStatus: status).isCompatible {
                    offlineDeviceIDs.insert(deviceID)
                } else {
                    blockedNonSelectedDeviceIDs.insert(deviceID)
                    offlineDeviceIDs.remove(deviceID)
                }
            } catch is CancellationError {} catch {
                guard isStillCurrent() else { return }
                // Could not read the handshake either: an unreachable device, not a version mismatch.
                offlineDeviceIDs.insert(deviceID)
            }
        }
    }

    /// Starts the 30 s age-clock beat. Streams push on change, not on a timer, so relative-time labels
    /// ("2m ago") need their own slow tick to stay live between changes; matches the Mac Alerts table's
    /// own cadence.
    private func startRelativeTimeReferenceClock() {
        guard relativeTimeReferenceTask == nil else { return }
        relativeTimeReferenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.advanceRelativeTimeReferenceIfDue()
            }
        }
    }

    private func stopRelativeTimeReferenceClock() {
        relativeTimeReferenceTask?.cancel()
        relativeTimeReferenceTask = nil
    }

    /// Fetches and publishes the active device's overview. Reentrant: a call joins the fetch already in
    /// flight only while the connection (`overviewIdentity`), its channel (`connectionChannelGeneration`),
    /// and the mutation generation are all unchanged, so a deep link arriving mid-refresh still resolves
    /// instead of dropping silently. A fetch issued before any of those moved describes a device this app
    /// has since left, a connection that was closed out from under it, or a device state a mutation has
    /// already replaced, and its result is discarded or its request aborted, so a caller is never answered
    /// by one: it waits the stale fetch out and then fetches fresh. Every awaited `refresh()` therefore
    /// returns having attempted an overview that was issued after the caller asked for one.
    func refresh() async {
        while let inFlight = refreshInFlight {
            let identity = overviewIdentity
            let channelGeneration = connectionChannelGeneration
            let generation = mutationGeneration
            await inFlight.task.value
            if inFlight.identity == identity, inFlight.channelGeneration == channelGeneration, inFlight.mutationGeneration == generation,
                overviewIdentity == identity, connectionChannelGeneration == channelGeneration, mutationGeneration == generation
            {
                return
            }
        }
        let identity = overviewIdentity
        let task = Task { await self.performRefresh(identity: identity) }
        refreshInFlight = (identity: identity, channelGeneration: connectionChannelGeneration, mutationGeneration: mutationGeneration, task: task)
        await task.value
    }

    /// Advances `relativeTimeReference` to the current wall-clock instant once at least 30 seconds have
    /// elapsed since it last moved — the same cadence the Mac's `AutomationsController.armRelativeTimeRefresh`
    /// uses for its own label-only beat. `startRelativeTimeReferenceClock`'s own task sleeps before its
    /// first tick, so it cannot be what catches a reference gone stale by more than 30 seconds across a
    /// background gap; `performRefresh`'s defer also calls this so the labels catch up in the same tick as
    /// the refresh that brings everything else back, rather than waiting out the clock's first tick too.
    private func advanceRelativeTimeReferenceIfDue() {
        let current = wallClock()
        guard current.timeIntervalSince(relativeTimeReference) >= 30 else { return }
        relativeTimeReference = current
    }

    /// Applies one fetched overview through the exact path every consumer must share: compatibility from
    /// its inline frozen-core status, the advertised-hosts merge, browser routes, and `publishOverview`'s
    /// pruning and deferred-delete resolution. Used by `performRefresh` for an explicit fetch, by
    /// `republishCachedStreamOverviewIfSelected` for a cached stream payload republished on selection, and
    /// by `handleDeviceStreamOverview` for a pushed overview from the selected device's stream, so a
    /// stream payload lands exactly where a refresh's payload would have.
    ///
    /// `deliveryGenerationAtFetch` is the staleness guard for the first two callers only: a stream push is
    /// the ordered source of truth (the daemon pushes on every change, so anything a fetch could reveal is
    /// also pushed), and always applies regardless of what else has landed since, which is why
    /// `handleDeviceStreamOverview` passes `nil` (the default) rather than a captured generation. A fetch
    /// or a cached republish has no such guarantee: it can still be in flight, or queued on the main actor,
    /// when a newer push (or a newer fetch) already accepted and published, and without this guard it
    /// would overwrite that newer state with its own older content even though identity and mutation
    /// generation both still match. Checked at entry and again after the `await` below, since a push can
    /// land while this call is suspended there.
    ///
    /// `isStillLatestFrame`, folded into `isStillCurrent` the same way, is the stream push's own ordering
    /// guard: two of its frames apply in two separate tasks, each suspended at the `await` below, so a
    /// quick burst can let an older frame's task resume after a newer frame's task already published, and
    /// `deliveryGeneration` does not catch it (both frames arrive before either is applied, so both would
    /// still read the same value). Only `handleDeviceStreamOverview` passes it.
    ///
    /// `advancesDeliveryGeneration` is false only for `republishCachedStreamOverviewIfSelected`: a cached
    /// republish and an explicit `refresh()` can both be in flight after a device switch, and the cached
    /// payload is never newer than whatever the daemon answers with, so it must never be the one that
    /// moves the counter. If it did, publishing the cached (older) content while a concurrent refresh is
    /// still in flight would advance `overviewDeliveryGeneration` out from under that refresh, so its own
    /// `deliveryGenerationAtFetch` capture no longer matches by the time it finishes and its newer content
    /// gets discarded as stale. The republish still discards itself the normal way when the generation
    /// moved for some other reason (a stream push, or that same refresh landing first).
    ///
    /// Returns `nil` when the identity moved on mid-apply, or `isStillCurrent` no longer holds (the
    /// payload is discarded, nothing to report); `true` when the overview was accepted and published;
    /// `false` when it decoded but was blocked (the daemon needs an update) and `publishOverview(nil)` ran
    /// instead. `performRefresh` folds this into its own `perfOutcome`; the other two callers ignore it; a
    /// stream delivery and a cached republish are not timed requests with a baseline to report into.
    @discardableResult private func applyFetchedOverview(
        _ overview: SpacesDeviceOverviewPayload, identity: Int, mutationGenerationAtFetch: Int, deliveryGenerationAtFetch: Int? = nil,
        isStillLatestFrame: (() -> Bool)? = nil, advancesDeliveryGeneration: Bool = true
    ) async -> Bool? {
        // Both conditions describe the same thing (this call's payload has been overtaken by something
        // newer, short of a connection or mutation change, which `isOverviewFetchCurrent` already covers
        // on its own) so callers, and `updateBrowserRoutes`, only need to ask this one question rather
        // than juggling both parameters themselves.
        let isStillCurrent: () -> Bool = {
            if let deliveryGenerationAtFetch, deliveryGenerationAtFetch != self.overviewDeliveryGeneration { return false }
            if let isStillLatestFrame, !isStillLatestFrame() { return false }
            return true
        }
        guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtFetch), isStillCurrent() else { return nil }
        applyCompatibility(overview.daemonStatus)
        // The daemon reports the addresses it is currently reachable at on every connection. This is
        // how a device paired before its Mac ever had Tailscale silently gains the tailnet fallback
        // the moment the Mac gets one, with no rescan needed, unlike the QR-rescan path.
        let hostsChanged = SpacesMobileDeviceStore.mergeAdvertisedHosts(
            overview.daemonStatus.deviceAPIAddresses, certificateFingerprint: settings.certificateFingerprint)
        // A decodable overview whose daemon nonetheless reports an incompatible protocol is blocked;
        // show the restart/update block, not its stale workspace data.
        let acceptedOverview = isActiveDeviceBlocked ? nil : overview
        if let acceptedOverview {
            await updateBrowserRoutes(
                overview: acceptedOverview, identity: identity, mutationGeneration: mutationGenerationAtFetch, isStillCurrent: isStillCurrent)
        }
        // Re-checked after the await above, not just at entry: a mutation applying while the route
        // update was suspended makes this attempt's payload pre-mutation state, and a stream push may
        // have landed and published newer state while this call was suspended there too.
        guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtFetch), isStillCurrent() else { return nil }
        // Cleared before publishing, not after: the device answered, so any stale connection error is
        // over, but publishing is also what settles a deferred delete, and that may raise an error of
        // its own (`resolveDeferredWorkspaceDeletions`). Clearing afterwards would wipe it.
        connectionNotice = nil
        errorMessage = nil
        refreshFailureStreak = nil
        if advancesDeliveryGeneration { overviewDeliveryGeneration &+= 1 }
        publishOverview(acceptedOverview)
        // Rebuilds the live client only after the overview above is already published, deliberately:
        // this can run mid-refresh, and racing the rebuild against the `overviewIdentity` guards earlier
        // in this method could drop the very overview the caller is waiting for. Publishing first means
        // there is nothing left for a rebuild to corrupt: the identity guard just above already
        // confirmed no device switch happened in between.
        if hostsChanged { rebuildLiveClientAfterHostsBackfill() }
        return acceptedOverview != nil
    }

    /// The failure path shared by an explicit refresh's request failure and a stream disconnect or
    /// connect failure for the selected device (`handleDeviceStreamFailure`): the compatibility handshake,
    /// auth-failure recovery, daemon-update suppression, and the failure streak driving the 5 s delayed
    /// "Connection Error" alert (suppressed while a terminal is open) all run from here, so a stream
    /// failure looks exactly like a refresh failure did.
    ///
    /// Returns the outcome to fold into the caller's own `perfOutcome`, or `nil` when nothing should be
    /// reported: a stale identity, the incompatible-daemon block, or an auth failure (none of those is a
    /// completed measurement), or a daemon-update-suppressed attempt (a device offline on purpose is not a
    /// failure worth counting into the baseline).
    private func handleOverviewFailure(
        identity: Int, mutationGenerationAtFetch: Int, deliveryGenerationAtAttempt: Int, attemptStartedAt: ContinuousClock.Instant,
        monitoringGeneration: Int, error: Error
    ) async -> (count: Int?, success: Bool, error: String?)? {
        // A mutation or another attempt that landed while this one was failing has already published the
        // device's real state and cleared any error; a stale failure must not overwrite that with an
        // outage report.
        guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtFetch) else { return nil }
        // A newer success already accepted a payload and cleared the streak while this attempt's own
        // compatibility handshake (below) was still in flight; that later success has already settled the
        // question this attempt was trying to answer, so this attempt has nothing left to report.
        guard deliveryGenerationAtAttempt == overviewDeliveryGeneration else { return nil }
        // The overview did not decode (a wire-incompatible daemon) or the device is unreachable. The
        // frozen-core handshake stays decodable across versions, so use it to tell those apart: an
        // incompatible verdict shows the block; otherwise surface the original connection error.
        await refreshCompatibility(
            identity: identity,
            isStillCurrent: {
                isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtFetch)
                    && deliveryGenerationAtAttempt == overviewDeliveryGeneration
            })
        // The user may have switched or removed the active device, or a mutation may have published
        // fresher state, while the fallback handshake was in flight; a stale verdict must not
        // overwrite either.
        guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtFetch) else { return nil }
        guard deliveryGenerationAtAttempt == overviewDeliveryGeneration else { return nil }
        if isActiveDeviceBlocked {
            overview = nil
            connectionNotice = nil
            errorMessage = nil
            return nil
        }
        if let recoveryMessage = SpacesDeviceAPIAuthentication.recoveryMessage(for: error) {
            handleAuthenticationFailure(message: recoveryMessage)
            return nil
        }
        // A requested daemon update takes the device offline on purpose, and `requestDaemonUpdate()` is
        // already watching across that outage. An authentication failure above still surfaces: that is
        // not an outage and does not resolve itself when the daemon returns.
        guard !isApplyingDaemonUpdate else { return nil }
        // Measured in wall-clock time rather than failure count because the kinds of failure this folds
        // together are not comparable in duration: a dead socket throws immediately, while an unreachable
        // host burns a whole request timeout (twice, counting the compatibility handshake above) before it
        // throws even once, and a stream disconnect can fire anywhere between the two. Counting attempts
        // would report the fast case in a few seconds and the slow case only after a minute; timing the run
        // reports both within one window. User-initiated work (mutations, deep links) does not come
        // through here; it still reports on its first failure.
        // This attempt started before the app last stopped watching, so its elapsed time is mostly time
        // nothing was watching the connection. It cannot start or extend a run; that would resurrect,
        // dated before the pause, exactly the run `noteConnectionMonitoringPaused` ended.
        guard monitoringGeneration == connectionMonitoringGeneration else { return nil }
        // While the selected device's overview stream is live, it is the authority on reachability: the
        // daemon is provably still there, so a lone failed one-off refresh (pull-to-refresh, foreground
        // resume, a terminal dismissal) neither starts nor extends the streak. A connection that is
        // actually dead is caught by the stream itself, a disconnect or its silence watchdog
        // (`streamStalled`), which reports a stream failure through this same function once the
        // coordinator has already moved the device out of `.live`, and starts the run then. Without this,
        // a streak a single failed fetch started could never be cleared by a healthy, quiet stream
        // (keepalives are filtered below the model, so a live connection alone publishes nothing), and an
        // unrelated failure minutes later would read as one continuous outage. Still a completed
        // measurement for the perf log: the request itself failed normally, only the streak is bypassed.
        if let activeDeviceID, overviewStreamSubscriptions.isLive(deviceID: activeDeviceID) {
            return (count: nil, success: false, error: DevicePerformanceLog.sanitized(error.localizedDescription))
        }
        let streakStartedAt = refreshFailureStreak?.identity == identity ? refreshFailureStreak?.startedAt : nil
        let startedAt = streakStartedAt ?? attemptStartedAt
        refreshFailureStreak = (identity: identity, startedAt: startedAt)
        let outcome: (count: Int?, success: Bool, error: String?) = (
            count: nil, success: false, error: DevicePerformanceLog.sanitized(error.localizedDescription)
        )
        guard now() - startedAt >= refreshFailureAlertDelay else { return outcome }
        // While a terminal is open, its own connection banner (Reconnecting, then Device unreachable)
        // already reports this exact outage, so the modal alert would just repeat it while dimming the
        // whole screen. The streak above keeps advancing regardless, so leaving the terminal while the
        // device is still failing raises the alert on the very next failure rather than restarting the
        // delay. A browser session detail has no banner of its own, so it is not covered here.
        // The gate is the open terminal, not the banner: a terminal whose session already ended shows no
        // banner, and an outage that starts while it is open goes unreported until the user leaves it.
        // Accepted: the ended pane is what the user is looking at, nothing on it can change, and the next
        // failure after leaving raises the alert with the streak intact.
        // The open terminal can also belong to another paired device (opened from Agents or Alerts), whose
        // banner says nothing about this device. Still held back, by product decision: an alert about the
        // selected device must not interrupt the terminal the user is working in, and this device's
        // Agents/Alerts rows already read offline in the meantime.
        guard activeTerminalSessionID == nil else { return outcome }
        errorMessage = error.localizedDescription
        return outcome
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
        // Captured at the same moment, and passed to both this attempt's success and failure paths: if a
        // stream push (or another refresh) accepts a payload and bumps this before this attempt finishes,
        // this attempt's own result is older than what is already published and must not overwrite it,
        // whichever way this attempt itself turns out.
        let deliveryGenerationAtStart = overviewDeliveryGeneration
        let perfBeganAtUptimeNanoseconds = DevicePerformanceLog.overviewRefreshBegin()
        // Set at this attempt's one success or one reported-failure exit (`applyFetchedOverview` below, or
        // the `catch` once `handleOverviewFailure` has updated `refreshFailureStreak`); left nil for every
        // other exit (a stale-identity discard, cancellation, the blocked-device branch, an authentication
        // failure, or a daemon-update-suppressed poll): none of those is a completed list-load measurement
        // worth reporting into the baseline. The failure branch sets it regardless of whether the streak
        // has crossed `refreshFailureAlertDelay`, so a failure that never reaches the user-facing alert
        // still closes out the `overview_refresh_begin` this attempt opened.
        var perfOutcome: (count: Int?, success: Bool, error: String?)?
        defer {
            isLoading = false
            refreshInFlight = nil
            // Runs on every refresh attempt regardless of outcome: it only reads the local wall clock, so
            // a fetch failure or a stale-identity discard still counts as "we checked in". That matters for
            // a returning tab (hidden, backgrounded, or behind a closed detail route, each a state with no
            // stream open and so no clock task running): its first refresh on resume already clears the
            // 30-second bar by itself, since the reference sat untouched for the whole gap, so labels catch
            // straight up with no separate "just resumed" case to write.
            advanceRelativeTimeReferenceIfDue()
            if let perfOutcome {
                DevicePerformanceLog.overviewRefreshEnd(
                    beganAtUptimeNanoseconds: perfBeganAtUptimeNanoseconds, count: perfOutcome.count, success: perfOutcome.success,
                    error: perfOutcome.error)
            }
        }
        do {
            // Read compatibility from the overview's inline frozen-core status so the compatible steady
            // state costs a single round-trip. Only a refresh that fails entirely falls back to the
            // standalone frozen-core handshake below.
            let overview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
            guard
                let applied = await applyFetchedOverview(
                    overview, identity: identity, mutationGenerationAtFetch: mutationGenerationAtFetch,
                    deliveryGenerationAtFetch: deliveryGenerationAtStart)
            else { return }
            // A refresh that decoded but published nothing (the daemon needs an update) is not a list load
            // the user saw, so it does not count as one.
            perfOutcome =
                applied ? (count: overview.sessions.count, success: true, error: nil) : (count: nil, success: false, error: "daemon_update_required")
        } catch is CancellationError { return } catch {
            perfOutcome = await handleOverviewFailure(
                identity: identity, mutationGenerationAtFetch: mutationGenerationAtFetch, deliveryGenerationAtAttempt: deliveryGenerationAtStart,
                attemptStartedAt: attemptStartedAt, monitoringGeneration: monitoringGeneration, error: error)
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
        // would clear a live successor's state, re-enabling the button mid-update and letting ordinary
        // overview traffic straight into the handoff this flag exists to protect.
        daemonUpdateGeneration += 1
        let generation = daemonUpdateGeneration
        isApplyingDaemonUpdate = true
        defer { if daemonUpdateGeneration == generation { isApplyingDaemonUpdate = false } }

        // This flow runs on its own command channel rather than the shared one. The shared channel
        // carries explicit overview refreshes and every user mutation, and the transport does not serialize whole
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
        // path has to release to re-enable the button. Releasing the flag un-suppresses the selected
        // device's stream failures (`handleOverviewFailure`), which then reports a genuinely unreachable
        // device the ordinary way, so nothing is left stale.
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

    // MARK: - Restoring coding agents whose work was cut short

    /// Re-derives what the active device is offering to bring back. Called from every assignment of the
    /// two things the offer is made of: the daemon status that carries the record, and the overview that
    /// names its workspaces.
    ///
    /// Assigns only on a change, because both setters fire on every overview delivery while the steady
    /// state of this property is nil: an unconditional write would invalidate every view observing the
    /// model on every push for a question nobody asked.
    private func updateSessionRestoreOffer() {
        // The answer in flight owns the sheet until the device has answered it, and the answer's own
        // completion re-derives this. See `isAnsweringSessionRestore`.
        guard !isAnsweringSessionRestore else { return }
        // What raises a question and what takes one away are different rules: a status this app cannot
        // read, or cannot answer across, raises nothing but is no reason to withdraw a question the user
        // is already looking at. See `retainedPresentedOffer`.
        let offer = currentSessionRestoreOffer() ?? retainedPresentedOffer()
        guard offer != sessionRestoreOffer else { return }
        sessionRestoreOffer = offer
    }

    /// The question already on screen, when nothing about the device's current status is a reason to take
    /// it away, or nil when it is.
    ///
    /// Raising an offer is gated on a device this app can read and answer; withdrawing one must not be,
    /// or a failed status fetch and a daemon updated mid-question would each dismiss the sheet with no
    /// answer given and nothing said, and the version gap would lose the one surface that reports it (the
    /// answer path states it inline). What does take the question away is the device saying the record is
    /// gone, this client having settled it, or the user having switched to another device, since an offer
    /// is about the device it was made for and cannot be answered on a different one.
    private func retainedPresentedOffer() -> SessionRestoreOffer? {
        guard let presented = sessionRestoreOffer, presented.deviceID == activeDeviceID,
            !hasSettledSessionRestoreRecord(deviceID: presented.deviceID, generation: presented.generation),
            SessionRestoreOffer.retainsPresentedOffer(presented: presented, status: activeDeviceDaemonStatus)
        else { return nil }
        return presented
    }

    /// Whether this client has already dealt with the record `generation` names on `deviceID`: it
    /// answered it and the device accepted (remembered across launches), or the question was retired
    /// without an accepted answer (remembered for this run, see `retiredSessionRestoreGenerations`). A
    /// settled record is never raised, and never kept on screen.
    private func hasSettledSessionRestoreRecord(deviceID: String, generation: String) -> Bool {
        SessionRestoreAnsweredGenerationsStore.generation(deviceID: deviceID) == generation
            || retiredSessionRestoreGenerations[deviceID] == generation
    }

    /// What the active device is offering right now, or nil when it is offering nothing this app has not
    /// already answered.
    ///
    /// The short circuit on an empty record comes before everything else: this runs on every overview
    /// delivery, and the steady state is that the device is offering nothing.
    ///
    /// A device with no paired record of its own is offered nothing, because its id is the key the
    /// answer is remembered under, and an offer this app could not remember answering would be raised
    /// again on every refresh for as long as the record stood.
    private func currentSessionRestoreOffer() -> SessionRestoreOffer? {
        guard let daemonStatus = activeDeviceDaemonStatus, !daemonStatus.restorableSessions.isEmpty, let activeDeviceID else { return nil }
        // The answered generation is the rule the pure decision carries; the check below adds the record a
        // device refused an answer to, which is settled for this run the same way.
        guard
            let offer = SessionRestoreOffer.make(
                deviceID: activeDeviceID, deviceName: connectionSummary, status: daemonStatus,
                workspaceNamesByID: Dictionary((overview?.workspaces ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
                answeredGeneration: SessionRestoreAnsweredGenerationsStore.generation(deviceID: activeDeviceID)),
            !hasSettledSessionRestoreRecord(deviceID: activeDeviceID, generation: offer.generation)
        else { return nil }
        return offer
    }

    /// Answers the offer on screen and reports what the sheet should do: nil closes it, a message keeps
    /// it open so the user can try again or skip instead.
    ///
    /// Every answer is preceded by a fresh daemon-status read of the device it is for, the rule the Mac's
    /// `SessionRestoreController.probedDaemonStatus` follows: the offer was built from a status the
    /// device may have replaced since, because a daemon can be updated or restarted while the sheet is
    /// up, and the status this app holds can be minutes old or missing after a failed fetch. Answering on
    /// that would let a device on another wire version relaunch the agents and clear its record while
    /// this app cannot decode what came back or report which relaunches failed. Only a compatible probe
    /// lets the answer go out; a probe that fails is not permission either, and reports the device as
    /// unreachable with the record left standing.
    ///
    /// Rows the device accepted but could not relaunch are reported separately
    /// (`sessionRestoreFailureReport`), because the answer itself landed: the sheet closes and the app
    /// shell says which agents are not coming back.
    func answerSessionRestoreOffer(_ answer: SessionRestoreAnswer, offer: SessionRestoreOffer) async -> String? {
        isAnsweringSessionRestore = true
        let identity = overviewIdentity
        // Sent on a dedicated command channel rather than the shared one an explicit overview refresh
        // also uses, for the reason `performDeleteWorkspace` uses one: a restore relaunches one agent per
        // row under the daemon's long-running request timeout, far longer than the 8s a refresh allows
        // itself, and the transport does not serialize whole round trips on a connection (issue #248), so
        // a refresh timing out would close this request's connection out from under it while the device
        // restores regardless. Traffic on the shared channel is not shielded from this either: the daemon
        // serves the overview and the restore on the same serial lane, so a restore that outlasts a
        // refresh's timeout times that refresh out and, past the alert delay, shows a connection error
        // while the agents are still being relaunched. Accepted: it takes dozens of agents to hold the
        // lane that long, the message is factual about the request that failed, and the selected
        // device's next stream push or refresh clears it once the restore finishes.
        let answerChannel = bridgeClient.makeCommandChannel()
        let client = bridgeClient
        // The version check rides that same channel, so an explicit refresh cannot close the connection
        // out from under the check either, and the answer that follows reuses the connection the check just proved.
        let probe: Result<TerminalServiceDaemonStatus, any Error>
        do { probe = .success(try await client.fetchDaemonStatus(commandChannel: answerChannel)) } catch { probe = .failure(error) }
        // The active device changed while the check was in flight, so there is no sheet left to report to
        // and this model now describes a different device.
        guard identity == overviewIdentity else {
            await endAnswerAttempt(channel: answerChannel)
            updateSessionRestoreOffer()
            return nil
        }
        switch probe {
        case .failure(let error):
            await endAnswerAttempt(channel: answerChannel)
            // A check the device would not authenticate is the same refusal the answer's own outcome
            // carries, and it ends the same way: the sheet comes down so the re-pair surface it covers is
            // reachable, and the record, which this app never reached, is offered again once paired.
            if let recoveryMessage = SpacesDeviceAPIAuthentication.recoveryMessage(for: error) {
                retireOfferForFailedAuthentication(offer: offer, recoveryMessage: recoveryMessage)
                return nil
            }
            updateSessionRestoreOffer()
            return Self.deviceUnreachableAnswerFailure(deviceName: connectionSummary)
        case .success(let probedStatus):
            // The check is the freshest word this app has about the device, and every restore decision
            // reads the published status, so it is installed rather than read once and dropped: what the
            // offer is derived from next is what the answer was allowed on. Nothing moves on screen while
            // this call owns the sheet (see `isAnsweringSessionRestore`).
            applyCompatibility(probedStatus)
            if let blocked = DaemonCompatibilityCopy.actionBlockedBody(
                deviceName: connectionSummary, verdict: SpacesWireCompatibility.evaluate(daemonStatus: probedStatus))
            {
                await endAnswerAttempt(channel: answerChannel)
                updateSessionRestoreOffer()
                return blocked
            }
        }
        let outcome = await SessionRestoreAnswering.perform(
            answer, generation: offer.generation, restore: { try await client.restoreSessions(generation: $0, commandChannel: answerChannel) },
            discard: { try await client.discardRestorableSessions(generation: $0, commandChannel: answerChannel) })
        await endAnswerAttempt(channel: answerChannel)
        // The active device changed while the answer was in flight. It was answered on the device it was
        // made about, so nothing here is wrong; there is simply no sheet left to report to, and this
        // model now describes a different device.
        guard identity == overviewIdentity else {
            updateSessionRestoreOffer()
            return nil
        }
        let disposition = SessionRestoreAnswering.disposition(for: outcome)
        if let failureMessage = disposition.failureMessage {
            // The record stays unanswered and the offer stays on screen: the agents are still on the
            // device, and the user can try the same answer again or skip instead.
            updateSessionRestoreOffer()
            return failureMessage
        }
        if disposition.recordsGeneration { SessionRestoreAnsweredGenerationsStore.record(generation: offer.generation, deviceID: offer.deviceID) }
        if case .unauthenticated(let recoveryMessage) = outcome {
            // The device did not recognize this app, so the answer never reached the record: it stands,
            // and the device offers it again once the user has paired. The sheet has to come down first:
            // it cannot be swiped away, and what it covers (Devices, and the re-pair the notice asks for)
            // is the only way through. The generation is held only until that pairing lands, which is
            // what brings the question back.
            retireOfferForFailedAuthentication(offer: offer, recoveryMessage: recoveryMessage)
            return nil
        }
        if case .superseded = outcome {
            // The device replaced the record while the question was on screen. Retire the question with it
            // rather than leaving the sheet up on a record its own device has disowned, and ask for a fresh
            // status at once: the record that replaced it is one the user has not been asked about, and
            // nothing else raises it until the device's stream next pushes an overview, which is soon
            // while foregrounded but does not happen at all once backgrounded.
            retiredSessionRestoreGenerations[offer.deviceID] = offer.generation
            updateSessionRestoreOffer()
            // The refusal is the device reporting a record this app has never seen, which every overview
            // fetch issued before it describes without. Bumped like any other device-changing call so one
            // of those in flight is discarded rather than published, and so the read below issues its own
            // request instead of being answered by it.
            mutationGeneration &+= 1
            await refresh()
            return nil
        }
        // The other two outcomes have returned by here, so this is the device accepting the answer.
        guard case .answered(let restored) = outcome else { return nil }
        let failureReport = SessionRestoreAnswering.failureReport(restored.failures, offer: offer)
        // Only a Restore changes what this app shows: the relaunched agents are sessions the overview does
        // not carry yet, and the restore response answers with their ids alone. A Skip leaves every list
        // exactly as it was, and bumps nothing, so an overview fetch in flight across it still publishes.
        if answer == .restore {
            // The device has relaunched the agents, so every overview fetch issued before this answer
            // describes a device without them. Bumped like any other device-changing call so one of those
            // in flight is discarded rather than published, and so the read below issues its own request
            // instead of being answered by it, which is what puts the relaunched sessions in the lists.
            mutationGeneration &+= 1
            await refresh()
        }
        updateSessionRestoreOffer()
        // Raised last, once the answered record has retired the offer and taken its sheet down with it: an
        // alert asked for while that sheet is still on screen is an alert over a view that is dismissing.
        // Nothing is lost by the wait, since only a Restore can report failures and a Restore always has
        // the refresh above to wait behind.
        if let failureReport { sessionRestoreFailureReport = failureReport }
        return nil
    }

    /// Closes the channel one answer attempt ran on and unfreezes the derivation. Every exit from
    /// `answerSessionRestoreOffer` past the point the channel exists goes through here, so a sheet is
    /// never left frozen on an answer that has finished.
    private func endAnswerAttempt(channel: SpacesDeviceAPICommandChannel) async {
        await channel.close()
        isAnsweringSessionRestore = false
    }

    /// The one thing this app does about a device that will not authenticate it, whether the refusal came
    /// from the version check or from the answer itself: the question is retired for this connection so
    /// the re-pair surface the sheet covers is reachable, and the device, whose record the answer never
    /// reached, offers it again once the user has paired (which clears what was retired here).
    private func retireOfferForFailedAuthentication(offer: SessionRestoreOffer, recoveryMessage: String) {
        retiredSessionRestoreGenerations[offer.deviceID] = offer.generation
        updateSessionRestoreOffer()
        handleAuthenticationFailure(message: recoveryMessage)
    }

    /// What a version check that never answered tells the user, worded like the Mac's
    /// `deviceUnreachableError` for the same refusal: the record is untouched on a device this app could
    /// not reach, and reconnecting is what makes the answer possible.
    private static func deviceUnreachableAnswerFailure(deviceName: String) -> String { "\(deviceName) is offline. Reconnect it and try again." }

    func dismissSessionRestoreFailureReport() { sessionRestoreFailureReport = nil }

    /// Standalone frozen-core handshake, used only as a fallback when the overview cannot carry the
    /// inline status (an older daemon) or could not be fetched/decoded at all (incompatible/offline).
    /// A probe result applies only while the failure that started it is still the latest word on the
    /// device: this fallback only runs once an overview fetch has already failed, and with the selected
    /// device retrying every 2 s, its own reconnect and a fresh overview can land while this handshake
    /// is still in flight. Applying a stale verdict over that fresher state (clearing a status the
    /// reconnect just recovered, or applying an incompatible verdict from before it) would go
    /// uncorrected until the next push, since nothing else polls. `isStillCurrent` is the only caller's
    /// (`handleOverviewFailure`) own currency check for the failure this handshake is answering, built
    /// before the await and re-run after it so a mutated fresher state during the fetch is caught.
    private func refreshCompatibility(identity: Int, isStillCurrent: () -> Bool) async {
        do {
            let status = try await bridgeClient.fetchDaemonStatus(commandChannel: commandChannel)
            guard isStillCurrent() else { return }
            applyCompatibility(status)
        } catch is CancellationError { return } catch {
            guard isStillCurrent() else { return }
            // A requested update takes the device offline on purpose. Clearing the status there would
            // drop the banner (it renders off `daemonStatus`) and unblock the device (blocking reads
            // `compatibility`), flashing stale workspace controls back mid-update; keep the last known
            // facts until the device's own status reporting says otherwise.
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
        // Cleared before the identity moves, for the reason `selectDevice` clears it there.
        clearActiveDeviceFacts()
        self.settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        bridgeClient = SpacesDeviceAPIClient(settings: deviceState.settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
        SpacesMobileSettingsStore.save(deviceState.settings)
        // Pairing again is what recovers a connection this device could not authenticate, so it is also
        // what brings back a restore question that was retired because its answer could not be
        // authenticated: the device still holds that record and offers it on the next status.
        retiredSessionRestoreGenerations.removeAll()
        stagedApplyDidNotLandAlert = nil
        workspaceCreateOptions = nil
        connectionNotice = nil
        pendingPairingLink = nil
        loadDismissedAlertIDsForPairedDevices()
        pruneDismissedAlertsForUnknownDevices()
        if let deviceID = activeDeviceID {
            // This call rebuilds `bridgeClient` above unconditionally, so a re-pair of the device already
            // selected (same id, new token) reuses that id with a subscription still tracked under the
            // old client. `reconcileDeviceStreamsAfterIdentityChange`'s own reset only clears an armed
            // retry; an `.opening` or `.live` subscription would stay current otherwise, and its late
            // unauthorized failure could reopen re-pair recovery right after pairing just succeeded, or a
            // late push on the old client could clear the auth notice that recovery raised. Resetting
            // unconditionally, whatever the device's state, abandons that old attempt so the reconcile
            // below opens a fresh one on the new client. A brand new device has no tracked state yet, so
            // this is a no-op for it. The cached overview is dropped too: left in place, the reconcile's
            // own republish would show whatever the old, now-invalid credentials last delivered, which a
            // re-pair usually follows revoking or failing, so that payload can be arbitrarily stale (it
            // would sit there until the new stream's first push, or indefinitely if the new connection
            // never connects) and would merge its advertised addresses back into the persisted hosts.
            overviewStreamSubscriptions.resetForUserRetry(deviceID: deviceID)?.cancel()
            // The full invalidation, not a bare cache clear: `deviceID` can carry a leftover
            // `nonActiveDeviceStreamClients`/`nonSelectedDeviceCommandChannels` entry from before this
            // device became selected (it was paired as a secondary device, or this same re-pair is what
            // just made it active), built against the credential this re-pair is replacing. Only nilling
            // the client cache would leave that entry's command channel open and its mutation identity
            // unchanged, so a mutation issued through it before this call (back when it was still that
            // stale client) would still read as current when its response lands and apply a result read
            // with the credential this re-pair just retired.
            invalidateNonSelectedDeviceConnection(deviceID: deviceID)
            deviceOverviews[deviceID] = nil
        }
        reconcileDeviceStreamsAfterIdentityChange()
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
    /// closes the shared command channel's current connection, so the very next explicit overview refresh
    /// or mutation re-races every candidate address, preferring the LAN address again when this device
    /// is back on it, instead of continuing on whatever address it settled on while away. Reuses
    /// `SpacesDeviceAPICommandChannel.close()` rather than a parallel teardown path.
    ///
    /// Deliberately touches only this app-wide command channel, never a `TerminalViewerModel`'s own
    /// channel or its live session stream, nor the selected device's overview stream (see
    /// `resumeFromBackground`'s doc comment for that accepted residual): a working terminal session must
    /// not be interrupted just to re-prefer a lower-latency path. An open viewer keeps its stream, which
    /// re-races on its own the next time it actually disconnects (see
    /// `SpacesDeviceNetworkBackend.openSessionStream`'s disconnect handling).
    ///
    /// Accepted race: a connect already suspended inside `connectIfNeeded` when this runs can install its
    /// connection and repopulate the resolver's cache afterwards, leaving the app on the address it had
    /// rather than re-preferring the LAN one. The window is narrow (this reset itself, at foreground
    /// resume) and the consequence is only staying on a path that already works, with the next foreground
    /// clearing it again. Not worth generation-stamping every connect to close.
    func resetActiveConnectionEndpoint() { Task { await resetActiveConnectionEndpointAndWait() } }

    private func resetActiveConnectionEndpointAndWait() async {
        let client = bridgeClient
        let channel = commandChannel
        await client.resetEndpointResolution()
        await channel.close()
        // Bumped after the close, so every fetch the close could have aborted carries the older
        // generation and no later caller can be answered by one. A fetch issued after this point is on
        // the reconnected channel and is joinable like any other.
        connectionChannelGeneration += 1
    }

    /// The whole of what returning to the foreground asks of the connection, in the one order that works:
    /// re-prefer the endpoint, and only then read the device.
    ///
    /// Sequenced rather than started side by side because the reset closes the shared command channel,
    /// and a close landing on the read already in flight aborts it: the app would come back to the
    /// foreground having fetched nothing, with no explicit next attempt queued and only the selected
    /// device's stream eventually reporting anything, on its own schedule. The reset is also what
    /// makes the refresh below issue its own request rather than join one: the close bumps
    /// `connectionChannelGeneration`, and a fetch from before it is never joined (see `refresh()`).
    ///
    /// The read is what the app misses without this: anything the device decided while the app was away,
    /// which is exactly when a device restarts and starts offering the coding agents its restart cut
    /// short. Paired only: an unpaired app has nothing to read and would answer with a connection error.
    ///
    /// Narrower than the endpoint re-preference as a whole: this resets only the command path's resolver
    /// (`bridgeClient`'s own `resolver`). There is no already-open stream to reset here: streams are
    /// foreground-only (`stopDeviceStreams`/`startDeviceStreams`), so backgrounding already closed every
    /// one and foreground reopens them fresh. Each stream's resolver instance still survives the
    /// backgrounding (built once per paired device, outliving its stream's own connect/disconnect
    /// cycles), so left alone a reopened stream would first try whatever address that resolver last
    /// proved reachable rather than re-racing from the top. `RootTabView`'s `.active` branch resets every
    /// paired device's overview-stream resolver directly, before calling `startDeviceStreams()`
    /// (`resetDeviceStreamEndpointsForForeground()`), so that reopened streams do get the same
    /// re-preference this reset gives the command path.
    func resumeFromBackground() async {
        let generation = foregroundEndpointRefreshGeneration
        latestForegroundResumeToken &+= 1
        let resumeToken = latestForegroundResumeToken
        defer { releaseForegroundEndpointRefreshWaiters(armedBy: generation, startedAs: resumeToken) }
        await resetActiveConnectionEndpointAndWait()
        guard settings.isPaired else { return }
        await refresh()
    }

    /// Whether the shell still owes the connection the foreground refresh above, which backgrounding asked
    /// for it, and which resume is currently the one that owes it. Plumbing for the gate below rather than
    /// anything a view reads, so it stays out of observation.
    ///
    /// Two stamps, because a resume that is still inside its overview read can be overtaken in two ways,
    /// and in both the older call's work has stopped being the refresh that warms the cache. It can be
    /// overtaken by a new backgrounding (rapid app switching), which the generation catches. And it can be
    /// overtaken by another resume in the same generation, since `RootTabView` runs one on every `.active`
    /// and an `.inactive` bounce (a control-center pull, a call banner) reaches `.active` again with no
    /// backgrounding in between: the second call's endpoint reset closes the command channel and aborts
    /// the first call's fetch, so the first call returns having read nothing. Releasing on the way out of
    /// either would open the gate for a redial whose own refresh has not landed, which is exactly what the
    /// gate exists to prevent. A counter bumped at entry and checked at release names the newest resume;
    /// coalescing the overlapping calls instead would have to make the newer caller inherit the older
    /// call's work, which is the thing that just got aborted, so it is both more machinery and wrong.
    @ObservationIgnored private var isForegroundEndpointRefreshPending = false
    @ObservationIgnored private var foregroundEndpointRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var latestForegroundResumeToken: UInt64 = 0
    @ObservationIgnored private var foregroundEndpointRefreshWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether a non-selected device's own foreground redial still owes
    /// `resetDeviceStreamEndpointsForForeground()` having recorded this backgrounding's per-device reset
    /// tasks (`nonSelectedDeviceForegroundResetTasks`). Mirrors `isForegroundEndpointRefreshPending`'s own
    /// reason for existing: SwiftUI gives no ordering between the shell's `scenePhase` observer (which
    /// calls `resetDeviceStreamEndpointsForForeground()`) and a terminal detail's own, so a detail that
    /// reaches `.active` first would find no task recorded yet for its device and redial the stale
    /// pre-background address before the reset even starts. No generation/token pair like that gate's,
    /// because its release site (`resetDeviceStreamEndpointsForForeground()`) runs to completion with no
    /// `await` in between arming and releasing, so there is no window for a second backgrounding to
    /// interleave and make a release answer for the wrong cycle.
    @ObservationIgnored private var isNonSelectedForegroundResetPending = false
    @ObservationIgnored private var nonSelectedForegroundResetWaiters: [CheckedContinuation<Void, Never>] = []

    /// Records that the app left the foreground, arming the gate `waitForForegroundEndpointRefresh()`
    /// holds callers behind for this backgrounding, and the one above it that a non-selected device's own
    /// redial holds behind until `resetDeviceStreamEndpointsForForeground()` has started that device's
    /// reset.
    ///
    /// Armed on the way out rather than on the way back in: SwiftUI gives no ordering between the shell's
    /// `scenePhase` observer and an open detail's, so a viewer that reaches `.active` first would find no
    /// refresh in flight yet and go on to dial the address the reset is about to forget. Arming at
    /// background makes the gate closed before either observer can run.
    func noteBackgroundedForEndpointRefresh() {
        foregroundEndpointRefreshGeneration &+= 1
        isForegroundEndpointRefreshPending = true
        isNonSelectedForegroundResetPending = true
    }

    /// Arms the gate from the shell's very first scene phase, for an app that mounts with the scene
    /// already backgrounded (state restoration, a background launch). Such a mount gets no `.background`
    /// change of its own, while a terminal detail mounting beside it does arm its own foreground redial
    /// for exactly that phase, so without this the redial would find the gate open and dial ahead of the
    /// endpoint reset the return to the foreground is about to make. Any other initial phase arms
    /// nothing: the app is on screen and owes the connection no refresh.
    ///
    /// Safe to be followed by a `.background` change for the same absence: arming twice only spends a
    /// generation, and the release is keyed to the generation current when the resume starts, which is
    /// the last arming before it.
    func noteInitialSceneIsBackgrounded(_ isBackgrounded: Bool) {
        guard isBackgrounded else { return }
        noteBackgroundedForEndpointRefresh()
    }

    /// Suspends until `resumeFromBackground()` has finished re-racing this device's endpoint candidates
    /// and reading the device, and returns immediately when no such refresh is owed. An open terminal's
    /// foreground redial waits here so its single-candidate stream dial reads a warm cache.
    ///
    /// A waiter cannot be stranded: `RootTabView` runs `resumeFromBackground()` on every `.active`, so the
    /// backgrounding that armed the gate is always followed either by a resume or by the app being
    /// terminated, which takes the waiter with it. Whichever resume started last is the one that releases,
    /// and it always reaches its release: the release is deferred, so it runs even if the call returns
    /// early or is cancelled. That invariant is why there is no timeout here.
    func waitForForegroundEndpointRefresh() async {
        guard isForegroundEndpointRefreshPending else { return }
        await withCheckedContinuation { foregroundEndpointRefreshWaiters.append($0) }
    }

    /// Client-scoped counterpart for a terminal viewer's foreground redial. Keyed on the exact client
    /// instance the viewer captured when its route opened (`DeviceTerminalContext.client`), not on
    /// `deviceID`'s current role: a device's role (selected/non-selected) can change after that capture
    /// (a device switch, in either direction) while the viewer goes on dialing through the same client
    /// object regardless, and `selectDevice`/`overviewStreamClient(forDeviceID:)` each hand out a fresh
    /// client instance on a role change rather than reusing the old one, so the device's *current* role is
    /// not necessarily the captured client's own.
    ///
    /// - The captured client is still `bridgeClient` (the device was selected when the viewer opened and
    ///   still is): waits on the gate above, since `resumeFromBackground()` resets exactly this instance's
    ///   command path and releases the gate only once that reset lands.
    /// - Otherwise: never waits on the selected gate, since nothing about the selected device's own
    ///   refresh says anything about this client (matches the previous device-scoped behavior for a
    ///   non-selected device that stays non-selected). If the client is still the cached client for its
    ///   own device, this call first waits for `resetDeviceStreamEndpointsForForeground()` to have even
    ///   started this device's reset (`waitForNonSelectedForegroundResetToStart()`, needed because
    ///   SwiftUI gives no ordering between the shell's `.active` callback and this one, so this call can
    ///   run first and find nothing recorded yet), then awaits that same in-flight reset via
    ///   `nonSelectedDeviceForegroundResetTasks` before returning, so the redial that follows never reads
    ///   a still-stale address. If the client has instead stopped being the cached client for its own
    ///   device (orphaned by a role change since the viewer opened: it was `bridgeClient` and the device
    ///   has since been deselected, or it was a `nonActiveDeviceStreamClients` entry the device has since
    ///   been selected away from), nothing else resets it going forward:
    ///   `resetDeviceStreamEndpointsForForeground()` only walks `bridgeClient` and the *current*
    ///   `nonActiveDeviceStreamClients` entries, neither of which is this stale instance anymore. Its
    ///   resolvers are reset in place here instead, awaited so the reset lands before the redial that
    ///   follows this call.
    func waitForForegroundEndpointRefresh(client: SpacesDeviceAPIClient, deviceID: String) async {
        if client.hasSameIdentity(as: bridgeClient) {
            await waitForForegroundEndpointRefresh()
            return
        }
        guard !isCurrentTerminalClient(client, forDeviceID: deviceID) else {
            await waitForNonSelectedForegroundResetToStart()
            await nonSelectedDeviceForegroundResetTasks[deviceID]?.value
            return
        }
        client.resetOverviewStreamEndpointResolution()
        await client.resetEndpointResolution()
    }

    /// Suspends until `resetDeviceStreamEndpointsForForeground()` has recorded this backgrounding's
    /// per-device reset tasks, or returns immediately when none is owed. See
    /// `isNonSelectedForegroundResetPending`'s doc comment for why a non-selected terminal's own
    /// foreground redial needs this ahead of awaiting its device's own recorded task.
    ///
    /// A waiter cannot be stranded, for the same reason `waitForForegroundEndpointRefresh()`'s own
    /// documents: `RootTabView` runs `resetDeviceStreamEndpointsForForeground()` on every `.active`, so
    /// the backgrounding that armed this gate is always followed either by that call or by the app being
    /// terminated, which takes the waiter with it.
    private func waitForNonSelectedForegroundResetToStart() async {
        guard isNonSelectedForegroundResetPending else { return }
        await withCheckedContinuation { nonSelectedForegroundResetWaiters.append($0) }
    }

    /// Whether `client` is still the value actively serving `deviceID` right now: `bridgeClient` for the
    /// selected device, or `nonActiveDeviceStreamClients[deviceID]`'s cached client for any other paired
    /// device. Read-only by design (unlike `overviewStreamClient(forDeviceID:)`, which can build and
    /// cache a fresh client as a side effect of a settings change): a foreground-refresh identity check
    /// must never itself be what causes a client to be replaced.
    private func isCurrentTerminalClient(_ client: SpacesDeviceAPIClient, forDeviceID deviceID: String) -> Bool {
        guard deviceID != activeDeviceID else { return client.hasSameIdentity(as: bridgeClient) }
        guard let cached = nonActiveDeviceStreamClients[deviceID]?.client else { return false }
        return client.hasSameIdentity(as: cached)
    }

    /// Opens the gate, but only for the newest resume of the backgrounding still outstanding: a later
    /// `noteBackgroundedForEndpointRefresh()`, or a later resume of the same backgrounding, leaves the
    /// gate armed for that later call to release. Everyone waiting is released together, since the gate
    /// answers one question ("has the foreground refresh landed"), and the refresh that lands is the
    /// newest one.
    private func releaseForegroundEndpointRefreshWaiters(armedBy generation: UInt64, startedAs resumeToken: UInt64) {
        guard foregroundEndpointRefreshGeneration == generation, latestForegroundResumeToken == resumeToken else { return }
        isForegroundEndpointRefreshPending = false
        let waiters = foregroundEndpointRefreshWaiters
        foregroundEndpointRefreshWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Opens `isNonSelectedForegroundResetPending`'s gate, releasing every non-selected device's own
    /// foreground redial that was waiting only for the reset to have started (not for it to have landed:
    /// each waiter still separately awaits its own device's recorded task after this). No generation check
    /// like `releaseForegroundEndpointRefreshWaiters` needs: see `isNonSelectedForegroundResetPending`'s
    /// doc comment for why this gate has no window for a release to answer for the wrong backgrounding.
    private func releaseNonSelectedForegroundResetWaiters() {
        guard isNonSelectedForegroundResetPending else { return }
        isNonSelectedForegroundResetPending = false
        let waiters = nonSelectedForegroundResetWaiters
        nonSelectedForegroundResetWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func selectDevice(id: String) {
        guard !isDemoModeEnabled else {
            connectionNotice = Self.demoModeGuardNotice
            return
        }
        guard let deviceState = SpacesMobileDeviceStore.select(deviceID: id, installationID: settings.installationID) else { return }
        let previousDeviceID = activeDeviceID
        let previousCommandChannel = commandChannel
        // Cleared before the identity moves, not after: what the previous device reported is read as a
        // statement about whichever device `activeDeviceID` names, so the two must never be crossed, not
        // even for the few assignments in between.
        clearActiveDeviceFacts()
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        bridgeClient = SpacesDeviceAPIClient(settings: settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
        // The device losing selection and the device gaining it both leave a non-selected identity
        // behind them (see `nonSelectedDeviceIdentities`'s doc comment): without this, a mutation token
        // captured against `id` while it was still non-selected could read as current again after `id`
        // is selected and then deselected back, since nothing else bumps that identity across the trip.
        // `previousDeviceID` reads nil only when nothing was selected before (first-ever selection), which
        // leaves nothing to bump.
        if let previousDeviceID { invalidateNonSelectedDeviceConnection(deviceID: previousDeviceID) }
        invalidateNonSelectedDeviceConnection(deviceID: id)
        SpacesMobileSettingsStore.save(settings)
        // The report names the device it was raised for, so it goes with that device rather than being
        // read as a statement about the one just switched to. Its mark survives: the device it describes
        // still has that build staged and unapplied, and switching back must not re-fire the apply.
        stagedApplyDidNotLandAlert = nil
        workspaceCreateOptions = nil
        connectionNotice = nil
        errorMessage = nil
        loadDismissedAlertIDsForPairedDevices()
        reconcileDeviceStreamsAfterIdentityChange()
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
        let previousDeviceID = activeDeviceID
        let previousCommandChannel = commandChannel
        let deviceState = SpacesMobileDeviceStore.remove(deviceID: id, fallbackSettings: settings)
        // Drops `id`'s own cached overview, client/channel, and mutation identity directly, rather than
        // leaving it to `reconcileDeviceStreams`'s stale-device cleanup: that cleanup only runs while
        // `overviewStreamSubscriptions.isEnabled` (streams are foreground-only), so without this an unpair
        // made while streams happen to be stopped would leave a removed device's state in place, and a
        // mutation already in flight against it could land afterward, its response still reading as
        // current and resurrecting `deviceOverviews[id]` for a device the app no longer shows anywhere.
        deviceOverviews[id] = nil
        invalidateNonSelectedDeviceConnection(deviceID: id)
        offlineDeviceIDs.remove(id)
        // Cleared before the identity moves, for the reason `selectDevice` clears it there. Runs after the
        // drop above so its retained-screen prune reads `deviceOverviews` with `id` already gone.
        clearActiveDeviceFacts()
        settings = deviceState.settings
        pairedDevices = deviceState.devices
        activeDeviceID = deviceState.activeDeviceID
        bridgeClient = SpacesDeviceAPIClient(settings: settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
        // Removing a device that was active hands selection to a fallback device, the same role change
        // `selectDevice` makes; bump both ends of it for the reason given there. `id` itself is already
        // invalidated above regardless of which end of the change it was on. Either side can read nil
        // (no device was active before, or none is active after removing the last paired device), which
        // leaves nothing to bump on that side.
        if let previousDeviceID { invalidateNonSelectedDeviceConnection(deviceID: previousDeviceID) }
        if let activeDeviceID { invalidateNonSelectedDeviceConnection(deviceID: activeDeviceID) }
        SpacesMobileSettingsStore.save(settings)
        stagedApplyDidNotLandAlert = nil
        forgetStagedApplyState(deviceID: id)
        workspaceCreateOptions = nil
        connectionNotice = nil
        loadDismissedAlertIDsForPairedDevices()
        pruneDismissedAlertsForUnknownDevices()
        browserRoutingTable.removeDevice(deviceID: id)
        let table = browserRoutingTable
        Task { await browserProxy.updateRoutes(table) }
        reconcileDeviceStreamsAfterIdentityChange()
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
        let previousDeviceID = activeDeviceID
        let previousCommandChannel = commandChannel
        // Cleared before the identity moves, for the reason `selectDevice` clears it there.
        clearActiveConnectionState()
        let demoSettings = SpacesMobileDemoDevice.settings(installationID: settings.installationID)
        settings = demoSettings
        pairedDevices = [SpacesMobileDemoDevice.record()]
        activeDeviceID = SpacesMobileDemoDevice.id
        isDemoModeEnabled = true
        bridgeClient = SpacesDeviceAPIClient(settings: demoSettings, deviceName: UIDevice.current.name, backend: backend)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
        // The same role-change bump `selectDevice` makes, for the parked real device losing selection
        // and the synthetic demo device gaining it. `previousDeviceID` reads nil only when nothing was
        // selected before, which leaves nothing to bump on that side.
        if let previousDeviceID { invalidateNonSelectedDeviceConnection(deviceID: previousDeviceID) }
        invalidateNonSelectedDeviceConnection(deviceID: SpacesMobileDemoDevice.id)
        DemoModeStore.save(true)
        loadDismissedAlertIDsForPairedDevices()
        reconcileDeviceStreamsAfterIdentityChange()
        Task { await previousCommandChannel.close() }
    }

    private func disableDemoMode() {
        let restored = parkedRealDeviceState ?? SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileSettingsStore.load())
        parkedRealDeviceState = nil
        let previousDeviceID = activeDeviceID
        let previousCommandChannel = commandChannel
        // Cleared before the identity moves, for the reason `selectDevice` clears it there.
        clearActiveConnectionState()
        settings = restored.settings
        pairedDevices = restored.devices
        activeDeviceID = restored.activeDeviceID
        isDemoModeEnabled = false
        bridgeClient = SpacesDeviceAPIClient(settings: restored.settings, deviceName: UIDevice.current.name)
        commandChannel = bridgeClient.makeCommandChannel()
        overviewIdentity += 1
        // The same role-change bump `selectDevice` makes, for the demo device losing selection and the
        // restored real device gaining it. Either side can read nil (no device was ever selected before
        // Demo Mode, or the restored real state has no active device), which leaves nothing to bump on
        // that side.
        if let previousDeviceID { invalidateNonSelectedDeviceConnection(deviceID: previousDeviceID) }
        if let activeDeviceID { invalidateNonSelectedDeviceConnection(deviceID: activeDeviceID) }
        DemoModeStore.save(false)
        loadDismissedAlertIDsForPairedDevices()
        pruneDismissedAlertsForUnknownDevices()
        reconcileDeviceStreamsAfterIdentityChange()
        Task { await previousCommandChannel.close() }
    }

    /// What the active device itself reported: the overview, the wire status, and the verdict derived
    /// from it. Every path that points this model at a different device clears these, and clears them
    /// before it changes `activeDeviceID`, so no derivation ever reads one device's facts as the next
    /// device's. Also prunes retained screens immediately, though nilling `overview` here does not by
    /// itself drop the previous selected device's own: `pruneRetainedTerminalScreens` reads every device,
    /// including whichever one `activeDeviceID` still names at this instant, through `overview(forDeviceID:)`,
    /// which falls back to that device's own `deviceOverviews` entry once its `overview` reads nil (see
    /// that accessor's and the prune's own doc comments), so the previous device's last-known overview
    /// still vouches for its screens here. A device actually stops being that source of truth only once
    /// its `deviceOverviews` entry itself is cleared: on unpair (`removeDevice`), on re-pair
    /// (`applyConnectionSettings`), or once the compatibility gate blocks it (`overview(forDeviceID:)`
    /// again).
    private func clearActiveDeviceFacts() {
        overview = nil
        daemonStatus = nil
        compatibility = nil
        pruneRetainedTerminalScreens()
    }

    /// Clears every piece of published state tied to the previous active connection, matching what a
    /// device switch resets so no stale overview, status, or notice bleeds across the swap.
    private func clearActiveConnectionState() {
        clearActiveDeviceFacts()
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
    /// it destroyed the only in-memory copy of something still on disk and left every future stream
    /// reconnect (or explicit refresh) failing on the exact same auth error, with no way it could ever
    /// prove the device reachable again. Keeping it means a failure that was really transport trouble
    /// self-heals on the stream's next retry, while a genuinely revoked device simply fails the next
    /// request and lands back on this same screen. The connection itself is still reset, since the
    /// address and socket that just failed are not worth trusting and the next request should re-race
    /// every candidate. The client is not rebuilt: with the credential unchanged a rebuild would produce
    /// an identical client and throw away the resolver state the recovery is about to use.
    ///
    /// Re-entrant by design: with the stream still retrying, a device that keeps rejecting this token calls
    /// here every couple of seconds. `connectionNotice` is the episode marker, cleared by a successful
    /// refresh, so the recovery surface is raised once per episode rather than pulling the user back to
    /// Paired Devices every time they navigate away from it.
    func handleAuthenticationFailure(message: String) {
        guard connectionNotice != message else { return }
        overviewIdentity += 1
        overview = nil
        pruneRetainedTerminalScreens()
        workspaceCreateOptions = nil
        connectionNotice = message
        pendingPairingLink = nil
        errorMessage = nil
        isShowingConnectionSettings = true
        resetActiveConnectionEndpoint()
    }

    /// Single entry for any authentication failure raised against a specific device, whether discovered
    /// by a terminal viewer's own request (`TerminalSessionNavigationModifier`, after its route closes)
    /// or by a row mutation issued from elsewhere (`handleBridgeError(_:deviceID:)`). The selected device
    /// gets `handleAuthenticationFailure(message:)`'s full recovery; another device only gets the
    /// device-named text below (its own stream already reports the rejection as an offline marking via
    /// `handleDeviceStreamFailure`, with nothing else here to reset) plus the rejection signal above,
    /// which closes any terminal route still open for it.
    func handleAuthenticationFailure(message: String, deviceID: String) {
        guard deviceID == activeDeviceID else {
            errorMessage = deviceAuthenticationRejectedMessage(deviceID: deviceID)
            nextDeviceAuthenticationRejectionToken += 1
            nonSelectedDeviceAuthenticationRejection = DeviceAuthenticationRejection(
                deviceID: deviceID, token: nextDeviceAuthenticationRejectionToken)
            return
        }
        handleAuthenticationFailure(message: message)
    }

    /// Text for a paired device that has rejected this iPhone's credential: the only recovery is
    /// re-pairing through Devices.
    private func deviceAuthenticationRejectedMessage(deviceID: String) -> String {
        let deviceName = pairedDevices.first(where: { $0.id == deviceID })?.name ?? "This device"
        return "\(deviceName) no longer recognizes this iPhone. Open Devices and pair it again."
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

    /// A link printed inside a terminal names that terminal's own device when it names none: daemons
    /// print same-device links unqualified, and the terminal rendering the link may belong to a paired
    /// device other than the one currently selected, which is what an unqualified link would otherwise
    /// resolve against. Stamping the selected device's own id is harmless: `openTerminalDeepLink` treats
    /// `deviceID == activeDeviceID` exactly like an unqualified link.
    nonisolated static func deepLink(_ link: SpacesTerminalDeepLink, printedOnDeviceID deviceID: String) -> SpacesTerminalDeepLink {
        guard link.deviceID == nil else { return link }
        return SpacesTerminalDeepLink(sessionID: link.sessionID, deviceID: deviceID)
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
        // The cached overview may predate the linked session: the link can arrive before that
        // device's stream has delivered the change that created the session, or while its stream is
        // reconnecting, and switching to a device with no cached overview of its own leaves this
        // empty too. A lookup miss refreshes once before the link is declared dead.
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
                CreateWorkspaceConfig(
                    projectID: projectID, branch: branch, baseBranch: baseBranch, directoryName: directoryName,
                    allowExistingBranchReuse: allowExistingBranchReuse), commandChannel: commandChannel)
            await applyMutationResponse(response, identity: identity)
            guard identity == overviewIdentity else { return }
            isShowingWorkspaceCreateSheet = false
        } catch {
            guard identity == overviewIdentity else { return }
            handleBridgeError(error)
        }
    }

    func openWorkspaceTerminal(workspaceID: String) async -> SpacesDeviceTerminalSessionSummary? {
        guard let activeDeviceID else { return nil }
        return await performMutationReturningSession(deviceID: activeDeviceID) { channel, client in
            try await client.openWorkspaceTerminal(workspaceID: workspaceID, commandChannel: channel)
        }
    }

    /// Runs a row's process on `deviceID`, the selected device or any other paired one alike: both resolve
    /// their client and channel through `mutationConnection(forDeviceID:)` and apply the response through
    /// the same `isCurrent(token)`-gated path (see `performMutationReturningSession`).
    func run(row: SpacesMobileWorkspaceRuntimeRow, deviceID: String) async -> SpacesDeviceTerminalSessionSummary? {
        let timeoutRecovery = SpacesMobileMutationTimeoutRecovery.requireFreshOverview(previousSessionID: row.sessionID)
        switch row.source {
        case .process(let process):
            guard process.canRun else { return nil }
            return await performMutationReturningSession(deviceID: deviceID, fallbackRowID: row.id, timeoutRecovery: timeoutRecovery) {
                channel, client in
                try await client.runWorkspaceProcess(
                    workspaceID: process.workspaceID, processKey: process.name, processTemplateID: process.templateID ?? process.id,
                    commandChannel: channel)
            }
        case .codingAgent, .terminal, .browserSession: return nil
        }
    }

    func performPrimaryAction(for row: SpacesMobileWorkspaceRuntimeRow, deviceID: String) async -> SpacesDeviceTerminalSessionSummary? {
        // `terminalSession(for:)` alone reads the selected device's own `overview`, which is the wrong
        // evidence for a row from any other paired device's Agents/Alerts entry: it would either resolve
        // against a different device's sessions or find nothing and re-run an already-running row.
        if let session = terminalSession(for: row, in: overview(forDeviceID: deviceID)) { return session }
        return await run(row: row, deviceID: deviceID)
    }

    func stop(row: SpacesMobileWorkspaceRuntimeRow, deviceID: String) async {
        guard !isMutating else { return }
        guard let connection = mutationConnection(forDeviceID: deviceID) else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let response: SpacesDeviceAPIResponse
            switch row.source {
            case .process(let process):
                guard let processID = process.processID else { return }
                response = try await connection.client.stopWorkspaceProcess(
                    workspaceID: process.workspaceID, processID: processID, processKey: process.name, commandChannel: connection.channel)
            case .codingAgent(let agent):
                // Automation agents share the workspace terminal stop route: the daemon first cancels an
                // active automation run, then stops the registered or pre-signal session. The server still
                // recognizes ordinary configured-process agent rows on this route.
                if let sessionID = agent.sessionID {
                    response = try await connection.client.stopWorkspaceTerminal(
                        workspaceID: agent.workspaceID, sessionID: sessionID, commandChannel: connection.channel)
                } else if let agentID = agent.agentID {
                    response = try await connection.client.stopCodingAgent(
                        workspaceID: agent.workspaceID, agentID: agentID, commandChannel: connection.channel)
                } else {
                    return
                }
            case .terminal(let terminal):
                guard let sessionID = terminal.sessionID else { return }
                response = try await connection.client.stopWorkspaceTerminal(
                    workspaceID: terminal.workspaceID, sessionID: sessionID, commandChannel: connection.channel)
            case .browserSession: return
            }
            await applyMutationResponse(response, token: connection.token)
        } catch {
            guard isCurrent(connection.token) else { return }
            handleBridgeError(error, deviceID: deviceID)
        }
    }

    func restart(row: SpacesMobileWorkspaceRuntimeRow, deviceID: String) async -> SpacesDeviceTerminalSessionSummary? {
        let timeoutRecovery = SpacesMobileMutationTimeoutRecovery.requireFreshOverview(previousSessionID: row.sessionID)
        switch row.source {
        case .process(let process):
            guard let processID = process.processID else { return nil }
            return await performMutationReturningSession(deviceID: deviceID, fallbackRowID: row.id, timeoutRecovery: timeoutRecovery) {
                channel, client in
                try await client.restartWorkspaceProcess(
                    workspaceID: process.workspaceID, processID: processID, processKey: process.name, commandChannel: channel)
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

    /// Sets one workspace's visibility: a single hidden-flag mutation, hide and unhide alike. Hide changes
    /// only the hidden flag, never run state, so a running workspace keeps running hidden and stays one
    /// unhide away in the Workspaces sheet.
    func setWorkspaceHidden(workspaceID: String, isHidden: Bool) async {
        // Hiding a workspace whose delete is still unresolved would act on a row that is already leaving.
        // `performWorkspaceMutation` below still gates on `isMutating`, since this rides the shared
        // `commandChannel`, but that alone would not catch this: an unresolved delete leaves `isMutating`
        // false (see `deleteWorkspace`), so this needs its own check of the pending-deletion mark. The
        // marked predicate, not the local set: a delete started on another client is just as much a row
        // on its way out.
        guard !isWorkspacePendingDeletion(workspaceID) else { return }
        await performWorkspaceMutation {
            try await bridgeClient.setWorkspaceHidden(workspaceID: workspaceID, isHidden: isHidden, commandChannel: commandChannel)
        }
    }

    /// Sets a project's visibility: a single hidden-flag mutation, hide and unhide alike. Hide changes only
    /// the hidden flag, never run state, so the project's running workspaces keep running hidden.
    ///
    /// The project flag is independent of each workspace's, so this never writes a child's flag: unhiding
    /// the project brings back exactly the workspaces that were shown before it was hidden.
    func setProjectHidden(projectID: String, isHidden: Bool) async {
        await performWorkspaceMutation {
            try await bridgeClient.setProjectHidden(projectID: projectID, isHidden: isHidden, commandChannel: commandChannel)
        }
    }

    /// Reconciliation attempts after an indeterminate `archiveWorkspace` failure (see `deleteWorkspace`
    /// and `isIndeterminateDeleteOutcome`). The daemon
    /// runs the delete on its own teardown queue and can keep going well past this request's timeout, so
    /// refetching the overview a few times gives a delete that is still finishing a chance to resolve to
    /// success instead of a spurious error. Five attempts at `workspaceDeletionReconciliationInterval`
    /// give the daemon a settle window on the order of the selected device's stream retry cadence rather
    /// than an instant verdict.
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
        // Sent on a dedicated command channel rather than the shared one an explicit overview refresh
        // also uses. The daemon runs a delete's teardown (stop, worktree removal, record drop) on its own
        // queue, so it can take many seconds, far longer than the 8s a refresh allows itself. The
        // transport does not serialize whole request/response round trips on a connection (issue #248):
        // a refresh and this request can interleave on one connection, and when the refresh's own request
        // times out, `SpacesDeviceNetworkRequestTransport.send` closes the shared connection out from
        // under whatever else is using it, aborting this request client-side while the daemon keeps
        // deleting regardless.
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
        // These fetches are issued after the delete was sent, so each one is newer than any overview fetch
        // already in flight; publishing one retires those fetches the same way applying a mutation's own
        // overview does.
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
            await updateBrowserRoutes(
                overview: refreshedOverview, identity: identity, mutationGeneration: mutationGenerationAtFetch, isStillCurrent: { true })
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

    /// Session-ID and row-ID lookup index over the runtime rows derived from the published `overview`,
    /// for `runtimeRow(forSessionID:)` and the published-overview `refreshedSession(forRowID:)` below —
    /// both are called on every body evaluation of hot chrome (e.g. `TerminalDetailView.runtimeRow`),
    /// and previously rebuilt every workspace's runtime rows with `flatMap` and linearly scanned them on
    /// every call. First key wins on a duplicate session/row id, matching the `.first {}` scans this
    /// replaces.
    private struct RuntimeRowIndex {
        let bySessionID: [String: SpacesMobileWorkspaceRuntimeRow]
        let byRowID: [String: SpacesMobileWorkspaceRuntimeRow]
    }

    /// Built lazily on first access after `overview` changes; `overview`'s `didSet` clears this back to
    /// `nil`. Not observed by `@Observable`: it is a derived cache of the published `overview`, not
    /// independent state a view should re-render on.
    @ObservationIgnored private var cachedRuntimeRowIndex: RuntimeRowIndex?

    private var runtimeRowIndex: RuntimeRowIndex {
        // Read `overview` through its observable getter on every lookup — including cache hits.
        // The cache is `@ObservationIgnored`, so without this read a warm-cache body evaluation
        // would register no dependency on `overview`, and a later overview-only update would not
        // invalidate the view (stale terminal title/actions until unrelated state changed).
        let overview = self.overview
        if let cachedRuntimeRowIndex { return cachedRuntimeRowIndex }
        var bySessionID: [String: SpacesMobileWorkspaceRuntimeRow] = [:]
        var byRowID: [String: SpacesMobileWorkspaceRuntimeRow] = [:]
        for row in overview?.workspaces.flatMap(workspaceRuntimeRows(for:)) ?? [] {
            byRowID[row.id] = byRowID[row.id] ?? row
            if let sessionID = row.sessionID { bySessionID[sessionID] = bySessionID[sessionID] ?? row }
        }
        let index = RuntimeRowIndex(bySessionID: bySessionID, byRowID: byRowID)
        cachedRuntimeRowIndex = index
        return index
    }

    func runtimeRow(forSessionID sessionID: String) -> SpacesMobileWorkspaceRuntimeRow? { runtimeRowIndex.bySessionID[sessionID] }

    /// See `terminalSession(for:)`/`terminalSession(for:in:)`: reads the published `overview`.
    func refreshedSession(forRowID rowID: String) -> SpacesDeviceTerminalSessionSummary? {
        runtimeRowIndex.byRowID[rowID].flatMap { terminalSession(for: $0, in: overview) }
    }

    /// `refreshedSession(forRowID:)`, scoped to any paired device: the selected device's cached
    /// `runtimeRowIndex`, or a cold scan of `overview(forDeviceID:)` for any other device (mirrors
    /// `runtimeRow(forSessionID:deviceID:)`).
    func refreshedSession(forRowID rowID: String, deviceID: String) -> SpacesDeviceTerminalSessionSummary? {
        guard deviceID != activeDeviceID else { return refreshedSession(forRowID: rowID) }
        let deviceOverview = overview(forDeviceID: deviceID)
        return deviceOverview?.workspaces.flatMap(workspaceRuntimeRows(for:)).first(where: { $0.id == rowID }).flatMap {
            terminalSession(for: $0, in: deviceOverview)
        }
    }

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

    /// `operation` receives the connection's channel and client, so a caller issues its request through
    /// whichever paired device `deviceID` resolves to (see `mutationConnection(forDeviceID:)`) without
    /// knowing whether that is the selected device or another one.
    private func performMutationReturningSession(
        deviceID: String, fallbackRowID: String? = nil, timeoutRecovery: SpacesMobileMutationTimeoutRecovery = .acceptCachedOverview,
        _ operation: (SpacesDeviceAPICommandChannel, SpacesDeviceAPIClient) async throws -> SpacesDeviceAPIResponse
    ) async -> SpacesDeviceTerminalSessionSummary? {
        guard !isMutating else { return nil }
        guard let connection = mutationConnection(forDeviceID: deviceID) else { return nil }
        isMutating = true
        defer { isMutating = false }
        do {
            let response = try await operation(connection.channel, connection.client)
            await applyMutationResponse(response, token: connection.token)
            // The connection changed while the mutation was in flight: the response describes the
            // previous backend, so resolving a session from it would hand back the wrong device's row.
            guard isCurrent(connection.token) else { return nil }
            // Resolved from `response.overview`, this mutation's own evidence of what it just did, not
            // from the model's published state. `applyMutationResponse` above gates its own publish on
            // freshness, which answers a different question ("is this the newest overview-derived fact
            // right now") than the one this call owes its caller ("did my own action produce a session"):
            // a fresher, unrelated fetch can win that race even though this mutation fully succeeded.
            // Reading published state here would then report a successful Run/Restart/Terminal as a
            // failure, self-healing on the next overview delivery, but only after already showing the
            // wrong answer (#450).
            if let sessionID = response.sessionID { return response.overview?.sessions.first(where: { $0.id == sessionID }) }
            if let fallbackRowID { return refreshedSession(forRowID: fallbackRowID, in: response.overview) }
            return nil
        } catch {
            guard isCurrent(connection.token) else { return nil }
            if let fallbackRowID, isMutationTimeout(error),
                let session = await reconciledSessionAfterMutationTimeout(
                    rowID: fallbackRowID, timeoutRecovery: timeoutRecovery, connection: connection)
            {
                return session
            }
            guard isCurrent(connection.token) else { return nil }
            handleBridgeError(error, deviceID: deviceID)
            return nil
        }
    }

    /// Row-mutation counterpart of `applyMutationResponse(_:identity:)`: the selected device delegates to
    /// it unchanged; another device applies through `acceptNonSelectedDeviceOverview`, the same function
    /// its stream push uses. A response can land after a newer stream push already updated that device's
    /// overview; the next push corrects it, the same accepted bound `applyMutationResponse(_:identity:)`
    /// documents for the selected device.
    private func applyMutationResponse(_ response: SpacesDeviceAPIResponse, token: MutationConnectionToken) async {
        guard isCurrent(token) else { return }
        guard token.isSelected else {
            if let overview = response.overview { acceptNonSelectedDeviceOverview(overview, deviceID: token.deviceID) }
            return
        }
        await applyMutationResponse(response, identity: token.identity)
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
        // changed either way, so any refresh already in flight is describing the world before it. Captured
        // right after bumping, and re-checked once this call resumes from the await below: a delete's
        // private channel no longer excludes a shared-channel mutation from running at the same time
        // (#450), so two responses can now be applying concurrently, and there is no guarantee the one
        // that started first is the one that resumes first. If some other call's response already bumped
        // and published while this one was suspended, this one is the stale side of that race.
        mutationGeneration &+= 1
        let mutationGenerationAtApply = mutationGeneration
        guard let overview = response.overview else { return }
        await updateBrowserRoutes(overview: overview, identity: identity, mutationGeneration: mutationGenerationAtApply, isStillCurrent: { true })
        // Skip rather than republish: a newer mutation's response already landed and published its
        // overview while this one was suspended above, so this one is describing a moment the app has
        // already moved past.
        //
        // Accepted bound of this ordering: "newer" is apply-start order on this client, not daemon
        // snapshot order. Responses arriving on independent connections can invert — an older lifecycle
        // response bumping the generation after a newer delete response started applying discards the
        // delete's overview — because nothing in the wire carries a daemon-side revision to totally
        // order snapshots by. The mutation's own daemon-side change is also pushed on the stream, and that
        // push corrects the misordered pair's stale rows; a daemon revision (a wire change) is what fixing
        // the ordering itself would take.
        guard isOverviewFetchCurrent(identity: identity, mutationGeneration: mutationGenerationAtApply) else { return }
        // Cleared before publishing, for the same reason as in `performRefresh`.
        connectionNotice = nil
        errorMessage = nil
        publishOverview(overview)
        // A mutation's refreshed overview is proof the device answered, so it ends any run of failed
        // refreshes exactly as a successful refresh does. Otherwise a run interrupted by a successful
        // mutation keeps its original start time, and the next isolated failure alerts on the strength
        // of an outage that demonstrably ended.
        refreshFailureStreak = nil
    }

    /// Publishes an accepted overview and trims stale alert dismissals against it. Every path that
    /// publishes a fetched overview goes through here, so the persisted dismissal set is pruned exactly
    /// once per refresh. Clearing the overview (a device switch, a block) deliberately does not prune:
    /// there is nothing to prune against, and pruning against nothing would discard every dismissal.
    /// Settles deletes whose outcome nothing could confirm when they finished (see the `.unknown` case in
    /// `deleteWorkspace`). Every published overview is a chance to answer, whichever path produced it: a
    /// stream push, an explicit refresh, a later mutation, or a reconciliation. The resolution lives here,
    /// at the one place an overview becomes the app's state.
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

    /// Republishes `overview` only when the freshly fetched payload actually differs from what's already
    /// published. Several paths can deliver a payload describing state that has not actually changed: the
    /// selected device's stream sends its current overview again on every reconnect, and a metadata-only
    /// daemon change still pushes a full overview on its own coalesced cadence
    /// (`overviewMetadataCoalesceInterval`); an unconditional `overview = payload` here would re-trigger
    /// `@Observable`'s change notification on every one of those regardless, even a no-op delivery,
    /// invalidating and re-rendering every view reading `overview` (#540: the Automations tab's constant
    /// visible churn). `SpacesDeviceOverviewPayload` is `Equatable`, so a matching fetch is skipped here at
    /// effectively no cost.
    ///
    /// The two calls below still run against every fetched `payload`, gate or no gate: both are idempotent
    /// against an unchanged payload (they derive their result solely from `payload`'s own content, so a
    /// repeat payload reproduces the same no-op), and `resolveDeferredWorkspaceDeletions` in particular is
    /// documented to treat "every published overview" — read: every successful fetch, not just the ones
    /// that changed `overview` — as a chance to settle a deferred delete.
    /// Sessions `overview` says are still worth retaining a painted screen for: still open (not ended) and
    /// not actively owned by an owner elsewhere. Shared by `pruneRetainedTerminalScreens` across every
    /// paired device's own overview.
    private func retainableSessionIDs(in overview: SpacesDeviceOverviewPayload) -> Set<String> {
        Set(
            overview.sessions.filter { session in
                !TerminalViewerModel.isEndedRuntimeState(session.state) && !retainedTerminalScreens.isOwnedElsewhere(session.attachmentSnapshot)
            }.map(\.id))
    }

    /// Recomputes `retainedTerminalScreens`' keep-set from the published `overview` plus every paired
    /// device's last-known overview, and prunes down to just those sessions. Called whenever any device's
    /// overview changes: the selected device's own publish, and a non-selected device's stream push, so a
    /// non-selected device's own ended or reassigned session drops its retained screen as promptly as the
    /// selected device's does, and the selected device publishing never evicts a screen retained for a
    /// device its own payload says nothing about.
    ///
    /// Two sources, unioned, because neither alone covers every construction this app (and its tests) can
    /// be in:
    /// - The published `overview` field directly, unconditionally. This is the only source for a device
    ///   that has no `pairedDevices` record at all (a bootstrap or single-connection state that never went
    ///   through pairing), so its own retained screens would otherwise never be credited by anything.
    /// - Every `pairedDevices` entry, read through `overview(forDeviceID:)` (the same accessor Agents/Alerts
    ///   rows use), rather than a hand-split "this device's `overview`, every *other* device's
    ///   `deviceOverviews` entry": `clearActiveDeviceFacts()` calls this between nilling `overview` and
    ///   moving `activeDeviceID` to the device a switch, re-pair, or removal is headed to, so at that
    ///   instant `overview` already reads nil but `activeDeviceID` still names the device leaving
    ///   selection. A hand-split version keyed off `activeDeviceID` would credit that device with nothing
    ///   (`overview` nil) while also skipping its own `deviceOverviews` entry, dropping every one of its
    ///   retained screens even though it is still paired and its last known overview, sitting untouched in
    ///   `deviceOverviews[id]`, still lists them. Reading through `overview(forDeviceID:)` for every paired
    ///   device sidesteps the ordering entirely: whichever device `activeDeviceID` names at the moment this
    ///   runs still gets `overview ?? deviceOverviews[activeDeviceID]`, exactly the fallback that accessor
    ///   documents for the selected device.
    ///
    /// A blocked device's screens are dropped along with its rows: `overview(forDeviceID:)` reads nil for
    /// one (see that accessor's own doc comment), so it contributes no session ids here either, the same
    /// as a device this app has stopped hearing from entirely. Reopening it once it clears the block finds
    /// nothing retained, the same first-open experience as any other freshly reachable device. This never
    /// leaks through the unconditional `overview` read above either: `applyFetchedOverview` already nils
    /// the published `overview` for a blocked active device before this runs.
    private func pruneRetainedTerminalScreens() {
        var keep: Set<String> = []
        if let overview { keep.formUnion(retainableSessionIDs(in: overview)) }
        for device in pairedDevices {
            guard let deviceOverview = overview(forDeviceID: device.id) else { continue }
            keep.formUnion(retainableSessionIDs(in: deviceOverview))
        }
        retainedTerminalScreens.retainOnly(sessionIDs: keep)
    }

    private func publishOverview(_ payload: SpacesDeviceOverviewPayload?) {
        if payload != overview { overview = payload }
        if let payload {
            if let activeDeviceID { pruneDismissedAlertIDs(deviceID: activeDeviceID, against: payload) }
            resolveDeferredWorkspaceDeletions(against: payload)
            // A session the device no longer lists cannot be reopened, an ended one is never painted from
            // memory (its final transcript is what it shows, and it stays listed for days), and one that
            // another device actively owns is being drawn somewhere else, so the screen this device last
            // saw is stale and a reopen would show the active-owner notice instead of it. Their retained
            // screens are dropped here (see `pruneRetainedTerminalScreens`, which also keeps every other
            // paired device's own retained screens instead of evicting them the moment the selected device
            // happens to publish). An owner that is one of this app's own viewers does not count: the
            // viewer keeps the store current itself, and it stays attached for a round trip after its
            // detail is dismissed, which is exactly when the list's first refresh lands.
            pruneRetainedTerminalScreens()
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

    /// Row-mutation counterpart of `handleBridgeError(_:)`, for a request issued against `deviceID` rather
    /// than always the selected device. The selected device defers to it unchanged. Another device never
    /// resets a connection or raises Paired Devices: its own stream already reports the disconnect through
    /// `handleDeviceStreamFailure`. An authentication failure routes through `handleAuthenticationFailure(
    /// message:deviceID:)` rather than setting `errorMessage` directly, so a device that rejects a
    /// mutation also closes any terminal route still open for it, not just this one's error text; any
    /// other failure only names it for the terminal the user was looking at.
    private func handleBridgeError(_ error: Error, deviceID: String) {
        guard deviceID != activeDeviceID else {
            handleBridgeError(error)
            return
        }
        guard !(error is CancellationError) else { return }
        if let recoveryMessage = SpacesDeviceAPIAuthentication.recoveryMessage(for: error) {
            handleAuthenticationFailure(message: recoveryMessage, deviceID: deviceID)
            return
        }
        errorMessage = error.localizedDescription
    }

    /// Reconciles a row's session after `run`/`restart` timed out, by refetching the overview through
    /// `connection` and looking for a fresh session in it. The selected device folds its fetch through the
    /// same generation/identity guards `applyMutationResponse` uses; another device applies through
    /// `acceptNonSelectedDeviceOverview`, gated only on `isCurrent(connection.token)` since it shares no
    /// generation counter with the selected device's own fetches.
    private func reconciledSessionAfterMutationTimeout(
        rowID: String, timeoutRecovery: SpacesMobileMutationTimeoutRecovery, connection: MutationConnection
    ) async -> SpacesDeviceTerminalSessionSummary? {
        let token = connection.token
        if timeoutRecovery.acceptsCachedOverview, let session = refreshedSession(forRowID: rowID, deviceID: token.deviceID) {
            if token.isSelected {
                errorMessage = nil
                connectionNotice = nil
            }
            return session
        }
        do {
            let refreshedOverview: SpacesDeviceOverviewPayload
            if token.isSelected {
                // Fetched after the mutation was sent, so it supersedes any refresh already in flight.
                // Captured right after bumping, before the fetch: a fresher fact landing during the fetch
                // itself must already be reflected in the baseline this compares against.
                mutationGeneration &+= 1
                let mutationGenerationAtFetch = mutationGeneration
                refreshedOverview = try await connection.client.fetchOverview(commandChannel: connection.channel)
                guard isCurrent(token) else { return nil }
                await updateBrowserRoutes(
                    overview: refreshedOverview, identity: token.identity, mutationGeneration: mutationGenerationAtFetch, isStillCurrent: { true })
                guard isCurrent(token) else { return nil }
                if mutationGeneration == mutationGenerationAtFetch {
                    errorMessage = nil
                    connectionNotice = nil
                    refreshFailureStreak = nil
                    publishOverview(refreshedOverview)
                }
            } else {
                refreshedOverview = try await connection.client.fetchOverview(commandChannel: connection.channel)
                guard isCurrent(token) else { return nil }
                acceptNonSelectedDeviceOverview(refreshedOverview, deviceID: token.deviceID)
            }
            // Resolved from `refreshedOverview`, this fetch's own evidence, not from published state, for
            // the same reason `performMutationReturningSession` reads its `response.overview`.
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

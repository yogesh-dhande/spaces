import AppKit
import Carbon
import Foundation
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalui
import systembridge
import workspacecore

/// Owns window-focus and window-shortcut dispatch: the numbered Cmd-1…Cmd-0 shortcuts, by-name and
/// by-process focus, MRU window-cycling (cycle-burst cursors, keyed per workspace), global hotkey
/// summon/toggle/reveal (including moving a window to the active Space), global window navigation
/// (workspace-agnostic next/prev), and the command-palette/attention-item focus path shared by both.
/// Extracted from `AppKitController` as a behavior-preserving move (part of the ongoing decomposition
/// of that type); `AppKitController` holds this as `windowFocus` and reaches it as `host.windowFocus`
/// from other files (`ShortcutsController`, `CommandPaletteController`, `AlertsController`,
/// `SidebarController`, `TransientOverlaysController`, the `SidebarRuntimeTargetItem` extension) that
/// dispatch a shortcut, present the palette, or focus an attention item. `AppKitController` stays the
/// host for device resolution, sidebar/overview state, the target-derivation layer
/// (`workspaceShortcutTargets`, `windowShortcutTargetResolution`, and friends), generic perf-metric
/// logging (`logPerfMetric`, `windowShortcutElapsedMS`), and the workspace/detail-pane state this
/// controller reads and mutates through `host.`.
///
/// `HotkeyPerfContext`, `PendingCommandPalettePresentation`, and `GlobalNavigationWorkspaceResolution`
/// are declared here; `AppKitController` keeps transitional `typealias`es to them (matching the
/// `AlertsGroup`/`DeviceSection` precedent) since callers outside this domain still spell them
/// `AppKitController.<Type>`. `AppKitController.WindowFocusRequest` stays declared on `AppKitController` itself: it has
/// too many qualified external references (command palette, attention items) to be worth moving.
@MainActor final class WindowFocusController {
    unowned let host: AppKitController

    init(host: AppKitController) { self.host = host }

    /// Cancels in-flight deferred work owned by this controller. Called from
    /// `AppKitController.applicationWillTerminate` so a pending selection refresh never fires after
    /// the app starts tearing down.
    func cancelDeferredWork() { deferredHotkeySelectionRefreshTask?.cancel() }

    /// The app finished activating: log and clear an in-flight shortcut profile (the route landed while
    /// the app was still becoming active). Called from `AppKitController`'s
    /// `NSApplication.didBecomeActiveNotification` observer.
    func noteAppDidBecomeActive() {
        if let profile = activeWindowShortcutProfile {
            let routeElapsedMS = profile.routeCompletedAt.map { host.windowShortcutElapsedMS(since: $0) } ?? -1
            logWindowShortcutProfile(
                "stage=app_became_active index=\(profile.index) elapsed_ms=\(host.windowShortcutElapsedMS(since: profile.startedAt)) route_gap_ms=\(routeElapsedMS)"
            )
            activeWindowShortcutProfile = nil
        }
    }

    /// The app resigned active: log and clear an in-flight shortcut profile (the route never completed
    /// before focus left the app). Called from `AppKitController`'s
    /// `NSApplication.didResignActiveNotification` observer.
    func noteAppDidResignActive() {
        guard let profile = activeWindowShortcutProfile else { return }
        let routeElapsedMS = profile.routeCompletedAt.map { host.windowShortcutElapsedMS(since: $0) } ?? -1
        logWindowShortcutProfile(
            "stage=app_resigned_active index=\(profile.index) elapsed_ms=\(host.windowShortcutElapsedMS(since: profile.startedAt)) route_gap_ms=\(routeElapsedMS)"
        )
        activeWindowShortcutProfile = nil
    }

    // MARK: - Perf context types

    struct HotkeyPerfContext {
        let startedAt: Date
        let appWasActive: Bool
        let appWasHidden: Bool
        let mainWindowWasVisible: Bool
        let paletteWasVisible: Bool
    }

    struct PendingCommandPalettePresentation {
        let perfContext: HotkeyPerfContext?
        let mainWindowWasVisible: Bool
    }

    struct GlobalNavigationWorkspaceResolution: Equatable, Sendable {
        let workspaceID: String?
        let source: String
    }

    // MARK: - State

    private var deferredHotkeySelectionRefreshTask: Task<Void, Never>?
    private var activeSpaceSummonCleanupTask: Task<Void, Never>?

    private var activeWindowShortcutProfile: WindowShortcutProfile?

    private var appToggleReturnApplicationProcessID: pid_t?

    private struct WindowShortcutProfile {
        let index: Int
        let startedAt: Date
        var routeCompletedAt: Date?
    }

    private struct WindowFocusResolutionContext {
        let resolution: AppKitController.DeviceWindowShortcutResolution
        let target: AppKitController.WorkspaceRunShortcutTarget?
        let detail: SpacesDeviceWorkspaceDetailViewModel?
    }

    // MARK: - Focusable window context and named/process focus

    /// A workspace's focusable targets read out of the app's current sidebar snapshot, with the data
    /// needed to name and resolve them.
    typealias FocusableWindowContext = (
        detail: SpacesDeviceWorkspaceDetailViewModel, overview: SpacesDeviceOverviewPayload, browserSessions: [BrowserSession],
        targets: [AppKitController.WorkspaceRunShortcutTarget]
    )

    /// The workspace's focusable targets plus the context needed to name and resolve them,
    /// using the same ordering and (all configured) browser sessions as the numbered
    /// shortcuts so by-name focus, the names dump, and Cmd-N stay consistent.
    func focusableWindowContext(workspaceID: String) -> FocusableWindowContext? {
        guard let overview = host.overview(forWorkspaceID: workspaceID), let detail = AppKitController.workspaceDetail(workspaceID, in: overview)
        else { return nil }
        let browserSessions = detail.config.resolvedBrowserSessions.map(AppKitController.localBrowserSession(from:))
        let targets = AppKitController.workspaceShortcutTargets(detail: detail, browserSessions: browserSessions)
        return (detail, overview, browserSessions, targets)
    }

    /// The display name for a focusable target, matching the names the numbered-shortcut
    /// list surfaces (browser session name, process/terminal title, agent label).
    nonisolated static func focusableWindowName(
        for target: AppKitController.WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel, browserSessions: [BrowserSession]
    ) -> String? {
        switch target.kind {
        case .browser: return BrowserSessionCoordinator.browserSessionDisplayName(for: target.targetURL, sessions: browserSessions)
        case .process: return target.processID.flatMap { id in detail.processRows.first(where: { ($0.processID ?? $0.id) == id })?.name }
        case .window: return target.windowListIndex.flatMap { detail.terminalRows.indices.contains($0) ? detail.terminalRows[$0].title : nil }
        case .agent: return target.agentWindow?.label
        case .missingConfiguredProcess: return target.processKey
        }
    }

    /// The workspace's ordered focusable window names. The app owns this ordering, so the
    /// dump IPC lets harnesses read it instead of recomputing it from daemon data.
    func focusableWindowNames(workspaceID: String) -> [String] {
        guard let context = focusableWindowContext(workspaceID: workspaceID) else { return [] }
        return context.targets.compactMap { Self.focusableWindowName(for: $0, detail: context.detail, browserSessions: context.browserSessions) }
    }

    private struct FocusableWindowNamesDump: Codable { let names: [String] }

    // Not private: AppKitController's `handleDumpFocusableWindowNamesIPC` calls this from a
    // different file in the same module (cross-file `private` isn't visible).
    func writeFocusableWindowNames(workspaceID: String, to outputPath: String) {
        let url = URL(fileURLWithPath: outputPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(FocusableWindowNamesDump(names: focusableWindowNames(workspaceID: workspaceID)))
            try data.write(to: url, options: [.atomic])
        } catch {}
    }

    /// Focuses a workspace window by display name through the shared focus path. Emits the
    /// `named_window_focus` perf line the real-system E2E parses (it also satisfies the
    /// browser-focus matcher, since a browser session resolves to the same name).
    // Not private: AppKitController's `handleFocusWorkspaceWindowByNameIPC` calls this from a
    // different file in the same module (cross-file `private` isn't visible).
    func focusWorkspaceWindowByName(workspaceID: String, name: String) async {
        let startedAt = Date()
        var targetResolutionMS = 0
        var routeMS = 0
        var retriedAfterReload = false
        func logResult(_ success: Bool, reason: String = "") {
            let reasonDetail = reason.isEmpty ? "" : " reason=\(reason)"
            let retryDetail = retriedAfterReload ? " retried_after_reload=1" : ""
            host.logPerfMetric(
                "named_window_focus", target: name, elapsedMS: host.windowShortcutElapsedMS(since: startedAt), success: success,
                detail: "target_resolution_ms=\(targetResolutionMS) route_ms=\(routeMS)\(reasonDetail)\(retryDetail)")
        }
        let resolutionStartedAt = Date()
        let resolved = await resolvingAfterFreshSidebarSnapshot {
            () -> (context: FocusableWindowContext, target: AppKitController.WorkspaceRunShortcutTarget)? in
            guard let context = self.focusableWindowContext(workspaceID: workspaceID),
                let target = context.targets.first(where: {
                    Self.focusableWindowName(for: $0, detail: context.detail, browserSessions: context.browserSessions).map {
                        AppKitController.normalizedRunRowName($0) == AppKitController.normalizedRunRowName(name)
                    } ?? false
                })
            else { return nil }
            return (context, target)
        }
        retriedAfterReload = resolved.retried
        guard let match = resolved.value else {
            targetResolutionMS = host.windowShortcutElapsedMS(since: resolutionStartedAt)
            logResult(false, reason: "no_match")
            return
        }
        let (context, target) = match
        targetResolutionMS = host.windowShortcutElapsedMS(since: resolutionStartedAt)
        let resolution = AppKitController.windowShortcutTargetResolution(
            target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
        let routeStartedAt = Date()
        guard await executeWindowFocusResolution(resolution, preferredTarget: target, preferredDetail: context.detail) else {
            routeMS = host.windowShortcutElapsedMS(since: routeStartedAt)
            logResult(false, reason: "focus_failed")
            return
        }
        routeMS = host.windowShortcutElapsedMS(since: routeStartedAt)
        logResult(true)
    }

    /// Resolves `resolve` against the app's current sidebar snapshot and, when it finds nothing, once
    /// more after the next snapshot lands.
    ///
    /// A focus or open request can arrive in the window between the daemon writing a just-started
    /// process (or a just-created workspace) and the app's paced reload applying the snapshot that
    /// carries it. In that window a miss says nothing about whether the target exists, so the request
    /// waits for the app to catch up instead of being refused. Exactly one fresh snapshot and exactly
    /// one retry: the second answer is about the target, not about the app being behind.
    ///
    /// - Returns: what the resolution found, and whether it took the retry, which the caller's log line
    ///   reports so a stale snapshot can be told from a genuinely missing target.
    private func resolvingAfterFreshSidebarSnapshot<T>(_ resolve: @MainActor () -> T?) async -> (value: T?, retried: Bool) {
        if let value = resolve() { return (value, false) }
        await host.sidebar.reloadAwaitingFreshSnapshot()
        return (resolve(), true)
    }

    /// The focusable target for a workspace's running process, by template name, waiting once for a
    /// fresh sidebar snapshot when the current one has no running row for that name yet (it lists the
    /// process as a `.missingConfiguredProcess` target until the reload carrying the row lands).
    func processFocusMatch(workspaceID: String, processName: String) async -> (
        value: (context: FocusableWindowContext, target: AppKitController.WorkspaceRunShortcutTarget)?, retried: Bool
    ) {
        await resolvingAfterFreshSidebarSnapshot { () -> (context: FocusableWindowContext, target: AppKitController.WorkspaceRunShortcutTarget)? in
            guard let context = self.focusableWindowContext(workspaceID: workspaceID),
                let target = context.targets.first(where: { target in
                    guard target.kind == .process, let id = target.processID,
                        let rowName = context.detail.processRows.first(where: { ($0.processID ?? $0.id) == id })?.name
                    else { return false }
                    return AppKitController.normalizedRunRowName(rowName) == AppKitController.normalizedRunRowName(processName)
                })
            else { return nil }
            return (context, target)
        }
    }

    /// Focuses a workspace's running process window by template name. Threads `requestID`
    /// to the terminal focus so the `terminal_window_focus_ipc` line carries it, which the
    /// real-system E2E correlates; also emits `process_focus` for the non-correlated path.
    // Not private: AppKitController's `handleFocusWorkspaceProcessIPC` calls this from a
    // different file in the same module (cross-file `private` isn't visible).
    func focusWorkspaceProcess(workspaceID: String, processName: String, requestID: String?) async {
        let startedAt = Date()
        var targetResolutionMS = 0
        var routeMS = 0
        var retriedAfterReload = false
        func logResult(_ success: Bool, reason: String = "") {
            let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
            let reasonDetail = reason.isEmpty ? "" : " reason=\(reason)"
            let retryDetail = retriedAfterReload ? " retried_after_reload=1" : ""
            host.logPerfMetric(
                "process_focus", target: processName, elapsedMS: host.windowShortcutElapsedMS(since: startedAt), success: success,
                detail: "target_resolution_ms=\(targetResolutionMS) route_ms=\(routeMS)\(requestDetail)\(reasonDetail)\(retryDetail)")
        }
        let resolutionStartedAt = Date()
        let resolved = await processFocusMatch(workspaceID: workspaceID, processName: processName)
        retriedAfterReload = resolved.retried
        guard let match = resolved.value else {
            targetResolutionMS = host.windowShortcutElapsedMS(since: resolutionStartedAt)
            logResult(false, reason: "no_match")
            return
        }
        let (context, target) = match
        targetResolutionMS = host.windowShortcutElapsedMS(since: resolutionStartedAt)
        let resolution = AppKitController.windowShortcutTargetResolution(
            target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
        let routeStartedAt = Date()
        guard await executeWindowFocusResolution(resolution, requestID: requestID, preferredTarget: target, preferredDetail: context.detail) else {
            routeMS = host.windowShortcutElapsedMS(since: routeStartedAt)
            logResult(false, reason: "focus_failed")
            return
        }
        routeMS = host.windowShortcutElapsedMS(since: routeStartedAt)
        logResult(true)
    }

    // MARK: - Window-cycle state and core

    // In-memory window-cycle state (a "window" is a client concept), filed by cycle scope.
    // MainActor-isolated, so no lock is needed.
    private var windowCycleState = WindowCycleState()

    /// Every cycle step runs through this queue, whichever entry point asked for it. A burst of
    /// presses is one sequence: each step starts from where the previous step landed, so a press that
    /// arrives while an earlier step is still awaiting Chrome or a remote pane open waits for that
    /// landing instead of reading the same pre-landing state and repeating its target.
    private let windowCycleSteps = WindowCycleStepQueue()

    /// Which set of windows the next/previous shortcuts rotate over. Read from the client database
    /// once at launch and written back on every change, the `activeWorkspaceID` pattern.
    private(set) var windowCycleMode: WindowCycleMode = .workspace

    /// Adopts the profile's persisted cycling mode. Called once from
    /// `AppKitController.applicationDidFinishLaunching`, before any shortcut can fire.
    func loadStoredWindowCycleMode() { windowCycleMode = host.clientWindowCycleMode() }

    /// Steps to the next cycling mode. Bound to the `Cycle mode` shortcut.
    func stepWindowCycleMode() { selectWindowCycleMode(windowCycleMode.next) }

    /// Adopts a cycling mode and persists it. The mode shortcut and the sidebar cycling row's menu
    /// both land here, so picking a mode by hand is the same change as stepping to it, down to the
    /// confirmation the host shows.
    func selectWindowCycleMode(_ mode: WindowCycleMode) {
        windowCycleMode = mode
        AppKitController.setClientWindowCycleMode(mode)
        // `windowCycleModeDidChange` repaints the row for the HUD (`sidebar.refreshCycleModeRow()`),
        // and the row's own refresh funnel starts the throttled Chrome refresh, so entering a
        // browser-backed mode with no cached Chrome snapshot yet (freshly launched, or switching in
        // from a mode that never needed one) is caught up by that same call, without a separate one
        // here. `refreshCycleModeBrowserState` republishes the row itself once the snapshot lands; if
        // that lands within the HUD's one-second life, it repaints only the row, by design (accepted
        // behavior: the HUD confirms the keystroke with what was known at the keystroke, the row is
        // the durable readout).
        host.windowCycleModeDidChange(mode)
    }

    // MARK: - Cycling-mode contents, for the sidebar row and the mode HUD

    /// The last Chrome/browser-tracking snapshot a cycle step or a row-count refresh obtained, the
    /// workspace set it covers, and when it was taken.
    ///
    /// Building that snapshot is an AppleScript round trip to Chrome, and the sidebar applies new
    /// data several times a second under a live workspace, so the cycling row's count must never ask
    /// for a fresh one on the apply path: it reuses this one and lets `refreshCycleModeBrowserState`
    /// replace it out of band. Cheap for the count to read (it is already in memory) and correct for
    /// what the count is: how many windows the next cycle press could land on, which is what the
    /// previous press saw plus whatever changed since. `workspaceIDs` is the same set
    /// `startBrowserCycleStateRefresh` (or a cross-device cycle step) passed to
    /// `trackedBrowserCycleState`, empty for the `.noBrowserState` placeholder (nothing was actually
    /// queried for it, so it cannot claim to answer any particular set); `BrowserCycleStateRefreshDecision`
    /// compares it against the current set to decide whether the cache still answers a new request.
    private var cachedBrowserCycleState: (state: BrowserSessionCoordinator.BrowserCycleState, workspaceIDs: Set<String>, takenAt: Date) = (
        .noBrowserState, [], .distantPast
    )
    private var browserCycleStateRefreshInFlight = false
    /// The workspace set the in-flight round trip captured at its own start (see
    /// `startBrowserCycleStateRefresh`'s snapshot), meaningful only while `browserCycleStateRefreshInFlight`
    /// is `true`. A device's overview that arrives mid-round-trip is invisible to that round trip, so
    /// a request landing with a different current set cannot be answered by it; `refreshCycleModeBrowserState`
    /// compares against this to decide whether to mark `browserCycleStateRefreshPending` instead of
    /// silently dropping the request.
    private var browserCycleStateRefreshInFlightWorkspaceIDs: Set<String> = []
    /// Set when a refresh is requested while one is already in flight for a different workspace set,
    /// and cleared once the rerun it requested has started. Without this, a request that arrives
    /// mid-round-trip for a set the round trip does not cover would be dropped outright, and the
    /// completion would stamp its (still-mismatched) snapshot with a fresh `takenAt`; the next request
    /// for the same, still-uncovered set would then read as a same-set, within-age cache hit and skip
    /// too, leaving the row stuck on stale data until something else changes the set again. See
    /// `refreshCycleModeBrowserState`. Also set by `invalidateBrowserCycleState` when a forced
    /// invalidation (a browser open, adopt, or close) lands while a round trip is already in flight,
    /// so that round trip's about-to-be-stale result gets superseded by a rerun instead of standing
    /// as the cache until the next unrelated trigger ages it out.
    private var browserCycleStateRefreshPending = false
    /// How stale the cached Chrome snapshot may get before a sidebar apply refreshes it. The apply
    /// rate is the sidebar's, not the user's, so refreshing on every apply would put Chrome
    /// scripting in a continuous loop behind a busy workspace.
    private static let browserCycleStateRefreshInterval: TimeInterval = 2

    /// What the sidebar's cycling row and the mode HUD report: the mode in effect and the size of the
    /// set it would rotate over. Built from the same builders a cycle press walks, so the row cannot
    /// disagree with what the next press does.
    func cycleModeRowModel() -> CycleModeRowModel {
        let mode = windowCycleMode
        switch mode {
        case .workspace:
            // Mirrors `globalWindowNavigationWorkspaceID`'s precedence (focused built-in terminal, then
            // focused Chrome window, then the persisted active workspace) so the row and the HUD cannot
            // name a different workspace than the one the next cycle press actually lands in (for
            // example, a terminal pane focused in a global panel window that belongs to a workspace
            // other than the one selected in the sidebar, or the Alerts/Automations view showing with
            // no workspace selected at all, where `host.selectedWorkspaceID` is nil but a press still
            // cycles the active workspace). Unlike a keypress, this model is rebuilt on every sidebar
            // apply (several times a second under a live workspace; see `refreshCycleModeRow`'s
            // callers), so the middle tier is served from `cachedBrowserCycleState` instead of running
            // `globalWindowNavigationWorkspaceID`'s AppleScript-backed `clientWorkspaceIDForFocusedWindow`:
            // no extra Chrome round trip on this path, at the cost of the tier being up to
            // `browserCycleStateRefreshInterval` stale. It applies the same URL-matching rule
            // `clientWorkspaceIDForFocusedWindow` uses against the live press
            // (`BrowserSessionCoordinator.workspaceIDForFrontmostBrowserURL`) to the cached snapshot's
            // frontmost URL, so the row cannot disagree with the press over which workspace a shared
            // target URL belongs to; neither path tie-breaks, so a URL matching two workspaces'
            // sessions at the same prefix length resolves to the first one encountered on both. The
            // final fallback reads `host.clientActiveWorkspaceID()`, a stored client-database value.
            // Accepted gap: the snapshot samples Chrome only while some workspace has a tracked window
            // (see `trackedBrowserCycleState`), so a matching tab the user opened outside Spaces on a
            // profile with nothing tracked is invisible to this tier, and the row falls through to the
            // active workspace while the press, which asks Chrome directly, may resolve that tab's
            // workspace. Sampling Chrome on every cadence with nothing tracked would cost an
            // AppleScript round trip every couple of seconds for a case the next press corrects.
            let focusedTerminalSessionWorkspaceID = focusedBuiltInTerminalSessionIDForGlobalNavigation().flatMap {
                host.clientWorkspaceID(forTerminalSession: $0)
            }
            let cachedFrontmostBrowserWorkspaceID = BrowserSessionCoordinator.workspaceIDForFrontmostBrowserURL(
                cachedBrowserCycleState.state.frontmostURL, in: host.deviceModel.deviceSections.compactMap(\.overview))
            guard let workspaceID = focusedTerminalSessionWorkspaceID ?? cachedFrontmostBrowserWorkspaceID ?? host.clientActiveWorkspaceID(),
                let overview = host.overview(forWorkspaceID: workspaceID), let detail = AppKitController.workspaceDetail(workspaceID, in: overview)
            else { return CycleModeRowModel(mode: mode, count: 0, deviceCount: 0, workspaceName: nil) }
            let targets = Self.cycleWindowTargets(
                detail: detail, browserSessions: cachedBrowserCycleState.state.openBrowserSessions(workspaceID: workspaceID),
                openTerminalSessionIDs: Set(host.panelCoordinator.openTerminalSessionIDs(workspaceID: workspaceID)))
            return CycleModeRowModel(mode: mode, count: targets.count, deviceCount: 1, workspaceName: detail.title)
        case .attention, .allAgents, .openSessions:
            let devices = host.deviceModel.deviceSections.compactMap { section in
                section.overview.map { WindowCycleDeviceSnapshot(deviceID: section.deviceID, overview: $0) }
            }
            let browserState = cachedBrowserCycleState.state
            // A frozen cycle session (a burst still within `WorkspaceWindowCycle.cycleSessionTimeout`)
            // keeps rotating over the cursors it landed on, not over a freshly filtered set, so a
            // target that left the mode's filter mid-burst (an agent that stopped waiting, say) is
            // still something the next press in that burst can land on. Retaining the same cursors
            // here, exactly as the next press would via `cycleWindows`, keeps the row's count matching
            // what the rotation actually holds instead of undercounting it. Outside a valid session
            // there is nothing to retain. Accepted: nothing repaints when the session expires on its
            // own, so a count painted mid-burst that retained a departed target stands until the next
            // trigger (a sidebar apply lands within a second under any live workspace); a timer per
            // burst is not worth a count that is at most one high for that gap.
            let targets = WindowCycleModeTargets.targets(
                mode: mode, devices: devices,
                openTerminalSessionIDsByWorkspace: mode == .openSessions ? openTerminalSessionIDsForCycleModes(devices: devices) : [:],
                openBrowserSessionsByWorkspace: mode == .openSessions ? browserState.openBrowserSessionsByWorkspace : [:],
                trackedBrowserWindowIDsByWorkspace: mode == .openSessions ? browserState.trackedWindowIDsByWorkspace : [:],
                recentCursors: windowCycleState.recentCursors(for: .mode(mode)),
                retaining: windowCycleState.validCycleSession(for: .mode(mode))?.orderedCursors ?? [])
            return CycleModeRowModel(mode: mode, count: targets.count, deviceCount: Set(targets.map(\.deviceID)).count, workspaceName: nil)
        }
    }

    /// Refreshes the cached Chrome snapshot off the main actor, for the modes whose set can hold a
    /// browser target. `SidebarController.refreshCycleModeRow()` calls this on every repaint, which is
    /// every documented row trigger (sidebar data apply, panel layout change, workspace selection,
    /// mode change, shortcut reload, cycle press), so this is the single place that starts the
    /// refresh; `BrowserCycleStateRefreshDecision` still caps the real work to once per couple of
    /// seconds for an unchanging workspace set, regardless of how many triggers land in that window.
    /// It runs at most once at a time (the decision is made synchronously here, before any Chrome
    /// work) and skips only when the cache's workspace set matches the current one and has not aged
    /// past `browserCycleStateRefreshInterval`; a changed set bypasses the age guard and refreshes
    /// immediately; see `BrowserCycleStateRefreshDecision` for the full rule, including how it treats
    /// a request that lands while a round trip for a different set is already in flight.
    /// `trackedBrowserCycleState` does its client-database read and its Chrome scripting on a detached
    /// task, so nothing here blocks the main actor; the recount runs when it returns.
    ///
    /// `startBrowserCycleStateRefresh`'s completion starts any pending rerun before it calls
    /// `refreshCycleModeRow()`, which calls this function again: by the time that repaint-driven call
    /// runs, the rerun it might have started is already marked in flight for the current set, or, when
    /// nothing was pending, the cache was just stamped with that set and a fresh `takenAt`. Either way
    /// the decision resolves to `.skip` immediately, so the repaint's call here is always a no-op and
    /// the two calls never leave more than one round trip in flight.
    func refreshCycleModeBrowserState() {
        let mode = windowCycleMode
        guard mode == .workspace || mode == .openSessions else { return }
        let currentWorkspaceIDs = Self.browserCycleWorkspaceIDs(deviceSections: host.deviceModel.deviceSections)
        // The set is keyed by workspace ids alone. Accepted: a browser-session or port edit inside the
        // same workspaces does not bypass the age guard, so a snapshot captured just before such an
        // edit stands until the next trigger after `browserCycleStateRefreshInterval` (the edit's own
        // overview apply, or any apply after it). Settings edits are rare and the gap is a couple of
        // seconds; fingerprinting the browser configuration per apply would cost more than it saves.
        let decision = BrowserCycleStateRefreshDecision.decide(
            inFlight: browserCycleStateRefreshInFlight, inFlightWorkspaceIDs: browserCycleStateRefreshInFlightWorkspaceIDs,
            cachedWorkspaceIDs: cachedBrowserCycleState.workspaceIDs, cachedAge: Date().timeIntervalSince(cachedBrowserCycleState.takenAt),
            currentWorkspaceIDs: currentWorkspaceIDs, maxAge: Self.browserCycleStateRefreshInterval)
        switch decision {
        case .skip: return
        case .markPending:
            // The in-flight round trip does not cover this request's set; ask it to rerun once it
            // lands instead of dropping this request outright (see `browserCycleStateRefreshPending`).
            browserCycleStateRefreshPending = true
        case .refresh: startBrowserCycleStateRefresh()
        }
    }

    /// Runs the actual Chrome round trip and republish. Split out of `refreshCycleModeBrowserState` so
    /// the pending rerun it schedules can start this directly: that rerun's request arrived while this
    /// round trip was already in flight, so `BrowserCycleStateRefreshDecision`'s in-flight branch,
    /// not its age/set branch, is what let it through, and the in-flight guard here still applies to
    /// it as normal. Never guarded against being called while a round trip is already in flight
    /// (beyond that in-flight branch): the completion below starts the pending rerun before it
    /// repaints, so at most one round trip is ever in flight and a reentrancy guard here would be
    /// dead code.
    private func startBrowserCycleStateRefresh() {
        // Snapshot the workspace set synchronously, before any suspension point, so the in-flight
        // capture other requests compare against always matches what this round trip actually queries.
        let workspaces = host.deviceModel.deviceSections.compactMap(\.overview).flatMap { overview in
            overview.workspaces.map {
                BrowserSessionCoordinator.BrowserCycleWorkspace(workspaceID: $0.id, detail: SpacesDeviceWorkspaceDetailViewModel(workspace: $0))
            }
        }
        let workspaceIDs = Set(workspaces.map(\.workspaceID))
        browserCycleStateRefreshInFlight = true
        browserCycleStateRefreshInFlightWorkspaceIDs = workspaceIDs
        Task { [weak self] in
            guard let self else { return }
            // `trackedBrowserCycleState`'s Chrome tab snapshot runs `tell application "Google
            // Chrome"`, which launches Chrome via Apple Events when it is not already running. This
            // refresh fires on every sidebar apply, including app launch, so it must never be what
            // launches Chrome on a machine where the user has not opened it: publish the empty state
            // instead and let the next refresh, once Chrome is running, pick up real sessions.
            let state: BrowserSessionCoordinator.BrowserCycleState
            if ChromeAdapter().isRunning() {
                state = await host.browserSessions.trackedBrowserCycleState(workspaces: workspaces)
            } else {
                state = .noBrowserState
            }
            // Tag even the no-Chrome placeholder with `workspaceIDs`, the set this round trip queried
            // for, rather than an empty set: the placeholder covers that set for this cadence window,
            // so the next refresh only re-checks whether Chrome is running once the cadence elapses or
            // the workspace set changes. Tagging it empty instead would make every subsequent request
            // for a non-empty set see a cache/current mismatch and refresh immediately, looping without
            // bound for as long as Chrome stays closed.
            noteBrowserCycleState(state, workspaceIDs: workspaceIDs)
            browserCycleStateRefreshInFlight = false
            // A pending rerun means this round trip's inputs changed under it (the workspace set moved,
            // or a browser open, adopt, or close landed), so the state just cached is already stale:
            // start the rerun and let its completion repaint, rather than painting a count this code
            // knows is wrong for the length of another Chrome round trip. With nothing pending, repaint
            // here; that repaint's call back into `refreshCycleModeBrowserState` sees the fresh cache
            // for the current set and skips, so the completion never starts a second round trip.
            if browserCycleStateRefreshPending {
                browserCycleStateRefreshPending = false
                startBrowserCycleStateRefresh()
                return
            }
            host.sidebar.refreshCycleModeRow()
        }
    }

    /// Every workspace every device's overview currently reports, mirroring the set
    /// `startBrowserCycleStateRefresh` builds `BrowserCycleWorkspace`s from. Shared so
    /// `refreshCycleModeBrowserState`'s guard compares against exactly the set the round trip it may
    /// start would capture.
    private static func browserCycleWorkspaceIDs(deviceSections: [AppKitController.DeviceSection]) -> Set<String> {
        Set(deviceSections.compactMap(\.overview).flatMap { overview in overview.workspaces.map(\.id) })
    }

    /// Records a snapshot a cycle step or a refresh just obtained, tagged with the workspace set it
    /// covers, so the next request's guard can tell whether the cache actually answers it.
    private func noteBrowserCycleState(_ state: BrowserSessionCoordinator.BrowserCycleState, workspaceIDs: Set<String>) {
        cachedBrowserCycleState = (state, workspaceIDs, Date())
    }

    /// Ages out the cached Chrome snapshot and asks the row to repaint, for a caller that just
    /// changed what the snapshot would report (a browser focus that opened or adopted a tab, a
    /// teardown that closed tracked tabs) rather than leaving the row on stale data until something
    /// else trips `browserCycleStateRefreshInterval`. Backdating `takenAt` instead of clearing the set
    /// keeps `BrowserCycleStateRefreshDecision`'s same-set/aged-cache branch in play, so the repaint
    /// below funnels through the normal refresh path rather than a special one.
    ///
    /// A round trip already in flight for the current workspace set is a different case: that
    /// request was decided, and possibly issued, before this invalidation's change happened, so its
    /// result cannot reflect it. Backdating `takenAt` here would let its completion overwrite the
    /// backdate with a fresh-but-still-stale snapshot and repaint the row on it, same as the race
    /// `browserCycleStateRefreshPending` already exists to close for a differing workspace set.
    /// Marking pending instead defers to that same mechanism: the in-flight completion reruns before
    /// its own repaint, so the row's next paint is always built from a snapshot taken after this call.
    func invalidateBrowserCycleState() {
        if browserCycleStateRefreshInFlight {
            browserCycleStateRefreshPending = true
            return
        }
        cachedBrowserCycleState.takenAt = .distantPast
        host.sidebar.refreshCycleModeRow()
    }

    /// The open-pane map a cross-device mode is built from, including the panes the persisted layout
    /// of an unvisited workspace holds, exactly as a cycle press builds it.
    private func openTerminalSessionIDsForCycleModes(devices: [WindowCycleDeviceSnapshot]) -> [String: [String]] {
        host.panelCoordinator.openTerminalSessionIDsByWorkspace(
            includingPersistedLayoutsFor: devices.flatMap { device in
                device.overview.workspaces.map { PanelLayoutEngine.WorkspaceKey(deviceID: device.deviceID, workspaceID: $0.id) }
            })
    }

    /// The world one cycle step walks: its candidate targets, the overview each candidate resolves
    /// against, and the browser/pane state the current-target resolution and the perf line report.
    private struct WindowCycleTargetSnapshot {
        let targets: [WindowCycleTarget]
        let overviewsByDeviceID: [String: SpacesDeviceOverviewPayload]
        let frontmostBrowserURL: String?
        /// Chrome's front window id, which separates two workspaces whose browser sessions share a
        /// target URL. Snapshot level rather than per target: there is one front window.
        let frontmostBrowserWindowID: Int?
        let openTerminalPaneCount: Int
        let browserPerfDetail: String
    }

    /// Cycles focus to the next/previous window of a scope, entirely client-side: rebuilds the
    /// candidate targets (one workspace's open windows, or the mode's set across every device),
    /// resolves the current target from the focused terminal session / frontmost Chrome tab /
    /// remembered cursor, advances, and focuses through the shared `executeWindowFocusResolution`.
    ///
    /// Private because every entry point reaches a step through `windowCycleSteps`, never directly.
    private func cycleWindows(scope: WindowCycleScope, delta: Int, preferredTerminalSessionID: String?, requestID: String? = nil) async {
        // A cycle press can change what the row counts, whichever scope it walks: a workspace rotation
        // reads its workspace's live pane/browser state, and a mode rotation can refresh the shared
        // Chrome snapshot. `cycleWindows` is the one function both scopes run through, so repainting
        // here, once, regardless of how the press ends (landed, found nothing, failed to focus), is
        // the single place for it, instead of a call buried in one scope's snapshot builder.
        defer { host.sidebar.refreshCycleModeRow() }
        let cycleStartedAt = Date()
        let direction = delta > 0 ? "next" : "previous"
        // A cross-device rotation has no workspace until it lands on one; the landed (or first
        // attempted) target supplies it, and a rotation that never got that far reports none.
        var metricWorkspaceID = scope.workspaceID ?? "none"
        // The real-system E2E waits for this `window_cycle` perf line, so emit it on both
        // success and failure (matching the orchestrator's format) — it is a parsed surface.
        // Existing fields keep their order and `mode=` is appended last, so those matchers keep
        // matching.
        func logCycleMetric(target: String, success: Bool, detail extraDetail: String = "") {
            let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
            let suffix = extraDetail.isEmpty ? "" : " \(extraDetail)"
            TerminalPerformance.logWorkspaceMetric(
                "window_cycle", workspaceID: metricWorkspaceID, target: target, elapsedMS: host.windowShortcutElapsedMS(since: cycleStartedAt),
                success: success, detail: "direction=\(direction)\(requestDetail)\(suffix) mode=\(scope.mode.rawValue)")
        }
        let cycleSession = windowCycleState.validCycleSession(for: scope)
        let targetResolutionStartedAt = Date()
        // The live burst's cursors go into the candidate build, not just into `cycleOrdering`: a mode's
        // filter would otherwise drop a target the burst is walking the moment its state changed, and
        // the rotation would be rebuilt mid-burst.
        guard
            let snapshot = await cycleTargetSnapshot(
                scope: scope, preferredTerminalSessionID: preferredTerminalSessionID, retaining: cycleSession?.orderedCursors ?? [])
        else {
            logCycleMetric(target: "none", success: false)
            return
        }
        let targetResolutionMS = host.windowShortcutElapsedMS(since: targetResolutionStartedAt)
        let resolutionDetail =
            "target_resolution_ms=\(targetResolutionMS) \(snapshot.browserPerfDetail) open_terminal_panes=\(snapshot.openTerminalPaneCount)"
        guard !snapshot.targets.isEmpty else {
            logCycleMetric(target: "none", success: false, detail: "\(resolutionDetail) reason=empty")
            return
        }

        let cursor = windowCycleState.cursor(for: scope)
        let currentIndex = Self.cycleCurrentIndex(
            targets: snapshot.targets, focusedTerminalSessionID: preferredTerminalSessionID, frontmostBrowserURL: snapshot.frontmostBrowserURL,
            frontmostBrowserWindowID: snapshot.frontmostBrowserWindowID, cursor: cursor)
        if let currentIndex { rememberWindowNavigationCycleTarget(snapshot.targets[currentIndex], preserveWindowCycleSession: true) }
        let ordering = WorkspaceWindowCycle.cycleOrdering(
            cursors: snapshot.targets.map(\.cursorKey), currentIndex: currentIndex, session: cycleSession,
            recentCursors: windowCycleState.recentCursors(for: scope))
        let orderedTargets = ordering.indices.map { snapshot.targets[$0] }
        let orderedCursors = orderedTargets.map(\.cursorKey)
        let startIndex = WorkspaceWindowCycle.nextIndex(orderedCount: orderedTargets.count, orderedCurrentIndex: ordering.currentIndex, delta: delta)

        // Cycling closes the palette for every target it can land on, browser sessions included,
        // because the palette is a transient panel over whatever the cycle is navigating to. It
        // closes before the focus work rather than after: focusing a browser activates Chrome, and
        // an open palette resigning key to Chrome mid-await would run the ordinary dismissal, whose
        // return-focus restore would take the front straight back from the app just focused.
        host.commandPalette.dismissCommandPaletteForBuiltInWindowNavigation()

        var didFocus = false
        var resolvedIndex = startIndex
        for attempt in 0..<orderedTargets.count {
            let candidateIndex = (startIndex + (attempt * delta) + (orderedTargets.count * 4)) % orderedTargets.count
            let candidate = orderedTargets[candidateIndex]
            // Keyed by the same devices the candidates were built from, so this names the overview the
            // candidate's workspace came from and cannot miss.
            guard let overview = snapshot.overviewsByDeviceID[candidate.deviceID] else { continue }
            let resolution = AppKitController.windowShortcutTargetResolution(
                candidate.target, workspaceID: candidate.workspaceID, detail: candidate.detail, overview: overview)
            if await executeWindowFocusResolution(
                resolution, requestID: requestID, preferredTarget: candidate.target, preferredDetail: candidate.detail,
                preserveWindowCycleSession: true)
            {
                didFocus = true
                resolvedIndex = candidateIndex
                break
            }
        }
        guard didFocus else {
            metricWorkspaceID = orderedTargets[startIndex].workspaceID
            logCycleMetric(
                target: Self.cycleDebugName(for: orderedTargets[startIndex].target, detail: orderedTargets[startIndex].detail), success: false,
                detail: resolutionDetail)
            return
        }

        windowCycleState.recordCycleLanding(scope: scope, orderedCursors: orderedCursors, index: resolvedIndex)
        metricWorkspaceID = orderedTargets[resolvedIndex].workspaceID
        logCycleMetric(
            target: Self.cycleDebugName(for: orderedTargets[resolvedIndex].target, detail: orderedTargets[resolvedIndex].detail), success: true,
            detail: resolutionDetail)
    }

    private func cycleTargetSnapshot(
        scope: WindowCycleScope, preferredTerminalSessionID: String?, retaining retainedCursors: [WorkspaceWindowCycle.Cursor]
    ) async -> WindowCycleTargetSnapshot? {
        switch scope {
        // A workspace rotation has no state filter to retain anything against: its targets are the
        // workspace's open windows, so a target leaves that set only by closing.
        case .workspace(let workspaceID):
            return await workspaceCycleTargetSnapshot(workspaceID: workspaceID, preferredTerminalSessionID: preferredTerminalSessionID)
        case .mode(let mode):
            return await modeCycleTargetSnapshot(mode: mode, preferredTerminalSessionID: preferredTerminalSessionID, retaining: retainedCursors)
        }
    }

    /// One workspace's open windows: the same base targets the numbered shortcuts use, limited to
    /// running windows (open browsers, running processes/terminals, agents) and carrying the
    /// per-workspace cursor keys, which are what the workspace rotation has always been filed under.
    private func workspaceCycleTargetSnapshot(workspaceID: String, preferredTerminalSessionID: String?) async -> WindowCycleTargetSnapshot? {
        guard let overview = host.overview(forWorkspaceID: workspaceID), let detail = AppKitController.workspaceDetail(workspaceID, in: overview),
            let deviceID = host.deviceID(forWorkspaceID: workspaceID)
        else { return nil }
        let browserCycleState = await host.browserSessions.trackedBrowserCycleState(workspaces: [
            BrowserSessionCoordinator.BrowserCycleWorkspace(workspaceID: workspaceID, detail: detail)
        ])
        let openTerminalSessionIDs = Set(host.panelCoordinator.openTerminalSessionIDs(workspaceID: workspaceID))
        let targets = Self.cycleWindowTargets(
            detail: detail, browserSessions: browserCycleState.openBrowserSessions(workspaceID: workspaceID),
            openTerminalSessionIDs: openTerminalSessionIDs
        ).map {
            WindowCycleTarget(
                deviceID: deviceID, workspaceID: workspaceID, cursorKey: Self.cycleCursorKey(for: $0, detail: detail), target: $0, detail: detail,
                // Only a browser target can be matched against a Chrome window.
                trackedBrowserWindowIDs: $0.kind == .browser ? browserCycleState.trackedWindowIDs(workspaceID: workspaceID) : [])
        }
        // A focused built-in terminal decides the current target before any browser state is read, so
        // the browser fields are dropped together when there is one.
        let readsBrowserState = preferredTerminalSessionID?.isEmpty != false
        return WindowCycleTargetSnapshot(
            targets: targets, overviewsByDeviceID: [deviceID: overview],
            frontmostBrowserURL: readsBrowserState ? browserCycleState.frontmostURL : nil,
            frontmostBrowserWindowID: readsBrowserState ? browserCycleState.frontmostWindowID : nil,
            openTerminalPaneCount: openTerminalSessionIDs.count, browserPerfDetail: browserCycleState.perfDetail)
    }

    /// A cross-device mode's set, built from every device's installed overview.
    private func modeCycleTargetSnapshot(
        mode: WindowCycleMode, preferredTerminalSessionID: String?, retaining retainedCursors: [WorkspaceWindowCycle.Cursor]
    ) async -> WindowCycleTargetSnapshot {
        let devices = host.deviceModel.deviceSections.compactMap { section in
            section.overview.map { WindowCycleDeviceSnapshot(deviceID: section.deviceID, overview: $0) }
        }
        // Only Open sessions can contain a browser target, so the other modes never script Chrome or
        // read the browser-tracking table for a cycle step. They give up nothing by it: with no
        // browser candidate to match, the frontmost Chrome tab could not resolve the current target
        // either.
        let needsBrowserState = mode == .openSessions
        // Every workspace every device reports, so a workspace whose panel this launch has not
        // restored contributes the panes its persisted layout holds. Restoration is lazy, so without
        // it a fresh launch would name only the workspaces the user has already visited.
        let openTerminalSessionIDsByWorkspace =
            needsBrowserState
            ? host.panelCoordinator.openTerminalSessionIDsByWorkspace(
                includingPersistedLayoutsFor: devices.flatMap { device in
                    device.overview.workspaces.map { PanelLayoutEngine.WorkspaceKey(deviceID: device.deviceID, workspaceID: $0.id) }
                }) : [:]
        // Captured synchronously, before the round trip's suspension point, so the tag below names
        // exactly the set this round trip queried, not whatever `host.deviceModel.deviceSections`
        // reports once it returns: a workspace added or removed elsewhere during that await would
        // otherwise mis-tag the cache with a set the round trip never actually covered.
        let workspaces = devices.flatMap { device in
            device.overview.workspaces.map {
                BrowserSessionCoordinator.BrowserCycleWorkspace(workspaceID: $0.id, detail: SpacesDeviceWorkspaceDetailViewModel(workspace: $0))
            }
        }
        let browserCycleState = needsBrowserState ? await host.browserSessions.trackedBrowserCycleState(workspaces: workspaces) : .noBrowserState
        // Only the cross-device snapshot is cached for the cycling row's count. A workspace
        // rotation's snapshot covers one workspace, and caching a partial map would make the Open
        // sessions count silently drop every other workspace's browser sessions. `cycleWindows`
        // repaints the row once the step finishes, so this only needs to update the cache, tagged
        // with the workspace set actually queried above.
        if needsBrowserState { noteBrowserCycleState(browserCycleState, workspaceIDs: Set(workspaces.map(\.workspaceID))) }
        let targets = WindowCycleModeTargets.targets(
            mode: mode, devices: devices, openTerminalSessionIDsByWorkspace: openTerminalSessionIDsByWorkspace,
            openBrowserSessionsByWorkspace: browserCycleState.openBrowserSessionsByWorkspace,
            trackedBrowserWindowIDsByWorkspace: browserCycleState.trackedWindowIDsByWorkspace,
            recentCursors: windowCycleState.recentCursors(for: .mode(mode)), retaining: retainedCursors)
        // A focused built-in terminal decides the current target before any browser state is read, so
        // the browser fields are dropped together when there is one.
        let readsBrowserState = preferredTerminalSessionID?.isEmpty != false
        return WindowCycleTargetSnapshot(
            targets: targets, overviewsByDeviceID: Dictionary(devices.map { ($0.deviceID, $0.overview) }, uniquingKeysWith: { first, _ in first }),
            frontmostBrowserURL: readsBrowserState ? browserCycleState.frontmostURL : nil,
            frontmostBrowserWindowID: readsBrowserState ? browserCycleState.frontmostWindowID : nil,
            openTerminalPaneCount: openTerminalSessionIDsByWorkspace.values.reduce(0) { $0 + $1.count },
            browserPerfDetail: browserCycleState.perfDetail)
    }

    nonisolated static func cycleWindowTargets(
        detail: SpacesDeviceWorkspaceDetailViewModel, browserSessions: [BrowserSession], openTerminalSessionIDs: Set<String>
    ) -> [AppKitController.WorkspaceRunShortcutTarget] {
        AppKitController.workspaceShortcutTargets(detail: detail, browserSessions: browserSessions).filter { target in
            switch target.kind {
            case .browser: return true
            case .process, .window, .agent:
                guard let sessionID = cycleTargetSessionID(for: target, detail: detail), !sessionID.isEmpty else { return false }
                return openTerminalSessionIDs.contains(sessionID)
            case .missingConfiguredProcess: return false
            }
        }
    }

    /// Stable per-target identity used to remember the cursor and preserve cycle order.
    nonisolated static func cycleCursorKey(for target: AppKitController.WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel)
        -> String
    {
        switch target.kind {
        case .browser: return "browser:\(target.targetURL ?? "")"
        case .process: return "process:\(target.processID ?? "")"
        case .window: return "terminal:\(cycleTargetSessionID(for: target, detail: detail) ?? String(target.windowListIndex ?? -1))"
        case .agent: return "agent:\(target.agentWindow?.id ?? "")"
        case .missingConfiguredProcess: return "missing:\(target.processKey ?? "")"
        }
    }

    nonisolated private static func cycleTargetSessionID(
        for target: AppKitController.WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel
    ) -> String? {
        switch target.kind {
        case .process: return detail.processRows.first(where: { ($0.processID ?? $0.id) == target.processID })?.sessionID
        case .window:
            guard let index = target.windowListIndex, detail.terminalRows.indices.contains(index) else { return nil }
            return detail.terminalRows[index].sessionID
        case .agent: return detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == target.agentWindow?.id })?.sessionID
        case .browser, .missingConfiguredProcess: return nil
        }
    }

    /// Records a visit to one cycle candidate. The cursor passed in is always the candidate's
    /// per-workspace key: the recording site derives the cross-workspace key from it, whichever scope
    /// the rotation itself is using.
    private func rememberWindowNavigationCycleTarget(_ target: WindowCycleTarget, preserveWindowCycleSession: Bool) {
        rememberWindowNavigationCursor(
            Self.cycleCursorKey(for: target.target, detail: target.detail), workspaceID: target.workspaceID,
            preserveWindowCycleSession: preserveWindowCycleSession)
    }

    private func rememberWindowNavigationFocus(
        resolution: AppKitController.DeviceWindowShortcutResolution, preferredTarget: AppKitController.WorkspaceRunShortcutTarget? = nil,
        preferredDetail: SpacesDeviceWorkspaceDetailViewModel? = nil, preserveWindowCycleSession: Bool = false
    ) {
        guard let workspaceID = Self.workspaceID(for: resolution) else { return }
        if let preferredTarget {
            let detail = preferredDetail ?? focusableWindowContext(workspaceID: workspaceID)?.detail
            if let detail,
                rememberWindowNavigationTargetIfCycleable(
                    preferredTarget, workspaceID: workspaceID, detail: detail, preserveWindowCycleSession: preserveWindowCycleSession)
            {
                return
            }
        }

        switch resolution {
        case .openURL(_, let targetURL):
            guard !targetURL.isEmpty else { return }
            rememberWindowNavigationCursor("browser:\(targetURL)", workspaceID: workspaceID, preserveWindowCycleSession: preserveWindowCycleSession)
        case .openTerminal(let request):
            rememberWindowNavigationTerminalSession(
                workspaceID: request.workspaceID, sessionID: request.sessionID, preserveWindowCycleSession: preserveWindowCycleSession)
        case .runProcess(_, let processKey, _):
            rememberWindowNavigationProcess(workspaceID: workspaceID, processKey: processKey, preserveWindowCycleSession: preserveWindowCycleSession)
        case .noWorkspace, .noMatch: return
        }
    }

    @discardableResult private func rememberWindowNavigationTargetIfCycleable(
        _ target: AppKitController.WorkspaceRunShortcutTarget, workspaceID: String, detail: SpacesDeviceWorkspaceDetailViewModel,
        preserveWindowCycleSession: Bool
    ) -> Bool {
        switch target.kind {
        case .browser: guard target.targetURL?.isEmpty == false else { return false }
        case .process, .window, .agent: guard Self.cycleTargetSessionID(for: target, detail: detail)?.isEmpty == false else { return false }
        case .missingConfiguredProcess: return false
        }
        rememberWindowNavigationCursor(
            Self.cycleCursorKey(for: target, detail: detail), workspaceID: workspaceID, preserveWindowCycleSession: preserveWindowCycleSession)
        return true
    }

    private func rememberWindowNavigationTerminalSession(workspaceID: String, sessionID: String, preserveWindowCycleSession: Bool) {
        guard !sessionID.isEmpty, let context = focusableWindowContext(workspaceID: workspaceID) else { return }
        let matches = context.targets.filter { Self.cycleTargetSessionID(for: $0, detail: context.detail) == sessionID }
        guard !matches.isEmpty else { return }
        let currentCursor = windowCycleState.cursor(for: .workspace(workspaceID))
        if let currentCursor, let target = matches.first(where: { Self.cycleCursorKey(for: $0, detail: context.detail) == currentCursor }),
            rememberWindowNavigationTargetIfCycleable(
                target, workspaceID: workspaceID, detail: context.detail, preserveWindowCycleSession: preserveWindowCycleSession)
        {
            return
        }
        let recentCursors = windowCycleState.recentCursors(for: .workspace(workspaceID))
        for cursor in recentCursors {
            if let target = matches.first(where: { Self.cycleCursorKey(for: $0, detail: context.detail) == cursor }),
                rememberWindowNavigationTargetIfCycleable(
                    target, workspaceID: workspaceID, detail: context.detail, preserveWindowCycleSession: preserveWindowCycleSession)
            {
                return
            }
        }
        if let target = matches.last {
            rememberWindowNavigationTargetIfCycleable(
                target, workspaceID: workspaceID, detail: context.detail, preserveWindowCycleSession: preserveWindowCycleSession)
        }
    }

    func noteWindowNavigationTerminalFocus(sessionID: String) {
        guard let workspaceID = host.clientWorkspaceID(forTerminalSession: sessionID) else { return }
        rememberWindowNavigationTerminalSession(workspaceID: workspaceID, sessionID: sessionID, preserveWindowCycleSession: false)
    }

    /// The session this controller last tried to record a content visit for. Every other recording
    /// path clears it, so it is only ever set while that visit is still the most recent one.
    private var lastNotedContentVisitSessionID: String?

    /// A click or a keystroke landed in a terminal pane's content: record it as a visit, so a pane
    /// reached by hand becomes the most recent target for cycling exactly as one reached by focusing
    /// it does.
    ///
    /// Every keystroke in a focused pane reaches here, and recording rebuilds the workspace's target
    /// list, so the same session in a row is noted once. That is deliberately one note per session
    /// rather than one per recorded visit: a session with no cycleable target yet (its pane opened
    /// ahead of the overview that describes it) would otherwise rebuild that list on every keystroke
    /// for as long as the user keeps typing. Such a session simply stays unvisited until focus lands
    /// on it again, which is what any focus path already records.
    ///
    /// The visit is recorded without preserving the cycle session on purpose: a keystroke in the target
    /// a burst landed on is the user engaging with it, and that ends the burst in every mode. In
    /// Attention mode that means answering a waiting agent and pressing Next right away starts a new
    /// sequence from that agent, over the set as it stands then (the answered agent, now working, is
    /// no longer in it), rather than continuing the frozen order. Accepted: the retained-target rule
    /// in `WindowCycleModeTargets` covers state changes the user did not cause, and a burst the user
    /// interrupted by typing is over.
    func noteWindowNavigationContentVisit(sessionID: String) {
        guard sessionID != lastNotedContentVisitSessionID else { return }
        noteWindowNavigationTerminalFocus(sessionID: sessionID)
        lastNotedContentVisitSessionID = sessionID
    }

    private func rememberWindowNavigationProcess(workspaceID: String, processKey: String, preserveWindowCycleSession: Bool) {
        guard let context = focusableWindowContext(workspaceID: workspaceID) else { return }
        let target = context.targets.first { target in
            guard target.kind == .process, let processID = target.processID,
                let row = context.detail.processRows.first(where: { ($0.processID ?? $0.id) == processID })
            else { return false }
            return AppKitController.normalizedRunRowName(row.name) == AppKitController.normalizedRunRowName(processKey)
        }
        if let target {
            rememberWindowNavigationTargetIfCycleable(
                target, workspaceID: workspaceID, detail: context.detail, preserveWindowCycleSession: preserveWindowCycleSession)
        }
    }

    private func rememberWindowNavigationCursor(_ cursor: WorkspaceWindowCycle.Cursor, workspaceID: String, preserveWindowCycleSession: Bool) {
        // The cross-device rotations order by visits across every workspace, so the same visit is
        // also recorded under a key carrying the owning device and workspace. That device is resolved
        // here rather than threaded through every caller: `deviceID(forWorkspaceID:)` is an O(1)
        // index lookup, and a workspace whose device is not loaded is one no cross-device rotation
        // can name a target in anyway.
        let globalCursor = host.deviceID(forWorkspaceID: workspaceID).map {
            WindowCycleTarget.globalCursorKey(deviceID: $0, workspaceID: workspaceID, cursorKey: cursor)
        }
        windowCycleState.recordVisit(
            cursor: cursor, globalCursor: globalCursor, workspaceID: workspaceID, preserveCycleSession: preserveWindowCycleSession)
        lastNotedContentVisitSessionID = nil
    }

    nonisolated private static func workspaceID(for resolution: AppKitController.DeviceWindowShortcutResolution) -> String? {
        switch resolution {
        case .openURL(let workspaceID, _), .runProcess(let workspaceID, _, _): return workspaceID
        case .openTerminal(let request): return request.workspaceID
        case .noWorkspace, .noMatch: return nil
        }
    }

    /// Short name for a target, used in the `window_cycle` perf line the E2E parses; matches
    /// the orchestrator's `kind:name` shape (e.g. `process:web`, `terminal:shell`).
    nonisolated private static func cycleDebugName(
        for target: AppKitController.WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel
    ) -> String {
        switch target.kind {
        case .browser: return "browser:\(target.targetURL ?? "")"
        case .process:
            let name = target.processID.flatMap { id in detail.processRows.first(where: { ($0.processID ?? $0.id) == id })?.name }
            return "process:\(name ?? target.processID ?? "")"
        case .window:
            let title = target.windowListIndex.flatMap { detail.terminalRows.indices.contains($0) ? detail.terminalRows[$0].title : nil }
            return "terminal:\(title ?? "")"
        case .agent: return "agent:\(target.agentWindow?.effectiveLabel ?? target.agentWindow?.id ?? "")"
        case .missingConfiguredProcess: return "process:\(target.processKey ?? "")"
        }
    }

    /// Which candidate the cycle is standing on: the focused terminal session, else the frontmost
    /// Chrome tab (by URL, narrowed by the front window's id when that separates two workspaces), else
    /// the rotation's remembered cursor. Each candidate is matched against its own workspace's detail,
    /// so this reads the same for one workspace's rotation and for one spanning devices.
    // Not private: pure, and covered directly by `WindowCycleCurrentIndexTests`.
    nonisolated static func cycleCurrentIndex(
        targets: [WindowCycleTarget], focusedTerminalSessionID: String?, frontmostBrowserURL: String?, frontmostBrowserWindowID: Int?, cursor: String?
    ) -> Int? {
        if let focusedTerminalSessionID, !focusedTerminalSessionID.isEmpty {
            let matches = targets.indices.filter {
                cycleTargetSessionID(for: targets[$0].target, detail: targets[$0].detail) == focusedTerminalSessionID
            }
            if !matches.isEmpty {
                if let cursor, let match = matches.first(where: { targets[$0].cursorKey == cursor }) { return match }
                return matches.last
            }
        }
        if let frontmostBrowserURL, !frontmostBrowserURL.isEmpty {
            let matches = targets.indices.compactMap { index -> (offset: Int, matchLength: Int)? in
                let candidate = targets[index]
                guard candidate.target.kind == .browser, let targetURL = candidate.target.targetURL, !targetURL.isEmpty else { return nil }
                let browserTargetURLs = BrowserSessionCoordinator.browserSessionTargetURLs(
                    resolvedSessions: candidate.detail.config.resolvedBrowserSessions)
                let siblingTargetURLs = BrowserSessionCoordinator.browserSessionSiblingTargetURLs(targetURL: targetURL, targetURLs: browserTargetURLs)
                guard
                    let matchLength = BrowserSessionCoordinator.browserObservedURLMatchLength(
                        frontmostBrowserURL, targetURL: targetURL, siblingTargetURLs: siblingTargetURLs, assignedPorts: candidate.detail.assignedPorts
                    )
                else { return nil }
                return (index, matchLength)
            }
            if !matches.isEmpty {
                // Two workspaces can configure the same target URL and have it open in separate Chrome
                // windows, and then the URL matches both. The window the frontmost tab is in belongs to
                // exactly one of their tracked sets, so it names the workspace the user is standing in;
                // without it (no front window, or an untracked one) every URL match stays in play.
                let windowMatches =
                    frontmostBrowserWindowID.map { windowID in matches.filter { targets[$0.offset].trackedBrowserWindowIDs.contains(windowID) } }
                    ?? []
                let candidates = windowMatches.isEmpty ? matches : windowMatches
                if let cursor, let match = candidates.first(where: { targets[$0.offset].cursorKey == cursor }) { return match.offset }
                return candidates.max(by: { $0.matchLength < $1.matchLength })?.offset
            }
        }
        if let cursor { return targets.firstIndex(where: { $0.cursorKey == cursor }) }
        return nil
    }

    // MARK: - Activation and reveal helpers

    private func activateCurrentApplicationForTargetedReveal() { NSApp.activate(ignoringOtherApps: true) }

    /// Which pane a summon should select. A focused tracked workspace window is an explicit signal to
    /// switch to that workspace; without one the summon carries no view intent, so `nil` means keep
    /// whatever pane was already visible rather than switching the user's view for them.
    nonisolated static func activationSelectionTarget(focusedWorkspaceID: String?) -> AppKitController.SidebarArrowSelectionTarget? {
        guard let focusedWorkspaceID else { return nil }
        return .workspace(focusedWorkspaceID)
    }

    // MARK: - Focus resolution and dispatch

    func performWindowFocus(_ request: AppKitController.WindowFocusRequest) async {
        guard await executeWindowFocus(request) else { return }
        host.reloadData()
    }

    /// Resolves an explicit focus request against its workspace's overview and focuses the
    /// client's window for it, returning whether a target was focused. Shared by the command
    /// palette and attention-item focus. A missing window is reopened by the executor itself,
    /// so there is no separate recovery prompt.
    func executeWindowFocus(_ request: AppKitController.WindowFocusRequest) async -> Bool {
        guard let overview = host.overview(forWorkspaceID: request.workspaceID) else { return false }
        let targetContext = Self.windowFocusTarget(for: request, overview: overview)
        return await executeWindowFocusResolution(
            Self.windowFocusResolution(for: request, overview: overview), preferredTarget: targetContext?.target,
            preferredDetail: targetContext?.detail)
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func runWindowShortcut(index: Int, startedAt: Date) async {
        activeWindowShortcutProfile = WindowShortcutProfile(index: index, startedAt: startedAt)
        logWindowShortcutProfile("stage=received index=\(index) alerts=\(host.showingAlerts ? 1 : 0)")
        let shortcutDispatchMS = host.windowShortcutElapsedMS(since: startedAt)
        let resolutionStartedAt = Date()
        let resolutionContext = windowShortcutResolutionContext(index: index)
        let targetResolutionMS = host.windowShortcutElapsedMS(since: resolutionStartedAt)
        await dispatchWindowShortcut(
            resolutionContext, index: index, startedAt: startedAt, shortcutDispatchMS: shortcutDispatchMS, targetResolutionMS: targetResolutionMS)
    }

    /// Resolves a window-shortcut press to a device-agnostic focus target. Alerts focus
    /// uses the clicked attention item; otherwise the target is reconstructed from the
    /// selected workspace's overview — the same path for local and remote workspaces.
    private func windowShortcutResolutionContext(index: Int) -> WindowFocusResolutionContext {
        if host.showingAlerts {
            guard let request = host.alerts.alertsFocusRequest(for: index) else {
                return WindowFocusResolutionContext(resolution: .noMatch, target: nil, detail: nil)
            }
            guard let overview = host.overview(forWorkspaceID: request.workspaceID) else {
                return WindowFocusResolutionContext(resolution: .noMatch, target: nil, detail: nil)
            }
            let targetContext = Self.windowFocusTarget(for: request, overview: overview)
            return WindowFocusResolutionContext(
                resolution: Self.windowFocusResolution(for: request, overview: overview), target: targetContext?.target, detail: targetContext?.detail
            )
        }
        guard let selectedWorkspaceID = host.selectedWorkspaceID else {
            return WindowFocusResolutionContext(resolution: .noWorkspace, target: nil, detail: nil)
        }
        guard let overview = host.overview(forWorkspaceID: selectedWorkspaceID) else {
            return WindowFocusResolutionContext(resolution: .noWorkspace, target: nil, detail: nil)
        }
        guard index > 0 else { return WindowFocusResolutionContext(resolution: .noMatch, target: nil, detail: nil) }
        guard let deviceWorkspace = overview.workspaces.first(where: { $0.id == selectedWorkspaceID }) else {
            return WindowFocusResolutionContext(resolution: .noWorkspace, target: nil, detail: nil)
        }
        let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: deviceWorkspace)
        let targets = AppKitController.workspaceShortcutTargets(
            detail: detail, browserSessions: detail.config.resolvedBrowserSessions.map(AppKitController.localBrowserSession(from:)))
        guard targets.indices.contains(index - 1) else { return WindowFocusResolutionContext(resolution: .noMatch, target: nil, detail: detail) }
        let target = targets[index - 1]
        return WindowFocusResolutionContext(
            resolution: AppKitController.windowShortcutTargetResolution(target, workspaceID: selectedWorkspaceID, detail: detail, overview: overview),
            target: target, detail: detail)
    }

    /// Maps an explicit alerts/command-palette focus request to the same device-agnostic
    /// target the numbered-shortcut path produces, so both flow through one dispatcher.
    nonisolated static func windowFocusResolution(for request: AppKitController.WindowFocusRequest, overview: SpacesDeviceOverviewPayload)
        -> AppKitController.DeviceWindowShortcutResolution
    {
        switch request {
        case .workspaceBrowserSession(let workspaceID, let targetURL): return .openURL(workspaceID: workspaceID, targetURL: targetURL)
        case .workspaceProcess(let workspaceID, let processID):
            guard let detail = AppKitController.workspaceDetail(workspaceID, in: overview),
                let row = detail.processRows.first(where: { ($0.processID ?? $0.id) == processID }), let sessionID = row.sessionID
            else { return .noMatch }
            return openTerminalResolution(
                workspaceID: workspaceID, sessionID: sessionID, fallbackTitle: row.name, fallbackDir: detail.dir, fallbackKind: .process,
                overview: overview)
        case .workspaceWindow(let workspaceID, let index):
            guard let detail = AppKitController.workspaceDetail(workspaceID, in: overview), detail.terminalRows.indices.contains(index - 1),
                let sessionID = detail.terminalRows[index - 1].sessionID
            else { return .noMatch }
            let row = detail.terminalRows[index - 1]
            return openTerminalResolution(
                workspaceID: workspaceID, sessionID: sessionID, fallbackTitle: row.title, fallbackDir: row.workingDirectory, fallbackKind: .shell,
                overview: overview)
        case .workspaceMissingConfiguredProcess(let workspaceID, let processKey):
            let templateID = AppKitController.workspaceDetail(workspaceID, in: overview)?.config.processes.first {
                AppKitController.normalizedRunRowName($0.name ?? "") == AppKitController.normalizedRunRowName(processKey)
            }?.id
            return .runProcess(workspaceID: workspaceID, processKey: processKey, processTemplateID: templateID)
        case .agentWindow(let record):
            guard let detail = AppKitController.workspaceDetail(record.workspaceID, in: overview),
                let row = detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == record.id }), let sessionID = row.sessionID
            else { return .noMatch }
            return openTerminalResolution(
                workspaceID: record.workspaceID, sessionID: sessionID, fallbackTitle: row.name, fallbackDir: detail.dir, fallbackKind: .agent,
                overview: overview)
        case .terminalSession(let workspaceID, let sessionID):
            guard let session = overview.sessions.first(where: { $0.id == sessionID }) else { return .noMatch }
            return openTerminalResolution(
                workspaceID: workspaceID, sessionID: sessionID, fallbackTitle: session.title, fallbackDir: session.workingDirectory,
                fallbackKind: AppKitController.terminalSessionKind(rowKind: session.rowKind), overview: overview)
        }
    }

    nonisolated private static func windowFocusTarget(for request: AppKitController.WindowFocusRequest, overview: SpacesDeviceOverviewPayload) -> (
        target: AppKitController.WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel
    )? {
        guard let detail = AppKitController.workspaceDetail(request.workspaceID, in: overview) else { return nil }
        let targets = AppKitController.workspaceShortcutTargets(
            detail: detail, browserSessions: detail.config.resolvedBrowserSessions.map(AppKitController.localBrowserSession(from:)))
        let target: AppKitController.WorkspaceRunShortcutTarget?
        switch request {
        case .workspaceBrowserSession(_, let targetURL): target = targets.first { $0.kind == .browser && $0.targetURL == targetURL }
        case .workspaceProcess(_, let processID): target = targets.first { $0.kind == .process && $0.processID == processID }
        case .workspaceWindow(_, let index): target = targets.first { $0.kind == .window && $0.windowListIndex == index - 1 }
        case .workspaceMissingConfiguredProcess(_, let processKey):
            target = targets.first {
                $0.kind == .missingConfiguredProcess
                    && AppKitController.normalizedRunRowName($0.processKey ?? "") == AppKitController.normalizedRunRowName(processKey)
            }
        case .agentWindow(let record): target = targets.first { $0.kind == .agent && $0.agentWindow?.id == record.id }
        // A bell alert's session isn't one of the workspace's numbered run-shortcut targets, so it
        // has no run-shortcut target to resolve.
        case .terminalSession: target = nil
        }
        guard let target else { return nil }
        return (target, detail)
    }

    /// Builds an `.openTerminal` target for a session, preferring live session-catalog
    /// metadata from the overview and falling back to the row's own title/dir when the
    /// session has not yet surfaced in the catalog (e.g. a just-started process).
    nonisolated private static func openTerminalResolution(
        workspaceID: String, sessionID: String, fallbackTitle: String, fallbackDir: String, fallbackKind: TerminalSessionKind,
        overview: SpacesDeviceOverviewPayload
    ) -> AppKitController.DeviceWindowShortcutResolution {
        .openTerminal(
            AppKitController.deviceTerminalOpenRequest(workspaceID: workspaceID, sessionID: sessionID, overview: overview)
                ?? AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: workspaceID, sessionID: sessionID, title: fallbackTitle, workingDirectory: fallbackDir, kind: fallbackKind))
    }

    /// The single window-shortcut dispatcher for every device. It executes the resolved
    /// target, then applies the window-shortcut profiling. The focus work itself lives in
    /// `executeWindowFocusResolution` so the cycle and command-palette paths reuse it.
    private func dispatchWindowShortcut(
        _ context: WindowFocusResolutionContext, index: Int, startedAt: Date, shortcutDispatchMS: Int, targetResolutionMS: Int
    ) async {
        let routeStartedAt = Date()
        let resolution = context.resolution
        let kind = Self.windowShortcutKind(for: resolution)
        guard await executeWindowFocusResolution(resolution, preferredTarget: context.target, preferredDetail: context.detail) else {
            logWindowShortcutProfile("stage=aborted index=\(index) kind=\(kind) elapsed_ms=\(host.windowShortcutElapsedMS(since: startedAt))")
            host.logPerfMetric(
                "window_shortcut", target: "index=\(index)", elapsedMS: host.windowShortcutElapsedMS(since: startedAt), success: false,
                detail:
                    "kind=\(kind) shortcut_dispatch_ms=\(shortcutDispatchMS) target_resolution_ms=\(targetResolutionMS) route_ms=\(host.windowShortcutElapsedMS(since: routeStartedAt))"
            )
            activeWindowShortcutProfile = nil
            return
        }
        let routeMS = host.windowShortcutElapsedMS(since: routeStartedAt)
        logWindowShortcutProfile("stage=route_done index=\(index) kind=\(kind) elapsed_ms=\(routeMS)")
        host.logPerfMetric(
            "window_shortcut", target: "index=\(index)", elapsedMS: host.windowShortcutElapsedMS(since: startedAt), success: true,
            detail: "kind=\(kind) shortcut_dispatch_ms=\(shortcutDispatchMS) target_resolution_ms=\(targetResolutionMS) route_ms=\(routeMS)")
        activeWindowShortcutProfile = nil
    }

    private struct RoutedBrowserFocusTarget: Sendable {
        let targetURL: URL
        let siblingTargetURLs: [String]
    }

    /// Executes a resolved focus target on the client and reports whether a target was
    /// focused (the executor surfaces its own errors on failure). Shared by the
    /// numbered-shortcut, command-palette, and cycle focus paths so all three behave
    /// identically. Only two leaves depend on where the workspace's daemon runs: browser
    /// URLs may need remote-service routing before local Chrome focus, and terminal
    /// windows use native sessions locally vs Device API mirrors remotely.
    @discardableResult func executeWindowFocusResolution(
        _ resolution: AppKitController.DeviceWindowShortcutResolution, requestID: String? = nil,
        preferredTarget: AppKitController.WorkspaceRunShortcutTarget? = nil, preferredDetail: SpacesDeviceWorkspaceDetailViewModel? = nil,
        preserveWindowCycleSession: Bool = false
    ) async -> Bool {
        switch resolution {
        case .openURL(let workspaceID, let targetURL):
            guard URL(string: targetURL) != nil else {
                host.showError(WorkspaceError.invalidArgument(message: "Browser session URL is invalid."))
                return false
            }
            // Whether the URL needs remote-service routing depends on the owning device. With no
            // known owner there is no answer, and opening the raw URL would point this Mac's
            // Chrome at a localhost port that belongs to another machine's workspace.
            guard let workspaceDeviceID = host.deviceID(forWorkspaceID: workspaceID) else {
                host.showDeviceNotLoadedError()
                return false
            }
            let browserSessionTargetURLs = BrowserSessionCoordinator.browserSessionTargetURLs(
                workspaceID: workspaceID, targetURL: targetURL, overview: host.overview(forWorkspaceID: workspaceID))
            let siblingTargetURLs = BrowserSessionCoordinator.browserSessionSiblingTargetURLs(
                targetURL: targetURL, targetURLs: browserSessionTargetURLs)
            if host.isRemoteDeviceID(workspaceDeviceID) {
                guard let device = host.deviceForWorkspaceMutation(workspaceID: workspaceID) else {
                    host.showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
                    return false
                }
                guard let workspace = host.deviceWorkspaceSummary(workspaceID: workspaceID) else {
                    host.showError(WorkspaceError.invalidArgument(message: "Workspace not found on the selected device."))
                    return false
                }
                // Opening a missing workspace SSH forward and reconciling the Caddy route blocks (spawns
                // `ssh`, polls local ports and router config up to the timeout), so run it off the main
                // actor to keep the focus keypress from freezing the UI. The manager is `Sendable` and
                // serializes its own state, so the detached task can safely own the reconciliation.
                let manager = host.browserSessions.forwardManager
                let routeResult: Result<RoutedBrowserFocusTarget, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let routedURL = try manager.routedURL(targetURL: targetURL, workspace: workspace, device: device)
                        let routedSiblingTargetURLs = try siblingTargetURLs.map {
                            try manager.routedURL(targetURL: $0, workspace: workspace, device: device).absoluteString
                        }
                        return .success(RoutedBrowserFocusTarget(targetURL: routedURL, siblingTargetURLs: routedSiblingTargetURLs))
                    } catch { return .failure(error) }
                }.value
                switch routeResult {
                case .success(let routedTarget):
                    host.browserSessions.refreshVisibleServicePortDisplays(deviceID: device.id)
                    guard
                        await host.browserSessions.focusLocalChromeTab(
                            workspaceID: workspaceID, targetURL: routedTarget.targetURL.absoluteString,
                            siblingTargetURLs: routedTarget.siblingTargetURLs)
                    else {
                        host.browserSessions.showBrowserSessionFocusFailureError()
                        return false
                    }
                case .failure(let error):
                    host.showError(error)
                    return false
                }
            } else {
                guard
                    await host.browserSessions.focusLocalChromeTab(
                        workspaceID: workspaceID, targetURL: targetURL, siblingTargetURLs: siblingTargetURLs)
                else {
                    host.browserSessions.showBrowserSessionFocusFailureError()
                    return false
                }
            }
            AppKitController.setClientActiveWorkspaceID(workspaceID)
            // A browser landing brings Chrome forward rather than a Spaces window, so unlike the
            // terminal path (which selects through its own pane), nothing else re-selects the
            // sidebar's workspace when the user comes back to Spaces. Select it here so the
            // sidebar matches the workspace the landing just focused.
            if host.selectedWorkspaceID != workspaceID, let (_, workspace) = host.findWorkspace(id: workspaceID) { host.selectWorkspace(workspace) }
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return true
        case .openTerminal(let request):
            guard await openOrFocusTerminalTarget(request, requestID: requestID) else { return false }
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return true
        case .runProcess(let workspaceID, let processKey, let processTemplateID):
            guard
                await runTerminalSessionMutationAndOpenPane(
                    workspaceID: workspaceID,
                    operation: { device in
                        try SpacesDeviceClient.runWorkspaceProcess(
                            workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID,
                            context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                    })
            else { return false }
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return true
        case .noWorkspace, .noMatch: return false
        }
    }

    @discardableResult private func openOrFocusTerminalTarget(_ request: AppKitController.DeviceTerminalOpenRequest, requestID: String? = nil) async
        -> Bool
    {
        let startedAt = Date()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        var requestResolveMS = 0
        var existingPaneFocusMS = 0
        var paneOpenMS = 0
        var ownershipRequestMS = 0
        var focusObservationMS = 0
        var focusObserved = false
        var retriedAfterReload = false
        func logTerminalPaneFocus(success: Bool, reason: String = "") {
            let reasonDetail = reason.isEmpty ? "" : " reason=\(reason)"
            let retryDetail = retriedAfterReload ? " retried_after_reload=1" : ""
            host.logPerfMetric(
                "terminal_pane_focus", target: "session=\(request.sessionID)", elapsedMS: host.windowShortcutElapsedMS(since: startedAt),
                success: success,
                detail:
                    "request_resolution_ms=\(requestResolveMS) existing_pane_focus_ms=\(existingPaneFocusMS) pane_open_ms=\(paneOpenMS) ownership_request_ms=\(ownershipRequestMS) focus_observation_ms=\(focusObservationMS) focus_observed=\(focusObserved ? 1 : 0)\(requestDetail)\(reasonDetail)\(retryDetail)"
            )
        }
        // Window-focus terminal targets are always workspace-backed (they come from a
        // workspace's run-target list), so a workspace whose owning device is unknown is a not-loaded
        // state. Reachability is deliberately not required here, because this entry point covers both
        // focusing an existing pane (client-side, and available through an outage — that pane renders
        // as disconnected) and opening one that does not exist yet. Only the latter needs the daemon,
        // and it is refused inside `openOrFocusTerminalPane`, which is where the two are told apart
        // once the workspace's persisted layout has been adopted; the resolutions that create a
        // session are gated at their own mutations.
        guard host.deviceID(forWorkspaceID: request.workspaceID) != nil else {
            host.showDeviceNotLoadedError()
            logTerminalPaneFocus(success: false, reason: "device_not_loaded")
            return false
        }
        AppKitController.setClientActiveWorkspaceID(request.workspaceID)
        // A row-built resolution can predate the session's overview entry and lack the
        // real shell/command. Only recover that metadata when opening a new pane: an
        // already-open pane already has its state model and can focus entirely client-side.
        let existingPaneBeforeResolution = host.panelCoordinator.placement(forSessionID: request.sessionID) != nil
        let requestResolveStartedAt = Date()
        var openRequest: AppKitController.DeviceTerminalOpenRequest
        let needsColdResolution = Self.terminalOpenRequestNeedsColdResolution(request, hasExistingPane: existingPaneBeforeResolution)
        if needsColdResolution {
            openRequest = await host.resolveTerminalSessionPaneOpenRequest(sessionID: request.sessionID) ?? request
        } else {
            openRequest = request
        }
        requestResolveMS = host.windowShortcutElapsedMS(since: requestResolveStartedAt)
        let reusedExistingPane = existingPaneBeforeResolution || host.panelCoordinator.placement(forSessionID: openRequest.sessionID) != nil
        let paneFocusStartedAt = Date()
        // The open resolves the workspace's scope through the sidebar's index. A request for a
        // just-created workspace whose index entry has not landed yet is refused for exactly that reason
        // (`workspaceScope(forWorkspaceID:)` nil), so wait for the app's next snapshot and try once more,
        // redoing the cold resolution when this request needed one, since the miss can be in either. A
        // request whose scope is already present was refused for something else entirely: an unreachable
        // or incompatible device (which already showed its own modal, since this focusing entry point is
        // always a focusing intent) or a content-construction failure. Retrying either would only repeat
        // the same refusal and its modal a second time.
        var openedPane = host.panelCoordinator.openOrFocusTerminalPane(openRequest, openIntent: .focused) != nil
        if !openedPane, host.panelCoordinator.workspaceScope(forWorkspaceID: openRequest.workspaceID) == nil {
            retriedAfterReload = true
            await host.sidebar.reloadAwaitingFreshSnapshot()
            if needsColdResolution { openRequest = await host.resolveTerminalSessionPaneOpenRequest(sessionID: request.sessionID) ?? openRequest }
            openedPane = host.panelCoordinator.openOrFocusTerminalPane(openRequest, openIntent: .focused) != nil
        }
        guard openedPane else {
            if reusedExistingPane {
                existingPaneFocusMS = host.windowShortcutElapsedMS(since: paneFocusStartedAt)
            } else {
                paneOpenMS = host.windowShortcutElapsedMS(since: paneFocusStartedAt)
            }
            logTerminalPaneFocus(success: false, reason: "pane_open_failed")
            return false
        }
        if reusedExistingPane {
            existingPaneFocusMS = host.windowShortcutElapsedMS(since: paneFocusStartedAt)
        } else {
            paneOpenMS = host.windowShortcutElapsedMS(since: paneFocusStartedAt)
        }
        // Focusing a workspace terminal target (sidebar row, numbered shortcut, window
        // cycle, `focus-workspace-process`) is an owner-intent action: the user wants to
        // interact. Reclaim ownership like the owner-mode open IPC does, so a pane that was
        // closed and reopened (or is currently a viewer) reattaches as owner instead of the
        // takeover shell. The viewer-only `focusTerminalSessionWindow` IPC takes the
        // separate `openTerminalSessionPane(mode:.viewer)` path and never lands here.
        let ownershipStartedAt = Date()
        host.panelCoordinator.content(forSessionID: openRequest.sessionID)?.requestOwnershipIfNeeded()
        ownershipRequestMS = host.windowShortcutElapsedMS(since: ownershipStartedAt)
        let focusObservationStartedAt = Date()
        await Task.yield()
        focusObserved = host.panelCoordinator.focusedSessionID() == openRequest.sessionID
        focusObservationMS = host.windowShortcutElapsedMS(since: focusObservationStartedAt)
        logTerminalPaneFocus(success: true)
        if let requestID, !requestID.isEmpty {
            host.logPerfMetric(
                "terminal_window_focus_ipc", target: "session=\(openRequest.sessionID)", elapsedMS: host.windowShortcutElapsedMS(since: startedAt),
                success: true,
                detail:
                    "route=pane request_resolution_ms=\(requestResolveMS) existing_pane_focus_ms=\(existingPaneFocusMS) pane_open_ms=\(paneOpenMS) ownership_request_ms=\(ownershipRequestMS) focus_observation_ms=\(focusObservationMS) focus_observed=\(focusObserved ? 1 : 0) request_id=\(requestID)"
            )
            if focusObserved {
                host.logPerfMetric(
                    "terminal_window_focus_observed", target: "session=\(openRequest.sessionID)",
                    elapsedMS: host.windowShortcutElapsedMS(since: startedAt), success: true, detail: "route=pane request_id=\(requestID)")
            }
        }
        return true
    }

    nonisolated static func terminalOpenRequestNeedsColdResolution(_ request: AppKitController.DeviceTerminalOpenRequest, hasExistingPane: Bool)
        -> Bool
    { !hasExistingPane && request.shell == nil }

    private func runTerminalSessionMutationAndOpenPane(
        workspaceID: String, operation: @Sendable @escaping (SpacesPairedDeviceRecord) throws -> SpacesDeviceAPIResponse
    ) async -> Bool {
        guard let request = await host.runTerminalSessionMutation(workspaceID: workspaceID, operation: operation),
            await openOrFocusTerminalTarget(request)
        else { return false }
        return true
    }

    nonisolated private static func windowShortcutKind(for resolution: AppKitController.DeviceWindowShortcutResolution) -> String {
        switch resolution {
        case .openURL: return "browser"
        case .openTerminal: return "terminal"
        case .runProcess: return "process"
        case .noWorkspace, .noMatch: return "none"
        }
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func logWindowShortcutProfile(_ message: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("spaces: window_shortcut \(message)\n", stderr)
    }

    func captureHotkeyPerfContext() -> HotkeyPerfContext {
        HotkeyPerfContext(
            startedAt: Date(), appWasActive: NSApp.isActive, appWasHidden: NSApp.isHidden,
            mainWindowWasVisible: host.window?.isVisible == true && host.window?.isMiniaturized != true,
            paletteWasVisible: host.commandPalette.commandPalettePanel?.isVisible == true)
    }

    nonisolated static func commandPalettePresentationIsComplete(panelIsVisible: Bool, panelIsKey: Bool) -> Bool { panelIsVisible && panelIsKey }

    nonisolated static func shouldDismissCommandPaletteForToggle(panelIsVisible: Bool, panelIsFocused: Bool) -> Bool {
        panelIsVisible && panelIsFocused
    }

    nonisolated static func shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: Bool) -> Bool { appIsActive }

    nonisolated static func shouldUseFocusedChromeWindowForWorkspaceLookup(frontmostApplicationBundleIdentifier: String?) -> Bool {
        frontmostApplicationBundleIdentifier == "com.google.Chrome"
    }

    nonisolated static func activeWorkspaceIDForGlobalNavigation(appIsActive: Bool, activeWorkspaceID: String?) -> String? {
        appIsActive ? activeWorkspaceID : nil
    }

    nonisolated static func shouldReloadSidebarForTerminalOverviewSignal(
        didStartBackgroundServices: Bool, notificationObject: String?, profileObject: String
    ) -> Bool { didStartBackgroundServices && notificationObject == profileObject }

    nonisolated static func preferredWorkspaceIDForGlobalNavigation(
        focusedTerminalSessionWorkspaceID: String?, focusedWindowWorkspaceID: String?, activeWorkspaceID: String?
    ) -> GlobalNavigationWorkspaceResolution {
        if let focusedTerminalSessionWorkspaceID {
            return GlobalNavigationWorkspaceResolution(workspaceID: focusedTerminalSessionWorkspaceID, source: "focused_terminal_session")
        }
        if let focusedWindowWorkspaceID {
            return GlobalNavigationWorkspaceResolution(workspaceID: focusedWindowWorkspaceID, source: "focused_window")
        }
        if let activeWorkspaceID { return GlobalNavigationWorkspaceResolution(workspaceID: activeWorkspaceID, source: "active_workspace") }
        return GlobalNavigationWorkspaceResolution(workspaceID: nil, source: "none")
    }

    nonisolated static func shouldHideMainWindowForToggle(appIsHidden: Bool, mainWindowIsFocused: Bool) -> Bool {
        !appIsHidden && mainWindowIsFocused
    }

    func logHotkeyPerfMetric(_ metric: String, action: String, context: HotkeyPerfContext) {
        let target =
            "action=\(action) app_active_before=\(context.appWasActive ? 1 : 0) app_hidden_before=\(context.appWasHidden ? 1 : 0) main_visible_before=\(context.mainWindowWasVisible ? 1 : 0) palette_visible_before=\(context.paletteWasVisible ? 1 : 0)"
        host.logPerfMetric(metric, target: target, elapsedMS: host.windowShortcutElapsedMS(since: context.startedAt), success: true)
    }

    func windowShortcutIndex(for event: NSEvent) -> Int? {
        guard let windowShortcutSpec = host.shortcuts.windowShortcutSpec else { return nil }
        return numberedWindowShortcutIndex(for: event, spec: windowShortcutSpec)
    }

    private func numberedWindowShortcutIndex(for event: NSEvent, spec: HotkeySpec) -> Int? {
        guard host.shortcuts.eventModifierCarbonFlags(event) == spec.modifiersCarbon else { return nil }
        let keyMap: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3, UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
            UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9, UInt16(kVK_ANSI_0): 10,
        ]
        return keyMap[event.keyCode]
    }

    func windowShortcutBadgeText(index: Int) -> String {
        let keyText = index == 10 ? "0" : String(index)
        guard let windowShortcutSpec = host.shortcuts.windowShortcutSpec else { return "⌘\(keyText)" }
        return host.shortcuts.displayShortcut(windowShortcutSpec, keyText: keyText)
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func focusGlobalWindowNavigation(direction: Int) {
        let requestID = UUID().uuidString
        // Elapsed is measured from the press, so a step that waited its turn behind an earlier press
        // reports the wait: that is what the user felt.
        let startedAt = Date()
        // The mode is read at the press: a press means "step in the mode I am in now", and a mode
        // change typed while this press waits behind a slow step must not retroactively change what
        // the earlier press meant. The workspace the mode resolves and the focused session are read
        // inside the step instead, so they describe where the previous step of the burst landed.
        let mode = windowCycleMode
        windowCycleSteps.enqueue { [weak self] in
            guard let self else { return }
            // Workspace mode resolves the one workspace to cycle first, and has nothing to do when it
            // cannot; every other mode spans devices, so there is no workspace to resolve.
            let scope: WindowCycleScope
            if mode == .workspace {
                guard let workspaceID = self.globalWindowNavigationWorkspaceID(requestID: requestID) else {
                    self.host.logPerfMetric(
                        "global_window_navigation", target: "workspace=nil", elapsedMS: self.host.windowShortcutElapsedMS(since: startedAt),
                        success: false, detail: "direction=\(direction > 0 ? "next" : "previous") reason=no_workspace request_id=\(requestID)")
                    return
                }
                scope = .workspace(workspaceID)
            } else {
                scope = .mode(mode)
            }
            await self.cycleWindows(
                scope: scope, delta: direction > 0 ? 1 : -1, preferredTerminalSessionID: self.focusedBuiltInTerminalSessionIDForGlobalNavigation(),
                requestID: requestID)
            self.host.logPerfMetric(
                "global_window_navigation", target: "workspace=\(scope.workspaceID ?? "none")",
                elapsedMS: self.host.windowShortcutElapsedMS(since: startedAt), success: true,
                detail: "direction=\(direction > 0 ? "next" : "previous") mode=\(scope.mode.rawValue) request_id=\(requestID)")
        }
    }

    /// The `spaces.ipc.cycle-workspace-window` entry point, which names the workspace to cycle rather
    /// than reading the shortcut's mode. It joins the same chain as the shortcut so an IPC step and a
    /// keypress cannot run against the same pre-landing state.
    func enqueueWorkspaceWindowCycleStep(workspaceID: String, delta: Int, preferredTerminalSessionID: String?) {
        windowCycleSteps.enqueue { [weak self] in
            guard let self else { return }
            let sessionID =
                (preferredTerminalSessionID?.isEmpty == false)
                ? preferredTerminalSessionID : self.focusedBuiltInTerminalSessionIDForGlobalNavigation()
            await self.cycleWindows(scope: .workspace(workspaceID), delta: delta, preferredTerminalSessionID: sessionID)
        }
    }

    private func globalWindowNavigationWorkspaceID(requestID: String? = nil) -> String? {
        let startedAt = Date()
        let activeTerminalSessionStartedAt = Date()
        let focusedTerminalSessionID = focusedBuiltInTerminalSessionIDForGlobalNavigation()
        let activeTerminalSessionMS = host.windowShortcutElapsedMS(since: activeTerminalSessionStartedAt)

        var focusedTerminalSessionWorkspaceID: String?
        var focusedWindowWorkspaceID: String?
        var activeWorkspaceID: String?
        var terminalWorkspaceMS = 0
        var focusedWindowWorkspaceMS = 0
        var activeWorkspaceMS = 0
        var terminalWorkspaceSource = "skipped"
        var terminalWorkspaceStatus = "skipped"
        var focusedWindowWorkspaceStatus = "skipped"
        var activeWorkspaceStatus = "skipped"

        if let focusedTerminalSessionID {
            let lookupStartedAt = Date()
            focusedTerminalSessionWorkspaceID = host.clientWorkspaceID(forTerminalSession: focusedTerminalSessionID)
            terminalWorkspaceMS = host.windowShortcutElapsedMS(since: lookupStartedAt)
            terminalWorkspaceSource = "focused"
            terminalWorkspaceStatus = focusedTerminalSessionWorkspaceID == nil ? "miss" : "hit"
        }

        if focusedTerminalSessionWorkspaceID == nil {
            let lookupStartedAt = Date()
            focusedWindowWorkspaceID = host.clientWorkspaceIDForFocusedWindow()
            focusedWindowWorkspaceMS = host.windowShortcutElapsedMS(since: lookupStartedAt)
            focusedWindowWorkspaceStatus = focusedWindowWorkspaceID == nil ? "miss" : "hit"
        }

        if focusedTerminalSessionWorkspaceID == nil, focusedWindowWorkspaceID == nil {
            let lookupStartedAt = Date()
            activeWorkspaceID = host.clientActiveWorkspaceID()
            activeWorkspaceMS = host.windowShortcutElapsedMS(since: lookupStartedAt)
            activeWorkspaceStatus = activeWorkspaceID == nil ? "miss" : "hit"
        }

        let resolution = Self.preferredWorkspaceIDForGlobalNavigation(
            focusedTerminalSessionWorkspaceID: focusedTerminalSessionWorkspaceID, focusedWindowWorkspaceID: focusedWindowWorkspaceID,
            activeWorkspaceID: activeWorkspaceID)
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        let detail =
            "selected_source=\(resolution.source) active_terminal_session=\(focusedTerminalSessionID == nil ? "miss" : "hit") active_terminal_session_ms=\(activeTerminalSessionMS) terminal_workspace=\(terminalWorkspaceStatus) terminal_workspace_source=\(terminalWorkspaceSource) terminal_workspace_ms=\(terminalWorkspaceMS) focused_window_workspace=\(focusedWindowWorkspaceStatus) focused_window_workspace_ms=\(focusedWindowWorkspaceMS) active_workspace=\(activeWorkspaceStatus) active_workspace_ms=\(activeWorkspaceMS)\(requestDetail)"
        host.logPerfMetric(
            "global_window_navigation_workspace_resolution", target: "workspace=\(resolution.workspaceID ?? "nil")",
            elapsedMS: host.windowShortcutElapsedMS(since: startedAt), success: resolution.workspaceID != nil, detail: detail)
        return resolution.workspaceID
    }

    /// The focused built-in terminal session for global navigation: the pane holding
    /// keyboard focus, only while Spaces is active (an inactive app's stale focus must
    /// not hijack cycling from unrelated apps).
    // Not private: AppKitController's `handleCycleWorkspaceWindowIPC` calls this from a different
    // file in the same module (cross-file `private` isn't visible).
    func focusedBuiltInTerminalSessionIDForGlobalNavigation() -> String? {
        guard Self.shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: NSApp.isActive) else { return nil }
        return host.panelCoordinator.focusedSessionID()
    }

    nonisolated static func preferredWorkspaceIDForAppToggle(focusedTerminalSessionWorkspaceID: String?, focusedWindowWorkspaceID: String?) -> String?
    { focusedTerminalSessionWorkspaceID ?? focusedWindowWorkspaceID }

    /// Terminal panes live inside app windows (the main window and global panel
    /// windows), all hidden together by the app-wide hide; the only after-hide
    /// restoration is returning focus to the previously frontmost app.
    nonisolated static func shouldRestoreReturnApplicationAfterMainHide(returnApplicationProcessID: pid_t?) -> Bool {
        returnApplicationProcessID != nil
    }

    nonisolated static func returnApplicationProcessIDForAppToggle(frontmostApplicationProcessID: pid_t?, currentProcessID: pid_t) -> pid_t? {
        guard let frontmostApplicationProcessID, frontmostApplicationProcessID != currentProcessID else { return nil }
        return frontmostApplicationProcessID
    }

    // MARK: - Hotkey reveal and toggle

    func toggleWindowFromHotkey() {
        guard let window = host.window else { return }
        let toggleStartedAt = Date()
        let perfContext = captureHotkeyPerfContext()
        host.logHotkeyDebug("toggle_window begin \(host.hotkeyWindowStateSummary())")
        if Self.shouldHideMainWindowForToggle(appIsHidden: NSApp.isHidden, mainWindowIsFocused: window.isKeyWindow) {
            host.logHotkeyDebug("toggle_window hide_main_only")
            let returnApplicationProcessID = appToggleReturnApplicationProcessID
            window.orderOut(nil)
            NSApp.hide(nil)
            if Self.shouldRestoreReturnApplicationAfterMainHide(returnApplicationProcessID: returnApplicationProcessID),
                let returnApplicationProcessID
            {
                let restoreStartedAt = Date()
                host.activateReturnApplication(processIdentifier: returnApplicationProcessID)
                host.logPerfMetric(
                    "toggle_window_return_application_focus", target: "pid=\(returnApplicationProcessID)",
                    elapsedMS: host.windowShortcutElapsedMS(since: restoreStartedAt), success: true)
            }
            appToggleReturnApplicationProcessID = nil
            logHotkeyPerfMetric("toggle_window", action: "hide", context: perfContext)
            return
        }
        let returnApplicationProcessID = Self.returnApplicationProcessIDForAppToggle(
            frontmostApplicationProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            currentProcessID: ProcessInfo.processInfo.processIdentifier)
        let focusedTerminalSessionID = host.panelCoordinator.focusedSessionID()
        let focusedTerminalWorkspaceID: String?
        let selectionRefreshSource: String
        if let terminalSessionID = focusedTerminalSessionID {
            let lookupStartedAt = Date()
            focusedTerminalWorkspaceID = host.clientWorkspaceID(forTerminalSession: terminalSessionID)
            host.logPerfMetric(
                "toggle_window_terminal_workspace_lookup", target: "session=\(terminalSessionID)",
                elapsedMS: host.windowShortcutElapsedMS(since: lookupStartedAt), success: focusedTerminalWorkspaceID != nil)
            selectionRefreshSource = "terminal_session"
        } else {
            focusedTerminalWorkspaceID = nil
            selectionRefreshSource = "focused_window"
        }
        let focusedWindowWorkspaceID: String?
        if focusedTerminalWorkspaceID == nil {
            let focusedWindowLookupStartedAt = Date()
            focusedWindowWorkspaceID = host.clientWorkspaceIDForFocusedWindow()
            host.logPerfMetric(
                "toggle_window_focused_window_workspace_lookup", target: "frontmost_window",
                elapsedMS: host.windowShortcutElapsedMS(since: focusedWindowLookupStartedAt), success: focusedWindowWorkspaceID != nil)
        } else {
            focusedWindowWorkspaceID = nil
        }
        let focusedWorkspaceID = Self.preferredWorkspaceIDForAppToggle(
            focusedTerminalSessionWorkspaceID: focusedTerminalWorkspaceID, focusedWindowWorkspaceID: focusedWindowWorkspaceID)
        let revealStartedAt = Date()
        revealTargetedHotkeyWindow(window)
        host.logPerfMetric(
            "toggle_window_reveal_target", target: "main", elapsedMS: host.windowShortcutElapsedMS(since: revealStartedAt), success: true,
            detail: "app_active=\(NSApp.isActive ? 1 : 0)")
        host.logHotkeyDebug("toggle_window show_main focused_workspace=\(focusedWorkspaceID ?? "nil") \(host.hotkeyWindowStateSummary())")
        host.logPerfMetric("toggle_window_flow", target: "main", elapsedMS: host.windowShortcutElapsedMS(since: toggleStartedAt), success: true)
        logHotkeyPerfMetric("toggle_window", action: "show", context: perfContext)
        appToggleReturnApplicationProcessID = returnApplicationProcessID
        scheduleDeferredHotkeySelectionRefresh(focusedWorkspaceID: focusedWorkspaceID ?? nil, source: selectionRefreshSource)
    }

    func revealTargetedHotkeyWindow(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if Self.shouldFocusVisibleTargetedHotkeyWindow(
            appIsActive: NSApp.isActive, windowIsVisible: window.isVisible, windowIsMiniaturized: window.isMiniaturized)
        {
            window.orderFront(nil)
            window.makeKey()
            return
        }
        if Self.shouldUseDirectTargetedHotkeyReveal(appIsActive: NSApp.isActive) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if Self.shouldActivateAppForTargetedHotkeyReveal(appIsActive: NSApp.isActive) { activateCurrentApplicationForTargetedReveal() }
        prepareWindowForActiveSpaceSummon(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Task { @MainActor [weak window] in
            await Task.yield()
            guard let window, window.isVisible, !window.isMiniaturized else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func prepareWindowForActiveSpaceSummon(_ window: NSWindow) {
        activeSpaceSummonCleanupTask?.cancel()
        window.collectionBehavior = Self.collectionBehaviorForActiveSpaceSummon(window.collectionBehavior)
        activeSpaceSummonCleanupTask = Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self, !Task.isCancelled, let window else { return }
            window.collectionBehavior = Self.collectionBehaviorAfterActiveSpaceSummon(window.collectionBehavior)
            self.activeSpaceSummonCleanupTask = nil
        }
    }

    nonisolated static func collectionBehaviorForActiveSpaceSummon(_ behavior: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        var updated = behavior
        updated.insert(.moveToActiveSpace)
        return updated
    }

    nonisolated static func collectionBehaviorAfterActiveSpaceSummon(_ behavior: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        var updated = behavior
        updated.remove(.moveToActiveSpace)
        return updated
    }

    nonisolated static func shouldUseDirectTargetedHotkeyReveal(appIsActive: Bool) -> Bool { appIsActive }

    nonisolated static func shouldActivateAppForTargetedHotkeyReveal(appIsActive: Bool) -> Bool { !appIsActive }

    nonisolated static func shouldFocusVisibleTargetedHotkeyWindow(appIsActive: Bool, windowIsVisible: Bool, windowIsMiniaturized: Bool) -> Bool {
        appIsActive && windowIsVisible && !windowIsMiniaturized
    }

    nonisolated static func shouldActivateAppForCommandPalettePresentation(appIsActive: Bool) -> Bool { !appIsActive }

    private func scheduleDeferredHotkeySelectionRefresh(focusedWorkspaceID: String?, source: String) {
        deferredHotkeySelectionRefreshTask?.cancel()
        deferredHotkeySelectionRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            let refreshStartedAt = Date()
            self.refreshWorkspaceSelectionForActivation(focusedWorkspaceID: focusedWorkspaceID)
            self.host.logPerfMetric(
                "toggle_window_selection_refresh", target: "workspace=\(focusedWorkspaceID ?? "keep_current")",
                elapsedMS: self.host.windowShortcutElapsedMS(since: refreshStartedAt), success: true, detail: "source=\(source)")
        }
    }

    func refreshWorkspaceSelectionForActivation(focusedWorkspaceID: String?) {
        guard case .workspace(let targetWorkspaceID)? = Self.activationSelectionTarget(focusedWorkspaceID: focusedWorkspaceID) else {
            // No tracked focused window: the summon carries no view intent, so re-render the current pane
            // so its contents are fresh and change nothing about which pane is shown. `refreshSelection`
            // would re-resolve the pane from the selection, which is more than a summon is allowed to do.
            host.rerenderVisibleDetailPane()
            return
        }
        guard let (_, workspace) = host.findWorkspace(id: targetWorkspaceID) else { return }
        if host.selectedWorkspaceID == targetWorkspaceID, !host.showingAlerts, !host.showingSettings {
            host.refreshSelection()
            return
        }
        host.selectWorkspace(workspace)
    }
}

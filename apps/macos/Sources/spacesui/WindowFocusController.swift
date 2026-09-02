import AppKit
import Carbon
import Foundation
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalui
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

    init(host: AppKitController) {
        self.host = host
    }

    /// Cancels in-flight deferred work owned by this controller. Called from
    /// `AppKitController.applicationWillTerminate` so a pending selection refresh never fires after
    /// the app starts tearing down.
    func cancelDeferredWork() {
        deferredHotkeySelectionRefreshTask?.cancel()
    }

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
        guard let overview = host.overview(forWorkspaceID: workspaceID), let detail = AppKitController.workspaceDetail(workspaceID, in: overview) else { return nil }
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
        let resolved = await resolvingAfterFreshSidebarSnapshot { () -> (context: FocusableWindowContext, target: AppKitController.WorkspaceRunShortcutTarget)? in
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
        let resolution = AppKitController.windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
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
        let resolution = AppKitController.windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
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

    // In-memory window-cycle state (a "window" is a client concept). The cursor remembers
    // the last-focused target per workspace, recent cursors provide MRU ordering at the
    // start of a cycle burst, and the cycle session preserves that burst's rotation order
    // across rapid presses. MainActor-isolated, so no lock is needed.
    private static let maxWindowNavigationRecentCursorCount = 128
    private var windowNavigationCursorByWorkspace: [String: WorkspaceWindowCycle.Cursor] = [:]
    private var windowNavigationRecentCursorsByWorkspace: [String: [WorkspaceWindowCycle.Cursor]] = [:]
    private var windowNavigationCycleSessionByWorkspace: [String: WorkspaceWindowCycle.CycleSession] = [:]

    /// Cycles focus to the next/previous window of a workspace, entirely client-side:
    /// rebuilds the focusable targets from the workspace's overview, resolves the current
    /// target from the focused terminal session / frontmost Chrome tab / remembered
    /// cursor, advances, and focuses through the shared `executeWindowFocusResolution`.
    // Not private: AppKitController's `handleCycleWorkspaceWindowIPC` calls this from a different
    // file in the same module (cross-file `private` isn't visible).
    func cycleWorkspaceWindow(workspaceID: String, delta: Int, preferredTerminalSessionID: String?, requestID: String? = nil) async {
        let cycleStartedAt = Date()
        let direction = delta > 0 ? "next" : "previous"
        // The real-system E2E waits for this `window_cycle` perf line, so emit it on both
        // success and failure (matching the orchestrator's format) — it is a parsed surface.
        func logCycleMetric(target: String, success: Bool, detail extraDetail: String = "") {
            let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
            let suffix = extraDetail.isEmpty ? "" : " \(extraDetail)"
            TerminalPerformance.logWorkspaceMetric(
                "window_cycle", workspaceID: workspaceID, target: target, elapsedMS: host.windowShortcutElapsedMS(since: cycleStartedAt), success: success,
                detail: "direction=\(direction)\(requestDetail)\(suffix)")
        }
        guard let overview = host.overview(forWorkspaceID: workspaceID), let detail = AppKitController.workspaceDetail(workspaceID, in: overview) else {
            logCycleMetric(target: "none", success: false)
            return
        }
        let cycleSession = validCycleSession(workspaceID: workspaceID)
        let targetResolutionStartedAt = Date()
        let browserCycleState = await host.browserSessions.trackedBrowserCycleState(workspaceID: workspaceID, detail: detail)
        let openTerminalSessionIDs = Set(host.panelCoordinator.openTerminalSessionIDs(workspaceID: workspaceID))

        // Cycle over the same base targets the numbered shortcuts use, limited to running
        // windows (open browsers, running processes/terminals, agents) and ordered by MRU
        // at the start of the burst — not launch actions.
        let targets = Self.cycleWindowTargets(
            detail: detail, browserSessions: browserCycleState.openBrowserSessions, openTerminalSessionIDs: openTerminalSessionIDs)
        let targetResolutionMS = host.windowShortcutElapsedMS(since: targetResolutionStartedAt)
        let resolutionDetail =
            "target_resolution_ms=\(targetResolutionMS) client_db_lookup_ms=\(browserCycleState.clientDBLookupMS) chrome_applescript_ms=\(browserCycleState.chromeAppleScriptMS) tracked_browser_windows=\(browserCycleState.trackedWindowCount) tracked_browser_tabs=\(browserCycleState.trackedTabCount) open_terminal_panes=\(openTerminalSessionIDs.count)"
        guard !targets.isEmpty else {
            logCycleMetric(target: "none", success: false, detail: resolutionDetail)
            return
        }

        let cursorKeys = targets.map { Self.cycleCursorKey(for: $0, detail: detail) }
        let cursor = windowNavigationCursorByWorkspace[workspaceID]
        let frontmostBrowserURL = (preferredTerminalSessionID?.isEmpty == false) ? nil : browserCycleState.frontmostURL
        let configuredBrowserTargetURLs = BrowserSessionCoordinator.browserSessionTargetURLs(resolvedSessions: detail.config.resolvedBrowserSessions)
        let currentIndex = Self.cycleCurrentIndex(
            targets: targets, detail: detail, focusedTerminalSessionID: preferredTerminalSessionID, frontmostBrowserURL: frontmostBrowserURL,
            browserTargetURLs: configuredBrowserTargetURLs, cursorKeys: cursorKeys, cursor: cursor)
        if let currentIndex { rememberWindowNavigationCursor(cursorKeys[currentIndex], workspaceID: workspaceID, preserveWindowCycleSession: true) }
        let ordering = WorkspaceWindowCycle.cycleOrdering(
            cursors: cursorKeys, currentIndex: currentIndex, session: cycleSession,
            recentCursors: windowNavigationRecentCursorsByWorkspace[workspaceID] ?? [])
        let orderedTargets = ordering.indices.map { targets[$0] }
        let orderedCursors = ordering.indices.map { cursorKeys[$0] }
        guard !orderedTargets.isEmpty else {
            logCycleMetric(target: "none", success: false, detail: resolutionDetail)
            return
        }
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
            let resolution = AppKitController.windowShortcutTargetResolution(
                orderedTargets[candidateIndex], workspaceID: workspaceID, detail: detail, overview: overview)
            if await executeWindowFocusResolution(
                resolution, requestID: requestID, preferredTarget: orderedTargets[candidateIndex], preferredDetail: detail,
                preserveWindowCycleSession: true)
            {
                didFocus = true
                resolvedIndex = candidateIndex
                break
            }
        }
        guard didFocus else {
            logCycleMetric(target: Self.cycleDebugName(for: orderedTargets[startIndex], detail: detail), success: false, detail: resolutionDetail)
            return
        }

        windowNavigationCursorByWorkspace[workspaceID] = orderedCursors[resolvedIndex]
        windowNavigationCycleSessionByWorkspace[workspaceID] = WorkspaceWindowCycle.CycleSession(
            orderedCursors: orderedCursors, currentIndex: resolvedIndex, lastUsedAt: Date())
        logCycleMetric(target: Self.cycleDebugName(for: orderedTargets[resolvedIndex], detail: detail), success: true, detail: resolutionDetail)
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

    private func validCycleSession(workspaceID: String) -> WorkspaceWindowCycle.CycleSession? {
        guard let session = windowNavigationCycleSessionByWorkspace[workspaceID] else { return nil }
        guard Date().timeIntervalSince(session.lastUsedAt) <= WorkspaceWindowCycle.cycleSessionTimeout else {
            windowNavigationCycleSessionByWorkspace.removeValue(forKey: workspaceID)
            return nil
        }
        return session
    }

    /// Stable per-target identity used to remember the cursor and preserve cycle order.
    nonisolated static func cycleCursorKey(for target: AppKitController.WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel) -> String {
        switch target.kind {
        case .browser: return "browser:\(target.targetURL ?? "")"
        case .process: return "process:\(target.processID ?? "")"
        case .window: return "terminal:\(cycleTargetSessionID(for: target, detail: detail) ?? String(target.windowListIndex ?? -1))"
        case .agent: return "agent:\(target.agentWindow?.id ?? "")"
        case .missingConfiguredProcess: return "missing:\(target.processKey ?? "")"
        }
    }

    nonisolated private static func cycleTargetSessionID(for target: AppKitController.WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel)
        -> String?
    {
        switch target.kind {
        case .process: return detail.processRows.first(where: { ($0.processID ?? $0.id) == target.processID })?.sessionID
        case .window:
            guard let index = target.windowListIndex, detail.terminalRows.indices.contains(index) else { return nil }
            return detail.terminalRows[index].sessionID
        case .agent: return detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == target.agentWindow?.id })?.sessionID
        case .browser, .missingConfiguredProcess: return nil
        }
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
        _ target: AppKitController.WorkspaceRunShortcutTarget, workspaceID: String, detail: SpacesDeviceWorkspaceDetailViewModel, preserveWindowCycleSession: Bool
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
        let currentCursor = windowNavigationCursorByWorkspace[workspaceID]
        if let currentCursor, let target = matches.first(where: { Self.cycleCursorKey(for: $0, detail: context.detail) == currentCursor }),
            rememberWindowNavigationTargetIfCycleable(
                target, workspaceID: workspaceID, detail: context.detail, preserveWindowCycleSession: preserveWindowCycleSession)
        {
            return
        }
        let recentCursors = windowNavigationRecentCursorsByWorkspace[workspaceID] ?? []
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
        guard !cursor.isEmpty else { return }
        windowNavigationCursorByWorkspace[workspaceID] = cursor
        var cursors = windowNavigationRecentCursorsByWorkspace[workspaceID] ?? []
        cursors.removeAll { $0 == cursor }
        cursors.insert(cursor, at: 0)
        if cursors.count > Self.maxWindowNavigationRecentCursorCount { cursors.removeLast(cursors.count - Self.maxWindowNavigationRecentCursorCount) }
        windowNavigationRecentCursorsByWorkspace[workspaceID] = cursors
        if !preserveWindowCycleSession { windowNavigationCycleSessionByWorkspace.removeValue(forKey: workspaceID) }
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
    nonisolated private static func cycleDebugName(for target: AppKitController.WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel) -> String {
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

    nonisolated private static func cycleCurrentIndex(
        targets: [AppKitController.WorkspaceRunShortcutTarget], detail: SpacesDeviceWorkspaceDetailViewModel, focusedTerminalSessionID: String?,
        frontmostBrowserURL: String?, browserTargetURLs: [String], cursorKeys: [String], cursor: String?
    ) -> Int? {
        if let focusedTerminalSessionID, !focusedTerminalSessionID.isEmpty {
            let matches = targets.indices.filter { cycleTargetSessionID(for: targets[$0], detail: detail) == focusedTerminalSessionID }
            if !matches.isEmpty {
                if let cursor, let match = matches.first(where: { cursorKeys[$0] == cursor }) { return match }
                return matches.last
            }
        }
        if let frontmostBrowserURL, !frontmostBrowserURL.isEmpty {
            let matches = targets.indices.compactMap { index -> (offset: Int, matchLength: Int)? in
                guard targets[index].kind == .browser, let targetURL = targets[index].targetURL, !targetURL.isEmpty else { return nil }
                let siblingTargetURLs = BrowserSessionCoordinator.browserSessionSiblingTargetURLs(targetURL: targetURL, targetURLs: browserTargetURLs)
                guard
                    let matchLength = BrowserSessionCoordinator.browserObservedURLMatchLength(
                        frontmostBrowserURL, targetURL: targetURL, siblingTargetURLs: siblingTargetURLs, assignedPorts: detail.assignedPorts)
                else { return nil }
                return (index, matchLength)
            }
            if !matches.isEmpty {
                if let cursor, let match = matches.first(where: { cursorKeys[$0.offset] == cursor }) { return match.offset }
                return matches.max(by: { $0.matchLength < $1.matchLength })?.offset
            }
        }
        if let cursor { return cursorKeys.firstIndex(of: cursor) }
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
        guard let selectedWorkspaceID = host.selectedWorkspaceID else { return WindowFocusResolutionContext(resolution: .noWorkspace, target: nil, detail: nil) }
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
        let targets = AppKitController.workspaceShortcutTargets(detail: detail, browserSessions: detail.config.resolvedBrowserSessions.map(AppKitController.localBrowserSession(from:)))
        let target: AppKitController.WorkspaceRunShortcutTarget?
        switch request {
        case .workspaceBrowserSession(_, let targetURL): target = targets.first { $0.kind == .browser && $0.targetURL == targetURL }
        case .workspaceProcess(_, let processID): target = targets.first { $0.kind == .process && $0.processID == processID }
        case .workspaceWindow(_, let index): target = targets.first { $0.kind == .window && $0.windowListIndex == index - 1 }
        case .workspaceMissingConfiguredProcess(_, let processKey):
            target = targets.first {
                $0.kind == .missingConfiguredProcess && AppKitController.normalizedRunRowName($0.processKey ?? "") == AppKitController.normalizedRunRowName(processKey)
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
        _ resolution: AppKitController.DeviceWindowShortcutResolution, requestID: String? = nil, preferredTarget: AppKitController.WorkspaceRunShortcutTarget? = nil,
        preferredDetail: SpacesDeviceWorkspaceDetailViewModel? = nil, preserveWindowCycleSession: Bool = false
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
                guard await host.browserSessions.focusLocalChromeTab(workspaceID: workspaceID, targetURL: targetURL, siblingTargetURLs: siblingTargetURLs)
                else {
                    host.browserSessions.showBrowserSessionFocusFailureError()
                    return false
                }
            }
            AppKitController.setClientActiveWorkspaceID(workspaceID)
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

    @discardableResult private func openOrFocusTerminalTarget(_ request: AppKitController.DeviceTerminalOpenRequest, requestID: String? = nil) async -> Bool {
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
                "terminal_pane_focus", target: "session=\(request.sessionID)", elapsedMS: host.windowShortcutElapsedMS(since: startedAt), success: success,
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

    nonisolated static func terminalOpenRequestNeedsColdResolution(_ request: AppKitController.DeviceTerminalOpenRequest, hasExistingPane: Bool) -> Bool {
        !hasExistingPane && request.shell == nil
    }

    private func runTerminalSessionMutationAndOpenPane(
        workspaceID: String, operation: @Sendable @escaping (SpacesPairedDeviceRecord) throws -> SpacesDeviceAPIResponse
    ) async -> Bool {
        guard let request = await host.runTerminalSessionMutation(workspaceID: workspaceID, operation: operation), await openOrFocusTerminalTarget(request)
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
        let startedAt = Date()
        guard let workspaceID = globalWindowNavigationWorkspaceID(requestID: requestID) else {
            host.logPerfMetric(
                "global_window_navigation", target: "workspace=nil", elapsedMS: host.windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "direction=\(direction > 0 ? "next" : "previous") reason=no_workspace request_id=\(requestID)")
            return
        }
        let preferredFocusedBuiltInTerminalSessionID = focusedBuiltInTerminalSessionIDForGlobalNavigation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cycleWorkspaceWindow(
                workspaceID: workspaceID, delta: direction > 0 ? 1 : -1, preferredTerminalSessionID: preferredFocusedBuiltInTerminalSessionID,
                requestID: requestID)
            self.host.logPerfMetric(
                "global_window_navigation", target: "workspace=\(workspaceID)", elapsedMS: self.host.windowShortcutElapsedMS(since: startedAt),
                success: true, detail: "direction=\(direction > 0 ? "next" : "previous") request_id=\(requestID)")
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

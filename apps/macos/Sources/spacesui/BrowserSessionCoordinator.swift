import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import systembridge
import workspacecore

/// Owns the browser-session domain: reconciling remote SSH port forwards for a workspace's
/// browser sessions, the open workspace settings dialog's Services section (whose port texts a
/// forward start/stop refreshes in place), focusing or closing the local Chrome tabs those
/// sessions track, and the pure URL-matching helpers that decide whether an observed browser tab
/// or window belongs to a configured browser session. Extracted from `AppKitController` as a
/// behavior-preserving move (part of the ongoing decomposition of that type); `AppKitController`
/// holds this as `browserSessions` and reaches it as `host.browserSessions` from other files
/// (`SidebarController`, `WorkspaceDeletionCoordinator`, `AppKitController+WorkspaceSettingsDialog`,
/// `AppKitController+StopAllQuit`, `CommandPaletteItems`) that reconcile forwards, read the
/// Services display, or close a workspace's browser windows. The window-cycle and numbered-shortcut
/// focus dispatch (`cycleWorkspaceWindow`, `executeWindowFocusResolution`, `cycleCurrentIndex`) live
/// on `WindowFocusController`, routing their browser-session-specific work through this type's instance
/// methods and pure static helpers.
@MainActor final class BrowserSessionCoordinator {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
    }

    private let browserSSHForwardManager = BrowserSSHForwardManager()
    private var remoteBrowserForwardRevisions: [String: Int] = [:]

    // The open workspace settings dialog's Services section, kept so an SSH forward start/stop can
    // refresh the rows' port texts in place instead of rebuilding the section. The section object is
    // owned by its view (RowSectionCard.retain), so the weak reference clears itself when the dialog
    // closes. Set from the workspace settings dialog, which lives in a separate file, so these are
    // module-internal rather than private.
    weak var visibleWorkspacePortsSection: PortsSection?
    var visiblePortsWorkspaceID: String?

    /// The live SSH-forward manager, exposed so `AppKitController.applicationWillTerminate` can stop
    /// every forward on quit and `executeWindowFocusResolution` can route a remote browser-session
    /// focus's URL through the same manager off the main actor.
    var forwardManager: BrowserSSHForwardManager { browserSSHForwardManager }

    /// Stops every live SSH forward. Called from `AppKitController.applicationWillTerminate`.
    func stopAllForwards() { browserSSHForwardManager.stopAll() }

    /// Internal rather than `private`: `WindowFocusController.cycleWorkspaceWindow` reads this result of
    /// `trackedBrowserCycleState` to resolve the window-cycle target and log its metric.
    struct BrowserCycleState: Sendable {
        let openBrowserSessions: [BrowserSession]
        let frontmostURL: String?
        let clientDBLookupMS: Int
        let chromeAppleScriptMS: Int
        let trackedWindowCount: Int
        let trackedTabCount: Int
    }

    private struct BrowserFocusResult: Sendable {
        let focused: Bool
        let path: String
        let clientDBLookupMS: Int
        let clientDBWriteMS: Int
        let chromeAppleScriptMS: Int
    }

    /// A tab this app opened or adopted for a workspace browser session, keyed by the Chrome window
    /// id its target URL was last observed in. Used only by
    /// `closeLocalBrowserSessionWindowsSynchronously` to scope which tabs a stop/restart/delete closes.
    struct BrowserSessionWindowTracking: Equatable, Sendable {
        let targetURL: String
        let windowID: Int
    }

    func reconcileRemoteBrowserForwards(device: SpacesPairedDeviceRecord, overview: SpacesDeviceOverviewPayload) {
        guard device.id != host.deviceModel.localDeviceID else { return }
        let manager = browserSSHForwardManager
        let revision = nextRemoteBrowserForwardRevision(deviceID: device.id)
        Task.detached(priority: .utility) { [weak self] in
            manager.reconcile(device: device, overview: overview, revision: revision)
            await self?.refreshVisibleServicePortDisplays(deviceID: device.id)
        }
    }

    func stopRemoteBrowserForwards(deviceID: String) {
        guard deviceID != host.deviceModel.localDeviceID else { return }
        let manager = browserSSHForwardManager
        let revision = nextRemoteBrowserForwardRevision(deviceID: deviceID)
        Task.detached(priority: .utility) { [weak self] in
            manager.stop(deviceID: deviceID, revision: revision)
            await self?.refreshVisibleServicePortDisplays(deviceID: deviceID)
        }
    }

    private func nextRemoteBrowserForwardRevision(deviceID: String) -> Int {
        let next = (remoteBrowserForwardRevisions[deviceID] ?? 0) + 1
        remoteBrowserForwardRevisions[deviceID] = next
        return next
    }

    /// Live SSH-forward snapshots for a workspace's services: remote workspaces read the forward
    /// manager, local workspaces have no forwards (their assigned port is already local).
    func workspaceServiceForwards(workspaceID: String) -> [BrowserSSHForwardManager.ServiceForwardSnapshot] {
        guard let workspaceDeviceID = host.deviceID(forWorkspaceID: workspaceID), host.isRemoteDeviceID(workspaceDeviceID) else { return [] }
        return browserSSHForwardManager.forwardedServicePorts(deviceID: workspaceDeviceID, workspaceID: workspaceID)
    }

    /// Refreshes the open workspace settings dialog's Services rows' port texts after an SSH forward
    /// for `deviceID` starts or stops. Reloads the section in place (preserving open editors); when
    /// no workspace settings dialog is open the weak section reference is nil and this is a no-op.
    ///
    /// Internal rather than `private`: `WindowFocusController.executeWindowFocusResolution` also calls this
    /// after routing a remote browser session's URL through a freshly reconciled forward, so the open
    /// dialog's port text is current the moment the user focuses that session.
    func refreshVisibleServicePortDisplays(deviceID: String) {
        guard let section = visibleWorkspacePortsSection, let workspaceID = visiblePortsWorkspaceID,
            host.deviceID(forWorkspaceID: workspaceID) == deviceID, let workspace = host.deviceWorkspaceSummary(workspaceID: workspaceID)
        else { return }
        section.reload(
            ports: section.currentPorts,
            collapsedDisplayPortTexts: Self.servicePortDisplayTexts(
                assignedPorts: workspace.assignedPorts, forwards: workspaceServiceForwards(workspaceID: workspaceID)))
    }

    /// The Services row port text: `remote:local` while a remote service has a live SSH forward
    /// (e.g. "3000:52341"), otherwise the bare assigned port.
    nonisolated static func servicePortDisplay(assignedPort: Int?, forwardedLocalPort: Int?) -> String? {
        guard let assignedPort, assignedPort > 0 else { return nil }
        guard let forwardedLocalPort else { return String(assignedPort) }
        return "\(assignedPort):\(forwardedLocalPort)"
    }

    nonisolated static func servicePortDisplayTexts(
        assignedPorts: [SpacesDeviceAssignedPort], forwards: [BrowserSSHForwardManager.ServiceForwardSnapshot]
    ) -> [String?] {
        var localPorts: [String: Int] = [:]
        for forward in forwards { localPorts["\(forward.serviceName):\(forward.remotePort)"] = forward.localPort }
        return assignedPorts.map { servicePortDisplay(assignedPort: $0.port, forwardedLocalPort: localPorts["\($0.name):\($0.port)"]) }
    }

    static func browserSessionDisplayURLs(configuredSessions: [BrowserSession], resolvedSessions: [BrowserSession]) -> [String?] {
        var resolvedSessionCursor = 0
        return configuredSessions.map { session in
            guard let rawURL = session.url, !rawURL.isEmpty else { return nil }
            return matchedBrowserSessionResolvedURL(
                configuredSession: session, rawURL: rawURL, resolvedSessions: resolvedSessions, resolvedSessionCursor: &resolvedSessionCursor)
                ?? rawURL
        }
    }

    static func matchedBrowserSessionResolvedURL(
        configuredSession: BrowserSession, rawURL: String, resolvedSessions: [BrowserSession], resolvedSessionCursor: inout Int
    ) -> String? {
        let resolvedURLs = Set(resolvedSessions.compactMap(\.url).filter { !$0.isEmpty })
        return matchedBrowserSessionShortcutURL(
            configuredSession: configuredSession, rawURL: rawURL, resolvedSessions: resolvedSessions, resolvedSessionCursor: &resolvedSessionCursor,
            shortcutIndicesByURL: Dictionary(uniqueKeysWithValues: resolvedURLs.map { ($0, 0) }))
    }

    static func matchedBrowserSessionShortcutURL(
        configuredSession: BrowserSession, rawURL: String, resolvedSessions: [BrowserSession], resolvedSessionCursor: inout Int,
        shortcutIndicesByURL: [String: Int]
    ) -> String? {
        if shortcutIndicesByURL[rawURL] != nil { return rawURL }

        let trimmedName = configuredSession.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty,
            let matched = resolvedSessions.first(where: {
                $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedName && ($0.url.map { shortcutIndicesByURL[$0] != nil } ?? false)
            })?.url
        {
            return matched
        }

        guard rawURL.contains("$") else { return nil }
        while resolvedSessionCursor < resolvedSessions.count {
            let candidate = resolvedSessions[resolvedSessionCursor]
            resolvedSessionCursor += 1
            guard let candidateURL = candidate.url, shortcutIndicesByURL[candidateURL] != nil else { continue }
            return candidateURL
        }
        return nil
    }

    /// Closes the workspace browser-session tabs the app opened or adopted and clears their
    /// tracking rows. Browser-session tab locations are client/desktop-local, so the
    /// daemon cannot close them when a workspace stops — the GUI tears them down here. A no-op when
    /// the workspace has no tracked browser-session tabs.
    ///
    /// Called from two disjoint triggers: the GUI's own stop/restart/delete handlers (eager, and
    /// the only reliable signal for a restart's transient stop), and the sidebar's daemon-observed
    /// transition diff (the net for stop/delete initiated outside this GUI — CLI, MCP, the Device
    /// API, or another device). Idempotent: it clears the tracking rows, so a later reload that
    /// re-observes the same stopped workspace finds nothing to close.
    func closeLocalBrowserSessionWindows(workspaceID: String, configuredBrowserSessionTargetURLs: [String]) {
        Task.detached(priority: .utility) {
            Self.closeLocalBrowserSessionWindowsSynchronously(
                workspaceID: workspaceID, configuredBrowserSessionTargetURLs: configuredBrowserSessionTargetURLs)
        }
    }

    nonisolated static func closeLocalBrowserSessionWindowsSynchronously(workspaceID: String, configuredBrowserSessionTargetURLs: [String]) {
        let store = ClientBrowserWindowIDStore()
        let chrome = ChromeAdapter()
        closeLocalBrowserSessionWindowsSynchronously(
            workspaceID: workspaceID, configuredBrowserSessionTargetURLs: configuredBrowserSessionTargetURLs,
            trackedWindowIDs: {
                try store.windowIDs(workspaceID: workspaceID).map { BrowserSessionWindowTracking(targetURL: $0.targetURL, windowID: $0.windowID) }
            }, chromeIsRunning: { chrome.isRunning() },
            closeMatchingTabsInWindow: { windowID, urlPrefix, excludedURLPrefixes in
                try chrome.closeMatchingTabsInWindow(windowID: windowID, urlPrefix: urlPrefix, excludingURLPrefixes: excludedURLPrefixes)
            }, clearTrackedWindowIDs: { try store.clearAll(workspaceID: workspaceID) })
    }

    nonisolated static func closeLocalBrowserSessionWindowsSynchronously(
        workspaceID: String, configuredBrowserSessionTargetURLs: [String], trackedWindowIDs: () throws -> [BrowserSessionWindowTracking],
        chromeIsRunning: () -> Bool, closeMatchingTabsInWindow: (Int, String, [String]) throws -> Bool, clearTrackedWindowIDs: () throws -> Void
    ) {
        guard let tracked = try? trackedWindowIDs(), !tracked.isEmpty else { return }
        // This check avoids launching Chrome just to clean up tabs that disappeared when the user quit Chrome.
        if chromeIsRunning() {
            let teardownTargetURLs = browserSessionTeardownTargetURLs(
                configuredTargetURLs: configuredBrowserSessionTargetURLs, trackedTargetURLs: tracked.map(\.targetURL))
            for entry in tracked {
                // The URL guard keeps a stale reused Chrome window id from closing an unrelated user tab.
                _ = try? closeMatchingTabsInWindow(
                    entry.windowID, entry.targetURL, browserSessionSiblingTargetURLs(targetURL: entry.targetURL, targetURLs: teardownTargetURLs))
            }
        }
        try? clearTrackedWindowIDs()
    }

    /// Internal rather than `private`: `AppKitController.performRestartWorkspace`,
    /// `performStopWorkspace`, and `deleteWorkspace` each capture a workspace's configured browser
    /// target URLs before their mutation starts, so the ones closed on success reflect the overview at
    /// that point rather than whatever it becomes by the time the mutation resolves.
    func configuredBrowserSessionTargetURLsForTeardown(workspaceID: String) -> [String] {
        Self.browserSessionTargetURLs(workspaceID: workspaceID, overview: host.overview(forWorkspaceID: workspaceID))
    }

    nonisolated static func browserSessionDisplayName(for targetURL: String?, sessions: [BrowserSession]) -> String? {
        guard let targetURL, !targetURL.isEmpty else { return nil }
        var bestMatch: (length: Int, name: String)?
        for session in sessions {
            guard let prefix = session.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty, !name.isEmpty, targetURL.hasPrefix(prefix)
            else { continue }
            if let bestMatch, bestMatch.length >= prefix.count { continue }
            bestMatch = (length: prefix.count, name: name)
        }
        return bestMatch?.name
    }

    /// Reports a browser-session focus that Chrome refused. The permission is read at
    /// failure time so the message matches the current grant.
    ///
    /// Internal rather than `private`: `WindowFocusController.executeWindowFocusResolution` calls this
    /// when a local or (post-routing) remote Chrome focus attempt fails.
    func showBrowserSessionFocusFailureError() {
        host.showError(
            WorkspaceError.invalidArgument(message: Self.browserSessionFocusFailureMessage(automationStatus: ChromeAutomationPermission.status())))
    }

    /// Message for a browser-session focus that Chrome refused. Workspace browser sessions are a
    /// Chrome feature (Spaces tracks and groups their tabs by Chrome window id), so a failure is
    /// reported rather than redirected to another browser. A denied Automation permission is the
    /// one failure the user can fix themselves, so it names the setting; every other cause
    /// (Chrome missing, not running, or refusing the script) gets the plain message.
    nonisolated static func browserSessionFocusFailureMessage(automationStatus: ChromeAutomationStatus) -> String {
        switch automationStatus {
        case .denied:
            return
                "Spaces could not open this browser session because it is not allowed to control Google Chrome. Allow Spaces to control Google Chrome in System Settings > Privacy & Security > Automation."
        case .granted, .notDetermined, .unavailable:
            return
                // Not "installed and running": scripting a quit Chrome launches it, so a failure
                // here means Chrome is missing or cannot be scripted, never merely closed.
                "Spaces could not open this browser session in Google Chrome. Workspace browser sessions open in Google Chrome; make sure it is installed."
        }
    }

    /// Focuses the local Chrome tab for a workspace browser session. Browser-session window ids are
    /// client state keyed by resolved URL; multiple browser sessions in the same workspace may point
    /// at the same Chrome window so they stay grouped as tabs. Re-focus first uses the tracked window
    /// id for the fast path, then scans all Chrome windows for a matching URL so a tab the user moved
    /// by hand is adopted into tracking instead of duplicated. Workspace browser sessions are a Chrome
    /// feature; when Chrome cannot be scripted, the failure is reported to the caller rather than
    /// redirected to another browser. Remote service sessions use this after their URL has been
    /// routed through the Mac Caddy router.
    ///
    /// Internal rather than `private`: `WindowFocusController.executeWindowFocusResolution` calls this for
    /// both the local and (post-routing) remote focus paths.
    func focusLocalChromeTab(workspaceID: String, targetURL: String, siblingTargetURLs: [String]) async -> Bool {
        let startedAt = Date()
        let result: BrowserFocusResult = await Task.detached(priority: .userInitiated) {
            let chrome = ChromeAdapter()
            let store = ClientBrowserWindowIDStore()
            let dbLookupStartedAt = Date()
            let trackedEntries = ((try? store.windowIDs(workspaceID: workspaceID)) ?? []).filter { $0.windowID > 0 }
            let trackedID = trackedEntries.first(where: { BrowserSessionCoordinator.browserSessionTargetURL($0.targetURL, matches: targetURL) })?
                .windowID
            let clientDBLookupMS = TerminalPerformance.elapsedMS(since: dbLookupStartedAt)
            var chromeAppleScriptMS = 0
            var clientDBWriteMS = 0
            if let trackedID {
                let chromeStartedAt = Date()
                let didFocus =
                    (try? chrome.focusMatchingTabInWindow(windowID: trackedID, urlPrefix: targetURL, excludingURLPrefixes: siblingTargetURLs))
                    ?? false
                chromeAppleScriptMS += TerminalPerformance.elapsedMS(since: chromeStartedAt)
                if didFocus {
                    return BrowserFocusResult(
                        focused: true, path: "focused_tracked", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                        chromeAppleScriptMS: chromeAppleScriptMS)
                }
            }

            let allWindowFocusStartedAt = Date()
            let relocatedMatch = try? chrome.focusFirstMatchingTabMatch(urlPrefix: targetURL, excludingURLPrefixes: siblingTargetURLs)
            chromeAppleScriptMS += TerminalPerformance.elapsedMS(since: allWindowFocusStartedAt)
            if let relocatedMatch {
                let dbWriteStartedAt = Date()
                try? store.setWindowID(workspaceID: workspaceID, targetURL: targetURL, windowID: relocatedMatch.windowID)
                clientDBWriteMS += TerminalPerformance.elapsedMS(since: dbWriteStartedAt)
                return BrowserFocusResult(
                    focused: true, path: "focused_all_windows", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                    chromeAppleScriptMS: chromeAppleScriptMS)
            }

            let candidateWindowIDs = trackedEntries.map(\.windowID)
            let candidateURLPrefixes = trackedEntries.map(\.targetURL)
            let groupedTabStartedAt = Date()
            let groupedWindowID = try? chrome.openTabInFirstAvailableWindow(
                windowIDs: candidateWindowIDs, containingAnyURLPrefix: candidateURLPrefixes, url: targetURL, background: false)
            chromeAppleScriptMS += TerminalPerformance.elapsedMS(since: groupedTabStartedAt)
            if let groupedWindowID {
                let dbWriteStartedAt = Date()
                try? store.setWindowID(workspaceID: workspaceID, targetURL: targetURL, windowID: groupedWindowID)
                clientDBWriteMS += TerminalPerformance.elapsedMS(since: dbWriteStartedAt)
                return BrowserFocusResult(
                    focused: true, path: "opened_grouped_tab", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                    chromeAppleScriptMS: chromeAppleScriptMS)
            }

            let chromeStartedAt = Date()
            let newWindowID = (try? chrome.openWindow(url: targetURL, background: false)) ?? -1
            chromeAppleScriptMS += TerminalPerformance.elapsedMS(since: chromeStartedAt)
            guard newWindowID > 0 else {
                return BrowserFocusResult(
                    focused: false, path: "chrome_failed", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                    chromeAppleScriptMS: chromeAppleScriptMS)
            }
            let dbWriteStartedAt = Date()
            try? store.setWindowID(workspaceID: workspaceID, targetURL: targetURL, windowID: newWindowID)
            clientDBWriteMS += TerminalPerformance.elapsedMS(since: dbWriteStartedAt)
            return BrowserFocusResult(
                focused: true, path: "opened_window", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                chromeAppleScriptMS: chromeAppleScriptMS)
        }.value
        host.logPerfMetric(
            "browser_focus", target: URL(string: targetURL)?.host ?? targetURL, elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: result.focused,
            detail:
                "path=\(result.path) client_db_lookup_ms=\(result.clientDBLookupMS) client_db_write_ms=\(result.clientDBWriteMS) chrome_applescript_ms=\(result.chromeAppleScriptMS)"
        )
        return result.focused
    }

    /// Resolves the workspace of the focused desktop window when it is a Chrome browser window, by
    /// matching the frontmost tab URL to a configured browser session in the overview. Called from
    /// `AppKitController.clientWorkspaceIDForFocusedWindow`.
    nonisolated static func workspaceIDForObservedBrowserURL(_ activeURL: String, in overviews: [SpacesDeviceOverviewPayload]) -> String? {
        var best: (workspaceID: String, prefixLength: Int)?
        for overview in overviews {
            for workspace in overview.workspaces {
                let configuredTargetURLs = browserSessionTargetURLs(resolvedSessions: workspace.config.resolvedBrowserSessions)
                for session in workspace.config.resolvedBrowserSessions {
                    guard let url = session.url, !url.isEmpty else { continue }
                    let siblingTargetURLs = browserSessionSiblingTargetURLs(targetURL: url, targetURLs: configuredTargetURLs)
                    guard
                        let matchLength = browserObservedURLMatchLength(
                            activeURL, targetURL: url, siblingTargetURLs: siblingTargetURLs, assignedPorts: workspace.assignedPorts)
                    else { continue }
                    if best == nil || matchLength > best!.prefixLength { best = (workspace.id, matchLength) }
                }
            }
        }
        return best?.workspaceID
    }

    /// Builds the tracked-window/frontmost-tab snapshot `WindowFocusController.cycleWorkspaceWindow` needs
    /// to decide which of a workspace's configured browser sessions count as open for the cycle: a
    /// session counts only when both a tracked Chrome window and an open tab still match its target
    /// URL, so a session whose window the user closed by hand drops out of the cycle order.
    ///
    /// Internal rather than `private`: `WindowFocusController.cycleWorkspaceWindow` calls this before
    /// building the cycle's target list.
    func trackedBrowserCycleState(workspaceID: String, detail: SpacesDeviceWorkspaceDetailViewModel) async -> BrowserCycleState {
        let resolvedSessions = detail.config.resolvedBrowserSessions
        guard !resolvedSessions.isEmpty else {
            return BrowserCycleState(
                openBrowserSessions: [], frontmostURL: nil, clientDBLookupMS: 0, chromeAppleScriptMS: 0, trackedWindowCount: 0, trackedTabCount: 0)
        }
        return await Task.detached(priority: .userInitiated) {
            let dbStartedAt = Date()
            let trackedWindows = ((try? ClientBrowserWindowIDStore().windowIDs(workspaceID: workspaceID)) ?? []).filter { $0.windowID > 0 }
            let clientDBLookupMS = TerminalPerformance.elapsedMS(since: dbStartedAt)
            guard !trackedWindows.isEmpty else {
                return BrowserCycleState(
                    openBrowserSessions: [], frontmostURL: nil, clientDBLookupMS: clientDBLookupMS, chromeAppleScriptMS: 0, trackedWindowCount: 0,
                    trackedTabCount: 0)
            }

            let chrome = ChromeAdapter()
            let chromeStartedAt = Date()
            let snapshot =
                (try? chrome.tabSnapshot(inWindowIDs: trackedWindows.map(\.windowID))) ?? ChromeTabSnapshot(tabs: [], frontmostActiveTabURL: nil)
            let chromeAppleScriptMS = TerminalPerformance.elapsedMS(since: chromeStartedAt)
            let openBrowserSessions = Self.openBrowserSessionsForCycle(
                resolvedSessions: resolvedSessions, assignedPorts: detail.assignedPorts, trackedTargetURLs: trackedWindows.map(\.targetURL),
                openTabURLs: snapshot.tabs.map(\.url))
            return BrowserCycleState(
                openBrowserSessions: openBrowserSessions, frontmostURL: snapshot.frontmostActiveTabURL, clientDBLookupMS: clientDBLookupMS,
                chromeAppleScriptMS: chromeAppleScriptMS, trackedWindowCount: trackedWindows.count, trackedTabCount: snapshot.tabs.count)
        }.value
    }

    nonisolated static func openBrowserSessionsForCycle(
        resolvedSessions: [SpacesDeviceBrowserSession], assignedPorts: [SpacesDeviceAssignedPort], trackedTargetURLs: [String], openTabURLs: [String]
    ) -> [BrowserSession] {
        let configuredTargetURLs = browserSessionTargetURLs(resolvedSessions: resolvedSessions)
        return resolvedSessions.compactMap { session -> BrowserSession? in
            guard let url = session.url, !url.isEmpty else { return nil }
            let siblingTargetURLs = browserSessionSiblingTargetURLs(targetURL: url, targetURLs: configuredTargetURLs)
            guard
                trackedTargetURLs.contains(where: {
                    browserObservedURL($0, matchesBrowserSessionTargetURL: url, excluding: siblingTargetURLs, assignedPorts: assignedPorts)
                })
            else { return nil }
            guard
                openTabURLs.contains(where: {
                    browserObservedURL($0, matchesBrowserSessionTargetURL: url, excluding: siblingTargetURLs, assignedPorts: assignedPorts)
                })
            else { return nil }
            return AppKitController.localBrowserSession(from: session)
        }
    }

    nonisolated static func browserSessionTargetURLs(resolvedSessions: [SpacesDeviceBrowserSession], including targetURL: String? = nil) -> [String] {
        var values = resolvedSessions.compactMap(\.url)
        if let targetURL { values.append(targetURL) }
        return uniqueBrowserSessionTargetURLs(values)
    }

    nonisolated static func browserSessionTargetURLs(workspaceID: String, targetURL: String, overview: SpacesDeviceOverviewPayload?) -> [String] {
        browserSessionTargetURLs(
            resolvedSessions: overview.flatMap { AppKitController.workspaceDetail(workspaceID, in: $0)?.config.resolvedBrowserSessions } ?? [],
            including: targetURL)
    }

    nonisolated static func browserSessionTargetURLs(workspaceID: String, overview: SpacesDeviceOverviewPayload?) -> [String] {
        browserSessionTargetURLs(
            resolvedSessions: overview.flatMap { AppKitController.workspaceDetail(workspaceID, in: $0)?.config.resolvedBrowserSessions } ?? [])
    }

    nonisolated static func browserSessionTeardownTargetURLs(configuredTargetURLs: [String], trackedTargetURLs: [String]) -> [String] {
        uniqueBrowserSessionTargetURLs(configuredTargetURLs + trackedTargetURLs)
    }

    nonisolated private static func uniqueBrowserSessionTargetURLs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    nonisolated static func browserSessionSiblingTargetURLs(targetURL: String, targetURLs: [String]) -> [String] {
        guard !targetURL.isEmpty else { return [] }
        var seen = Set<String>()
        return targetURLs.filter { candidate in
            guard !candidate.isEmpty, !browserSessionTargetURL(candidate, matches: targetURL), candidate.hasPrefix(targetURL),
                seen.insert(candidate).inserted
            else { return false }
            return true
        }
    }

    nonisolated static func browserSessionTargetURL(_ candidateURL: String, matches targetURL: String) -> Bool {
        guard !candidateURL.isEmpty, !targetURL.isEmpty else { return false }
        return browserTabURLIsExactTarget(candidateURL, targetURL: targetURL)
    }

    nonisolated static func browserTabURL(_ tabURL: String, matchesBrowserSessionTargetURL targetURL: String, excluding siblingTargetURLs: [String])
        -> Bool
    {
        guard !targetURL.isEmpty else { return false }
        if browserTabURLIsExactTarget(tabURL, targetURL: targetURL) { return true }
        guard tabURL.hasPrefix(targetURL) else { return false }
        return !siblingTargetURLs.contains { siblingTargetURL in !siblingTargetURL.isEmpty && tabURL.hasPrefix(siblingTargetURL) }
    }

    nonisolated static func browserObservedURL(
        _ observedURL: String, matchesBrowserSessionTargetURL targetURL: String, excluding siblingTargetURLs: [String],
        assignedPorts: [SpacesDeviceAssignedPort]
    ) -> Bool {
        browserObservedURLMatchLength(observedURL, targetURL: targetURL, siblingTargetURLs: siblingTargetURLs, assignedPorts: assignedPorts) != nil
    }

    /// Internal rather than `private`: `WindowFocusController.cycleCurrentIndex` also needs the match
    /// length (not just whether it matched) to prefer the longest-matching browser target when more
    /// than one configured session's prefix matches the frontmost tab.
    nonisolated static func browserObservedURLMatchLength(
        _ observedURL: String, targetURL: String, siblingTargetURLs: [String], assignedPorts: [SpacesDeviceAssignedPort]
    ) -> Int? {
        if browserTabURL(observedURL, matchesBrowserSessionTargetURL: targetURL, excluding: siblingTargetURLs) { return targetURL.count }
        guard let routedTargetURL = routedBrowserSessionTargetURL(targetURL: targetURL, observedURL: observedURL, assignedPorts: assignedPorts) else {
            return nil
        }
        let routedSiblingTargetURLs = siblingTargetURLs.compactMap {
            routedBrowserSessionTargetURL(targetURL: $0, observedURL: observedURL, assignedPorts: assignedPorts)
        }
        guard browserTabURL(observedURL, matchesBrowserSessionTargetURL: routedTargetURL, excluding: routedSiblingTargetURLs) else { return nil }
        return routedTargetURL.count
    }

    nonisolated private static func routedBrowserSessionTargetURL(targetURL: String, observedURL: String, assignedPorts: [SpacesDeviceAssignedPort])
        -> String?
    {
        BrowserSSHForwardManager.routePlan(
            targetURL: targetURL, assignedPorts: assignedPorts, localRouterPort: URLComponents(string: observedURL)?.port)?.browserURL.absoluteString
    }

    nonisolated private static func browserTabURLIsExactTarget(_ tabURL: String, targetURL: String) -> Bool {
        if tabURL == targetURL { return true }
        guard !targetURL.contains("?"), !targetURL.contains("#") else { return false }
        if targetURL.hasSuffix("/") { return tabURL == String(targetURL.dropLast()) }
        return tabURL == targetURL + "/"
    }
}

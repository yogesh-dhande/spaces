import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    func focusedChromeWorkspaceID(windowID: Int) throws -> String? {
        if chrome.isAvailable(), let activeURL = (try? chrome.frontmostActiveTabURL()) ?? nil {
            var matchingWorkspaceIDs: [String] = []
            for project in try store.projects() {
                let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
                for workspace in workspaces where workspace.isRunning && !workspace.isArchived {
                    let prefixes = try resolvedBrowserSessionPrefixes(project: project, workspace: workspace)
                    if prefixes.contains(where: { activeURL.hasPrefix($0) }) { matchingWorkspaceIDs.append(workspace.id) }
                }
            }
            if let firstMatch = matchingWorkspaceIDs.first { return firstMatch }
        }

        let candidates = try store.windows(windowID: windowID).filter { $0.role == "browser" }
        guard !candidates.isEmpty else { return nil }
        let candidateWorkspaceIDs = Array(Set(candidates.map(\.workspaceID)))
        if candidateWorkspaceIDs.count == 1 { return candidateWorkspaceIDs[0] }
        return candidates.max(by: { lhs, rhs in lhs.lastSeenAt < rhs.lastSeenAt })?.workspaceID
    }

    func browserFocusName(workspaceID: String, targetURL: String?) throws -> String? {
        guard let targetURL = sanitizedFocusName(targetURL) else { return nil }
        let sessions = try resolvedBrowserSessionsForFocusNames(workspaceID: workspaceID)
        if let match = sessions.compactMap({ session -> (name: String, targetURL: String, score: Int)? in
            guard let score = browserURLMatchScore(targetURL, targetURL: session.targetURL) else { return nil }
            return (session.name, session.targetURL, score)
        }).max(by: { lhs, rhs in
            if lhs.score == rhs.score { return lhs.targetURL.count < rhs.targetURL.count }
            return lhs.score < rhs.score
        }) {
            return match.name
        }
        return targetURL
    }

    func resolvedBrowserSessionsForFocusNames(workspaceID: String, browserSessions: [BrowserSession]? = nil) throws -> [(
        name: String, targetURL: String
    )] {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let sessions = try browserSessions ?? store.workspaceBrowserSessions(workspaceID: workspace.id)
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
            runtimeManifest: runtimePlan.manifest)
        return try resolveBrowserSessions(sessions, env: env).compactMap { resolved in
            guard let targetURL = sanitizedFocusName(resolved.prefix) else { return nil }
            let name = try requiredConfiguredFocusName(resolved.session.name, kind: "Browser session")
            return (name, targetURL)
        }
    }

    func focusTrackedWindowOrRecoverBrowserWindow(_ window: WindowRecord, workspaceID: String, requestID: String?) throws -> Bool {
        let focused = focusTrackedWindow(window, workspaceID: workspaceID, requestID: requestID)
        guard !focused, window.role == "browser", let targetURL = window.targetURL else { return focused }
        try recoverMissingBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
        return true
    }

    func resolvedBrowserSessionPrefixes(project: ProjectRecord, workspace: WorkspaceRecord) throws -> [String] {
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        guard !sessions.isEmpty else { return [] }
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
            runtimeManifest: runtimePlan.manifest)
        return resolveBrowserSessions(sessions, env: env).map(\.prefix)
    }

    func resolveBrowserSessions(_ sessions: [BrowserSession], env: [String: String]) -> [ResolvedBrowserSession] {
        var resolved: [ResolvedBrowserSession] = []
        var seen = Set<String>()
        for (index, session) in sessions.enumerated() {
            guard let rawURL = session.url?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty else { continue }
            let prefix = applyEnvVars(rawURL, env: env)
            guard !prefix.isEmpty, !seen.contains(prefix) else { continue }
            seen.insert(prefix)
            resolved.append(ResolvedBrowserSession(index: index, prefix: prefix, session: session))
        }
        return resolved
    }

    func markExtractedWindowInvalid(workspaceID: String, sessions: [BrowserSession], index: Int) throws {
        guard sessions.indices.contains(index), let extractedWindow = sessions[index].extractedWindow else { return }
        guard extractedWindow.isValid else { return }
        var updatedSessions = sessions
        updatedSessions[index].extractedWindow = ExtractedBrowserWindowMapping(
            targetURL: extractedWindow.targetURL, windowID: extractedWindow.windowID, isValid: false)
        try store.setWorkspaceBrowserSessions(workspaceID: workspaceID, sessions: updatedSessions)
    }

    func markBrowserWindowMissing(workspaceID: String, targetURL: String, windowID: Int) throws {
        let sessions = try store.workspaceBrowserSessions(workspaceID: workspaceID)
        if let index = sessions.firstIndex(where: { $0.extractedWindow?.windowID == windowID || $0.url == targetURL }) {
            try markExtractedWindowInvalid(workspaceID: workspaceID, sessions: sessions, index: index)
        }
        for window in try store.windows(workspaceID: workspaceID) where window.role == "browser" && window.windowID == windowID {
            try store.deleteWindow(id: window.id)
        }
    }

    func liveBrowserWindows(workspaceID: String, browserPrefixes: [String], forceRefresh: Bool = false) throws -> [WindowRecord] {
        guard !browserPrefixes.isEmpty else { return [] }
        let refreshedAt = currentDate()
        if !forceRefresh {
            if let cached = cachedBrowserWindows(workspaceID: workspaceID, browserPrefixes: browserPrefixes, now: refreshedAt) {
                let cacheAgeMS = Int(refreshedAt.timeIntervalSince(cached.refreshedAt) * 1000)
                logBrowserFocus("workspace=\(workspaceID) scan_cache_hit age_ms=\(cacheAgeMS) rows=\(cached.scanResult.windows.count)")
                return cached.scanResult.windows
            }
        }
        logBrowserFocus("workspace=\(workspaceID) scan_cache_miss force_refresh=\(forceRefresh ? "1" : "0")")
        let scanResult = try scannedBrowserWindows(workspaceID: workspaceID, browserPrefixes: browserPrefixes)
        cacheBrowserWindows(workspaceID: workspaceID, browserPrefixes: browserPrefixes, refreshedAt: refreshedAt, scanResult: scanResult)
        return scanResult.windows
    }

    func cachedBrowserWindows(workspaceID: String, browserPrefixes: [String], now: Date) -> BrowserWindowScanCacheEntry? {
        browserScanCacheLock.lock()
        defer { browserScanCacheLock.unlock() }
        guard let entry = browserWindowScanCacheByWorkspace[workspaceID] else { return nil }
        guard entry.browserPrefixes == browserPrefixes else { return nil }
        let elapsed = now.timeIntervalSince(entry.refreshedAt)
        guard elapsed >= 0, elapsed < browserWindowScanDebounceInterval else { return nil }
        return entry
    }

    func cacheBrowserWindows(workspaceID: String, browserPrefixes: [String], refreshedAt: Date, scanResult: BrowserWindowScanResult) {
        browserScanCacheLock.lock()
        browserWindowScanCacheByWorkspace[workspaceID] = BrowserWindowScanCacheEntry(
            browserPrefixes: browserPrefixes, refreshedAt: refreshedAt, scanResult: scanResult)
        browserScanCacheLock.unlock()
    }

    func focusScannedBrowserTab(workspaceID: String, targetURL: String) throws -> Bool {
        let focusStartedAt = currentDate()
        for attempt in 1...2 {
            guard let target = try scannedBrowserFocusTarget(workspaceID: workspaceID, targetURL: targetURL, forceRefresh: attempt == 2),
                let cachedTarget = cachedScannedBrowserTabTarget(workspaceID: workspaceID, windowID: target.windowID, targetURL: target.matchedURL)
            else {
                logBrowserFocus("workspace=\(workspaceID) indexed_miss target=\(targetURL) attempt=\(attempt)")
                continue
            }

            let focusByIndexStartedAt = currentDate()
            let focused = try chrome.focusTab(windowID: target.windowID, tabIndex: target.tabIndex)
            logBrowserFocus(
                "workspace=\(workspaceID) indexed_focus window=\(target.windowID) tab_index=\(target.tabIndex) attempt=\(attempt) success=\(focused ? "1" : "0") focus_ms=\(elapsedMS(since: focusByIndexStartedAt))"
            )

            if focused {
                let verifyStartedAt = currentDate()
                let activeURL = try chrome.frontmostActiveTabURL()
                let matchesTarget = {
                    guard let activeURL else { return false }
                    return browserURLMatchesTarget(activeURL, targetURL: targetURL)
                }()
                let matchesWorkspace = {
                    guard let activeURL else { return false }
                    return browserURLMatchesWorkspace(activeURL, browserPrefixes: cachedTarget.browserPrefixes)
                }()
                logBrowserFocus(
                    "workspace=\(workspaceID) indexed_verify window=\(target.windowID) tab_index=\(target.tabIndex) attempt=\(attempt) exact_match=\(matchesTarget ? "1" : "0") workspace_match=\(matchesWorkspace ? "1" : "0") verify_ms=\(elapsedMS(since: verifyStartedAt)) url=\(activeURL ?? "")"
                )
                if matchesTarget {
                    logBrowserFocus(
                        "workspace=\(workspaceID) indexed_done window=\(target.windowID) target=\(targetURL) refreshed=\(attempt == 2 ? "1" : "0") elapsed_ms=\(elapsedMS(since: focusStartedAt))"
                    )
                    return true
                }
            }
        }
        logBrowserFocus("workspace=\(workspaceID) indexed_failed target=\(targetURL) elapsed_ms=\(elapsedMS(since: focusStartedAt))")
        return false
    }

    func scannedBrowserFocusTarget(workspaceID: String, targetURL: String, forceRefresh: Bool = false) throws -> ScannedBrowserFocusTarget? {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let browserPrefixes = try resolvedBrowserSessionPrefixes(project: project, workspace: workspace)
        guard !browserPrefixes.isEmpty else { return nil }
        let windows = try liveBrowserWindows(workspaceID: workspaceID, browserPrefixes: browserPrefixes, forceRefresh: forceRefresh)
        let matchedWindow = windows.compactMap { window -> (window: WindowRecord, score: Int)? in
            guard let scannedURL = window.targetURL, let score = browserURLMatchScore(scannedURL, targetURL: targetURL) else { return nil }
            return (window, score)
        }.max(by: { lhs, rhs in
            if lhs.score == rhs.score { return lhs.window.orderIndex > rhs.window.orderIndex }
            return lhs.score < rhs.score
        })?.window
        guard let matchedWindow, let matchedURL = matchedWindow.targetURL, let chromeWindowID = matchedWindow.windowID else { return nil }
        guard let cachedTarget = cachedScannedBrowserTabTarget(workspaceID: workspaceID, windowID: chromeWindowID, targetURL: matchedURL) else {
            return nil
        }
        return ScannedBrowserFocusTarget(windowID: chromeWindowID, tabIndex: cachedTarget.tabIndex, matchedURL: matchedURL)
    }

    func cachedScannedBrowserTabTarget(workspaceID: String, windowID: Int, targetURL: String) -> CachedScannedBrowserTabTarget? {
        browserScanCacheLock.lock()
        defer { browserScanCacheLock.unlock() }
        guard let entry = browserWindowScanCacheByWorkspace[workspaceID] else { return nil }
        let key = "\(windowID):\(targetURL)"
        guard let tabIndex = entry.scanResult.tabIndexByWindowAndURL[key] else { return nil }
        return CachedScannedBrowserTabTarget(tabIndex: tabIndex, browserPrefixes: entry.browserPrefixes)
    }

    func browserURLMatchesWorkspace(_ url: String, browserPrefixes: [String]) -> Bool {
        browserPrefixes.contains(where: { browserURLMatchesTarget(url, targetURL: $0) })
    }

    func browserURLMatchesTarget(_ url: String, targetURL: String) -> Bool { browserURLMatchScore(url, targetURL: targetURL) != nil }

    private struct ComparableBrowserURL {
        let scheme: String
        let host: String
        let port: Int?
        let path: String
    }

    private func comparableBrowserURL(_ raw: String) -> ComparableBrowserURL? {
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(), var host = components.host?.lowercased()
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return ComparableBrowserURL(scheme: scheme, host: host, port: components.port, path: path)
    }

    func browserURLMatchScore(_ url: String, targetURL: String) -> Int? {
        if url == targetURL { return 3_000_000 + targetURL.count }
        if url.hasPrefix(targetURL) { return 2_000_000 + targetURL.count }
        guard let actual = comparableBrowserURL(url), let target = comparableBrowserURL(targetURL) else { return nil }
        guard actual.scheme == target.scheme, actual.host == target.host, actual.port == target.port else { return nil }
        if target.path == "/" { return 1_000_000 }
        if actual.path == target.path { return 1_500_000 + target.path.count }
        if actual.path.hasPrefix(target.path + "/") { return 1_000_000 + target.path.count }
        return nil
    }

    func logBrowserFocus(_ message: String) {
        guard debugLoggingEnabled() else { return }
        Self.writeStandardError("spaces: browser focus \(message)\n")
    }

    func scannedBrowserWindows(workspaceID: String, browserPrefixes: [String]) throws -> BrowserWindowScanResult {
        guard !browserPrefixes.isEmpty else { return BrowserWindowScanResult(windows: [], tabIndexByWindowAndURL: [:]) }
        let scanStartedAt = Date()
        let tabs = try chrome.allTabs()
        struct MatchedTab {
            let tab: ChromeWindowMatch
            let prefixIndex: Int
            let matchScore: Int
        }
        var matchedTabs: [MatchedTab] = []
        var seen = Set<String>()
        for tab in tabs {
            guard
                let matchedPrefix = browserPrefixes.enumerated().compactMap({ index, prefix -> (index: Int, score: Int)? in
                    guard let score = browserURLMatchScore(tab.url, targetURL: prefix) else { return nil }
                    return (index, score)
                }).max(by: { lhs, rhs in
                    if lhs.score == rhs.score { return lhs.index > rhs.index }
                    return lhs.score < rhs.score
                })
            else { continue }
            let key = "\(tab.windowID):\(tab.url)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            matchedTabs.append(MatchedTab(tab: tab, prefixIndex: matchedPrefix.index, matchScore: matchedPrefix.score))
        }
        matchedTabs.sort { lhs, rhs in
            if lhs.prefixIndex != rhs.prefixIndex { return lhs.prefixIndex < rhs.prefixIndex }
            if lhs.matchScore != rhs.matchScore { return lhs.matchScore > rhs.matchScore }
            if lhs.tab.url != rhs.tab.url { return lhs.tab.url < rhs.tab.url }
            if lhs.tab.windowID != rhs.tab.windowID { return lhs.tab.windowID < rhs.tab.windowID }
            return lhs.tab.title < rhs.tab.title
        }
        var browserWindows: [WindowRecord] = []
        var tabIndexByWindowAndURL: [String: Int] = [:]
        for (index, match) in matchedTabs.enumerated() {
            tabIndexByWindowAndURL["\(match.tab.windowID):\(match.tab.url)"] = match.tab.tabIndex
            browserWindows.append(
                WindowRecord(
                    id: UUID().uuidString, workspaceID: workspaceID, app: "Google Chrome",
                    name: try browserFocusName(workspaceID: workspaceID, targetURL: match.tab.url) ?? match.tab.url, detail: match.tab.url,
                    targetURL: match.tab.url, windowID: match.tab.windowID, role: "browser", orderIndex: index, lastSeenAt: nowISO8601()))
        }
        if debugLoggingEnabled() {
            let elapsedMS = Int(Date().timeIntervalSince(scanStartedAt) * 1000)
            Self.writeStandardError(
                "spaces: browser scan workspace=\(workspaceID) tabs=\(tabs.count) matches=\(browserWindows.count) elapsed_ms=\(elapsedMS)\n")
        }
        return BrowserWindowScanResult(windows: browserWindows, tabIndexByWindowAndURL: tabIndexByWindowAndURL)
    }

    func closeTrackedBrowserTab(_ window: WindowRecord) {
        guard window.role == "browser" else { return }
        guard let trackedWindowID = window.windowID else { return }
        _ = try? yabai.closeWindow(id: trackedWindowID)
    }
}

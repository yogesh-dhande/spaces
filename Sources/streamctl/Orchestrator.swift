import Foundation
import appctl
import winmove

public final class StreamOrchestrator {
    private let store: SQLiteStore
    private let windowController: WindowController
    private let appLauncher: AppLauncher
    private let editorAdapter: EditorAdapter
    private let chromeAdapter: ChromeAdapter
    private let terminalAdapter: TerminalAdapter

    public init(
        store: SQLiteStore,
        windowController: WindowController = .init(),
        appLauncher: AppLauncher = .init(),
        editorAdapter: EditorAdapter = .init(),
        chromeAdapter: ChromeAdapter = .init(),
        terminalAdapter: TerminalAdapter = .init()
    ) {
        self.store = store
        self.windowController = windowController
        self.appLauncher = appLauncher
        self.editorAdapter = editorAdapter
        self.chromeAdapter = chromeAdapter
        self.terminalAdapter = terminalAdapter
    }

    public func create(projectName: String, streamName: String, worktreePath: String? = nil) throws -> Stream {
        guard let project = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        if let _ = try store.stream(projectID: project.id, name: streamName) {
            throw StreamctlError.streamAlreadyExists(project: projectName, stream: streamName)
        }

        let resolvedWorktree = worktreePath ?? defaultWorktreePath(project: project, streamName: streamName)
        let worktreesDir = URL(fileURLWithPath: resolvedWorktree).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)

        let branch = streamName
        try runGit(["-C", project.repoRoot, "worktree", "add", "-b", branch, resolvedWorktree])

        let stream = Stream(
            id: UUID(),
            projectID: project.id,
            name: streamName,
            worktreePath: resolvedWorktree
        )
        try store.upsert(stream: stream)

        let seedIdentity = StreamWindowIdentity(
            streamID: stream.id,
            editorMatchTitle: fallbackEditorMatchTitle(stream: stream),
            chromeAnchorURL: project.browserTabs.first,
            terminalTitlePrefix: terminalTitlePrefix(project: project, stream: stream),
            updatedAt: nowISO8601()
        )
        try store.upsert(windowIdentity: seedIdentity)

        return stream
    }

    public func destroy(projectName: String, streamName: String, removeBranch: Bool = false) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)

        try hide(projectName: projectName, streamName: streamName)

        if let anchor = identity?.chromeAnchorURL ?? project.browserTabs.first {
            _ = try? chromeAdapter.closeWindow(anchorURL: anchor)
        }
        let terminalPrefix = identity?.terminalTitlePrefix ?? terminalTitlePrefix(project: project, stream: stream)
        _ = try? terminalAdapter.closeWindows(prefix: terminalPrefix)

        try runGit(["-C", project.repoRoot, "worktree", "remove", "--force", stream.worktreePath])

        if removeBranch {
            _ = try? runGit(["-C", project.repoRoot, "branch", "-D", stream.name])
        }

        try store.deleteStream(id: stream.id)
    }

    public func show(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        let prefix = identity?.terminalTitlePrefix ?? terminalTitlePrefix(project: project, stream: stream)
        let anchorURL = identity?.chromeAnchorURL ?? project.browserTabs.first

        let chromeFound = try anchorURL.map { try chromeAdapter.focusWindow(anchorURL: $0) } ?? false
        let terminalHits = try terminalAdapter.focusWindows(prefix: prefix)

        if chromeFound || terminalHits > 0 {
            try focus(projectName: projectName, streamName: streamName)
        } else {
            try up(projectName: projectName, streamName: streamName)
        }
    }

    public func hide(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        let streamTitlePrefix = identity?.terminalTitlePrefix ?? terminalTitlePrefix(project: project, stream: stream)
        let editorTitle = identity?.editorMatchTitle ?? fallbackEditorMatchTitle(stream: stream)
        let anchorURL = identity?.chromeAnchorURL ?? project.browserTabs.first
        let logger = StreamLogger(stream: stream.name)

        if let anchorURL {
            _ = try? chromeAdapter.hideWindow(anchorURL: anchorURL)
        }
        _ = try? terminalAdapter.hideWindows(prefix: streamTitlePrefix)
        _ = try? windowController.setMinimized(
            target: WindowTarget(
                bundleID: project.defaultEditor.bundleID,
                matchTitle: editorTitle,
                preferFocusedWindow: false
            ),
            minimized: true
        )

        try store.markInactive(stream: stream)
        logger.info("stream hidden")
    }

    public func up(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        try ensureValidWorktree(stream: stream)

        let existingIdentity = try store.windowIdentity(streamID: stream.id)
        let streamTitlePrefix = existingIdentity?.terminalTitlePrefix ?? terminalTitlePrefix(project: project, stream: stream)
        let editorTitle = existingIdentity?.editorMatchTitle ?? fallbackEditorMatchTitle(stream: stream)
        let anchorURL = existingIdentity?.chromeAnchorURL ?? project.browserTabs.first

        let logger = StreamLogger(stream: stream.name)
        logger.info("launching stream")

        try appLauncher.ensureRunning(bundleID: project.defaultEditor.bundleID)
        try appLauncher.ensureRunning(bundleID: project.defaultBrowser.bundleID)
        try appLauncher.ensureRunning(bundleID: project.defaultTerminal.bundleID)

        let resolvedEditorTitle: String
        do {
            try editorAdapter.open(editor: project.defaultEditor, repoRoot: stream.worktreePath)
            let movedEditorWindow = try windowController.moveWindow(
                target: WindowTarget(
                    bundleID: project.defaultEditor.bundleID,
                    matchTitle: editorTitle,
                    preferFocusedWindow: true
                ),
                layout: project.editorLayout
            )
            resolvedEditorTitle = movedEditorWindow.title.isEmpty ? editorTitle : movedEditorWindow.title
        } catch {
            logger.error("editor launch/move failed: \(error.localizedDescription)")
            throw error
        }

        do {
            try chromeAdapter.ensureTabs(urls: project.browserTabs)
            if let anchorURL {
                _ = try? chromeAdapter.focusWindow(anchorURL: anchorURL)
            }
            _ = try windowController.moveWindow(
                target: WindowTarget(bundleID: project.defaultBrowser.bundleID),
                layout: project.browserLayout
            )
        } catch {
            logger.warn("browser setup failed: \(error.localizedDescription)")
        }

        for (index, terminal) in project.terminals.enumerated() {
            do {
                let terminalTitle = terminalWindowTitle(prefix: streamTitlePrefix, index: index)
                try terminalAdapter.openWindow(
                    worktreePath: stream.worktreePath,
                    command: terminal.command,
                    title: terminalTitle
                )
                _ = try windowController.moveWindow(
                    target: WindowTarget(
                        bundleID: project.defaultTerminal.bundleID,
                        matchTitle: terminalTitle,
                        preferFocusedWindow: false
                    ),
                    layout: terminal.layout
                )
            } catch {
                logger.warn("terminal setup failed: \(error.localizedDescription)")
            }
        }

        let nextIdentity = StreamWindowIdentity(
            streamID: stream.id,
            editorMatchTitle: resolvedEditorTitle,
            chromeAnchorURL: anchorURL,
            terminalTitlePrefix: streamTitlePrefix,
            updatedAt: nowISO8601()
        )
        try store.upsert(windowIdentity: nextIdentity)

        try store.markActive(stream: stream)
        logger.info("stream is up")
    }

    public func focus(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        let streamTitlePrefix = identity?.terminalTitlePrefix ?? terminalTitlePrefix(project: project, stream: stream)
        let editorTitle = identity?.editorMatchTitle ?? fallbackEditorMatchTitle(stream: stream)
        let anchorURL = identity?.chromeAnchorURL ?? project.browserTabs.first
        let logger = StreamLogger(stream: stream.name)

        try appLauncher.ensureRunning(bundleID: project.defaultTerminal.bundleID)
        try appLauncher.ensureRunning(bundleID: project.defaultBrowser.bundleID)
        try appLauncher.ensureRunning(bundleID: project.defaultEditor.bundleID)

        _ = try? terminalAdapter.focusWindows(prefix: streamTitlePrefix)
        if let anchorURL {
            _ = try? chromeAdapter.focusWindow(anchorURL: anchorURL)
        } else {
            try appLauncher.activate(bundleID: project.defaultBrowser.bundleID)
        }
        try appLauncher.activate(bundleID: project.defaultEditor.bundleID)

        _ = try? windowController.moveWindow(
            target: WindowTarget(
                bundleID: project.defaultEditor.bundleID,
                matchTitle: editorTitle,
                preferFocusedWindow: true
            ),
            layout: project.editorLayout
        )
        if anchorURL != nil {
            _ = try? windowController.moveWindow(
                target: WindowTarget(bundleID: project.defaultBrowser.bundleID),
                layout: project.browserLayout
            )
        }
        for (index, terminal) in project.terminals.enumerated() {
            let terminalTitle = terminalWindowTitle(prefix: streamTitlePrefix, index: index)
            _ = try? windowController.moveWindow(
                target: WindowTarget(
                    bundleID: project.defaultTerminal.bundleID,
                    matchTitle: terminalTitle,
                    preferFocusedWindow: false
                ),
                layout: terminal.layout
            )
        }

        let refreshedIdentity = StreamWindowIdentity(
            streamID: stream.id,
            editorMatchTitle: editorTitle,
            chromeAnchorURL: anchorURL,
            terminalTitlePrefix: streamTitlePrefix,
            updatedAt: nowISO8601()
        )
        try store.upsert(windowIdentity: refreshedIdentity)

        try store.markActive(stream: stream)
        logger.info("stream focused")
    }

    public func down(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        let streamTitlePrefix = identity?.terminalTitlePrefix ?? terminalTitlePrefix(project: project, stream: stream)
        let anchorURL = identity?.chromeAnchorURL ?? project.browserTabs.first
        let logger = StreamLogger(stream: stream.name)

        if let anchorURL {
            _ = try? chromeAdapter.closeWindow(anchorURL: anchorURL)
        }
        _ = try? terminalAdapter.closeWindows(prefix: streamTitlePrefix)
        try store.markInactive(stream: stream)
        logger.info("stream marked inactive")
    }

    public func list(projectName: String) throws -> [StreamSummary] {
        guard let project = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        return try store.streams(projectID: project.id)
    }

    public func listProjects() throws -> [Project] {
        try store.projects()
    }

    public func createProject(
        name: String,
        repoRoot: String,
        editor: String?,
        browser: String?,
        terminal: String?,
        editorDisplay: Int?,
        editorTile: String?,
        browserDisplay: Int?,
        browserTile: String?,
        browserTabs: [String]
    ) throws -> Project {
        if try store.project(named: name) != nil {
            throw StreamctlError.projectAlreadyExists(name: name)
        }

        let project = Project(
            id: UUID(),
            name: name,
            repoRoot: repoRoot,
            defaultEditor: try parseEditor(editor),
            defaultBrowser: try parseBrowser(browser),
            defaultTerminal: try parseTerminal(terminal),
            editorLayout: WindowLayout(displayIndex: editorDisplay ?? 0, tile: try parseTile(editorTile, fallback: .leftHalf)),
            browserLayout: WindowLayout(displayIndex: browserDisplay ?? 0, tile: try parseTile(browserTile, fallback: .rightHalf)),
            terminals: [],
            browserTabs: browserTabs
        )
        try store.upsert(project: project)
        return project
    }

    public func updateProject(
        name: String,
        repoRoot: String?,
        editor: String?,
        browser: String?,
        terminal: String?,
        editorDisplay: Int?,
        editorTile: String?,
        browserDisplay: Int?,
        browserTile: String?,
        browserTabs: [String]?
    ) throws -> Project {
        guard let current = try store.project(named: name) else {
            throw StreamctlError.missingProject(name: name)
        }

        let project = Project(
            id: current.id,
            name: current.name,
            repoRoot: repoRoot ?? current.repoRoot,
            defaultEditor: try parseEditor(editor, fallback: current.defaultEditor),
            defaultBrowser: try parseBrowser(browser, fallback: current.defaultBrowser),
            defaultTerminal: try parseTerminal(terminal, fallback: current.defaultTerminal),
            editorLayout: WindowLayout(
                displayIndex: editorDisplay ?? current.editorLayout.displayIndex,
                tile: try parseTile(editorTile, fallback: current.editorLayout.tile)
            ),
            browserLayout: WindowLayout(
                displayIndex: browserDisplay ?? current.browserLayout.displayIndex,
                tile: try parseTile(browserTile, fallback: current.browserLayout.tile)
            ),
            terminals: current.terminals,
            browserTabs: browserTabs ?? current.browserTabs
        )
        try store.upsert(project: project)
        return project
    }

    public func deleteProject(name: String) throws {
        guard try store.project(named: name) != nil else {
            throw StreamctlError.missingProject(name: name)
        }
        try store.deleteProject(name: name)
    }

    public func listProjectTerminals(projectName: String) throws -> [TerminalSpec] {
        guard let project = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        return project.terminals
    }

    public func addProjectTerminal(
        projectName: String,
        displayIndex: Int,
        tile: String,
        command: String?
    ) throws -> Project {
        guard let current = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        let spec = TerminalSpec(
            layout: WindowLayout(displayIndex: displayIndex, tile: try parseTile(tile, fallback: .bottomLeft)),
            command: command
        )
        let updated = Project(
            id: current.id,
            name: current.name,
            repoRoot: current.repoRoot,
            defaultEditor: current.defaultEditor,
            defaultBrowser: current.defaultBrowser,
            defaultTerminal: current.defaultTerminal,
            editorLayout: current.editorLayout,
            browserLayout: current.browserLayout,
            terminals: current.terminals + [spec],
            browserTabs: current.browserTabs
        )
        try store.upsert(project: updated)
        return updated
    }

    public func updateProjectTerminal(
        projectName: String,
        index: Int,
        displayIndex: Int?,
        tile: String?,
        command: String?
    ) throws -> Project {
        guard let current = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        guard index >= 0, index < current.terminals.count else {
            throw StreamctlError.invalidArgument(message: "terminal index out of range")
        }

        var terminals = current.terminals
        let existing = terminals[index]
        terminals[index] = TerminalSpec(
            layout: WindowLayout(
                displayIndex: displayIndex ?? existing.layout.displayIndex,
                tile: try parseTile(tile, fallback: existing.layout.tile)
            ),
            command: command ?? existing.command
        )

        let updated = Project(
            id: current.id,
            name: current.name,
            repoRoot: current.repoRoot,
            defaultEditor: current.defaultEditor,
            defaultBrowser: current.defaultBrowser,
            defaultTerminal: current.defaultTerminal,
            editorLayout: current.editorLayout,
            browserLayout: current.browserLayout,
            terminals: terminals,
            browserTabs: current.browserTabs
        )
        try store.upsert(project: updated)
        return updated
    }

    public func removeProjectTerminal(projectName: String, index: Int) throws -> Project {
        guard let current = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        guard index >= 0, index < current.terminals.count else {
            throw StreamctlError.invalidArgument(message: "terminal index out of range")
        }

        var terminals = current.terminals
        terminals.remove(at: index)

        let updated = Project(
            id: current.id,
            name: current.name,
            repoRoot: current.repoRoot,
            defaultEditor: current.defaultEditor,
            defaultBrowser: current.defaultBrowser,
            defaultTerminal: current.defaultTerminal,
            editorLayout: current.editorLayout,
            browserLayout: current.browserLayout,
            terminals: terminals,
            browserTabs: current.browserTabs
        )
        try store.upsert(project: updated)
        return updated
    }

    public func listActive() throws -> [ActiveStreamSummary] {
        try store.activeStreams()
    }

    public func doctor(projectName: String? = nil, streamName: String? = nil) throws -> [StreamDoctorReport] {
        let projects: [Project]
        if let projectName {
            guard let project = try store.project(named: projectName) else {
                throw StreamctlError.missingProject(name: projectName)
            }
            projects = [project]
        } else {
            projects = try store.projects()
        }

        var reports: [StreamDoctorReport] = []
        for project in projects {
            let streams = try store.fullStreams(projectID: project.id)
            for stream in streams where streamName == nil || stream.name == streamName {
                let identity = try store.windowIdentity(streamID: stream.id)
                let editorTitle = identity?.editorMatchTitle ?? fallbackEditorMatchTitle(stream: stream)
                let anchorURL = identity?.chromeAnchorURL ?? project.browserTabs.first
                let terminalPrefix = identity?.terminalTitlePrefix ?? terminalTitlePrefix(project: project, stream: stream)

                let editorFound = windowExists(bundleID: project.defaultEditor.bundleID, matchTitle: editorTitle)
                let chromeFound = (try? anchorURL.map { try chromeAdapter.hasWindow(anchorURL: $0) } ?? false) ?? false
                let terminalCount = (try? terminalAdapter.countWindows(prefix: terminalPrefix)) ?? 0
                let expectedTerminalCount = project.terminals.count

                reports.append(
                    StreamDoctorReport(
                        projectName: project.name,
                        streamName: stream.name,
                        worktreePath: stream.worktreePath,
                        editorMatchTitle: editorTitle,
                        chromeAnchorURL: anchorURL,
                        terminalTitlePrefix: terminalPrefix,
                        identityUpdatedAt: identity?.updatedAt,
                        editorWindowFound: editorFound,
                        chromeWindowFound: chromeFound,
                        terminalWindowCount: terminalCount,
                        expectedTerminalWindowCount: expectedTerminalCount
                    )
                )
            }
        }

        return reports.sorted {
            if $0.projectName == $1.projectName {
                return $0.streamName < $1.streamName
            }
            return $0.projectName < $1.projectName
        }
    }

    private func resolve(projectName: String, streamName: String) throws -> (Project, Stream) {
        guard let project = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        guard let stream = try store.stream(projectID: project.id, name: streamName) else {
            throw StreamctlError.missingStream(project: projectName, stream: streamName)
        }
        return (project, stream)
    }

    private func ensureValidWorktree(stream: Stream) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stream.worktreePath, isDirectory: &isDir), isDir.boolValue else {
            throw StreamctlError.invalidWorktree(path: stream.worktreePath)
        }
    }

    private func terminalTitlePrefix(project: Project, stream: Stream) -> String {
        "agentmux:\(project.name):\(stream.name)"
    }

    private func terminalWindowTitle(prefix: String, index: Int) -> String {
        "\(prefix)#\(index + 1)"
    }

    private func fallbackEditorMatchTitle(stream: Stream) -> String {
        URL(fileURLWithPath: stream.worktreePath).lastPathComponent
    }

    private func defaultWorktreePath(project: Project, streamName: String) -> String {
        let rootURL = URL(fileURLWithPath: project.repoRoot)
        return rootURL
            .appendingPathComponent(".agentmux-worktrees", isDirectory: true)
            .appendingPathComponent(streamName, isDirectory: true)
            .path
    }

    private func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        let out = Pipe()
        let err = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = out
        process.standardError = err

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw StreamctlError.gitCommandFailed(message: message)
        }
    }

    private func windowExists(bundleID: String, matchTitle: String) -> Bool {
        guard let listed = try? windowController.listWindows(bundleID: bundleID) else {
            return false
        }
        let needle = matchTitle.lowercased()
        if let focused = listed.focusedWindow, focused.title.lowercased().contains(needle) {
            return true
        }
        return listed.windows.contains { $0.title.lowercased().contains(needle) }
    }

    private func parseEditor(_ raw: String?, fallback: EditorKind = .windsurf) throws -> EditorKind {
        guard let raw else { return fallback }
        guard let kind = EditorKind(rawValue: raw.lowercased()) else {
            throw StreamctlError.invalidArgument(message: "editor must be one of: windsurf, vscode, cursor")
        }
        return kind
    }

    private func parseBrowser(_ raw: String?, fallback: BrowserKind = .chrome) throws -> BrowserKind {
        guard let raw else { return fallback }
        guard let kind = BrowserKind(rawValue: raw.lowercased()) else {
            throw StreamctlError.invalidArgument(message: "browser must be: chrome")
        }
        return kind
    }

    private func parseTerminal(_ raw: String?, fallback: TerminalKind = .terminal) throws -> TerminalKind {
        guard let raw else { return fallback }
        guard let kind = TerminalKind(rawValue: raw.lowercased()) else {
            throw StreamctlError.invalidArgument(message: "terminal must be: terminal")
        }
        return kind
    }

    private func parseTile(_ raw: String?, fallback: Tile) throws -> Tile {
        guard let raw else { return fallback }
        guard let tile = Tile(rawValue: raw) else {
            throw StreamctlError.invalidArgument(message: "tile must be one of: leftHalf,rightHalf,topLeft,topRight,bottomLeft,bottomRight")
        }
        return tile
    }
}

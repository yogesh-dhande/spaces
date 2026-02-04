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
    private let customAppAdapter: CustomAppAdapter

    public init(
        store: SQLiteStore,
        windowController: WindowController = .init(),
        appLauncher: AppLauncher = .init(),
        editorAdapter: EditorAdapter = .init(),
        chromeAdapter: ChromeAdapter = .init(),
        terminalAdapter: TerminalAdapter = .init(),
        customAppAdapter: CustomAppAdapter = .init()
    ) {
        self.store = store
        self.windowController = windowController
        self.appLauncher = appLauncher
        self.editorAdapter = editorAdapter
        self.chromeAdapter = chromeAdapter
        self.terminalAdapter = terminalAdapter
        self.customAppAdapter = customAppAdapter
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
            windows: [],
            updatedAt: nowISO8601()
        )
        try store.upsert(windowIdentity: seedIdentity)

        return stream
    }

    public func destroy(projectName: String, streamName: String, removeBranch: Bool = false) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        try destroyGenericWindows(project: project, stream: stream, identity: identity)

        try runGit(["-C", project.repoRoot, "worktree", "remove", "--force", stream.worktreePath])

        if removeBranch {
            _ = try? runGit(["-C", project.repoRoot, "branch", "-D", stream.name])
        }

        try store.deleteStream(id: stream.id)
    }

    public func show(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        try showGenericWindows(project: project, stream: stream, identity: identity)
    }

    public func hide(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        try hideGenericWindows(project: project, stream: stream, identity: identity)
    }

    public func up(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        try ensureValidWorktree(stream: stream)

        let existingIdentity = try store.windowIdentity(streamID: stream.id)
        try upGenericWindows(project: project, stream: stream, existingIdentity: existingIdentity)
    }

    public func focus(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        try focusGenericWindows(project: project, stream: stream, identity: identity)
    }

    public func down(projectName: String, streamName: String) throws {
        let (project, stream) = try resolve(projectName: projectName, streamName: streamName)
        let identity = try store.windowIdentity(streamID: stream.id)
        try hideGenericWindows(project: project, stream: stream, identity: identity)
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
            windows: [],
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
            windows: current.windows,
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

    public func listProjectWindows(projectName: String) throws -> [ProjectWindowSpec] {
        guard let project = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        return project.windows
    }

    public func addProjectWindow(
        projectName: String,
        name: String,
        kind: String,
        bundleID: String,
        displayIndex: Int,
        tile: String,
        launchCommand: String?,
        command: String?,
        urls: [String],
        matchTitle: String?,
        editorKind: String?
    ) throws -> Project {
        guard let current = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        guard let parsedKind = ProjectWindowKind(rawValue: kind.lowercased()) else {
            throw StreamctlError.invalidArgument(message: "kind must be one of: editor,browser,terminal,custom")
        }
        if current.windows.contains(where: { $0.name == name }) {
            throw StreamctlError.invalidArgument(message: "window name already exists")
        }
        let spec = ProjectWindowSpec(
            name: name,
            kind: parsedKind,
            bundleID: bundleID,
            layout: WindowLayout(displayIndex: displayIndex, tile: try parseTile(tile, fallback: .rightHalf)),
            launchCommand: launchCommand,
            command: command,
            urls: urls,
            matchTitle: matchTitle,
            editorKind: editorKind
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
            windows: current.windows + [spec],
            browserTabs: current.browserTabs
        )
        try store.upsert(project: updated)
        return updated
    }

    public func updateProjectWindow(
        projectName: String,
        index: Int,
        name: String?,
        kind: String?,
        bundleID: String?,
        displayIndex: Int?,
        tile: String?,
        launchCommand: String?,
        command: String?,
        urls: [String]?,
        matchTitle: String?,
        editorKind: String?
    ) throws -> Project {
        guard let current = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        guard index >= 0, index < current.windows.count else {
            throw StreamctlError.invalidArgument(message: "window index out of range")
        }
        var windows = current.windows
        let existing = windows[index]
        let parsedKind: ProjectWindowKind
        if let kind {
            guard let k = ProjectWindowKind(rawValue: kind.lowercased()) else {
                throw StreamctlError.invalidArgument(message: "kind must be one of: editor,browser,terminal,custom")
            }
            parsedKind = k
        } else {
            parsedKind = existing.kind
        }
        windows[index] = ProjectWindowSpec(
            name: name ?? existing.name,
            kind: parsedKind,
            bundleID: bundleID ?? existing.bundleID,
            layout: WindowLayout(
                displayIndex: displayIndex ?? existing.layout.displayIndex,
                tile: try parseTile(tile, fallback: existing.layout.tile)
            ),
            launchCommand: launchCommand ?? existing.launchCommand,
            command: command ?? existing.command,
            urls: urls ?? existing.urls,
            matchTitle: matchTitle ?? existing.matchTitle,
            editorKind: editorKind ?? existing.editorKind
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
            windows: windows,
            browserTabs: current.browserTabs
        )
        try store.upsert(project: updated)
        return updated
    }

    public func removeProjectWindow(projectName: String, index: Int) throws -> Project {
        guard let current = try store.project(named: projectName) else {
            throw StreamctlError.missingProject(name: projectName)
        }
        guard index >= 0, index < current.windows.count else {
            throw StreamctlError.invalidArgument(message: "window index out of range")
        }
        var windows = current.windows
        windows.remove(at: index)
        let updated = Project(
            id: current.id,
            name: current.name,
            repoRoot: current.repoRoot,
            defaultEditor: current.defaultEditor,
            defaultBrowser: current.defaultBrowser,
            defaultTerminal: current.defaultTerminal,
            editorLayout: current.editorLayout,
            browserLayout: current.browserLayout,
            windows: windows,
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
                var foundWindowCount = 0
                var missingWindows: [String] = []
                let terminalPrefix = terminalTitlePrefix(project: project, stream: stream)

                for spec in project.windows {
                    let known = identity?.windows.first(where: { $0.name == spec.name })
                    let titleFallback: String?
                    if spec.kind == .terminal {
                        titleFallback = known?.windowTitle ?? "\(terminalPrefix):\(spec.name)"
                    } else {
                        titleFallback = known?.windowTitle ?? spec.matchTitle
                    }
                    let exists = customAppAdapter.windowExists(
                        bundleID: spec.bundleID,
                        windowID: known?.windowID,
                        titleFallback: titleFallback
                    )
                    if exists {
                        foundWindowCount += 1
                    } else {
                        missingWindows.append(spec.name)
                    }
                }

                reports.append(
                    StreamDoctorReport(
                        projectName: project.name,
                        streamName: stream.name,
                        worktreePath: stream.worktreePath,
                        identityUpdatedAt: identity?.updatedAt,
                        foundWindowCount: foundWindowCount,
                        expectedWindowCount: project.windows.count,
                        missingWindows: missingWindows
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

    private func showGenericWindows(project: Project, stream: Stream, identity: StreamWindowIdentity?) throws {
        let found = project.windows.contains { spec in
            let known = identity?.windows.first(where: { $0.name == spec.name })
            let titleFallback = resolvedTitleFallback(project: project, spec: spec, known: known, stream: stream)
            return customAppAdapter.windowExists(bundleID: spec.bundleID, windowID: known?.windowID, titleFallback: titleFallback)
        }
        if found {
            try focusGenericWindows(project: project, stream: stream, identity: identity)
        } else {
            try upGenericWindows(project: project, stream: stream, existingIdentity: identity)
        }
    }

    private func hideGenericWindows(project: Project, stream: Stream, identity: StreamWindowIdentity?) throws {
        let logger = StreamLogger(stream: stream.name)
        for spec in project.windows {
            let known = identity?.windows.first(where: { $0.name == spec.name })
            let match = resolvedTitleFallback(project: project, spec: spec, known: known, stream: stream)
            _ = try? windowController.setMinimized(
                target: WindowTarget(bundleID: spec.bundleID, matchTitle: match, preferFocusedWindow: match == nil),
                minimized: true
            )
        }
        try store.markInactive(stream: stream)
        logger.info("stream hidden")
    }

    private func destroyGenericWindows(project: Project, stream: Stream, identity: StreamWindowIdentity?) throws {
        try hideGenericWindows(project: project, stream: stream, identity: identity)
        for spec in project.windows where spec.kind == .browser {
            let known = identity?.windows.first(where: { $0.name == spec.name })
            if let anchor = known?.anchorURL ?? spec.urls.first {
                _ = try? chromeAdapter.closeWindow(anchorURL: anchor)
            }
        }
    }

    private func upGenericWindows(project: Project, stream: Stream, existingIdentity: StreamWindowIdentity?) throws {
        let logger = StreamLogger(stream: stream.name)
        logger.info("launching stream")
        var identities: [WindowIdentity] = existingIdentity?.windows ?? []
        let terminalPrefix = terminalTitlePrefix(project: project, stream: stream)

        for spec in project.windows {
            do {
                try appLauncher.ensureRunning(bundleID: spec.bundleID)
                switch spec.kind {
                case .editor:
                    let kind = try parseEditor(spec.editorKind, fallback: .windsurf)
                    try editorAdapter.open(editor: kind, repoRoot: stream.worktreePath)
                    let fallback = fallbackEditorMatchTitle(stream: stream)
                    let moved = try windowController.moveWindow(
                        target: WindowTarget(bundleID: spec.bundleID, matchTitle: spec.matchTitle ?? fallback, preferFocusedWindow: true),
                        layout: spec.layout
                    )
                    upsertIdentity(&identities, WindowIdentity(name: spec.name, bundleID: spec.bundleID, windowID: nil, windowTitle: moved.title, anchorURL: nil))
                case .browser:
                    try chromeAdapter.ensureTabs(urls: spec.urls)
                    let anchor = spec.urls.first
                    if let anchor { _ = try? chromeAdapter.focusWindow(anchorURL: anchor) }
                    _ = try windowController.moveWindow(
                        target: WindowTarget(bundleID: spec.bundleID, matchTitle: spec.matchTitle, preferFocusedWindow: true),
                        layout: spec.layout
                    )
                    upsertIdentity(&identities, WindowIdentity(name: spec.name, bundleID: spec.bundleID, windowID: nil, windowTitle: spec.matchTitle, anchorURL: anchor))
                case .terminal:
                    let title = "\(terminalPrefix):\(spec.name)"
                    try terminalAdapter.openWindow(worktreePath: stream.worktreePath, command: spec.command, title: title)
                    _ = try windowController.moveWindow(
                        target: WindowTarget(bundleID: spec.bundleID, matchTitle: title, preferFocusedWindow: false),
                        layout: spec.layout
                    )
                    upsertIdentity(&identities, WindowIdentity(name: spec.name, bundleID: spec.bundleID, windowID: nil, windowTitle: title, anchorURL: nil))
                case .custom:
                    if let command = spec.launchCommand,
                       let detected = customAppAdapter.launchAndDetectWindow(bundleID: spec.bundleID, command: command, matchTitle: spec.matchTitle) {
                        let title = detected.title ?? spec.matchTitle
                        _ = try? windowController.moveWindow(
                            target: WindowTarget(bundleID: spec.bundleID, matchTitle: title, preferFocusedWindow: false),
                            layout: spec.layout
                        )
                        upsertIdentity(&identities, WindowIdentity(name: spec.name, bundleID: spec.bundleID, windowID: detected.windowID, windowTitle: title, anchorURL: nil))
                    } else {
                        logger.warn("custom window launch not detected: \(spec.name)")
                    }
                }
            } catch {
                logger.warn("window setup failed (\(spec.name)): \(error.localizedDescription)")
            }
        }

        let identity = StreamWindowIdentity(
            streamID: stream.id,
            windows: identities,
            updatedAt: nowISO8601()
        )
        try store.upsert(windowIdentity: identity)
        try store.markActive(stream: stream)
        logger.info("stream is up")
    }

    private func focusGenericWindows(project: Project, stream: Stream, identity: StreamWindowIdentity?) throws {
        let logger = StreamLogger(stream: stream.name)
        var identities: [WindowIdentity] = identity?.windows ?? []

        for spec in project.windows {
            do {
                try appLauncher.ensureRunning(bundleID: spec.bundleID)
                let known = identities.first(where: { $0.name == spec.name })
                let title = resolvedTitleFallback(project: project, spec: spec, known: known, stream: stream)

                switch spec.kind {
                case .browser:
                    let anchor = known?.anchorURL ?? spec.urls.first
                    if let anchor { _ = try? chromeAdapter.focusWindow(anchorURL: anchor) }
                default:
                    _ = try? appLauncher.activate(bundleID: spec.bundleID)
                }

                _ = try? windowController.setMinimized(
                    target: WindowTarget(bundleID: spec.bundleID, matchTitle: title, preferFocusedWindow: title == nil),
                    minimized: false
                )
                _ = try? windowController.moveWindow(
                    target: WindowTarget(bundleID: spec.bundleID, matchTitle: title, preferFocusedWindow: title == nil),
                    layout: spec.layout
                )

                if known == nil, let detected = customAppAdapter.detectWindow(bundleID: spec.bundleID, matchTitle: title) {
                    upsertIdentity(&identities, WindowIdentity(name: spec.name, bundleID: spec.bundleID, windowID: detected.windowID, windowTitle: detected.title ?? title, anchorURL: spec.urls.first))
                }
            } catch {
                logger.warn("window focus failed (\(spec.name)): \(error.localizedDescription)")
            }
        }

        let refreshed = StreamWindowIdentity(
            streamID: stream.id,
            windows: identities,
            updatedAt: nowISO8601()
        )
        try store.upsert(windowIdentity: refreshed)
        try store.markActive(stream: stream)
        logger.info("stream focused")
    }

    private func upsertIdentity(_ identities: inout [WindowIdentity], _ entry: WindowIdentity) {
        identities.removeAll { $0.name == entry.name }
        identities.append(entry)
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

    private func fallbackEditorMatchTitle(stream: Stream) -> String {
        URL(fileURLWithPath: stream.worktreePath).lastPathComponent
    }

    private func resolvedTitleFallback(project: Project, spec: ProjectWindowSpec, known: WindowIdentity?, stream: Stream) -> String? {
        if let knownTitle = known?.windowTitle, !knownTitle.isEmpty {
            return knownTitle
        }
        switch spec.kind {
        case .terminal:
            return "\(terminalTitlePrefix(project: project, stream: stream)):\(spec.name)"
        case .editor:
            return spec.matchTitle ?? fallbackEditorMatchTitle(stream: stream)
        default:
            return spec.matchTitle
        }
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

import XCTest

@testable import streamctl

final class OrchestratorTests: XCTestCase {
    func testUpdateEditorPreferencePersistsToConfig() throws {
        let dir = try makeTempDirectory()
        let path = dir.appendingPathComponent("config.yaml").path
        let configStore = ConfigStore(path: path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        _ = try orchestrator.updateEditorPreference(.cursor)
        let reloaded = try configStore.load()
        XCTAssertEqual(reloaded.editor, .cursor)

        _ = try orchestrator.updateEditorPreference(nil)
        let cleared = try configStore.load()
        XCTAssertNil(cleared.editor)
    }

    func testNextWindowOrderIndexUsesRoleOffsetAndMax() {
        let windows = [
            WindowRecord(
                id: UUID().uuidString,
                workspaceID: "ws",
                app: "Chrome",
                title: "Browser",
                windowID: 10,
                role: "browser",
                orderIndex: 0,
                lastSeenAt: "now"
            ),
            WindowRecord(
                id: UUID().uuidString,
                workspaceID: "ws",
                app: "iTerm2",
                title: "Term 1",
                windowID: 11,
                role: "terminal",
                orderIndex: 200,
                lastSeenAt: "now"
            ),
            WindowRecord(
                id: UUID().uuidString,
                workspaceID: "ws",
                app: "iTerm2",
                title: "Term 2",
                windowID: 12,
                role: "terminal",
                orderIndex: 205,
                lastSeenAt: "now"
            ),
        ]

        let nextTerminal = AgentmuxOrchestrator.nextWindowOrderIndex(
            existing: windows,
            role: "terminal",
            orderOffset: 200
        )
        XCTAssertEqual(nextTerminal, 206)

        let nextEditor = AgentmuxOrchestrator.nextWindowOrderIndex(
            existing: windows,
            role: "editor",
            orderOffset: 100
        )
        XCTAssertEqual(nextEditor, 100)
    }

    func testAddProjectByCloningUsesProjectsRootAndRepoName() throws {
        let fixture = try makeTempGitRepo(name: "sample-repo")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot
        )

        let project = try orchestrator.addProject(gitURL: fixture.path)

        let expected = projectsRoot.appendingPathComponent("sample-repo", isDirectory: true).path
        XCTAssertEqual(project.dir, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(expected)/README.md"))
    }

    func testAddProjectByCloningStripsGitSuffixFromRepoName() throws {
        let fixture = try makeTempGitRepo(name: "source.git")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot
        )

        let project = try orchestrator.addProject(gitURL: fixture.path)

        let expected = projectsRoot.appendingPathComponent("source", isDirectory: true).path
        XCTAssertEqual(project.dir, expected)
        XCTAssertEqual(project.name, "source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(expected)/README.md"))
    }

    func testRemoveProjectDeletesManagedGitProjectDirectory() throws {
        let fixture = try makeTempGitRepo(name: "managed")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot
        )

        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertNil(try store.project(dir: project.dir))
        XCTAssertTrue(try orchestrator.listProjects().isEmpty)
    }

    func testRemoveProjectDeletesManagedWorkspaceDirectoriesForManagedGitProject() throws {
        let fixture = try makeTempGitRepo(name: "managed-with-workspace")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot,
            workspacesRootDirectory: workspacesRoot
        )

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let projectWorkspaceRoot = workspacesRoot.appendingPathComponent(project.name, isDirectory: true)
        let workspaceDir = projectWorkspaceRoot.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertTrue(workspaceDir.path.hasPrefix(workspacesRoot.path))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectWorkspaceRoot.path))
    }

    func testRemoveProjectDoesNotDeleteUnmanagedProjectDirectoryButDeletesManagedWorkspaceDirectories() throws {
        let projectDir = try makeTempDirectory()
        try runGit(["init"], cwd: projectDir.path)
        try "hello".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: projectDir.path)
        try runGit(
            ["-c", "user.name=agentmux-test", "-c", "user.email=test@example.com", "commit", "-m", "init"],
            cwd: projectDir.path
        )

        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot,
            workspacesRootDirectory: workspacesRoot
        )

        let project = try orchestrator.addProject(dir: projectDir.path)
        let projectWorkspaceRoot = workspacesRoot.appendingPathComponent(project.name, isDirectory: true)
        let workspaceDir = projectWorkspaceRoot.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertTrue(workspaceDir.path.hasPrefix(workspacesRoot.path))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectWorkspaceRoot.path))
    }

    func testArchiveWorkspaceDoesNotDeleteProjectDirectoryForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let marker = projectDir.appendingPathComponent("marker.txt")
        try "marker".write(to: marker, atomically: true, encoding: .utf8)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
    }

    func testCreateWorkspaceForNonGitProjectAllocatesPorts() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        XCTAssertEqual(workspace.dir, projectDir.path)
        XCTAssertFalse(workspace.isArchived)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: workspace.id).count, 10)
    }

    func testSuggestedWorkspaceNameMatchesAutoGeneratedDirname() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-default")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            workspacesRootDirectory: workspacesRoot
        )

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: suggested, branch: suggested)

        XCTAssertEqual(workspace.name, suggested)
        XCTAssertEqual(workspace.dirname, suggested)
        XCTAssertEqual(workspace.branch, suggested)

        let nextSuggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        XCTAssertNotEqual(nextSuggested, suggested)
    }

    func testCreateWorkspaceUsesCustomNameWithAutoGeneratedDirname() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-custom")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            workspacesRootDirectory: workspacesRoot
        )

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id,
            name: "feature-name",
            branch: "feature-branch"
        )

        XCTAssertEqual(workspace.name, "feature-name")
        XCTAssertEqual(workspace.branch, "feature-branch")
        XCTAssertEqual(workspace.dirname, suggested)
    }

    func testListWorkspacesIncludesBranchMetadata() throws {
        let repo = try makeTempGitRepo(name: "workspace-branch-list")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            workspacesRootDirectory: workspacesRoot
        )

        let project = try orchestrator.addProject(dir: repo.path)
        _ = try orchestrator.createWorkspace(
            projectID: project.id,
            name: "feature-branch",
            branch: "feature-branch"
        )

        let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
        let feature = try XCTUnwrap(workspaces.first(where: { $0.name == "feature-branch" }))
        XCTAssertEqual(feature.branch, "feature-branch")
    }

    func testCreateWorkspaceRevivesArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let created = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.archiveWorkspace(workspaceID: created.id)

        let revived = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let persisted = try store.workspace(id: revived.id)

        XCTAssertEqual(revived.id, created.id)
        XCTAssertEqual(persisted?.isArchived, false)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: revived.id).count, 10)
    }

    func testListWorkspacesHonorsIncludeArchivedFlag() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let activeOnly = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false)
        XCTAssertEqual(activeOnly.map(\.name), ["default"])

        let all = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
        XCTAssertEqual(Set(all.map(\.name)), Set(["default", "feature"]))
    }

    func testGUIShortcutsAndActiveWorkspaceRoundTrip() throws {
        let root = try makeTempDirectory()
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        XCTAssertEqual(try orchestrator.guiHotkey(), SettingsKey.defaultGUIHotkey)
        XCTAssertEqual(try orchestrator.guiNextShortcut(), SettingsKey.defaultGUINextShortcut)
        XCTAssertEqual(try orchestrator.guiPreviousShortcut(), SettingsKey.defaultGUIPreviousShortcut)
        XCTAssertEqual(try orchestrator.guiShowShortcut(), SettingsKey.defaultGUIShowShortcut)
        XCTAssertEqual(try orchestrator.guiAddProjectShortcut(), SettingsKey.defaultGUIAddProjectShortcut)
        XCTAssertEqual(try orchestrator.guiAddWorkspaceShortcut(), SettingsKey.defaultGUIAddWorkspaceShortcut)
        XCTAssertEqual(try orchestrator.guiReloadShortcut(), SettingsKey.defaultGUIReloadShortcut)
        XCTAssertEqual(try orchestrator.guiOpenEditorShortcut(), SettingsKey.defaultGUIOpenEditorShortcut)
        XCTAssertEqual(try orchestrator.guiOpenTerminalShortcut(), SettingsKey.defaultGUIOpenTerminalShortcut)
        XCTAssertEqual(try orchestrator.guiOpenFinderShortcut(), SettingsKey.defaultGUIOpenFinderShortcut)
        XCTAssertEqual(try orchestrator.guiOpenSettingsShortcut(), SettingsKey.defaultGUIOpenSettingsShortcut)

        try orchestrator.setGUIHotkey("ctrl+alt+h")
        try orchestrator.setGUINextShortcut("ctrl+alt+n")
        try orchestrator.setGUIPreviousShortcut("ctrl+alt+p")
        try orchestrator.setGUIShowShortcut("ctrl+alt+s")
        try orchestrator.setGUIAddProjectShortcut("ctrl+alt+shift+n")
        try orchestrator.setGUIAddWorkspaceShortcut("ctrl+alt+w")
        try orchestrator.setGUIReloadShortcut("ctrl+alt+r")
        try orchestrator.setGUIOpenEditorShortcut("ctrl+alt+e")
        try orchestrator.setGUIOpenTerminalShortcut("ctrl+alt+t")
        try orchestrator.setGUIOpenFinderShortcut("ctrl+alt+f")
        try orchestrator.setGUIOpenSettingsShortcut("ctrl+alt+,")
        try orchestrator.setActiveWorkspace(id: "workspace-123")

        XCTAssertEqual(try orchestrator.guiHotkey(), "ctrl+alt+h")
        XCTAssertEqual(try orchestrator.guiNextShortcut(), "ctrl+alt+n")
        XCTAssertEqual(try orchestrator.guiPreviousShortcut(), "ctrl+alt+p")
        XCTAssertEqual(try orchestrator.guiShowShortcut(), "ctrl+alt+s")
        XCTAssertEqual(try orchestrator.guiAddProjectShortcut(), "ctrl+alt+shift+n")
        XCTAssertEqual(try orchestrator.guiAddWorkspaceShortcut(), "ctrl+alt+w")
        XCTAssertEqual(try orchestrator.guiReloadShortcut(), "ctrl+alt+r")
        XCTAssertEqual(try orchestrator.guiOpenEditorShortcut(), "ctrl+alt+e")
        XCTAssertEqual(try orchestrator.guiOpenTerminalShortcut(), "ctrl+alt+t")
        XCTAssertEqual(try orchestrator.guiOpenFinderShortcut(), "ctrl+alt+f")
        XCTAssertEqual(try orchestrator.guiOpenSettingsShortcut(), "ctrl+alt+,")
        XCTAssertEqual(try orchestrator.activeWorkspaceID(), "workspace-123")

        try orchestrator.setActiveWorkspace(id: nil)
        XCTAssertNil(try orchestrator.activeWorkspaceID())
    }

    func testRunStatusChecksPersistsResultsForMatchingProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(process: "api", command: "echo green", interval: 10, timeout: 2),
                StatusCheckDefinition(
                    name: "failing",
                    process: "api",
                    command: "echo red && exit 1",
                    interval: 10,
                    timeout: 2
                ),
                StatusCheckDefinition(process: "missing", command: "echo skipped", interval: 10, timeout: 2),
            ]
        )
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString,
            workspaceID: workspace.id,
            templateName: "api",
            command: "echo api",
            terminalApp: nil,
            windowID: nil,
            pid: 9000,
            status: .running,
            logPath: nil,
            lastOutputAt: nil,
            startedAt: "now",
            exitedAt: nil
        )
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)

        XCTAssertEqual(results.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.checkName, $0.status) })
        XCTAssertEqual(byName["api"], "green")
        XCTAssertEqual(byName["failing"], "red")

        let persisted = try orchestrator.statusResults(processID: runningProcess.id)
        XCTAssertEqual(persisted.count, 2)
    }

    func testCreateWorkspaceThrowsForUnknownProject() throws {
        let root = try makeTempDirectory()
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: "missing", name: "feature"))
    }

    func testCreateWorkspaceForGitProjectRequiresBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-requires-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            workspacesRootDirectory: workspacesRoot
        )
        let project = try orchestrator.addProject(dir: repo.path)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "workspace")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Branch name is required"))
        }
    }

    func testOpenWorkspaceEditorThrowsWhenEditorIsNotConfigured() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(try orchestrator.openWorkspaceEditor(workspaceID: workspace.id))
    }

    func testOpenWorkspaceEditorAttachesFocusedEditorWindow() throws {
        let (orchestrator, _, _, workspace, root) = try makeOrchestratorWithWorkspace(editor: .vscode)
        let openLog = root.appendingPathComponent("open.log")

        // Mocked dependencies: `yabai`, `osascript`, and `open`.
        // Why: deterministically emulate window discovery/focus and editor launching without GUI side effects.
        // Remaining risk: real macOS focus timing, launch delays, and yabai window snapshots may diverge.
        try withMockCommands(
            [
                "yabai": Self.orchestratorYabaiMockScript,
                "osascript": Self.orchestratorOsaScriptMock,
                "open": Self.openMockScript,
            ]
        ) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "555") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Visual Studio Code") {
                    try withEnv(name: "OPEN_LOG_FILE", value: openLog.path) {
                        try orchestrator.openWorkspaceEditor(workspaceID: workspace.id)
                    }
                }
            }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        let editorWindows = windows.filter { $0.role == "editor" }
        XCTAssertEqual(editorWindows.count, 1)
        XCTAssertEqual(editorWindows.first?.windowID, 555)

        let openArgs = try String(contentsOf: openLog)
        XCTAssertTrue(openArgs.contains("-a Visual Studio Code"))
        XCTAssertTrue(openArgs.contains(workspace.dir))
    }

    func testOpenWorkspaceTerminalAttachesFocusedTerminalWindow() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        // Mocked dependencies: `yabai` and `osascript`.
        // Why: validate terminal attach logic without requiring iTerm2/yabai in CI.
        // Remaining risk: real AppleScript/iTerm runtime behavior and command timing are not covered.
        try withMockCommands(
            [
                "yabai": Self.orchestratorYabaiMockScript,
                "osascript": Self.orchestratorOsaScriptMock,
            ]
        ) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "777") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") {
                    try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id)
                }
            }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        let terminalWindows = windows.filter { $0.role == "terminal" }
        XCTAssertEqual(terminalWindows.count, 1)
        XCTAssertEqual(terminalWindows.first?.windowID, 777)
    }

    func testOpenWorkspaceTerminalThrowsWhenITermIsUnavailable() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        // Mocked dependency: iTerm availability probe through `osascript`.
        // Why: force deterministic dependency-missing behavior.
        // Remaining risk: only one unavailability failure mode is simulated.
        try withMockCommands(
            [
                "yabai": Self.orchestratorYabaiMockScript,
                "osascript": Self.orchestratorOsaScriptMock,
            ]
        ) {
            try withEnv(name: "MOCK_ITERM_UNAVAILABLE", value: "1") {
                XCTAssertThrowsError(try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id))
            }
        }
    }

    func testFocusWorkspaceSkipsFailedWindowAndSetsActiveWorkspace() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                app: "iTerm2",
                title: "bad",
                windowID: 999,
                role: "terminal",
                orderIndex: 0,
                lastSeenAt: "now"
            )
        )
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                app: "iTerm2",
                title: "good",
                windowID: 101,
                role: "terminal",
                orderIndex: 1,
                lastSeenAt: "now"
            )
        )

        // Mocked dependency: `yabai` focus command outcomes.
        // Why: control success/failure ordering and verify fallback focus behavior.
        // Remaining risk: actual focus behavior can vary with spaces/displays and concurrent window changes.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspace(workspaceID: workspace.id)
            }
        }

        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["101"])
    }

    func testFocusWindowNavigationUsesRelativeOrderAndWraps() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("relative-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                app: "iTerm2",
                title: "one",
                windowID: 101,
                role: "terminal",
                orderIndex: 0,
                lastSeenAt: "now"
            )
        )
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                app: "iTerm2",
                title: "two",
                windowID: 202,
                role: "terminal",
                orderIndex: 1,
                lastSeenAt: "now"
            )
        )
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                app: "iTerm2",
                title: "three",
                windowID: 303,
                role: "terminal",
                orderIndex: 2,
                lastSeenAt: "now"
            )
        )

        // Mocked dependency: `yabai` focused-window query and focus command.
        // Why: deterministically exercise relative navigation and wraparound.
        // Remaining risk: real-time focus transitions and stale snapshots are not represented.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "YABAI_FOCUSED_ID", value: "202") {
                    try orchestrator.focusNextWindow(workspaceID: workspace.id)
                }
                try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                    try orchestrator.focusPreviousWindow(workspaceID: workspace.id)
                }
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["303", "303", "202"])
        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
    }

    func testWorkspaceIDForFocusedWindowMapsFromYabai() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                app: "iTerm2",
                title: "shell",
                windowID: 202,
                role: "terminal",
                orderIndex: 0,
                lastSeenAt: "now"
            )
        )

        // Mocked dependency: focused-window query from `yabai`.
        // Why: explicitly cover both "focused window exists" and "no focused window" branches.
        // Remaining risk: malformed/partial focused-window payloads are not simulated.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "202") {
                XCTAssertEqual(try orchestrator.workspaceIDForFocusedWindow(), workspace.id)
            }

            try withEnv(name: "YABAI_FOCUSED_NONE", value: "1") {
                XCTAssertNil(try orchestrator.workspaceIDForFocusedWindow())
            }
        }
    }

    func testListSpaceOptionsSortsByDisplayThenSpace() throws {
        let root = try makeTempDirectory()
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        // Mocked dependency: `yabai --spaces` payload ordering.
        // Why: guarantee sort assertions independently of host window-manager state.
        // Remaining risk: unexpected production fields or space metadata edge cases are not covered.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            let options = try orchestrator.listSpaceOptions()
            let values = options.map { "\($0.displayIndex):\($0.spaceIndex)" }
            XCTAssertEqual(values, ["1:1", "1:2", "2:3"])
        }
    }

    func testUpdateWorkspaceSettingsMarksWorkspaceRunningWhenRuntimeIndicatorsExist() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                templateName: "api",
                command: "npm run api",
                terminalApp: nil,
                windowID: nil,
                pid: nil,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: "now",
                exitedAt: nil
            )
        )

        // Mocked dependency: `yabai` query path used during process/window reconciliation.
        // Why: isolate store-state transition coverage from real window manager availability.
        // Remaining risk: reconciliation against rapidly changing real windows remains untested here.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in }
        }

        let updated = try store.workspace(id: workspace.id)
        XCTAssertEqual(updated?.isRunning, true)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    func testListProjectsReturnsSortedSummaries() throws {
        let root = try makeTempDirectory()
        let aDir = root.appendingPathComponent("alpha", isDirectory: true)
        let bDir = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        _ = try orchestrator.addProject(dir: bDir.path)
        _ = try orchestrator.addProject(dir: aDir.path)
        let projects = try orchestrator.listProjects()

        XCTAssertEqual(projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(projects.map(\.isGitRepo), [false, false])
    }

    func testSyncConfigDropsInvalidProjectAndSeedsDefaultWorkspace() throws {
        let root = try makeTempDirectory()
        let validDir = root.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        let missingDir = root.appendingPathComponent("missing", isDirectory: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        try configStore.save(
            AppConfig(
                editor: nil,
                portRange: PortRange(start: 20000, end: 30000),
                projects: [
                    ProjectConfig(dir: validDir.path),
                    ProjectConfig(dir: missingDir.path),
                ]
            )
        )

        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)
        let synced = try orchestrator.syncConfig()

        XCTAssertEqual(synced.projects.map(\.dir), [validDir.path])
        XCTAssertEqual(try store.projects().count, 1)
        XCTAssertNotNil(try store.workspace(projectID: validDir.path, name: "default"))
    }

    func testUpdateProjectConfigAndReadBackProjectConfig() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        let updated = ProjectConfig(
            dir: project.dir,
            setupScript: "echo setup",
            cleanupScript: "echo cleanup",
            processes: [ProcessTemplate(name: "api", command: "npm run api")],
            statusChecks: [
                StatusCheckDefinition(
                    name: "health",
                    process: "api",
                    command: "echo ok",
                    interval: 10,
                    timeout: 2,
                    onExit: .notify
                )
            ],
            browserSessions: [BrowserSession(url: "https://example.com")]
        )
        try orchestrator.updateProjectConfig(updated)

        let loaded = try orchestrator.projectConfig(projectID: project.id)
        XCTAssertEqual(loaded?.setupScript, "echo setup")
        XCTAssertEqual(loaded?.cleanupScript, "echo cleanup")
        XCTAssertEqual(loaded?.processes.first?.name, "api")
        XCTAssertEqual(loaded?.statusChecks.first?.name, "health")
        XCTAssertEqual(loaded?.browserSessions.first?.url, "https://example.com")
    }

    func testUpdateProjectConfigUsingClosurePersistsChanges() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.cleanupScript = "echo bye"
            config.processes = [ProcessTemplate(command: "echo process")]
        }

        let loaded = try orchestrator.projectConfig(projectID: project.id)
        XCTAssertEqual(loaded?.cleanupScript, "echo bye")
        XCTAssertEqual(loaded?.processes.first?.command, "echo process")
    }

    func testCreateWorkspaceRejectsDuplicateActiveWorkspace() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "feature"))
    }

    func testArchiveDefaultWorkspaceThrows() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        let defaultWorkspace = try XCTUnwrap(
            try orchestrator.listWorkspaces(projectID: project.id).first(where: { $0.isDefault })
        )
        XCTAssertThrowsError(try orchestrator.archiveWorkspace(workspaceID: defaultWorkspace.id))
    }

    func testStopWorkspaceUpdatesRunningStateAndCleansRuntimeRecords() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                app: "iTerm2",
                title: "shell",
                windowID: 501,
                role: "terminal",
                orderIndex: 0,
                lastSeenAt: "now"
            )
        )
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                templateName: "api",
                command: "npm run api",
                terminalApp: "iTerm2",
                windowID: 501,
                pid: nil,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: "now",
                exitedAt: nil
            )
        )

        // Mocked dependencies: window close via `yabai` and iTerm cleanup via `osascript`.
        // Why: verify cleanup semantics without touching real windows/processes.
        // Remaining risk: real process/window teardown can fail or race differently than this mocked path.
        try withMockCommands(
            [
                "yabai": Self.orchestratorYabaiMockScript,
                "osascript": Self.orchestratorOsaScriptMock,
            ]
        ) {
            try orchestrator.stopWorkspace(workspaceID: workspace.id)
        }
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        XCTAssertTrue(try orchestrator.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    func testLaunchWorkspaceRejectsArchivedWorkspace() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        // Mocked dependencies are present only to satisfy adapter calls; launch should fail before launching anything.
        // Remaining risk: launch behavior when partially archived/misaligned runtime state exists is covered elsewhere.
        try withMockCommands(
            [
                "yabai": Self.orchestratorYabaiMockScript,
                "osascript": Self.orchestratorOsaScriptMock,
            ]
        ) {
            XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id))
        }
    }

    func testWorkspaceSettingsAndAccessorsReflectStoreState() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [4100, 4101])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString,
                workspaceID: workspace.id,
                templateName: "job",
                command: "echo job",
                terminalApp: nil,
                windowID: nil,
                pid: nil,
                status: .running,
                logPath: nil,
                lastOutputAt: nil,
                startedAt: "now",
                exitedAt: nil
            )
        )

        // Mocked dependency: `yabai` queries used by settings reconciliation.
        // Why: keep this test focused on persisted settings/accessor behavior.
        // Remaining risk: browser-session behavior with real Chrome is intentionally excluded in this unit.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes = [ProcessTemplate(name: "job", command: "echo job")]
                settings.statusChecks = [
                    StatusCheckDefinition(process: "job", command: "echo ok", interval: 30, timeout: 3)
                ]
                settings.browserSessions = []
            }
        }

        let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id)
        XCTAssertEqual(settings?.processes.first?.name, "job")
        XCTAssertEqual(settings?.statusChecks.first?.process, "job")
        XCTAssertTrue(settings?.browserSessions.isEmpty ?? false)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: workspace.id), [4100, 4101])
        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).count, 1)
    }

    private func makeOrchestratorWithWorkspace(editor: EditorPreference? = nil) throws
        -> (AgentmuxOrchestrator, SQLiteStore, ProjectRecord, WorkspaceRecord, URL)
    {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)
        if let editor {
            _ = try orchestrator.updateEditorPreference(editor)
        }

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        return (orchestrator, store, project, workspace, root)
    }

    private func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
        // Mock mechanism: inject command stubs at the front of PATH.
        // Why: emulate yabai/osascript/open behavior deterministically in unit tests.
        // Remaining risk: these tests do not prove interoperability with real binaries or OS-level side effects.
        let directory = try makeTempDirectory()
        for (name, script) in commands {
            let file = directory.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        sharedPathMutationLock.lock()
        defer { sharedPathMutationLock.unlock() }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let updatedPath = originalPath.isEmpty ? directory.path : "\(directory.path):\(originalPath)"
        setenv("PATH", updatedPath, 1)
        defer { setenv("PATH", originalPath, 1) }

        try run()
    }

    private func withEnv(name: String, value: String, run: () throws -> Void) throws {
        let original = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer {
            if let original {
                setenv(name, original, 1)
            } else {
                unsetenv(name)
            }
        }
        try run()
    }

    private static let orchestratorYabaiMockScript = """
        #!/bin/bash
        # Mock `yabai` CLI used by orchestrator tests.
        # Coverage intent:
        # - space/display/window query payloads
        # - focus success/failure and focused-window toggles via env vars
        # Residual risk: real yabai output and timing can differ significantly under live desktops.
        args="$*"

        focused_id="${YABAI_FOCUSED_ID:-101}"
        focused_app="${YABAI_FOCUSED_APP:-iTerm2}"
        focused_title="${YABAI_FOCUSED_TITLE:-focused}"
        focused_json="{\\"id\\":${focused_id},\\"pid\\":11,\\"app\\":\\"${focused_app}\\",\\"title\\":\\"${focused_title}\\",\\"space\\":1,\\"display\\":1,\\"is-sticky\\":false,\\"is-hidden\\":false,\\"is-visible\\":true,\\"is-native-fullscreen\\":false}"

        if [[ "$args" == *"query --displays"* ]]; then
          echo '[{"index":1},{"index":2}]'
          exit 0
        fi

        if [[ "$args" == *"query --spaces"* ]]; then
          echo '[{"index":3,"display":2},{"index":2,"display":1},{"index":1,"display":1}]'
          exit 0
        fi

        if [[ "$args" == *"query --windows --window"* ]]; then
          if [[ "${YABAI_FOCUSED_NONE:-}" == "1" ]]; then
            echo "no focused window" >&2
            exit 1
          fi
          echo "$focused_json"
          exit 0
        fi

        if [[ "$args" == *"query --windows"* ]]; then
          if [[ -n "${YABAI_WINDOWS_JSON:-}" ]]; then
            echo "$YABAI_WINDOWS_JSON"
          else
            echo '[{"id":101,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":202,"pid":22,"app":"Google Chrome","title":"docs","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]'
          fi
          exit 0
        fi

        if [[ "$args" == *"window --focus"* ]]; then
          id="${@: -1}"
          if [[ "$id" == "999" || ",${YABAI_FOCUS_FAIL_IDS:-}," == *",${id},"* ]]; then
            echo "focus failed" >&2
            exit 1
          fi
          if [[ -n "${YABAI_FOCUS_LOG_FILE:-}" ]]; then
            echo "$id" >> "$YABAI_FOCUS_LOG_FILE"
          fi
          echo "ok"
          exit 0
        fi

        if [[ "$args" == *"window --close"* || "$args" == *"window --minimize"* ]]; then
          echo "ok"
          exit 0
        fi

        echo "unhandled command: $args" >&2
        exit 1
        """

    private static let orchestratorOsaScriptMock = """
        #!/bin/bash
        # Mock `osascript` bridge for iTerm/Chrome paths used by orchestrator tests.
        # Coverage intent:
        # - iTerm availability and window-id responses
        # - Chrome availability/session stubs
        # Residual risk: no validation of true AppleScript syntax/runtime against installed applications.
        script="${*: -1}"

        if [[ "$script" == *'tell application "iTerm2" to version'* ]]; then
          if [[ "${MOCK_ITERM_UNAVAILABLE:-}" == "1" ]]; then
            echo "iTerm2 unavailable" >&2
            exit 1
          fi
          echo "3.5.0"
          exit 0
        fi

        if [[ "$script" == *'create window with default profile'* ]]; then
          echo "${MOCK_ITERM_WINDOW_ID:-701}"
          exit 0
        fi

        if [[ "$script" == *'tell application "Google Chrome" to version'* ]]; then
          echo "122"
          exit 0
        fi

        if [[ "$script" == *'set output to ""'* ]]; then
          echo ""
          exit 0
        fi

        if [[ "$script" == *'set URL of active tab of newWindow'* ]]; then
          echo "88"
          exit 0
        fi

        if [[ "$script" == *'write text'* || "$script" == *'close w'* ]]; then
          echo ""
          exit 0
        fi

        echo ""
        exit 0
        """

    private static let openMockScript = """
        #!/bin/bash
        # Mock `open` for editor-launch assertions.
        # Residual risk: launch service resolution and app startup behavior are not exercised.
        if [[ -n "${OPEN_LOG_FILE:-}" ]]; then
          echo "$*" >> "$OPEN_LOG_FILE"
        fi
        exit 0
        """

    private func makeTempGitRepo(name: String) throws -> URL {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo.path)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: repo.path)
        try runGit(
            ["-c", "user.name=agentmux-test", "-c", "user.email=test@example.com", "commit", "-m", "init"],
            cwd: repo.path
        )
        return repo
    }

    private func runGit(_ arguments: [String], cwd: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "agentmux.tests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"]
            )
        }
    }
}

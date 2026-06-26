import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

extension OrchestratorTests {

    func testUpdateProjectConfigRejectsBlankPortNameAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)

        XCTAssertThrowsError(
            try orchestrator.updateProjectConfig(projectID: project.id) { project in project.ports = [PortDefinition(name: " \n\t ")] }
        ) { error in XCTAssertEqual(error.localizedDescription, "Invalid argument: Port name is required.") }
    }

    func testUpdateWorkspaceSettingsAcceptsSyntheticPortFallbackVariableAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [PortDefinition(name: "API_PORT")]
            settings.processes = [ProcessTemplate(name: "web", command: "PORT=$PORT0 npm run dev")]
        }

        let settings = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: workspace.id))
        XCTAssertEqual(settings.processes.first?.command, "PORT=$PORT0 npm run dev")
    }

    func testUpdateWorkspaceSettingsRejectsBlankPortNameAtSaveTime() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: root.path)
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.ports = [PortDefinition(name: "  ")] }
        ) { error in XCTAssertEqual(error.localizedDescription, "Invalid argument: Port name is required.") }
    }

    func testRollbackFailedImportedProjectCreationPreservesSiblingWorkspaceDirectoriesWithSameSanitizedName() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let managedDirname = managedProjectStorageDirname(
            namespace: "git", source: "12345678-1234-1234-1234-123456789ABC", preferredName: "sample-repo")

        let importedProject = ProjectRecord(
            id: "12345678-1234-1234-1234-123456789ABC", name: "sample-repo",
            dir: reposRoot.appendingPathComponent(managedDirname, isDirectory: true).path, isGitRepo: true, defaultBranch: "main")
        let sharedWorkspaceRoot = workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true)
        let importedWorkspaceDir = sharedWorkspaceRoot.appendingPathComponent("main", isDirectory: true).path
        let siblingWorkspaceDir = sharedWorkspaceRoot.appendingPathComponent("feature", isDirectory: true).path
        let importedProjectDir = importedProject.dir

        try FileManager.default.createDirectory(atPath: importedWorkspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: siblingWorkspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: importedProjectDir, withIntermediateDirectories: true)

        try store.upsert(project: importedProject)
        try store.upsert(
            workspace: WorkspaceRecord(
                id: UUID().uuidString, projectID: importedProject.id, dir: importedWorkspaceDir, dirname: "main", branch: "main", baseBranch: "main",
                isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil))

        try orchestrator.rollbackFailedImportedProjectCreation(project: importedProject, workspaceDirectory: importedWorkspaceDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: importedProjectDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedWorkspaceDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingWorkspaceDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedWorkspaceRoot.path))
    }

    func testWorkspaceSetupUsesShellCommandEnvironmentPath() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        let commandDir = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: commandDir, withIntermediateDirectories: true)

        let commandFile = commandDir.appendingPathComponent("setupcmd")
        try """
        #!/bin/sh
        echo setup command ran
        printf path-ok > setup-path-marker
        """.write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)

        let shellFile = root.appendingPathComponent("mock-shell")
        try """
        #!/bin/sh
        if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
          printf '\\n__SPACES_PATH__%s' "\(commandDir.path):/usr/bin:/bin"
          exit 0
        fi
        exec /bin/sh "$@"
        """.write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

        sharedEnvironmentMutationLock.lock()
        sharedPathMutationLock.lock()
        defer {
            sharedPathMutationLock.unlock()
            sharedEnvironmentMutationLock.unlock()
        }
        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let originalHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
        setenv("SHELL", shellFile.path, 1)
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("HOME", root.path, 1)
        defer {
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
            setenv("PATH", originalPath, 1)
            setenv("HOME", originalHome, 1)
        }

        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "setupcmd" }
        let workspace = try orchestrator.createWorkspace(projectID: project.id, runSetupScript: false)

        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)

        let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertEqual(state.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOfFile: URL(fileURLWithPath: workspace.dir).appendingPathComponent("setup-path-marker").path, encoding: .utf8),
            "path-ok")
    }

    // Tests refresh all workspace windows reports no mutation when nothing changed by arranging representative inputs and asserting the expected result.
    func testRefreshAllWorkspaceWindowsReportsNoMutationWhenNothingChanged() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()

        // No tracked windows and workspace is not running — refresh should report no DB mutation.
        var result: WorkspaceOrchestrator.RefreshResult?
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { result = try orchestrator.refreshAllWorkspaceWindows() }
        }

        let refreshResult = try XCTUnwrap(result)
        XCTAssertFalse(refreshResult.didMutateDB)
        // All non-archived workspaces should still appear in tracked counts (with zero windows).
        XCTAssertFalse(refreshResult.trackedWindowCounts.isEmpty)
        for (_, count) in refreshResult.trackedWindowCounts { XCTAssertEqual(count, 0) }
    }

    func testPreviewProjectDirImportsSpacesYAMLWithoutPersistingProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("preview-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try spacesYAMLFixture(stopScript: "echo preview-stop").write(
            to: projectDir.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let preview = try orchestrator.previewProject(dir: projectDir.path)

        XCTAssertEqual(preview.stopScript, "echo preview-stop")
        XCTAssertEqual(preview.processes.first?.command, "npm run api")
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.workspaces(projectID: preview.id).isEmpty)
    }

    func testPrepareGitProjectImportsSpacesYAMLWithoutPersistingUntilCommit() throws {
        let fixture = try makeTempGitRepo(name: "prepared-yaml-git-import")
        try spacesYAMLFixture(stopScript: "echo prepared-yaml-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add spaces yaml"], cwd: fixture.path)
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        var didCommit = false

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        defer { if !didCommit { try? orchestrator.discardPreparedGitProject(prepared) } }

        XCTAssertEqual(prepared.project.stopScript, "echo prepared-yaml-stop")
        XCTAssertNotNil(prepared.importedDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.workspaces(projectID: prepared.project.id).isEmpty)

        let project = try orchestrator.addPreparedGitProject(prepared) { config in
            config.stopScript = "echo edited-prepared-stop"
            config.agentLaunchers = [AgentLauncher(name: "Edited", command: "codex --model gpt-5")]
        }
        didCommit = true

        XCTAssertEqual(project.stopScript, "echo edited-prepared-stop")
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        XCTAssertEqual(defaultWorkspace.dir, prepared.defaultWorkspace.dir)
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo edited-prepared-stop")
        XCTAssertEqual(settings?.agentLaunchers.first?.name, "Edited")
    }

    func testImportSpacesYAMLUpdatesOnlyProjectWhenWorkspaceSyncIsOff() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.ports = [PortDefinition(id: "existing-port", name: "API_PORT")]
            config.processes = [ProcessTemplate(id: "existing-process", name: "api", command: "npm run api")]
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: defaultWorkspace.id) { settings in
            settings.stopScript = "echo workspace-stop"
            settings.processes = [ProcessTemplate(name: "workspace", command: "echo workspace")]
        }
        try spacesYAMLFixture(stopScript: "echo imported-stop").write(
            to: try orchestrator.spacesYAMLConfigURL(projectID: project.id), atomically: true, encoding: .utf8)

        let importedProject = try orchestrator.importSpacesYAML(projectID: project.id, updateAllWorkspaces: false)

        XCTAssertEqual(importedProject.stopScript, "echo imported-stop")
        XCTAssertEqual(importedProject.ports.first?.id, "existing-port")
        XCTAssertEqual(importedProject.processes.first?.id, "existing-process")
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo workspace-stop")
        XCTAssertEqual(settings?.processes.first?.name, "workspace")
    }

    func testPreviewProjectConfigDoesNotPersistImportedConfig() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path) { config in
            config.stopScript = "echo saved-stop"
            config.ports = [PortDefinition(id: "saved-port", name: "SAVED_PORT")]
        }
        let document = SpacesYAMLDocument(stopScript: "echo imported-stop", ports: [SpacesYAMLDocument.Port(name: "API_PORT")])

        let preview = try orchestrator.previewProjectConfig(projectID: project.id) { config in document.applying(to: &config) }

        XCTAssertEqual(preview.stopScript, "echo imported-stop")
        XCTAssertEqual(preview.ports.map(\.name), ["API_PORT"])
        let savedProject = try XCTUnwrap(try store.project(id: project.id))
        XCTAssertEqual(savedProject.stopScript, "echo saved-stop")
        XCTAssertEqual(savedProject.ports.map(\.name), ["SAVED_PORT"])
    }

    func testUpdateProjectConfigWithWorkspaceSyncKeepsInsertedPortsAlignedWithAssignments() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let api = PortDefinition(id: "port-api", name: "API_PORT")
        let project = try orchestrator.addProject(dir: projectDir.path) { config in config.ports = [api] }
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        defer { PortReserver.shared.releasePorts(workspaceID: workspace.id) }
        let previousAPIAssignment = try XCTUnwrap(try store.workspacePortsAssigned(workspaceID: workspace.id).first)

        let updatedProject = try orchestrator.updateProjectConfig(projectID: project.id, updateAllWorkspaces: true) { config in
            config.ports = [PortDefinition(name: "WEB_PORT"), PortDefinition(name: "API_PORT")]
        }

        XCTAssertEqual(updatedProject.ports.map(\.name), ["WEB_PORT", "API_PORT"])
        XCTAssertEqual(updatedProject.ports.last?.id, api.id)
        let assignments = try store.workspacePortsAssigned(workspaceID: workspace.id)
        XCTAssertEqual(assignments.map(\.name), ["WEB_PORT", "API_PORT"])
        let webAssignment = try XCTUnwrap(assignments.first { $0.name == "WEB_PORT" })
        let apiAssignment = try XCTUnwrap(assignments.first { $0.name == "API_PORT" })
        XCTAssertNotEqual(webAssignment.port, previousAPIAssignment.port)
        XCTAssertEqual(apiAssignment.port, previousAPIAssignment.port)
        XCTAssertEqual(apiAssignment.definitionID, api.id)
    }

    func testImportSpacesYAMLUpdatesActiveAndArchivedWorkspacesWhenWorkspaceSyncIsOn() throws {
        let repo = try makeTempGitRepo(name: "import-sync-archived")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let activeWorkspace = try orchestrator.createWorkspace(projectID: project.id, branch: "active")
        let archivedWorkspace = try orchestrator.createWorkspace(projectID: project.id, branch: "archived")
        _ = try orchestrator.archiveWorkspace(workspaceID: archivedWorkspace.id)
        try spacesYAMLFixture(stopScript: "echo synced-stop").write(
            to: try orchestrator.spacesYAMLConfigURL(projectID: project.id), atomically: true, encoding: .utf8)

        _ = try orchestrator.importSpacesYAML(projectID: project.id, updateAllWorkspaces: true)

        let activeSettings = try orchestrator.workspaceSettings(workspaceID: activeWorkspace.id)
        let archivedSettings = try orchestrator.workspaceSettings(workspaceID: archivedWorkspace.id)
        XCTAssertEqual(activeSettings?.stopScript, "echo synced-stop")
        XCTAssertEqual(activeSettings?.ports.map(\.name) ?? [], ["API_PORT"])
        XCTAssertEqual(activeSettings?.processes.first?.name, "api")
        XCTAssertEqual(archivedSettings?.stopScript, "echo synced-stop")
        XCTAssertEqual(archivedSettings?.browserSessions.first?.name, "app")
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: archivedWorkspace.id)).isArchived)
    }

    func testImportSpacesYAMLWithWorkspaceSyncRollsBackProjectAndEarlierWorkspacesOnFailure() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path) { config in
            config.stopScript = "echo old-stop"
            config.ports = [PortDefinition(id: "old-port", name: "OLD_PORT")]
            config.processes = [ProcessTemplate(id: "old-process", name: "old", command: "npm run old")]
            config.browserSessions = [BrowserSession(name: "old-app", url: "http://localhost:4000")]
            config.agentLaunchers = [AgentLauncher(name: "Old Codex", command: "old-codex")]
        }
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let conflictWorkspace = try orchestrator.createWorkspace(projectID: project.id)
        defer {
            PortReserver.shared.releasePorts(workspaceID: defaultWorkspace.id)
            PortReserver.shared.releasePorts(workspaceID: conflictWorkspace.id)
        }
        let defaultSettingsBefore = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id))
        let conflictSettingsBefore = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: conflictWorkspace.id))
        let defaultPortsBefore = try store.workspacePortsAssigned(workspaceID: defaultWorkspace.id)
        let conflictPortsBefore = try store.workspacePortsAssigned(workspaceID: conflictWorkspace.id)
        _ = try orchestrator.registerAgentWindow(workspaceID: conflictWorkspace.id, provider: .spaces, label: "api")
        try spacesYAMLFixture(stopScript: "echo imported-stop").write(
            to: try orchestrator.spacesYAMLConfigURL(projectID: project.id), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try orchestrator.importSpacesYAML(projectID: project.id, updateAllWorkspaces: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Duplicates: api"))
        }

        let restoredProject = try XCTUnwrap(try store.project(id: project.id))
        XCTAssertEqual(restoredProject.stopScript, "echo old-stop")
        XCTAssertEqual(restoredProject.ports.map(\.name), ["OLD_PORT"])
        XCTAssertEqual(restoredProject.processes.first?.command, "npm run old")

        let defaultSettingsAfter = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id))
        XCTAssertEqual(defaultSettingsAfter.stopScript, defaultSettingsBefore.stopScript)
        XCTAssertEqual(defaultSettingsAfter.ports.map(\.name), defaultSettingsBefore.ports.map(\.name))
        XCTAssertEqual(defaultSettingsAfter.processes.map(\.command), defaultSettingsBefore.processes.map(\.command))
        XCTAssertEqual(defaultSettingsAfter.browserSessions.map(\.url), defaultSettingsBefore.browserSessions.map(\.url))
        XCTAssertEqual(defaultSettingsAfter.agentLaunchers.map(\.command), defaultSettingsBefore.agentLaunchers.map(\.command))
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: defaultWorkspace.id).map { $0.name }, defaultPortsBefore.map { $0.name })
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: defaultWorkspace.id).map { $0.port }, defaultPortsBefore.map { $0.port })

        let conflictSettingsAfter = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: conflictWorkspace.id))
        XCTAssertEqual(conflictSettingsAfter.stopScript, conflictSettingsBefore.stopScript)
        XCTAssertEqual(conflictSettingsAfter.ports.map(\.name), conflictSettingsBefore.ports.map(\.name))
        XCTAssertEqual(conflictSettingsAfter.processes.map(\.command), conflictSettingsBefore.processes.map(\.command))
        XCTAssertEqual(conflictSettingsAfter.browserSessions.map(\.url), conflictSettingsBefore.browserSessions.map(\.url))
        XCTAssertEqual(conflictSettingsAfter.agentLaunchers.map(\.command), conflictSettingsBefore.agentLaunchers.map(\.command))
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: conflictWorkspace.id).map { $0.name }, conflictPortsBefore.map { $0.name })
        XCTAssertEqual(try store.workspacePortsAssigned(workspaceID: conflictWorkspace.id).map { $0.port }, conflictPortsBefore.map { $0.port })
    }

    func testExportSpacesYAMLOverwritesExistingFile() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let configURL = try orchestrator.spacesYAMLConfigURL(projectID: project.id)
        try "old: value\n".write(to: configURL, atomically: true, encoding: .utf8)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo exported-stop"
            config.agentLaunchers = [AgentLauncher(name: "Codex", command: "codex")]
        }

        let writtenURL = try orchestrator.exportSpacesYAML(projectID: project.id)
        let exported = try String(contentsOf: writtenURL, encoding: .utf8)

        XCTAssertEqual(writtenURL, configURL)
        XCTAssertTrue(exported.contains("stop_script: echo exported-stop"))
        XCTAssertTrue(exported.contains("command: codex"))
        XCTAssertFalse(exported.contains("old: value"))
    }

    // MARK: - buildWorkspaceEnv

    // Tests build workspace env sets spaces workspace dir by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvSetsSpacesWorkspaceDir() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/tmp/project/ws")
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])
        XCTAssertEqual(env["SPACES_WORKSPACE_DIR"], "/tmp/project/ws")
    }

    // Tests build workspace env sets spaces project dir by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvSetsSpacesProjectDir() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/tmp/project/ws")
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])
        XCTAssertEqual(env["SPACES_PROJECT_DIR"], "/tmp/project")
    }

    // Tests build workspace env does not contain scoped key by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvDoesNotContainScopedKey() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/tmp/project/ws")
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])
        let scopedKeys = env.keys.filter { $0.hasPrefix("spaces_") || $0.hasPrefix("SPACES_PROJECT_") && $0.hasSuffix("_WORKSPACE_DIR") }
        XCTAssertTrue(scopedKeys.isEmpty, "Expected no scoped cross-project keys, found: \(scopedKeys)")
    }

    // Tests build workspace env includes named ports by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvIncludesNamedPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/tmp/project/ws")
        let ports: [(port: Int, name: String)] = [(port: 3000, name: "FRONTEND_PORT"), (port: 8080, name: "API_PORT")]
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: ports)
        XCTAssertEqual(env["FRONTEND_PORT"], "3000")
        XCTAssertEqual(env["API_PORT"], "8080")
        XCTAssertEqual(env["SPACES_WORKSPACE_DIR"], "/tmp/project/ws")
        XCTAssertEqual(env["SPACES_PROJECT_DIR"], "/tmp/project")
    }

    func testBuildWorkspaceEnvDoesNotIncludePath() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/tmp/project/ws")

        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])

        XCTAssertNil(env["PATH"])
    }

    func testBuildWorkspaceEnvSkipsUnnamedPortsAndDoesNotSynthesizeFallbackKeys() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/tmp/project/ws")
        let ports: [(port: Int, name: String)] = [(port: 3000, name: " "), (port: 8080, name: "API_PORT")]

        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: ports)

        XCTAssertNil(env["PORT0"])
        XCTAssertNil(env["PORT1"])
        XCTAssertEqual(env["API_PORT"], "8080")
    }

    // MARK: - resolveEnvVars

    // Tests applyEnvVars substitutes a single named variable.
    func testApplyEnvVarsSubstitutesSingleVar() {
        let orchestrator = WorkspaceOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars("PORT=$FRONTEND_PORT npm run dev", env: ["FRONTEND_PORT": "20002"])
        XCTAssertEqual(result, "PORT=20002 npm run dev")
    }

    // Tests applyEnvVars substitutes multiple variables in one command.
    func testApplyEnvVarsSubstitutesMultipleVars() {
        let orchestrator = WorkspaceOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars(
            "PORT=$FRONTEND_PORT BACKEND=$BACKEND_PORT node server.js", env: ["FRONTEND_PORT": "3000", "BACKEND_PORT": "4000"])
        XCTAssertEqual(result, "PORT=3000 BACKEND=4000 node server.js")
    }

    // Tests applyEnvVars leaves unknown variables unchanged.
    func testApplyEnvVarsLeavesUnknownVarsUnchanged() {
        let orchestrator = WorkspaceOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars("PORT=$UNKNOWN npm start", env: ["FRONTEND_PORT": "3000"])
        XCTAssertEqual(result, "PORT=$UNKNOWN npm start")
    }

    // Tests applyEnvVars returns command unchanged when env is empty.
    func testApplyEnvVarsEmptyEnvReturnsCommandUnchanged() {
        let orchestrator = WorkspaceOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars("PORT=$FRONTEND_PORT npm run dev", env: [:])
        XCTAssertEqual(result, "PORT=$FRONTEND_PORT npm run dev")
    }

    // Tests resolveEnvVars replaces named port variable with allocated port number.
    func testResolveEnvVarsReplacesNamedPortVar() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [20002], names: ["FRONTEND_PORT"])

        let resolved = try orchestrator.resolveEnvVars(in: "PORT=$FRONTEND_PORT npm run dev", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "PORT=20002 npm run dev")
    }

    // Tests resolveEnvVars resolves multiple named ports.
    func testResolveEnvVarsResolvesMultipleNamedPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 4000], names: ["FRONTEND_PORT", "BACKEND_PORT"])

        let resolved = try orchestrator.resolveEnvVars(in: "FRONTEND=$FRONTEND_PORT BACKEND=$BACKEND_PORT node app.js", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "FRONTEND=3000 BACKEND=4000 node app.js")
    }

    // Tests resolveEnvVars leaves command unchanged when no ports are allocated.
    func testResolveEnvVarsNoPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)

        let resolved = try orchestrator.resolveEnvVars(in: "npm start", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "npm start")
    }

    // Tests resolveEnvVars injects SPACES_WORKSPACE_DIR into command.
    func testResolveEnvVarsInjectsWorkspaceDir() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)

        let resolved = try orchestrator.resolveEnvVars(in: "cd $SPACES_WORKSPACE_DIR && npm start", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "cd /workspaces/myapp/dev && npm start")
    }

    // MARK: - updatePortRange

    // Tests updatePortRange persists to the app config by arranging representative inputs and asserting the expected result.
    func testUpdatePortRangePersists() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let updated = try orchestrator.updatePortRange(PortRange(start: 25000, end: 35000))
        XCTAssertEqual(updated.portRange.start, 25000)
        XCTAssertEqual(updated.portRange.end, 35000)
        XCTAssertEqual(try orchestrator.appConfig().portRange.start, 25000)
    }

    // MARK: - workspacePorts

    // Tests workspacePortsNamed returns named ports by arranging representative inputs and asserting the expected result.
    func testWorkspacePortsNamedReturnsNamedPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/projects/myapp")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 4000], names: ["FRONTEND", "BACKEND"])

        let named = try orchestrator.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(named[0].name, "FRONTEND")
        XCTAssertEqual(named[0].port, 3000)
        XCTAssertEqual(named[1].name, "BACKEND")
        XCTAssertEqual(named[1].port, 4000)
    }

    func testPreparedGitProjectImportSavesWithSymlinkedManagedReposRoot() throws {
        let fixture = try makeTempGitRepo(name: "symlinked-root-repo")
        let root = try makeTempDirectory()
        let actualReposRoot = root.appendingPathComponent("actual-repos", isDirectory: true)
        let reposRoot = root.appendingPathComponent("repos-link", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: actualReposRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: reposRoot, withDestinationURL: actualReposRoot)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let managedDirname = managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "symlinked-root-repo")
        let entryProjectDir = reposRoot.appendingPathComponent(managedDirname, isDirectory: true)
        let normalizedProjectDir = actualReposRoot.appendingPathComponent(managedDirname, isDirectory: true).path

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        let project = try orchestrator.addPreparedGitProject(prepared) { _ in }

        XCTAssertEqual(prepared.project.dir, normalizedProjectDir)
        XCTAssertEqual(project.dir, normalizedProjectDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryProjectDir.appendingPathComponent("HEAD").path))
        XCTAssertEqual(try store.projects().map(\.dir), [normalizedProjectDir])
    }

    // Tests resolvedWorkspaceBrowserSessions expands port env vars to their allocated values.
    func testResolvedWorkspaceBrowserSessionsExpandsPortEnvVars() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 4000], names: ["PORT", "API_PORT"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "Frontend", url: "http://localhost:$PORT"), BrowserSession(name: "API", url: "http://localhost:$API_PORT/v1"),
            ])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].name, "Frontend")
        XCTAssertEqual(resolved[0].url, "http://localhost:3000")
        XCTAssertEqual(resolved[1].name, "API")
        XCTAssertEqual(resolved[1].url, "http://localhost:4000/v1")
    }
}

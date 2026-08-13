import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

extension OrchestratorTests {

    /// Workspace teardown runs off the Device API's serial request queue, so it no longer excludes other
    /// requests by construction — every workspace-scoped mutation has to be gated against it. A process,
    /// coding agent, or terminal started after the teardown snapshotted the workspace's rows but before it
    /// deleted the record would survive as a live terminal in a worktree that has been removed, with no
    /// row left to stop it by.
    func testWorkspaceMutationsFailLoudlyWhileThatWorkspaceIsBeingDeleted() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-workspace")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let teardownStarted = expectation(description: "the delete reached its terminal teardown")
        teardownStarted.assertForOverFulfill = false
        let releaseTeardown = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)
        // Two instances stand in for two Device API requests: the server opens a fresh orchestrator per
        // request and runs teardown on its own queue with yet another one.
        let deleter = makeTestOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot,
            builtInTerminalSessionTerminator: { _ in
                teardownStarted.fulfill()
                releaseTeardown.wait()
            })
        let contender = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try deleter.addProject(dir: repo.path)
        let workspace = try deleter.createWorkspace(projectID: project.id, branch: "feature-deleting")
        let bystander = try deleter.createWorkspace(projectID: project.id, branch: "feature-bystander")
        // A running process gives the delete a terminal to tear down, which is where it parks.
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-deleting", workspaceID: workspace.id, templateName: "api", command: "npm start",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "session-deleting", pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: nil, exitedAt: nil))

        Thread.detachNewThread {
            _ = try? deleter.archiveWorkspace(workspaceID: workspace.id)
            deleteFinished.signal()
        }
        wait(for: [teardownStarted], timeout: 30)

        for (label, mutation) in busyWorkspaceMutations(on: contender, workspaceID: workspace.id) {
            XCTAssertThrowsError(try mutation(), label) { error in
                XCTAssertTrue("\(error)".contains("already in progress"), "\(label) should report the busy error, got: \(error)")
            }
        }
        // A workspace the delete does not touch is not held hostage by it.
        XCTAssertNoThrow(try contender.updateWorkspaceNotes(workspaceID: bystander.id, notes: "still editable"))

        releaseTeardown.signal()
        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 30), .success)
        XCTAssertNil(try store.workspace(id: workspace.id))
    }

    /// Every workspace-scoped mutation that creates or changes runtime or configuration state, named once
    /// so the teardown test asserts the whole surface rather than a sample of it.
    private func busyWorkspaceMutations(on orchestrator: WorkspaceOrchestrator, workspaceID: String) -> [(String, () throws -> Void)] {
        [
            ("runConfiguredProcess", { _ = try orchestrator.runConfiguredProcess(workspaceID: workspaceID, processKey: "api") }),
            ("restartWorkspaceProcess", { try orchestrator.restartWorkspaceProcess(workspaceID: workspaceID, processID: "process-deleting") }),
            ("reserveWorkspaceTerminalLaunch", { _ = try orchestrator.reserveWorkspaceTerminalLaunch(workspaceID: workspaceID) }),
            (
                "createWorkspaceTerminalSession",
                { _ = try orchestrator.createWorkspaceTerminalSession(workspaceID: workspaceID, title: nil, command: nil) }
            ), ("updateWorkspaceNotes", { try orchestrator.updateWorkspaceNotes(workspaceID: workspaceID, notes: "note") }),
            ("updateWorkspaceHidden", { try orchestrator.updateWorkspaceHidden(workspaceID: workspaceID, isHidden: true) }),
            ("updateWorkspaceSettings", { try orchestrator.updateWorkspaceSettings(workspaceID: workspaceID) { $0.stopScript = "echo stop" } }),
        ]
    }

    /// A setup script is user-authored and can run for minutes. Creating a workspace holds the project key
    /// only for the structural half — record, worktree, seeded settings and ports — and releases it before
    /// running the script, so a delete anywhere in the project stays possible while setup runs. Holding the
    /// key across the script would make every sibling delete fail with "Project action is already in
    /// progress", contradicting the contract `runWorkspaceSetup` documents.
    func testWorkspaceSetupDoesNotBlockDeletingASiblingWorkspace() throws {
        let repo = try makeTempGitRepo(name: "setup-gate-sibling-delete")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let creator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let deleter = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try creator.addProject(dir: repo.path)
        // Created before the project has a setup script, so its own create returns immediately.
        let sibling = try creator.createWorkspace(projectID: project.id, branch: "feature-sibling")

        // A real setup script that parks until the test releases it: the delete has to land while it runs.
        let startedMarker = root.appendingPathComponent("setup-started")
        let releaseMarker = root.appendingPathComponent("setup-release")
        _ = try creator.updateProjectConfig(projectID: project.id, updateAllWorkspaces: false) {
            $0.setupScript = "touch '\(startedMarker.path)'; while [ ! -f '\(releaseMarker.path)' ]; do sleep 0.05; done"
        }

        var createError: (any Error)?
        let createFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do { _ = try creator.createWorkspace(projectID: project.id, branch: "feature-slow-setup") } catch { createError = error }
            createFinished.signal()
        }
        XCTAssertTrue(waitForFile(at: startedMarker, timeout: 60), "the setup script never started")

        // The point: a sibling delete, which claims the same project key, is not blocked by the setup.
        XCTAssertNoThrow(try deleter.archiveWorkspace(workspaceID: sibling.id))
        XCTAssertNil(try store.workspace(id: sibling.id))

        XCTAssertTrue(FileManager.default.createFile(atPath: releaseMarker.path, contents: nil))
        XCTAssertEqual(createFinished.wait(timeout: .now() + 120), .success)
        XCTAssertNil(createError, "the create should still have succeeded")

        // The parked setup records its outcome normally once it finishes.
        let created = try XCTUnwrap(try store.workspaces(projectID: project.id).first { $0.branch == "feature-slow-setup" })
        XCTAssertEqual(try store.workspaceSetupState(workspaceID: created.id)?.status, .succeeded)
    }

    /// A process configured `onExit: .restart` is relaunched by the detached process-exit monitor, which
    /// runs outside every lifecycle action. Deleting the workspace terminates that process, so the monitor
    /// sees it die — and without the workspace gate it would relaunch it into a worktree the delete is
    /// about to remove, leaving a live process whose record the delete then drops. The restart is skipped
    /// silently instead, because a background service has nobody to report a busy gate to.
    func testAutomaticProcessRestartIsSkippedWhileItsWorkspaceIsBeingDeleted() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-restart-on-exit")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let teardownStarted = expectation(description: "the delete reached its terminal teardown")
        teardownStarted.assertForOverFulfill = false
        let releaseTeardown = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)
        let didRelaunch = LockedBox(false)
        let deleter = makeTestOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot,
            builtInTerminalSessionTerminator: { _ in
                teardownStarted.fulfill()
                releaseTeardown.wait()
            })
        // The monitor runs on its own orchestrator, exactly as `ProcessExitMonitorService` does. Any
        // relaunch would have to go through this launcher.
        let monitor = makeTestOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot,
            builtInTerminalSessionLauncher: { _ in
                didRelaunch.set(true)
                throw WorkspaceError.invalidArgument(message: "no relaunch was expected")
            })

        let project = try deleter.addProject(dir: repo.path)
        let workspace = try deleter.createWorkspace(projectID: project.id, branch: "feature-restarting")
        try store.setWorkspaceProcesses(
            workspaceID: workspace.id, processes: [ProcessTemplate(id: "template-api", name: "api", command: "echo api", onExit: .restart)])
        // A running row whose PID is dead: the monitor's next tick sees the exit and consults `onExit`.
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-restarting", workspaceID: workspace.id, templateID: "template-api", templateName: "api", command: "echo api",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "session-restarting", pid: 99_999, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120)), exitedAt: nil))

        Thread.detachNewThread {
            _ = try? deleter.archiveWorkspace(workspaceID: workspace.id)
            deleteFinished.signal()
        }
        wait(for: [teardownStarted], timeout: 30)

        // The monitor tick that lands mid-teardown, while the workspace's rows are still present.
        XCTAssertNoThrow(try monitor.checkAndUpdateProcessStatuses(ignoreStartupGracePeriod: true))
        XCTAssertFalse(didRelaunch.get(), "no process may be relaunched into a workspace being deleted")

        releaseTeardown.signal()
        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 60), .success)
        XCTAssertNil(try store.workspace(id: workspace.id))
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty, "nothing outlives the delete")
        XCTAssertFalse(didRelaunch.get())
    }

    /// A non-git project owns exactly one workspace, so creating one again returns the record that already
    /// exists. That repeat create must stay a no-op: the workspace was provisioned when it was created, and
    /// running the project's setup script again would re-execute an arbitrary user-authored command every
    /// time a client retried the create.
    func testRepeatCreateOnANonGitProjectRunsTheSetupScriptOnlyOnce() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("plain-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        // Each setup run appends a line, so the file's line count is the number of runs.
        let runLog = root.appendingPathComponent("setup-runs.log")
        let project = try orchestrator.addProject(dir: projectDir.path) { $0.setupScript = "echo ran >> '\(runLog.path)'" }

        // The single workspace already exists — `addProject` seeded it — so neither create provisions
        // anything and neither may run the script.
        let first = try orchestrator.createWorkspace(projectID: project.id)
        let second = try orchestrator.createWorkspace(projectID: project.id)

        XCTAssertEqual(first.id, second.id, "a non-git project keeps its single workspace")
        XCTAssertEqual(setupRunCount(loggedAt: runLog), 0, "a create that returned the existing workspace must not run the setup script")

        // The counterpart: a create that genuinely makes a workspace runs the script exactly once.
        let gitRepo = try makeTempGitRepo(name: "setup-run-once-git")
        let gitRunLog = root.appendingPathComponent("git-setup-runs.log")
        let gitProject = try orchestrator.addProject(dir: gitRepo.path) { $0.setupScript = "echo ran >> '\(gitRunLog.path)'" }
        _ = try orchestrator.createWorkspace(projectID: gitProject.id, branch: "feature-provisioned")
        XCTAssertEqual(setupRunCount(loggedAt: gitRunLog), 1)
    }

    private func setupRunCount(loggedAt url: URL) -> Int { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count }

    private func waitForFile(at url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Deleting a workspace removes a git worktree and can delete branches — writes to the project's
    /// repository, not just to the workspace. So it claims the project key too, and a `createWorkspace`
    /// in the same project (which adds a worktree holding only that key) cannot run alongside it. One of
    /// the two fails loudly; the git operations never overlap.
    func testDeletingAWorkspaceBlocksAConcurrentCreateInTheSameProject() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-archive-create")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let teardownStarted = expectation(description: "the delete reached its terminal teardown")
        teardownStarted.assertForOverFulfill = false
        let releaseTeardown = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)
        let deleter = makeTestOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot,
            builtInTerminalSessionTerminator: { _ in
                teardownStarted.fulfill()
                releaseTeardown.wait()
            })
        let contender = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try deleter.addProject(dir: repo.path)
        let otherProject = try deleter.addProject(dir: try makeTempGitRepo(name: "teardown-gate-archive-create-other").path)
        let workspace = try deleter.createWorkspace(projectID: project.id, branch: "feature-archived")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-archived", workspaceID: workspace.id, templateName: "api", command: "npm start",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "session-archived", pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: nil, exitedAt: nil))

        Thread.detachNewThread {
            _ = try? deleter.archiveWorkspace(workspaceID: workspace.id, deleteLocalBranch: true, deleteRemoteBranch: false)
            deleteFinished.signal()
        }
        wait(for: [teardownStarted], timeout: 30)

        XCTAssertThrowsError(try contender.createWorkspace(projectID: project.id, branch: "feature-concurrent")) { error in
            XCTAssertTrue("\(error)".contains("already in progress"), "expected the busy error, got: \(error)")
        }
        // A rename is the other write into the project's shared ref store, and it is excluded too.
        XCTAssertThrowsError(try contender.updateWorkspaceMetadata(workspaceID: workspace.id, branch: "feature-renamed")) { error in
            XCTAssertTrue("\(error)".contains("already in progress"), "expected the busy error, got: \(error)")
        }
        // A delete in one project must not hold another project's creates hostage.
        XCTAssertNoThrow(try contender.createWorkspace(projectID: otherProject.id, branch: "feature-elsewhere"))

        releaseTeardown.signal()
        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 60), .success)
        XCTAssertNil(try store.workspace(id: workspace.id))
        XCTAssertNil(try store.workspace(dir: workspacesRoot.appendingPathComponent("feature-concurrent", isDirectory: true).path))
        XCTAssertFalse(GitClient().branchExists(path: repo.path, branch: "feature-concurrent"), "the rejected create left no branch behind")
    }

    /// Applying a project template to every workspace writes settings for each of them, so it must not run
    /// while one of those workspaces is being deleted: the write would land on a row the delete is about to
    /// remove, and its rollback would then fail on the missing row and leave the project half-configured.
    /// Whichever order the two arrive in, the project's configuration ends up whole.
    func testDeletingAWorkspaceAndApplyingProjectConfigToAllWorkspacesCannotOverlap() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-archive-config")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let teardownStarted = expectation(description: "the delete reached its terminal teardown")
        teardownStarted.assertForOverFulfill = false
        let releaseTeardown = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)
        let deleter = makeTestOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot,
            builtInTerminalSessionTerminator: { _ in
                teardownStarted.fulfill()
                releaseTeardown.wait()
            })
        let contender = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try deleter.addProject(dir: repo.path)
        let doomed = try deleter.createWorkspace(projectID: project.id, branch: "feature-doomed-config")
        let survivor = try deleter.createWorkspace(projectID: project.id, branch: "feature-survivor")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-doomed-config", workspaceID: doomed.id, templateName: "api", command: "npm start",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "session-doomed-config", pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: nil, exitedAt: nil))

        Thread.detachNewThread {
            _ = try? deleter.archiveWorkspace(workspaceID: doomed.id)
            deleteFinished.signal()
        }
        wait(for: [teardownStarted], timeout: 30)

        XCTAssertThrowsError(
            try contender.updateProjectConfig(projectID: project.id, updateAllWorkspaces: true) { $0.stopScript = "echo mid-delete" }
        ) { error in XCTAssertTrue("\(error)".contains("already in progress"), "expected the busy error, got: \(error)") }

        releaseTeardown.signal()
        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 60), .success)
        XCTAssertNil(try store.workspace(id: doomed.id))
        // The rejected update wrote nothing, and the same update run after the delete lands whole.
        XCTAssertNil(try store.workspaceStopScript(workspaceID: survivor.id))
        _ = try contender.updateProjectConfig(projectID: project.id, updateAllWorkspaces: true) { $0.stopScript = "echo after-delete" }
        XCTAssertEqual(try store.workspaceStopScript(workspaceID: survivor.id), "echo after-delete")
    }

    /// Updating a project's settings is a read-modify-write of its record, so it runs under the project
    /// gate: a delete landing between the read and the write would put the deleted project straight back,
    /// and its default-workspace ensure would rebuild rows under directories the teardown had removed. A
    /// resurrected project is the failure here — the delete must stay done.
    func testUpdatingProjectConfigFailsLoudlyWhileTheProjectIsBeingDeletedAndCannotResurrectIt() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-config-update")
        let otherRepo = try makeTempGitRepo(name: "teardown-gate-config-update-other")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let teardownStarted = expectation(description: "the project delete reached its terminal teardown")
        teardownStarted.assertForOverFulfill = false
        let releaseTeardown = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)
        let deleter = makeTestOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot,
            builtInTerminalSessionTerminator: { _ in
                teardownStarted.fulfill()
                releaseTeardown.wait()
            })
        let contender = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try deleter.addProject(dir: repo.path)
        let otherProject = try deleter.addProject(dir: otherRepo.path)
        let workspace = try deleter.createWorkspace(projectID: project.id, branch: "feature-config")
        let timestamp = "2026-08-03T00:00:00Z"
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-config", workspaceID: workspace.id, provider: .spaces, label: "codex", terminalTrackingID: "session-config",
                sessionKey: nil, status: .spinning, createdAt: timestamp, updatedAt: timestamp))

        Thread.detachNewThread {
            try? deleter.removeProject(id: project.id)
            deleteFinished.signal()
        }
        wait(for: [teardownStarted], timeout: 30)

        XCTAssertThrowsError(try contender.updateProjectConfig(projectID: project.id) { $0.setupScript = "echo late" }) { error in
            XCTAssertTrue("\(error)".contains("already in progress"), "expected the busy error, got: \(error)")
        }
        // A project the delete does not touch keeps taking configuration updates.
        XCTAssertNoThrow(try contender.updateProjectConfig(projectID: otherProject.id) { $0.setupScript = "echo fine" })

        releaseTeardown.signal()
        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 60), .success)
        XCTAssertNil(try store.project(id: project.id), "a rejected config update must not resurrect the deleted project")
        XCTAssertTrue(try store.workspaces(projectID: project.id).isEmpty, "no default workspace may be rebuilt for a deleted project")
    }

    /// A setup script can run for minutes and a delete has to stay possible throughout, so setup takes no
    /// lifecycle gate and its workspace can disappear mid-run. Finishing against a deleted workspace has
    /// to be a silent no-op: the settings foreign key rejects the write, so an unguarded setup ends by
    /// throwing a raw `FOREIGN KEY constraint failed` at whoever triggered it rather than accepting that
    /// the delete won.
    func testSetupFinishingAfterItsWorkspaceWasDeletedWritesNoState() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-setup-write")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-setup")
        // A normal setup records its outcome.
        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)
        XCTAssertEqual(try store.workspaceSetupState(workspaceID: workspace.id)?.status, .succeeded)

        // The delete wins the race: everything the setup writes afterwards is for a workspace that is gone.
        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)
        try orchestrator.runWorkspaceSetup(project: project, workspace: workspace)

        XCTAssertNil(try store.workspace(id: workspace.id), "the delete stands")
        XCTAssertNil(try store.workspaceSetupState(workspaceID: workspace.id), "no setup state may outlive the workspace it describes")
    }

    /// A project delete holds its gate from before it reads its workspace list until every worktree is
    /// gone, so no workspace can be added to the project inside that window and every workspace the
    /// project has is torn down — record, worktree and all. The end state is the point: a workspace whose
    /// record is cascaded away by the project delete but whose worktree survives is the failure this
    /// guards, and it is invisible from the record count alone.
    func testDeletingAProjectRejectsConcurrentCreatesAndLeavesNoWorktreeBehind() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-project-whole")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let teardownStarted = expectation(description: "the project delete reached its terminal teardown")
        teardownStarted.assertForOverFulfill = false
        let releaseTeardown = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)
        let deleter = makeTestOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot,
            builtInTerminalSessionTerminator: { _ in
                teardownStarted.fulfill()
                releaseTeardown.wait()
            })
        let contender = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try deleter.addProject(dir: repo.path)
        let workspace = try deleter.createWorkspace(projectID: project.id, branch: "feature-doomed")
        let workspaceDir = workspace.dir
        // An agent row gives the delete a terminal to tear down, which is where it parks — past the point
        // where it has read the project's workspace list.
        let timestamp = "2026-08-03T00:00:00Z"
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-doomed", workspaceID: workspace.id, provider: .spaces, label: "codex", terminalTrackingID: "session-doomed",
                sessionKey: nil, status: .spinning, createdAt: timestamp, updatedAt: timestamp))

        var deleteError: (any Error)?
        Thread.detachNewThread {
            do { try deleter.removeProject(id: project.id) } catch { deleteError = error }
            deleteFinished.signal()
        }
        wait(for: [teardownStarted], timeout: 30)

        XCTAssertThrowsError(try contender.createWorkspace(projectID: project.id, branch: "feature-slipped-in")) { error in
            XCTAssertTrue("\(error)".contains("already in progress"), "expected the busy error, got: \(error)")
        }

        releaseTeardown.signal()
        XCTAssertEqual(deleteFinished.wait(timeout: .now() + 60), .success)
        XCTAssertNil(deleteError, "the delete should have run to completion")
        XCTAssertNil(try store.project(id: project.id))
        XCTAssertTrue(try store.workspaces(projectID: project.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir), "no worktree may outlive the project that owned it")
        // A workspace delete that queued behind the project delete finds nothing left and says so plainly,
        // rather than failing somewhere inside the teardown it can no longer resolve.
        XCTAssertThrowsError(try contender.archiveWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue("\(error)".contains("Workspace not found."), "expected the not-found error, got: \(error)")
        }
    }

    /// A session create resolves its workspace under the lifecycle gate, so it can never launch against a
    /// record a delete has already removed: it fails loudly and starts no terminal at all. A launch that
    /// went ahead would leave a live shell in a directory that is gone, with no row to stop it by.
    func testCreatingATerminalSessionForADeletedWorkspaceFailsLoudlyAndLaunchesNothing() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-session-create")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let didLaunch = LockedBox(false)
        let orchestrator = makeTestOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot,
            builtInTerminalSessionLauncher: { _ in
                didLaunch.set(true)
                throw WorkspaceError.invalidArgument(message: "no terminal launch was expected")
            })

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-session")
        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertThrowsError(try orchestrator.createWorkspaceTerminalSession(workspaceID: workspace.id, title: nil, command: nil))
        XCTAssertThrowsError(try orchestrator.createWorkspaceAgentSession(workspaceID: workspace.id, command: "codex", title: nil))
        XCTAssertFalse(didLaunch.get(), "no terminal may be launched for a workspace that is gone")
    }

    /// Deleting a project tears down every workspace in it, so it claims each of their lifecycle gates —
    /// and claims them all before any destructive work. A workspace already busy makes the whole delete
    /// reject rather than leaving the project half-removed.
    func testDeletingAProjectIsRejectedWholeWhileOneOfItsWorkspacesIsBusy() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-project-busy")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let holder = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let contender = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try holder.addProject(dir: repo.path)
        let busyWorkspace = try holder.createWorkspace(projectID: project.id, branch: "feature-busy")
        let otherWorkspace = try holder.createWorkspace(projectID: project.id, branch: "feature-other")
        let automation = Automation(
            id: "project-busy-automation", name: "Project busy", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script,
            script: "true", workspaceID: otherWorkspace.id, timeoutSeconds: nil, concurrencyPolicy: .allow, missedRunPolicy: .runOnce,
            nextFireTime: nil, createdAt: Date(), updatedAt: Date())
        try store.upsertAutomation(automation)
        let service = AutomationService(store: store, orchestrator: contender, binaryDirectory: "/usr/bin", logError: { _ in })
        WorkspaceOrchestrator.setProcessWideAutomationWorkspaceTeardown {
            try service.deleteAutomationsTargetingWorkspaceDuringTeardown(workspaceID: $0)
        }
        defer { WorkspaceOrchestrator.setProcessWideAutomationWorkspaceTeardown(nil) }
        let workspaceCountBeforeDelete = try store.workspaces(projectID: project.id).count

        let lockHeld = expectation(description: "a workspace action is in flight")
        let releaseLock = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? holder.withWorkspaceLifecycleLock(workspaceID: busyWorkspace.id) {
                lockHeld.fulfill()
                releaseLock.wait()
            }
        }
        wait(for: [lockHeld], timeout: 15)
        defer { releaseLock.signal() }

        XCTAssertThrowsError(try contender.removeProject(id: project.id)) { error in
            XCTAssertTrue("\(error)".contains("already in progress"), "expected the busy error, got: \(error)")
        }
        XCTAssertNotNil(try store.project(id: project.id), "the project survives a rejected delete")
        XCTAssertEqual(try store.workspaces(projectID: project.id).count, workspaceCountBeforeDelete, "no workspace record is dropped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherWorkspace.dir), "no worktree is removed by a rejected delete")
        XCTAssertNotNil(try store.automation(id: automation.id), "a rejected project delete keeps targeting automations")
    }

    /// A workspace created while its project is being deleted would outlive the project as an orphan, and
    /// no workspace gate can cover it because the workspace does not exist yet — hence the project gate.
    func testCreatingAWorkspaceFailsLoudlyWhileItsProjectIsBeingDeleted() throws {
        let repo = try makeTempGitRepo(name: "teardown-gate-project-create")
        let otherRepo = try makeTempGitRepo(name: "teardown-gate-project-create-other")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let holder = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let contender = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try holder.addProject(dir: repo.path)
        let otherProject = try holder.addProject(dir: otherRepo.path)

        let lockHeld = expectation(description: "a project teardown is in flight")
        let releaseLock = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? holder.withProjectLifecycleLock(projectID: project.id) {
                lockHeld.fulfill()
                releaseLock.wait()
            }
        }
        wait(for: [lockHeld], timeout: 15)
        defer { releaseLock.signal() }

        XCTAssertThrowsError(try contender.createWorkspace(projectID: project.id, branch: "feature-late")) { error in
            XCTAssertTrue("\(error)".contains("already in progress"), "expected the busy error, got: \(error)")
        }
        // Another project's creates are unaffected.
        XCTAssertNoThrow(try contender.createWorkspace(projectID: otherProject.id, branch: "feature-elsewhere"))
    }

    // The Device API builds a fresh orchestrator per request and runs workspace/project teardown on its
    // own queue with another one, so the per-workspace lifecycle gate must span instances: a mutation
    // racing a teardown fails loudly instead of interleaving with it.
    func testWorkspaceLifecycleLockSerializesAcrossOrchestratorInstances() throws {
        let store = try makeTemporaryStore()
        let holder = makeTestOrchestrator(store: store)
        let contender = makeTestOrchestrator(store: store)

        let lockHeld = expectation(description: "holder entered the lifecycle lock")
        let releaseLock = DispatchSemaphore(value: 0)
        let workspaceID = "lifecycle-gate-cross-instance-\(UUID().uuidString)"
        Thread.detachNewThread {
            try? holder.withWorkspaceLifecycleLock(workspaceID: workspaceID) {
                lockHeld.fulfill()
                releaseLock.wait()
            }
        }
        wait(for: [lockHeld], timeout: 5)
        defer { releaseLock.signal() }

        XCTAssertThrowsError(try contender.withWorkspaceLifecycleLock(workspaceID: workspaceID) {}) { error in
            XCTAssertTrue("\(error)".contains("already in progress"), "expected the busy error, got: \(error)")
        }
        // Another workspace's lifecycle is not held hostage by the in-flight teardown.
        XCTAssertNoThrow(try contender.withWorkspaceLifecycleLock(workspaceID: "\(workspaceID)-other") {})
    }

    // Tests workspace stop script is seeded from project and can be overridden by arranging representative inputs and asserting the expected result.
    func testWorkspaceStopScriptIsSeededFromProjectAndCanBeOverridden() throws {
        let repo = try makeTempGitRepo(name: "stop-script-seed")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.stopScript = "echo project-stop" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")
        XCTAssertEqual(try orchestrator.workspaceSettings(workspaceID: workspace.id)?.stopScript, "echo project-stop")

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.stopScript = "echo workspace-stop" }
        XCTAssertEqual(try orchestrator.workspaceSettings(workspaceID: workspace.id)?.stopScript, "echo workspace-stop")

        // Project-level changes do not overwrite workspace-level overrides.
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.stopScript = "echo project-stop-updated" }
        XCTAssertEqual(try orchestrator.workspaceSettings(workspaceID: workspace.id)?.stopScript, "echo workspace-stop")
    }

    // Tests suggested workspace name matches auto generated dirname by arranging representative inputs and asserting the expected result.
    func testSuggestedWorkspaceNameMatchesAutoGeneratedDirname() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-default")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")

        // The display name is the branch; the checkout directory is a generated food
        // name chosen independently of the branch.
        XCTAssertEqual(workspace.displayName, "feature")
        XCTAssertEqual(workspace.branch, "feature")
        XCTAssertNotNil(workspace.dirname)
        XCTAssertNotEqual(workspace.dirname, "feature")

        let next = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-2")
        XCTAssertNotEqual(next.dirname, workspace.dirname)
    }

    // Tests static workspace name suggestion chooses first available food name by arranging representative inputs and asserting the expected result.
    func testSuggestWorkspaceNameUsesFirstAvailableCandidate() {
        XCTAssertEqual(WorkspaceOrchestrator.suggestWorkspaceName(existingNames: Set<String>()), "almond")
        XCTAssertEqual(WorkspaceOrchestrator.suggestWorkspaceName(existingNames: Set(["almond"])), "anchovy")
    }

    // Tests deferred workspace setup updates state and runs setup script when requested by arranging representative inputs and asserting the expected result.
    func testDeferredWorkspaceSetupUpdatesStateAndRunsSetupScript() throws {
        let repo = try makeTempGitRepo(name: "deferred-setup")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "echo ready > .spaces-setup-marker" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature", runSetupScript: false)
        let pendingState = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(pendingState.status, .pending)

        let markerURL = URL(fileURLWithPath: workspace.dir, isDirectory: true).appending(path: ".spaces-setup-marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)
        let succeededState = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(succeededState.status, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    // Tests first launch runs deferred workspace setup automatically by arranging a pending setup state and asserting launch completes setup.
    func testLaunchWorkspaceRunsDeferredSetupAutomatically() throws {
        let repo = try makeTempGitRepo(name: "deferred-launch-setup")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "echo ready > .spaces-launch-marker" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature", runSetupScript: false)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .pending)

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let markerURL = URL(fileURLWithPath: workspace.dir, isDirectory: true).appending(path: ".spaces-launch-marker")
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(try store.workspace(id: workspace.id)?.isRunning ?? false)
    }

    func testLaunchWorkspaceAfterArchiveThrowsBecauseTheRecordIsGone() throws {
        let repo = try makeTempGitRepo(name: "archived-pending-setup")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "echo ready > .spaces-launch-marker" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature", runSetupScript: false)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .pending)

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertNil(try store.workspace(id: workspace.id), "archiving removes the workspace record")
        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace not found"))
        }
    }

    func testWorkspaceSetupFailureStoresExitCodeLogAndBlocksLaunch() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "echo setup stdout; echo setup stderr >&2; exit 7"
        }
        let workspace = try orchestrator.createWorkspace(projectID: project.id, runSetupScript: false)

        try withEnv(name: SpacesProfile.runtimeDirectoryEnvironmentVariable, value: runtimeDir.path) {
            XCTAssertThrowsError(try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Setup script exited with code 7"))
            }

            let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
            XCTAssertEqual(state.status, .failed)
            XCTAssertEqual(state.exitCode, 7)
            let logPath = try XCTUnwrap(state.logPath)
            XCTAssertEqual(
                logPath,
                runtimeDir.appendingPathComponent("workspace-setup", isDirectory: true).appendingPathComponent(workspace.id, isDirectory: true)
                    .appendingPathComponent("setup.log", isDirectory: false).path)
            let log = try String(contentsOfFile: logPath, encoding: .utf8)
            XCTAssertTrue(log.contains("setup stdout"))
            XCTAssertTrue(log.contains("setup stderr"))

            XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Workspace setup failed"))
                XCTAssertTrue(error.localizedDescription.contains("exit code 7"))
            }
            XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        }
    }

    func testWorkspaceSetupDoesNotWaitForBackgroundChildHoldingOutputOpen() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let releaseBackgroundChildPath = root.appendingPathComponent("release-background-child").path

        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = """
                release_background_child=\(shellQuotedForSetupTest(releaseBackgroundChildPath))
                echo setup start
                (
                  attempts=0
                  while [ ! -e "$release_background_child" ] && [ "$attempts" -lt 80 ]; do
                    attempts=$((attempts + 1))
                    sleep 0.1
                  done
                  echo background finished
                ) &
                echo setup end
                """
        }
        let workspace = try orchestrator.createWorkspace(projectID: project.id, runSetupScript: false)
        defer { _ = FileManager.default.createFile(atPath: releaseBackgroundChildPath, contents: Data()) }

        let startedAt = Date()
        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)
        let elapsed = Date().timeIntervalSince(startedAt)

        let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertLessThan(elapsed, 4.0, "Setup should finish before the gated background child times out.")
        let logPath = try XCTUnwrap(state.logPath)
        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("setup start"))
        XCTAssertTrue(log.contains("setup end"))
        XCTAssertFalse(log.contains("background finished"))
    }

    // Tests list workspaces includes branch metadata by arranging representative inputs and asserting the expected result.
    func testListWorkspacesIncludesBranchMetadata() throws {
        let repo = try makeTempGitRepo(name: "workspace-branch-list")
        try runGit(["checkout", "-b", "develop"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        _ = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-branch", baseBranch: "develop")

        let workspaces = try orchestrator.listWorkspaces(projectID: project.id)
        let feature = try XCTUnwrap(workspaces.first(where: { $0.displayName == "feature-branch" }))
        XCTAssertEqual(feature.branch, "feature-branch")
        XCTAssertEqual(feature.baseBranch, "develop")
    }

    /// Archiving removes the workspace, so listing a project reports only what is left.
    func testListWorkspacesDropsArchivedWorkspace() throws {
        let repo = try makeTempGitRepo(name: "list-archived")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")
        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let remaining = try orchestrator.listWorkspaces(projectID: project.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(try XCTUnwrap(remaining.first).isDefault)
        XCTAssertNil(try store.workspace(id: workspace.id))
    }

    // Tests workspace metadata update can change title, branch, directory name, and notes by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataUpdatesTitleBranchDirectoryNameAndNotes() throws {
        let repo = try makeTempGitRepo(name: "workspace-update-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-start")

        try orchestrator.updateWorkspaceMetadata(
            workspaceID: workspace.id, branch: "feature-auth", directoryName: "feature_auth", notes: .some("Reviewing OAuth flow"))

        let updated = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(updated.displayName, "feature-auth")
        XCTAssertEqual(updated.branch, "feature-auth")
        XCTAssertEqual(updated.dirname, "feature_auth")
        XCTAssertEqual(updated.notes, "Reviewing OAuth flow")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--abbrev-ref", "HEAD"], cwd: workspace.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "feature-auth")
        let branches = try runGitAndCapture(["branch", "--format=%(refname:short)"], cwd: project.dir)
        XCTAssertTrue(branches.split(separator: "\n").contains("feature-auth"))
        XCTAssertFalse(branches.split(separator: "\n").contains("feature-start"))
    }

    // Tests workspace metadata update can clear notes by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataClearsNotes() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, notes: .some("Investigating timeout regression"))

        try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, notes: .some(nil))

        let updated = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertNil(updated.notes)
    }

    // Tests workspace active state can be toggled independently of runtime state by arranging representative inputs and asserting persistence.
    func testUpdateWorkspaceHiddenPersistsState() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: true)
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: workspace.id)).isHidden)

        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: false)
        XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isHidden)
    }

    // Tests workspace metadata update rejects renaming protected main branch by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataRejectsRenamingProtectedMainBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-update-main-protected")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let mainWorkspace = try XCTUnwrap(store.workspaces(projectID: project.id).first)

        XCTAssertEqual(mainWorkspace.branch, "main")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: mainWorkspace.id, branch: "main-renamed")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Protected branches main/master cannot be renamed"))
        }

        let updated = try XCTUnwrap(store.workspace(id: mainWorkspace.id))
        XCTAssertEqual(updated.branch, "main")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--abbrev-ref", "HEAD"], cwd: mainWorkspace.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "main")
    }

    // Tests workspace metadata update rejects renaming protected master branch by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataRejectsRenamingProtectedMasterBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-update-master-protected", initialBranch: "master")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let masterWorkspace = try XCTUnwrap(store.workspaces(projectID: project.id).first)

        XCTAssertEqual(masterWorkspace.branch, "master")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: masterWorkspace.id, branch: "master-renamed")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Protected branches main/master cannot be renamed"))
        }

        let updated = try XCTUnwrap(store.workspace(id: masterWorkspace.id))
        XCTAssertEqual(updated.branch, "master")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--abbrev-ref", "HEAD"], cwd: masterWorkspace.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "master")
    }

    // Tests workspace cycling includes orphaned running processes so recovered Spaces windows remain reachable even before a terminal row is rebuilt.
    // Tests direct coding-agent focus throws a missing-window error without offering process/browser recovery metadata.
    // Tests focus workspace window uses tracked chrome window id when target url is shared by arranging representative inputs and asserting the expected result.

    // Tests focus window navigation wraps across browser targets in same chrome window by arranging representative inputs and asserting the expected result.

    // Tests focus window navigation uses remembered target identity across shared chrome rows when the focused target cannot be resolved.

    // Tests focus window navigation falls back to the remembered cursor when Chrome URL matching is ambiguous across tracked windows.

    // Tests focus window navigation falls back to the remembered cursor when Chrome window matching is ambiguous for an unrelated active tab.

    // Tests focus window navigation cycles agent and process Spaces sessions separately when they share one Spaces window.

    // Tests focus window navigation remembers browser targets by identity instead of stale array index when targets reorder.

    // Tests focus window navigation uses remembered Spaces target identity when focused-session lookup cannot disambiguate shared tabs.

    // Tests windows live scan uses session prefixes and deduplicates overlapping matches by arranging representative inputs and asserting the expected result.

    // Tests windows live scan debounces refresh for ten seconds by arranging representative inputs and asserting the expected result.

    // Tests focus workspace window uses tab index fast path when live scan is present by arranging representative inputs and asserting the expected result.

    // Tests focus workspace window auto corrects when focused indexed tab does not match workspace by arranging representative inputs and asserting the expected result.

    // Tests focus workspace window rejects same-workspace wrong-tab verification and falls back to exact target by arranging representative inputs and asserting the expected result.

    // Tests focus workspace window uses distinct live tab ur ls for overlapping session prefixes by arranging representative inputs and asserting the expected result.

    // Tests tracked windows orders browser then terminal then other roles by arranging representative inputs and asserting the expected result.

    // Tests windows live scan orders browser rows by session prefix then url by arranging representative inputs and asserting the expected result.

    // Tests windows omits untargeted browser rows when targeted row shares window id by arranging representative inputs and asserting the expected result.

    // Tests launch workspace tracks one terminal row per process-backed terminal by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceWithBuiltInSpacesHostReturnsAfterSessionReadyWithoutWaitingForChildPID() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces.db").path

        let store = try makeTemporaryStore()
        let childPIDWritten = DispatchSemaphore(value: 0)
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, mode, _ in
                XCTAssertEqual(mode, .owner)
                let paths = try! TerminalSessionPaths.forSession(id: sessionID)
                try! paths.ensureDirectories()
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                try! seedTerminalSessionRow(sessionID: sessionID, paths: paths)
                try! TerminalSessionPersistence.writeRuntimeState(
                    .init(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: nil, state: .running,
                        updatedAt: "2026-05-09T17:00:00Z"), paths: paths)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    try! TerminalSessionPersistence.writeRuntimeState(
                        .init(
                            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: Int32(getpid()), state: .running,
                            updatedAt: "2026-05-09T17:00:01Z"), paths: paths)
                    childPIDWritten.signal()
                }
            })
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "api", command: "npm run api")]
        }

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
            // Launch has already returned without the childPID; wait for the delayed write here so it
            // still sees this profile's database and session directories rather than a torn-down one.
            XCTAssertEqual(childPIDWritten.wait(timeout: .now() + 5), .success)
        }

        let runningProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(runningProcess.terminalApp, TerminalHost.spaces.appName)

        let window = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(window.app, TerminalHost.spaces.appName)
        XCTAssertEqual(window.terminalTrackingID, runningProcess.terminalTrackingID)
    }

    // Tests launch workspace does not auto open editor by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceDoesNotAutoOpenEditor() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let root = try makeTempDirectory()
        let openLog = root.appendingPathComponent("launch-open.log")

        // Mocked dependencies: `osascript` and `open`.
        // Why: verify launch behavior keeps editor unopened/untracked.
        // Remaining risk: real launch timing may still differ under heavy desktop churn.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock, "open": Self.openMockScript]) {
            try withEnv(name: "OPEN_LOG_FILE", value: openLog.path) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
        }

        let editorWindows = try orchestrator.windows(workspaceID: workspace.id).filter { $0.role == "editor" }
        XCTAssertEqual(editorWindows.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: openLog.path))
    }

    func testDiscardPreparedGitProjectPreservesCloneWhenRegisteredBeforeCleanup() throws {
        let fixture = try makeTempGitRepo(name: "registered-before-prepared-discard")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let actualWorkspacesRoot = root.appendingPathComponent("actual-workspaces", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces-link", isDirectory: true)
        try FileManager.default.createDirectory(at: actualWorkspacesRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspacesRoot, withDestinationURL: actualWorkspacesRoot)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)

        try store.upsert(project: prepared.project)
        try store.upsert(workspace: prepared.defaultWorkspace)

        try orchestrator.discardPreparedGitProject(prepared)

        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))
        XCTAssertEqual(try store.project(id: prepared.project.id)?.dir, prepared.project.dir)
        XCTAssertEqual(try store.workspace(id: prepared.defaultWorkspace.id)?.dir, prepared.defaultWorkspace.dir)
    }

    func testPrepareGitProjectOverwritesAbandonedPreparedCloneOnRetry() throws {
        let fixture = try makeTempGitRepo(name: "retry-prepared-git-import")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let firstPrepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        XCTAssertNil(firstPrepared.importedDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPrepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPrepared.defaultWorkspace.dir))

        try spacesYAMLFixture(stopScript: "echo retry-prepared-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add spaces yaml"], cwd: fixture.path)

        let secondPrepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        defer { try? orchestrator.discardPreparedGitProject(secondPrepared) }

        XCTAssertEqual(secondPrepared.project.dir, firstPrepared.project.dir)
        XCTAssertEqual(secondPrepared.defaultWorkspace.dir, firstPrepared.defaultWorkspace.dir)
        XCTAssertEqual(secondPrepared.project.stopScript, "echo retry-prepared-stop")
        XCTAssertNotNil(secondPrepared.importedDocument)
        XCTAssertTrue(try store.projects().isEmpty)
    }

    func testAddPreparedGitProjectKeepsPreparedCloneWhenReviewedConfigIsInvalid() throws {
        let fixture = try makeTempGitRepo(name: "invalid-prepared-reviewed-git-import")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)
        defer { try? orchestrator.discardPreparedGitProject(prepared) }

        XCTAssertThrowsError(try orchestrator.addPreparedGitProject(prepared) { config in config.ports = [ServiceDefinition(name: "   ")] }) {
            error in XCTAssertTrue(error.localizedDescription.contains("service name"))
        }

        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))
    }

    // Tests archive default workspace throws by arranging representative inputs and asserting the expected result.
    func testArchiveDefaultWorkspaceThrows() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: { $0.isDefault }))
        XCTAssertThrowsError(try orchestrator.archiveWorkspace(workspaceID: defaultWorkspace.id))
    }

    // Tests stop workspace closes tracked browser tabs without closing chrome window by arranging representative inputs and asserting the expected result.

    // Tests stop workspace closes the shared Spaces window without force-closing the desktop window by arranging representative inputs and asserting the expected result.

    // Tests stop workspace closes all live detected browser session tabs by arranging representative inputs and asserting the expected result.

    /// Start is convergent (issue #438): tracked runtime that is not part of the workspace's configured
    /// processes (here, a process row with no matching template) never blocks or is touched by launch.
    func testLaunchWorkspaceWithUnconfiguredRuntimeIndicatorsIsAConvergentNoOp() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "unconfigured-process", workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "Spaces",
                terminalTarget: nil, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.map(\.id), ["unconfigured-process"], "an untracked-by-config process is left alone, not restarted")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    // Tests launch workspace waits for pending setup to finish by arranging a deferred setup run and asserting launch completes afterwards.
    func testLaunchWorkspaceWaitsForPendingSetupToFinish() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "sleep 1; echo done > .spaces-launch-wait-marker"
        }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, runSetupScript: false)
        let setupThread = WorkspaceSetupThread(orchestrator: orchestrator, workspaceID: workspace.id)
        setupThread.start()

        // Wait until the background setup has registered as in-flight before launching, so the
        // launch path deterministically observes a pending run to wait on rather than racing ahead
        // of the setup thread.
        let inFlightDeadline = Date().addingTimeInterval(5)
        while try orchestrator.workspaceSetupState(workspaceID: workspace.id).status != .running, Date() < inFlightDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        try orchestrator.launchWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .succeeded)
    }

    // Tests restart workspace kills every built-in terminal window in the shared Spaces container so stale windows do not survive the teardown.

    // Tests up workspace with restart enabled clears agent windows by arranging a running workspace with an Spaces2 agent window and asserting the record and built-in terminal window are removed before relaunch.

    // Tests stopWorkspace tears down the full built-in terminal session by arranging a running workspace with an Spaces2 agent window and asserting the record and session are removed.

    // Tests update workspace settings removing browser sessions closes tabs without closing chrome window by arranging representative inputs and asserting the expected result.

    // MARK: - workspaceSetupState from orchestrator

    // Tests workspaceSetupState returns current state by arranging representative inputs and asserting the expected result.
    func testOrchestratorWorkspaceSetupStateReturnsCurrentState() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Setup state is seeded automatically.
        let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(state.status, .succeeded)
    }

    // Tests gitBranchOptions returns empty for non-git project by arranging representative inputs and asserting the expected result.
    func testGitBranchOptionsReturnsEmptyForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let options = try orchestrator.gitBranchOptions(projectID: project.id)
        XCTAssertTrue(options.isEmpty)
    }

    // Tests updateWorkspaceHidden persists isHidden state by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceHiddenIdemopotentWhenSameValue() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // Default isHidden is false; setting it to false again should be a no-op.
        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: false)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, false)

        // Setting to true should persist.
        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: true)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, true)
    }

    // Tests updateWorkspaceNotes persists notes through orchestrator by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceNotesPersistsThroughOrchestrator() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: "Working on API")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.notes, "Working on API")

        try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: nil)
        XCTAssertNil(try store.workspace(id: workspace.id)?.notes)
    }

    func testManagedWorkspaceReplacementRejectsDirectoryUnderSymlinkedManagedAncestor() throws {
        let fixture = try makeTempGitRepo(name: "symlinked-worktree-root")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let outsideWorktreeRoot = root.appendingPathComponent("outside-worktree-root", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let managedWorktreeRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outsideWorktreeRoot, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: managedWorktreeRoot)
        try FileManager.default.createSymbolicLink(at: managedWorktreeRoot, withDestinationURL: outsideWorktreeRoot)
        let outsideFeature = outsideWorktreeRoot.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideFeature, withIntermediateDirectories: true)
        let outsideMarker = outsideFeature.appendingPathComponent("outside.txt")
        try "outside".write(to: outsideMarker, atomically: true, encoding: .utf8)

        XCTAssertNil(try orchestrator.managedWorkspaceReplacementCandidate(projectID: project.id, directoryName: "feature"))
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(
                projectID: project.id, branch: "feature", baseBranch: "main", directoryName: "feature", runSetupScript: false,
                replaceExistingManagedDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideMarker.path))
    }

    func testManagedWorkspaceReplacementDoesNotDeleteDatabaseOwnedWorkspaceDirectory() throws {
        let fixture = try makeTempGitRepo(name: "owned-workspace")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let workspaceRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        let ownedDir = workspaceRoot.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedDir, withIntermediateDirectories: true)
        let ownerMarker = ownedDir.appendingPathComponent("owner.txt")
        try "owner".write(to: ownerMarker, atomically: true, encoding: .utf8)
        try store.upsert(
            workspace: WorkspaceRecord(
                id: UUID().uuidString, projectID: project.id, dir: ownedDir.path, dirname: "owned", branch: "owned", baseBranch: "main",
                isDefault: false, isRunning: false, lastLaunchedAt: nil))

        XCTAssertThrowsError(
            try orchestrator.createWorkspace(
                projectID: project.id, branch: "feature", baseBranch: "main", directoryName: "owned", runSetupScript: false,
                replaceExistingManagedDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerMarker.path))
    }

    func testNonManagedDirectoryIsNotReplacementCandidate() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let outsideDir = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        XCTAssertNil(try orchestrator.managedDirectoryReplacementCandidate(path: outsideDir.path, kind: .projectRepository))
        XCTAssertNil(try orchestrator.managedDirectoryReplacementCandidate(path: outsideDir.path, kind: .workspaceDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDir.path))
    }

    // Tests checkAndUpdateProcessStatuses keeps live Spaces agent sessions by arranging representative inputs and asserting the expected result.

    // Tests gitBranchOptions returns branches for a real git project by arranging representative inputs and asserting the expected result.
    func testGitBranchOptionsForGitProject() throws {
        let fixture = try makeTempGitRepo(name: "branch-opts-test")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let options = try orchestrator.gitBranchOptions(projectID: project.id)
        XCTAssertFalse(options.isEmpty)
        XCTAssertTrue(options.contains("main"))
    }

    // Tests updateWorkspaceMetadata throws for empty branch on git project by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForEmptyBranchOnGitProject() throws {
        let repo = try makeTempGitRepo(name: "empty-branch-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-start")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, branch: "  ")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for empty directoryName on git project by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForEmptyDirectoryNameOnGitProject() throws {
        let repo = try makeTempGitRepo(name: "empty-dirname-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-start")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, directoryName: "")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for duplicate directory name across workspaces by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForDuplicateDirectoryName() throws {
        let repo = try makeTempGitRepo(name: "dup-dirname-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let ws1 = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-start")
        let ws2 = try orchestrator.createWorkspace(projectID: project.id, branch: "other-branch")
        guard let ws1Dirname = ws1.dirname, let ws2Dirname = ws2.dirname else { return }
        XCTAssertNotEqual(ws1Dirname, ws2Dirname)
        // Try to set ws2's dirname to ws1's dirname - should throw duplicate error
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: ws2.id, directoryName: ws1Dirname)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata branch update on non-git project throws by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataBranchThrowsForNonGitProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, branch: "new-branch")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata directoryName update on non-git project throws by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataDirectoryNameThrowsForNonGitProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, directoryName: "newdir")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests expandTilde resolves a standalone tilde to the home directory path by arranging representative inputs and asserting the expected result.
    func testExpandTildeResolvesStandaloneTildeToHome() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        // "~" expands to the home directory; no project exists there so removeProject returns silently.
        XCTAssertNoThrow(try orchestrator.removeProject(dir: "~"))
    }

    // Tests expandTilde resolves a tilde-slash prefix to the corresponding home subdirectory path by arranging representative inputs and asserting the expected result.
    func testExpandTildeResolvesTildeSlashPrefixToHomeSubdirectory() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        // "~/foo" expands to home/foo; no project exists there so removeProject returns silently.
        XCTAssertNoThrow(try orchestrator.removeProject(dir: "~/spaces-test-nonexistent-path-xyzzy"))
    }

    // Tests expandTilde passes through a tilde-name prefix unchanged by arranging representative inputs and asserting the expected result.
    func testExpandTildePassesThroughTildeNamePrefixUnchanged() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        // "~user" starts with ~ but is neither "~" alone nor "~/"; returned unchanged, no project found.
        XCTAssertNoThrow(try orchestrator.removeProject(dir: "~notahomedirectory"))
    }

    // Tests removeProject without projectsRootDirectory exercises the default repositories root path by arranging representative inputs and asserting the expected result.
    func testRemoveGitProjectWithoutProjectsRootDirectoryCoversDefaultRootPaths() throws {
        let store = try makeTemporaryStore()
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        // projectsRootDirectory is nil → repositoriesRootDirectory() uses ~/spaces/repos (default path).
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        // Insert a fake git project at a temp path so removeProject reaches isManagedRepositoryDirectory.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let projectRecord = ProjectRecord(id: tempDir, name: "coverage-test", dir: tempDir, isGitRepo: true, defaultBranch: "main")
        try store.upsert(project: projectRecord)
        let workspaceRecord = WorkspaceRecord(
            id: UUID().uuidString, projectID: tempDir, dir: tempDir, dirname: nil, branch: "main", isDefault: true, isRunning: false,
            lastLaunchedAt: nil)
        try store.upsert(workspace: workspaceRecord)

        // removeProject exercises isManagedRepositoryDirectory; the temp path is outside the managed root so nothing gets deleted.
        try orchestrator.removeProject(dir: tempDir)
        XCTAssertNil(try store.project(dir: tempDir))
    }

    // Tests updateWorkspaceMetadata with all-nil arguments is a no-op (covers guard didChange else { return }).
    func testUpdateWorkspaceMetadataWithAllNilArgsIsNoOp() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // No optional parameters → didChange stays false → guard else return is hit.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(fetched.displayName, workspace.displayName)
    }

    // Tests updateWorkspaceMetadata with notes matching the current (nil) is a no-op (covers notes == workspace.notes false branch).
    func testUpdateWorkspaceMetadataWithSameNotesIsNoOp() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        // notes: .some(nil) — outer optional is present, inner value is nil (same as current nil notes).
        // notes != workspace.notes → nil != nil → false → didChange stays false → guard else return.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, notes: .some(nil)))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertNil(fetched.notes)
    }
}

private func shellQuotedForSetupTest(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }

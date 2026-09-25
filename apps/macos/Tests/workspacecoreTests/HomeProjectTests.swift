import XCTest
import spacesdevicecore
import spacesterminalcore

@testable import workspacecore

/// The daemon-owned home project: the always-present row that holds terminals belonging to no project.
final class HomeProjectTests: XCTestCase {

    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

    private func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    /// The first daemon start mints the project and its single workspace at the home directory.
    func testEnsureHomeProjectCreatesTheProjectAndItsWorkspace() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertEqual(project.kind, .home)
        XCTAssertEqual(project.name, "~")
        XCTAssertEqual(resolved(project.dir), resolved(home.path))
        XCTAssertFalse(project.isGitRepo)
        XCTAssertFalse(project.isHidden)
        let workspaces = try orchestrator.listWorkspaces(projectID: project.id)
        XCTAssertEqual(workspaces.count, 1)
        let workspace = try XCTUnwrap(workspaces.first)
        XCTAssertTrue(workspace.isDefault)
        XCTAssertEqual(resolved(workspace.dir), resolved(home.path))
        XCTAssertNil(workspace.branch)
    }

    /// Every later daemon start converges on the same record instead of adding a second one.
    func testEnsureHomeProjectIsIdempotentAcrossDaemonStarts() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let first = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let second = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let third = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(third.id, first.id)
        XCTAssertEqual(try store.projects().filter { $0.kind == .home }.count, 1)
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: first.id).count, 1)
    }

    /// A home directory that moves (an account rename, or a profile restored under another home path)
    /// carries the project's single workspace with it, not just the project row.
    func testEnsureHomeProjectMovesItsWorkspaceWhenTheHomeDirectoryMoves() throws {
        let homeA = try makeTempDirectory()
        let homeB = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let first = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: homeA.path))
        let firstWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: first.id).first)
        XCTAssertEqual(resolved(firstWorkspace.dir), resolved(homeA.path))

        let moved = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: homeB.path))

        XCTAssertEqual(moved.id, first.id, "the same daemon-owned project record, repointed rather than replaced")
        XCTAssertEqual(resolved(moved.dir), resolved(homeB.path))
        let workspaces = try orchestrator.listWorkspaces(projectID: moved.id)
        XCTAssertEqual(workspaces.count, 1, "a home project owns exactly one workspace")
        let workspace = try XCTUnwrap(workspaces.first)
        XCTAssertEqual(workspace.id, firstWorkspace.id, "the workspace record itself, not a new one")
        XCTAssertEqual(resolved(workspace.dir), resolved(homeB.path))

        // A third ensure at the same path converges and writes nothing further.
        let again = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: homeB.path))
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: again.id).map(\.dir), [moved.dir])
    }

    /// A project the user added at the home path by hand becomes the home project rather than sitting
    /// beside a second one, keeping its id so the terminals already recorded against its workspace stay
    /// where they are.
    func testEnsureHomeProjectAdoptsAProjectTheUserAlreadyAddedAtTheHomePath() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        let addedWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertEqual(adopted.id, added.id)
        XCTAssertEqual(adopted.kind, .home)
        XCTAssertEqual(adopted.name, "~")
        XCTAssertEqual(try store.projects().count, 1)
        let workspaces = try orchestrator.listWorkspaces(projectID: adopted.id)
        XCTAssertEqual(workspaces.map(\.id), [addedWorkspace.id], "adoption keeps the workspace the terminals already belong to")
    }

    /// The home directory being a git repository (a dotfiles checkout) does not make the home project a
    /// git project: it is stored non-git so every git gate in the daemon and the clients treats it as the
    /// plain directory it is meant to be.
    func testEnsureHomeProjectStaysNonGitWhenTheHomeDirectoryIsAGitRepository() throws {
        let home = try makeTempGitRepo(name: "dotfiles")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertFalse(project.isGitRepo)
        XCTAssertNil(project.defaultBranch)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first)
        XCTAssertNil(workspace.branch, "the home workspace is the directory itself, never a branch checkout")
    }

    /// Adoption takes the configuration with it: a home project has no settings, so a project the user
    /// had configured at the home path keeps its id, its workspace, and its terminals, but not the
    /// processes, services, browser sessions, or scripts no surface can show or stop again.
    func testEnsureHomeProjectClearsTheConfigurationOfAProjectItAdopts() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        _ = try orchestrator.updateProjectConfig(projectID: added.id, updateAllWorkspaces: true) { config in
            config.setupScript = "echo setup"
            config.stopScript = "echo stop"
            config.ports = [ServiceDefinition(name: "web")]
            config.processes = [ProcessTemplate(name: "api", command: "npm run api")]
            config.browserSessions = [BrowserSession(name: "App", url: "http://localhost:3000")]
        }
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        let seeded = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: workspace.id))
        XCTAssertFalse(seeded.processes.isEmpty, "precondition: the hand-added project's workspace carries its configuration")
        XCTAssertFalse(try store.workspacePortsAssigned(workspaceID: workspace.id).isEmpty, "precondition: its services hold ports")

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertNil(adopted.setupScript)
        XCTAssertNil(adopted.stopScript)
        XCTAssertTrue(adopted.ports.isEmpty)
        XCTAssertTrue(adopted.processes.isEmpty)
        XCTAssertTrue(adopted.browserSessions.isEmpty)
        // These four are what the overview payload's workspace config is built from, so an empty
        // settings record is an overview with no process, service, or browser row for the home row.
        let settings = try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: workspace.id))
        XCTAssertNil(settings.stopScript)
        XCTAssertTrue(settings.ports.isEmpty)
        XCTAssertTrue(settings.processes.isEmpty)
        XCTAssertTrue(settings.browserSessions.isEmpty)
        XCTAssertTrue(try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.workspacePortsAssigned(workspaceID: workspace.id).isEmpty, "clearing the services releases the ports they held")
        XCTAssertEqual(
            try orchestrator.listWorkspaces(projectID: adopted.id).map(\.id), [workspace.id], "the workspace itself is kept, only its settings go")
    }

    /// Adoption takes the process runtime with it. The templates these rows came from are cleared, so a
    /// surviving row would show the home row a process it has no Stop, Restart, or settings for.
    func testEnsureHomeProjectRemovesTheRecordedProcessesOfAProjectItAdopts() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "api", command: "npm run api")]
        }
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: nil, pid: nil,
                status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "2026-09-20T10:00:00Z", exitedAt: "2026-09-20T10:05:00Z"))
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).count, 1, "precondition: the hand-added project recorded a process run")

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty, "the home row reports no process of its own")
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: adopted.id).map(\.id), [workspace.id])
    }

    /// An adopted project marked running with no `running_processes` rows to end (an empty or browser-only
    /// configuration is enough) never reaches `stopRunningProcess`, the chokepoint that otherwise clears
    /// `isRunning` once a process's rows are gone. Without a direct reconcile here, the home row would keep
    /// reading Running while `assertWorkspaceHasLifecycle` refuses Start, Stop, and Restart on it forever.
    func testEnsureHomeProjectClearsIsRunningWhenAnAdoptedProjectLeftNoProcessesToStop() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-09-20T10:00:00Z")
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty, "precondition: nothing recorded to stop")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true, "precondition: the adopted workspace reads as running")

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertEqual(
            try store.workspace(id: workspace.id)?.isRunning, false, "the home row is reconciled even though no stop ever ran to clear the flag")
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: adopted.id).map(\.id), [workspace.id])
    }

    /// A configured process still running when its project is adopted is ended rather than left running
    /// behind a row with no controls. The stop goes through the ordinary process stop, so the terminal
    /// session it owns is terminated and its window row goes with it.
    func testEnsureHomeProjectEndsTheRunningProcessesOfAProjectItAdopts() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let terminations = TerminalTerminateCapture()
        let closes = TerminalCloseCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _, _ in },
            builtInTerminalWindowCloser: { sessionID, disposition in
                closes.sessionIDs.append(sessionID)
                closes.dispositions.append(disposition)
            }, builtInTerminalSessionTerminator: { sessionID in terminations.sessionIDs.append(sessionID) },
            builtInTerminalSessionLauncher: { configuration in
                TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)")
            })
        let added = try orchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "api", command: "npm run api")]
        }
        try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "api")
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).count, 1, "precondition: the hand-added project launched one process")
        let running = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(running.status, .running, "precondition: and it is running")
        let sessionID = try XCTUnwrap(running.terminalTrackingID)

        _ = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        // The stop chokepoint ends a session and tears its pane down idempotently, so what matters here is
        // which session it acted on and how, not how many calls it took to get there.
        XCTAssertEqual(Set(terminations.sessionIDs), [sessionID], "the live process ends through the path the sidebar's Stop drives")
        XCTAssertEqual(Set(closes.sessionIDs), [sessionID])
        XCTAssertEqual(Set(closes.dispositions), [.teardown], "its pane is torn down, not held for a replacement that is never coming")
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty, "the process's terminal window row goes with it")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false, "and the home row stops reading as running")
    }

    /// Adoption removes the persisted row of a browser window a configured browser session left tracked.
    /// A browser tab is client-owned, so there is no session to stop, only the `runtime_targets` row of the
    /// target the workspace was configured to open; left in place it would count as a tracked runtime
    /// indicator forever, reading the home row as Running with no Stop or settings to clear it from.
    func testEnsureHomeProjectRemovesTheBrowserWindowsOfAProjectItAdopts() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.browserSessions = [BrowserSession(name: "App", url: "http://localhost:3000")]
        }
        let browserWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", name: "App", targetURL: "http://localhost:3000", role: .browser,
            orderIndex: 0, lastSeenAt: "2026-09-20T10:00:00Z")
        try store.upsert(window: browserWindow)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-09-20T10:00:00Z")
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).count, 1, "precondition: the hand-added project tracked one browser window")

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty, "the browser window's row goes with the session it was configured for")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false, "and the home row stops reading as running")
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: adopted.id).map(\.id), [workspace.id])

        // A second ensure finds no browser row left to remove and writes nothing.
        _ = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    /// A terminal window row is left alone: it can belong to a live ad hoc terminal that keeps running as a
    /// home terminal once adoption completes, and that row is what keeps the home workspace reading as
    /// running until the terminal exits on its own. Only browser rows are adoption's to remove.
    ///
    /// The session behind the row is seeded live, which is load-bearing for the running assertion: a pane
    /// whose session has ended is not a running indicator, so an unseeded one would read as stopped here
    /// for reasons that have nothing to do with adoption.
    func testEnsureHomeProjectKeepsTheTerminalWindowsOfAProjectItAdopts() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        let paths = try TerminalSessionPaths.forSession(id: "session-adhoc")
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: "session-adhoc", backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "Terminal", workingDirectory: home.path,
                shell: "/bin/zsh", command: nil, createdAt: "2026-09-20T10:00:00Z", workspaceID: workspace.id, kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "session-adhoc", backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 4321, state: .running,
                updatedAt: "2026-09-20T10:00:00Z", title: "Terminal", workingDirectory: home.path), paths: paths)
        let terminalWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "Terminal", terminalTrackingID: "session-adhoc",
            role: .terminal, orderIndex: 0, lastSeenAt: "2026-09-20T10:00:00Z")
        try store.upsert(window: terminalWindow)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-09-20T10:00:00Z")

        _ = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertEqual(
            try store.windows(workspaceID: workspace.id).map(\.id), [terminalWindow.id],
            "the live ad hoc terminal's row stays; adoption removes only browser rows")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true, "the row left behind keeps the home workspace reading as running")
    }

    /// Adoption takes the setup state with it. The setup script is part of the configuration it clears,
    /// so a `failed` state left standing would put the Workspace Setup screen and its Retry over the
    /// terminals the home row exists for, for a script that can never run again.
    func testEnsureHomeProjectClearsTheSetupStateOfAProjectItAdopts() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        try store.setWorkspaceSetupState(
            workspaceID: workspace.id, status: .failed, errorMessage: "Setup script exited with code 1.", startedAt: "2026-09-20T10:00:00Z",
            finishedAt: "2026-09-20T10:00:05Z", exitCode: 1, logPath: "/tmp/setup.log")

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(state.status, .succeeded, "the home workspace reads as one with no setup script")
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.startedAt)
        XCTAssertNil(state.finishedAt)
        XCTAssertNil(state.exitCode)
        XCTAssertNil(state.logPath)

        // Every record the ensure owns is in shape by now, so a later daemon start changes no row at all.
        let changesBeforeSecondEnsure = try XCTUnwrap(try store.queryRow(sql: "SELECT total_changes()")?.first)
        let reensured = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        XCTAssertEqual(reensured.id, adopted.id)
        XCTAssertEqual(try XCTUnwrap(try store.queryRow(sql: "SELECT total_changes()")?.first), changesBeforeSecondEnsure)
    }

    /// Adoption takes the note with it. `assertWorkspaceIsConfigurable` refuses a note write for a home
    /// workspace and neither client shows notes UI for it, so a note left standing would be persisted and
    /// sent in every overview with no way to view or remove it.
    func testEnsureHomeProjectClearsTheNoteOfAProjectItAdopts() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: "left over from the added project")
        XCTAssertNotNil(try store.workspace(id: workspace.id)?.notes, "precondition: the hand-added project's workspace carries a note")

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertNil(try store.workspace(id: workspace.id)?.notes, "the home row keeps no note from the project it adopted")
        XCTAssertEqual(
            try orchestrator.listWorkspaces(projectID: adopted.id).map(\.id), [workspace.id], "the workspace itself is kept, only its note goes")

        // Every record the ensure owns is in shape by now, so a later daemon start changes no row at all.
        let changesBeforeSecondEnsure = try XCTUnwrap(try store.queryRow(sql: "SELECT total_changes()")?.first)
        let reensured = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        XCTAssertEqual(reensured.id, adopted.id)
        XCTAssertEqual(try XCTUnwrap(try store.queryRow(sql: "SELECT total_changes()")?.first), changesBeforeSecondEnsure)
    }

    /// Adoption takes the review-comment drafts with it, but leaves a sent comment's archive row alone:
    /// every review-comment list, edit, delete, and send handler refuses a home workspace, so a draft left
    /// standing would sit in the database with no client able to ever show, edit, or send it again, while
    /// a sent comment is the workspace's record of what was actually sent and stays exactly like a sent
    /// comment on any other workspace deletion path.
    func testEnsureHomeProjectRemovesTheReviewDraftsOfAProjectItAdopts() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        try store.upsertReviewComment(
            WorkspaceReviewCommentRecord(
                id: "draft-1", workspaceID: workspace.id, filePath: "src/foo.ts", side: .new, lineNumber: 1, lineText: "const x = compute();",
                body: "why recompute?", createdAt: "2026-09-20T10:00:00Z", updatedAt: "2026-09-20T10:00:00Z", revision: 0, sentAt: nil))
        try store.upsertReviewComment(
            WorkspaceReviewCommentRecord(
                id: "sent-1", workspaceID: workspace.id, filePath: "src/foo.ts", side: .new, lineNumber: 5, lineText: "return compute();",
                body: "already sent", createdAt: "2026-09-20T09:00:00Z", updatedAt: "2026-09-20T09:00:00Z", revision: 0, sentAt: nil))
        try store.markReviewCommentsSent(ids: ["sent-1"], sentAt: "2026-09-20T09:05:00Z")
        XCTAssertEqual(
            try store.reviewCommentDrafts(workspaceID: workspace.id).map(\.id), ["draft-1"],
            "precondition: the hand-added project's workspace carries a review-comment draft")
        XCTAssertEqual(
            try store.reviewComment(id: "sent-1")?.sentAt, "2026-09-20T09:05:00Z",
            "precondition: the hand-added project's workspace also carries an already-sent comment")
        // An unrelated standard workspace's draft is untouched by adoption of a different project.
        let otherProject = try orchestrator.addProject(dir: try makeTempDirectory().path)
        let otherWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: otherProject.id).first)
        try store.upsertReviewComment(
            WorkspaceReviewCommentRecord(
                id: "draft-elsewhere", workspaceID: otherWorkspace.id, filePath: "src/bar.ts", side: .new, lineNumber: 2, lineText: "return y;",
                body: "unrelated draft", createdAt: "2026-09-20T10:00:00Z", updatedAt: "2026-09-20T10:00:00Z", revision: 0, sentAt: nil))

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertTrue(
            try store.reviewCommentDrafts(workspaceID: workspace.id).isEmpty, "the home row keeps no review draft from the project it adopted")
        XCTAssertEqual(
            try store.reviewComment(id: "sent-1")?.sentAt, "2026-09-20T09:05:00Z",
            "the home row keeps the already-sent comment as its record of what was sent")
        XCTAssertEqual(
            try orchestrator.listWorkspaces(projectID: adopted.id).map(\.id), [workspace.id], "the workspace itself is kept, only its drafts go")
        XCTAssertEqual(
            try store.reviewCommentDrafts(workspaceID: otherWorkspace.id).map(\.id), ["draft-elsewhere"],
            "an unrelated standard workspace's draft is untouched")

        // Every record the ensure owns is in shape by now, so a later daemon start changes no row at all.
        let changesBeforeSecondEnsure = try XCTUnwrap(try store.queryRow(sql: "SELECT total_changes()")?.first)
        let reensured = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        XCTAssertEqual(reensured.id, adopted.id)
        XCTAssertEqual(try XCTUnwrap(try store.queryRow(sql: "SELECT total_changes()")?.first), changesBeforeSecondEnsure)
    }

    /// A home workspace has no settings to write, so the daemon refuses the write itself rather than
    /// relying on there being no dialog that offers it.
    func testUpdateWorkspaceSettingsIsRefusedForTheHomeWorkspace() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first)

        XCTAssertThrowsError(
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes = [ProcessTemplate(name: "api", command: "npm run api")]
            }
        ) { error in XCTAssertEqual((error as? WorkspaceError)?.errorDescription, "Invalid argument: The home project has no configuration.") }
        XCTAssertTrue(try XCTUnwrap(try orchestrator.workspaceSettings(workspaceID: workspace.id)).processes.isEmpty)
    }

    /// Start, Stop, and Restart are refused for the home workspace however they are reached. It has no
    /// configured runtime to launch, and it reads as running only because a terminal is open in it, so a
    /// stop would mean killing those terminals from a row that offers no such control.
    func testWorkspaceLifecycleVerbsAreRefusedForTheHomeWorkspace() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first)
        let expected = "Invalid argument: The home project has no workspace lifecycle; open a terminal in it instead."

        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertEqual((error as? WorkspaceError)?.errorDescription, expected)
        }
        XCTAssertThrowsError(try orchestrator.stopWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertEqual((error as? WorkspaceError)?.errorDescription, expected)
        }
        XCTAssertThrowsError(try orchestrator.restartWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertEqual((error as? WorkspaceError)?.errorDescription, expected)
        }
    }

    /// `createWorkspace` is refused for the home project's id, not just filtered out of the create-options
    /// list: the home project already owns its one workspace (its non-git shape would otherwise make
    /// `createWorkspace` read that existing workspace back as a fresh create), and a direct Device API
    /// request naming the home project id must not be able to reach `runWorkspaceSetupInBackground` and
    /// write setup-state or log metadata into it.
    func testCreateWorkspaceIsRefusedForTheHomeProject() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspacesBefore = try orchestrator.listWorkspaces(projectID: project.id)
        let workspace = try XCTUnwrap(workspacesBefore.first)
        // `ensureHomeProject` itself already normalized this to the no-setup-script shape (`succeeded`,
        // no error/timestamps/exit code/log path; see `clearHomeWorkspaceSetupState`); the refusal must
        // leave that row exactly as it found it rather than writing a fresh one.
        let setupStateBefore = try store.workspaceSetupState(workspaceID: workspace.id)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id)) { error in
            XCTAssertEqual(
                (error as? WorkspaceError)?.errorDescription,
                "Invalid argument: The home project already owns its one workspace; it cannot create another.")
        }

        XCTAssertEqual(
            try orchestrator.listWorkspaces(projectID: project.id).map(\.id), workspacesBefore.map(\.id),
            "the refusal creates no second workspace under the home project")
        let setupStateAfter = try store.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(setupStateAfter?.status, setupStateBefore?.status)
        XCTAssertNil(setupStateAfter?.errorMessage, "no setup state is written for the refused create")
        XCTAssertNil(setupStateAfter?.startedAt, "no setup state is written for the refused create")
        XCTAssertNil(setupStateAfter?.finishedAt, "no setup state is written for the refused create")
        XCTAssertNil(setupStateAfter?.logPath, "no setup state is written for the refused create")
    }

    /// A direct `runWorkspaceSetup(workspaceID:)` call names the home workspace the same way a Device API
    /// `.runWorkspaceSetup` request or the `spaces` CLI would. The home project has no setup script, and
    /// everywhere else a missing script is treated as a successful run: without this refusal, the call
    /// would create `workspace-setup/<id>/setup.log` and write fresh `running`/`succeeded` setup-state
    /// metadata, restoring exactly the state `ensureHomeProject` clears (`clearHomeWorkspaceSetupState`).
    func testRunWorkspaceSetupIsRefusedForTheHomeWorkspace() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first)
        // Same "leave the already-normalized row untouched" assertion `testCreateWorkspaceIsRefusedFor-
        // TheHomeProject` makes for create: `ensureHomeProject` already forced this to the no-setup-script
        // shape, and the refusal must not write a fresh one.
        let setupStateBefore = try store.workspaceSetupState(workspaceID: workspace.id)
        let runtimeDirectoryPath = try XCTUnwrap(ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable])
        let setupLogPath = URL(fileURLWithPath: runtimeDirectoryPath, isDirectory: true).appendingPathComponent("workspace-setup", isDirectory: true)
            .appendingPathComponent(workspace.id, isDirectory: true).appendingPathComponent("setup.log", isDirectory: false).path

        XCTAssertThrowsError(try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)) { error in
            XCTAssertEqual((error as? WorkspaceError)?.errorDescription, "Invalid argument: The home project has no configuration.")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: setupLogPath), "the refusal creates no setup log directory for the home workspace")
        let setupStateAfter = try store.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(setupStateAfter?.status, setupStateBefore?.status)
        XCTAssertNil(setupStateAfter?.errorMessage, "no setup state is written for the refused run")
        XCTAssertNil(setupStateAfter?.startedAt, "no setup state is written for the refused run")
        XCTAssertNil(setupStateAfter?.finishedAt, "no setup state is written for the refused run")
        XCTAssertNil(setupStateAfter?.logPath, "no setup state is written for the refused run")
    }

    /// The home project has no workspace Stop, so a terminal open in it ends through the per-session stop
    /// the sidebar's Stop on a terminal row and `spaces terminal stop` share, which is also what Stop All
    /// and Quit routes its home sessions through. That path is what removes the terminal's window row and
    /// reconciles the home workspace's running flag; a raw termination would end the process and leave a
    /// running `~` row pointing at a terminal that no longer exists.
    func testStoppingAHomeTerminalRemovesItsRowAndLeavesTheHomeWorkspaceStopped() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let terminateCapture = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalSessionTerminator: { sessionID in terminateCapture.sessionIDs.append(sessionID) })
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        // The stored record, not the summary, since the session fixture writes its workspace id and dir.
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)
        let sessionID = "home-terminal-session"
        try seedHomeTerminalSession(sessionID: sessionID, workspace: workspace)
        try seedTerminalSessionWindow(store: store, workspaceID: workspace.id, sessionID: sessionID)
        // An ad hoc terminal opened in the home row is what marks it running, so the flag starts set here
        // exactly as a live terminal leaves it.
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-07-01T00:00:00Z")

        let outcome = try orchestrator.stopLiveWorkspaceTerminalSession(
            workspaceID: workspace.id, sessionID: sessionID, automationOperations: nil, killAgentSession: { _ in false })

        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(terminateCapture.sessionIDs, [sessionID])
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty, "the terminal's row goes with the session")
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false, "nothing is tracked against the home row any more")
    }

    /// Writes the on-disk launch configuration and running runtime state of a live home terminal, the
    /// shape every stop path reads to decide what a session is and who owns it. The control socket is the
    /// live-session marker the session host unlinks the moment a session ends.
    private func seedHomeTerminalSession(sessionID: String, workspace: WorkspaceRecord) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: sessionID, workingDirectory: workspace.dir,
                shell: "/bin/zsh", command: nil, createdAt: "2026-01-01T00:00:00Z", workspaceID: workspace.id, kind: .shell), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: nil,
                state: .running, updatedAt: "2026-01-01T00:00:00Z", title: sessionID, workingDirectory: workspace.dir), paths: paths)
        XCTAssertTrue(FileManager.default.createFile(atPath: paths.controlSocketPath, contents: nil))
    }

    /// The home workspace is never the workspace a command run from an unregistered directory lands on.
    /// Its directory contains most places a user can be standing in, so resolving by proximity would make
    /// a bare `spaces workspace stop` act on the home row instead of reporting that this directory
    /// belongs to no workspace.
    func testImplicitWorkspaceResolutionNeverPicksTheHomeWorkspace() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        try orchestrator.ensureHomeProject(homeDirectory: home.path)
        let unregistered = home.appendingPathComponent("notes/scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: unregistered, withIntermediateDirectories: true)

        XCTAssertThrowsError(try orchestrator.resolveWorkspaceID(explicitWorkspaceID: nil, cwd: unregistered.path)) { error in
            XCTAssertEqual(
                (error as? WorkspaceError)?.errorDescription,
                "Invalid argument: Current directory \(unregistered.path) is not inside a Spaces workspace. "
                    + "Run this command inside a workspace or pass --workspace <id>.")
        }

        // A project that lives under the home directory is an ordinary project and still resolves.
        let nested = home.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedProject = try orchestrator.addProject(dir: nested.path)
        let nestedWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: nestedProject.id).first)
        XCTAssertEqual(
            try orchestrator.resolveWorkspaceID(explicitWorkspaceID: nil, cwd: nested.appendingPathComponent("src").path), nestedWorkspace.id)
    }

    /// Adopting a git-backed project at the home path forces the same non-git shape. It owns the one
    /// workspace a home project is allowed, so adoption is what happens to it.
    func testEnsureHomeProjectForcesNonGitWhenAdoptingAGitProjectAtTheHomePath() throws {
        let home = try makeTempGitRepo(name: "dotfiles-added-by-hand")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        XCTAssertTrue(added.isGitRepo, "precondition: the hand-added project reads the home directory as a git repository")
        let addedWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertEqual(adopted.id, added.id)
        XCTAssertEqual(adopted.kind, .home)
        XCTAssertFalse(adopted.isGitRepo)
        XCTAssertNil(adopted.defaultBranch)
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: adopted.id).map(\.id), [addedWorkspace.id])
    }

    /// A git project at the home path that the user grew past one workspace is left exactly as it is. The
    /// home project is stored non-git, and a non-git project is one row with one workspace on every
    /// surface, so adopting this one would leave each of its workspaces but the default reachable from
    /// nothing. The device goes without a home project instead.
    func testEnsureHomeProjectLeavesAProjectOwningSeveralWorkspacesUntouched() throws {
        let home = try makeTempGitRepo(name: "dotfiles-with-two-workspaces")
        let workspacesRoot = try makeTempDirectory().appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let added = try orchestrator.addProject(dir: home.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        let secondWorkspace = try orchestrator.createWorkspace(projectID: added.id, branch: "feature", runSetupScript: false)

        XCTAssertNil(try orchestrator.ensureHomeProject(homeDirectory: home.path))

        let kept = try XCTUnwrap(try store.project(id: added.id))
        XCTAssertEqual(kept.kind, .standard)
        XCTAssertEqual(kept.name, added.name)
        XCTAssertTrue(kept.isGitRepo, "the project keeps the git shape its branches and Editor depend on")
        XCTAssertEqual(
            Set(try orchestrator.listWorkspaces(projectID: added.id).map(\.id)), [defaultWorkspace.id, secondWorkspace.id],
            "both workspaces stay where the user can still reach them")
        XCTAssertTrue(try store.projects().filter { $0.kind == .home }.isEmpty, "the device has no home project while that project stands")
    }

    /// A project at the home path that an automation already targets is left exactly as it is. `~` is not a
    /// valid automation target, so adopting it would strand an automation on a row with no Stop to cancel a
    /// queued run with and no editing surface to retarget it from. The device goes without a home project
    /// until the user deletes the automation.
    func testEnsureHomeProjectLeavesAProjectAnAutomationTargetsUntouched() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: added.id).first)
        try store.upsertAutomation(
            Automation(
                id: UUID().uuidString, name: "Nightly", enabled: true, triggerKind: .manual, cronExpression: nil, kind: .script, script: "true",
                workspaceID: workspace.id, timeoutSeconds: nil, concurrencyPolicy: .queue, missedRunPolicy: .runOnce, nextFireTime: nil,
                createdAt: Date(), updatedAt: Date()))

        XCTAssertNil(try orchestrator.ensureHomeProject(homeDirectory: home.path))

        let kept = try XCTUnwrap(try store.project(id: added.id))
        XCTAssertEqual(kept.kind, .standard)
        XCTAssertEqual(try store.automationIDs(workspaceID: workspace.id).count, 1, "the automation stays where the user can still delete it")
        XCTAssertTrue(try store.projects().filter { $0.kind == .home }.isEmpty, "the device has no home project while that automation stands")
    }

    /// A project hidden when it is adopted stays hidden, as its workspace. The home row reads as a non-git
    /// row, and that row's visibility checkbox drives its workspace's flag, so a project-level flag would
    /// take the row out of every list with no control anywhere that could bring it back.
    func testEnsureHomeProjectMovesTheHiddenFlagOfAnAdoptedProjectToItsWorkspace() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        try orchestrator.updateProjectHidden(projectID: added.id, isHidden: true)

        let adopted = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertFalse(adopted.isHidden)
        XCTAssertEqual(try store.project(id: adopted.id)?.isHidden, false)
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: adopted.id).map(\.isHidden), [true])

        // A later daemon start leaves both flags exactly where the user can see and change them.
        let reensured = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        XCTAssertFalse(reensured.isHidden)
        XCTAssertEqual(try store.project(id: adopted.id)?.isHidden, false)
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: adopted.id).map(\.isHidden), [true])
    }

    /// The discovery scan never imports worktrees into the home project, so a dotfiles repo's other
    /// checkouts do not turn the home row into a list of branches.
    func testWorktreeDiscoveryDoesNotImportWorktreesIntoTheHomeProject() throws {
        let home = try makeTempGitRepo(name: "dotfiles-with-worktrees")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let worktree = home.deletingLastPathComponent().appendingPathComponent("dotfiles-feature", isDirectory: true)
        try GitClient().createWorktree(path: home.path, worktreePath: worktree.path, branch: "dotfiles-feature")

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees()

        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: project.id).count, 1)
    }

    /// The home project is the daemon's, not the user's: deleting it would take the terminals living in
    /// it with it and the next daemon start would mint it again.
    func testRemoveProjectRefusesTheHomeProject() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertThrowsError(try orchestrator.removeProject(id: project.id)) { error in
            XCTAssertEqual((error as? WorkspaceError)?.errorDescription, "Invalid argument: The home project cannot be deleted.")
        }
        XCTAssertThrowsError(try orchestrator.removeProject(dir: home.path))
        XCTAssertNotNil(try store.project(id: project.id))
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: project.id).count, 1)
    }

    /// The home row's visibility has one authority: its workspace's own flag, the one the Workspaces
    /// dialog's non-git row drives (`WorkspaceVisibilityTree.Toggle.workspace`). A project-level hide
    /// request, whichever caller sends it, reaches nothing to write to and leaves both flags exactly
    /// where they were, so a client that bypassed the dialog can never strand the row hidden with no UI
    /// path back to it.
    func testUpdateProjectHiddenRefusesTheHomeProject() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first)

        XCTAssertThrowsError(try orchestrator.updateProjectHidden(projectID: project.id, isHidden: true)) { error in
            XCTAssertEqual((error as? WorkspaceError)?.errorDescription, "Invalid argument: The home project is hidden through its workspace.")
        }

        XCTAssertEqual(try store.project(id: project.id)?.isHidden, false, "the refused write leaves the project's own flag untouched")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, false, "and reaches the workspace's flag not at all")
    }

    /// A home project's own `isHidden` can read true in a database written before `updateProjectHidden`
    /// refused a project-level hide for the home kind (or by a direct store write, standing in for one
    /// here). `ensureHomeProject` normalizes it on every run, not only adoption's: the flag moves onto the
    /// workspace, the one place the Workspaces dialog can still clear it, and the project's own flag is
    /// written back to false, since the home row's visibility has exactly one authority.
    func testEnsureHomeProjectNormalizesAProjectLevelHiddenFlagOntoItsWorkspace() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first)
        // Stands in for a database written before the project-level refusal existed: the store write
        // itself, not `orchestrator.updateProjectHidden`, which refuses this for the home kind.
        try store.updateProjectHidden(id: project.id, isHidden: true)

        let normalized = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertFalse(normalized.isHidden)
        XCTAssertEqual(try store.project(id: project.id)?.isHidden, false)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, true, "the flag moved to the one place that can still clear it")

        // A later start finds the project's flag already clear and writes nothing further: the workspace
        // stays exactly where the user left it, hidden or not.
        try orchestrator.updateWorkspaceHidden(workspaceID: workspace.id, isHidden: false)
        let reensured = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        XCTAssertFalse(reensured.isHidden)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isHidden, false, "nothing re-hides a workspace the user unhid")
    }

    /// A home project carries no configuration surface at all, so the daemon refuses to write one even
    /// when a request reaches it directly rather than through a client that hides the controls.
    func testHomeProjectRefusesConfigurationAndSpacesYAML() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        XCTAssertThrowsError(try orchestrator.updateProjectConfig(projectID: project.id) { $0.setupScript = "echo hi" }) { error in
            XCTAssertEqual((error as? WorkspaceError)?.errorDescription, "Invalid argument: The home project has no configuration.")
        }
        XCTAssertThrowsError(try orchestrator.exportSpacesYAML(projectID: project.id))
        XCTAssertThrowsError(try orchestrator.importSpacesYAML(projectID: project.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("spaces.yaml").path))
        XCTAssertNil(try store.project(id: project.id)?.setupScript)
    }

    /// `configuredProjectRecord` rebuilds a `ProjectRecord` around whatever `update` changes, and every
    /// other field, `kind` included, has to survive that rebuild unchanged: `kind` never edits after a
    /// record is created. `previewProjectConfig` is the public entry point that drives it, so this reads
    /// the home project back through that path rather than calling the internal helper directly.
    func testConfiguredProjectRecordKeepsTheHomeKindOnRebuild() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        let rebuilt = try orchestrator.previewProjectConfig(projectID: project.id) { _ in }

        XCTAssertEqual(rebuilt.kind, .home)
    }

    /// The home workspace's routed hostname uses the fixed `home` label. The project is named `~`, which
    /// is not a DNS label, and the home folder's own name is the account's user name.
    func testHomeWorkspaceSlugUsesTheHomeLabel() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        let environment = SpacesDevicePlanner.runtimeManifest(project: project, workspace: workspace, namedPorts: []).processEnvironment

        let slug = try XCTUnwrap(environment["SPACES_WORKSPACE_SLUG"])
        XCTAssertTrue(slug.hasPrefix("home-"), "expected a home-labelled slug, got \(slug)")
        XCTAssertEqual(
            slug, SpacesProfile.workspaceHostSlug(branch: nil, projectName: "~", isGitRepo: false, isHomeProject: true, workspaceID: workspace.id))
    }

    /// A workspace adopted from a git project at the home path keeps the branch it was checked out on,
    /// and the slug must still read `home`: the home label is chosen before the branch is consulted, or
    /// the home row's routed hostname would read `main-…`.
    func testHomeWorkspaceSlugUsesTheHomeLabelEvenWhenTheWorkspaceRetainsABranch() throws {
        let home = try makeTempGitRepo(name: "dotfiles-with-a-branch")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let added = try orchestrator.addProject(dir: home.path)
        XCTAssertNotNil(
            try XCTUnwrap(try store.workspaces(projectID: added.id).first).branch,
            "precondition: the hand-added git project's workspace carries a branch")

        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let workspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first)

        XCTAssertNotNil(workspace.branch, "adoption keeps the workspace record, branch and all")
        let environment = SpacesDevicePlanner.runtimeManifest(project: project, workspace: workspace, namedPorts: []).processEnvironment
        let slug = try XCTUnwrap(environment["SPACES_WORKSPACE_SLUG"])
        XCTAssertTrue(slug.hasPrefix("home-"), "expected a home-labelled slug, got \(slug)")
    }

    /// Every client reads the home row's name from one place, so the project and its workspace both
    /// report `~` rather than the account's user name.
    func testHomeProjectAndWorkspaceBothDisplayAsTilde() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))

        let summary = try XCTUnwrap(try orchestrator.listProjects().first { $0.id == project.id })
        XCTAssertEqual(summary.name, ProjectKind.homeProjectName)
        XCTAssertEqual(summary.kind, .home)
        let workspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first)
        XCTAssertEqual(workspace.displayName, ProjectKind.homeProjectName)
        XCTAssertEqual(workspace.projectKind, .home)
    }

    /// The daemon runs this maintenance off its main actor, and it has to: ending a live process reaches
    /// the built-in session terminator, which enters the terminal engine actor through
    /// `TerminalEngineActor.runSynchronously`, whose one-way-rule precondition aborts the process rather
    /// than throwing when it is called from the main thread, so no `catch` around the ensure could
    /// recover from it. This drives the ensure from a background thread the way
    /// `SpacesdMain.ensureHomeProject` drives it.
    ///
    /// It also pins the order adoption establishes: the process ends before any record is rewritten, so a
    /// start that fails part-way through leaves the ordinary project the next start adopts again, never a
    /// home row still owning a process it offers no Stop, Restart, or settings for.
    func testEnsureHomeProjectEndsProcessesOffTheMainActorBeforeItAdoptsTheProject() throws {
        let home = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let databasePath = try DatabaseLocator.defaultPath()
        let setupOrchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _, _ in }, builtInTerminalWindowCloser: { _, _ in },
            builtInTerminalSessionTerminator: { _ in },
            builtInTerminalSessionLauncher: { configuration in
                TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)")
            })
        let added = try setupOrchestrator.addProject(dir: home.path)
        let workspace = try XCTUnwrap(try setupOrchestrator.listWorkspaces(projectID: added.id).first)
        try setupOrchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "api", command: "npm run api")]
        }
        try setupOrchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: "api")
        let running = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(running.status, .running, "precondition: the hand-added project has a live configured process")
        let sessionID = try XCTUnwrap(running.terminalTrackingID)

        let stops = HomeAdoptionStopRecord()
        let finished = expectation(description: "the home-project ensure finishes off the main actor")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                // One store connection per execution context, which is what this thread models: the
                // daemon builds the ensure's orchestrator its own store inside the detached task.
                let backgroundStore = try SQLiteStore(path: databasePath)
                let orchestrator = makeTestOrchestrator(
                    store: backgroundStore, builtInTerminalWindowOpener: { _, _, _ in }, builtInTerminalWindowCloser: { _, _ in },
                    builtInTerminalSessionTerminator: { stoppedSessionID in
                        stops.sessionIDs.append(stoppedSessionID)
                        stops.ranOnTheMainThread = stops.ranOnTheMainThread || Thread.isMainThread
                        let homeRecord = (try? backgroundStore.homeProject()) ?? nil
                        stops.homeProjectExisted.append(homeRecord != nil)
                    })
                stops.adoptedProjectID = try orchestrator.ensureHomeProject(homeDirectory: home.path)?.id
            } catch { stops.failure = error }
        }
        wait(for: [finished], timeout: 30)

        XCTAssertNil(stops.failure, "the ensure completed rather than trapping or throwing")
        XCTAssertEqual(Set(stops.sessionIDs), [sessionID], "the live process ends through the path the sidebar's Stop drives")
        XCTAssertFalse(stops.ranOnTheMainThread, "the stop reaches the engine actor's synchronous bridge, which traps on the main thread")
        XCTAssertEqual(Set(stops.homeProjectExisted), [false], "the process ends before the adopted record is rewritten as the home project")
        XCTAssertEqual(stops.adoptedProjectID, added.id, "the hand-added project is adopted rather than left beside a second home project")
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty, "the home row reports no process of its own")
        XCTAssertEqual(try store.project(id: added.id)?.kind, .home)
    }
}

/// What the off-main home-project ensure's process stop recorded, from the thread it ran on.
private final class HomeAdoptionStopRecord: @unchecked Sendable {
    var sessionIDs: [String] = []
    var ranOnTheMainThread = false
    var homeProjectExisted: [Bool] = []
    var adoptedProjectID: String?
    var failure: (any Error)?
}

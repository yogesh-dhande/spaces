import Foundation
import XCTest

@testable import spacesterminalcore
@testable import workspacecore

/// What the tracked-runtime rule costs on a workspace that has accumulated retained panes. Every ended
/// pane keeps its `runtime_targets` row so it stays listed and reopenable, and the home workspace is where
/// they pile up, so classifying them one row at a time would put a round trip per row on the profile
/// database's serialized lane, on a path the device overview rebuilds several times a second.
extension OrchestratorTests {

    private struct RetainedPaneFixture {
        let orchestrator: WorkspaceOrchestrator
        let store: SQLiteStore
        let workspaces: [WorkspaceRecord]
    }

    /// `workspaceCount` workspaces under one project, each holding `panesPerWorkspace` panes whose sessions
    /// have exited and whose rows are kept.
    private func makeRetainedEndedPaneFixture(workspaceCount: Int, panesPerWorkspace: Int) throws -> RetainedPaneFixture {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        var workspaces: [WorkspaceRecord] = []
        for workspaceIndex in 0..<workspaceCount {
            // One plain (non-git) project per workspace: such a project holds exactly one workspace.
            let projectDir = try makeTempDirectory().appendingPathComponent("project-\(workspaceIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let project = try orchestrator.addProject(dir: projectDir.path)
            let workspace = try orchestrator.createWorkspace(projectID: project.id)
            try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "2026-09-24T00:00:00Z")
            for paneIndex in 0..<panesPerWorkspace {
                let sessionID = "retained-\(workspaceIndex)-\(paneIndex)"
                try writeTerminalSessionFixture(
                    sessionID: sessionID, workspace: workspace, kind: .shell,
                    runtimeState: TerminalSessionRuntimeState(
                        sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 4321, state: .exited,
                        updatedAt: "2026-09-24T00:00:00Z", exitedAt: "2026-09-24T00:01:00Z", title: sessionID, workingDirectory: workspace.dir))
                try store.upsert(
                    window: WindowRecord(
                        id: "window-\(sessionID)", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: sessionID, detail: nil,
                        targetURL: nil, terminalTrackingID: sessionID, role: "terminal", orderIndex: 200 + paneIndex,
                        lastSeenAt: "2026-09-24T00:00:00Z"))
            }
            workspaces.append(workspace)
        }
        return RetainedPaneFixture(orchestrator: orchestrator, store: store, workspaces: workspaces)
    }

    /// One workspace's own run state: reporting it reads the retained sessions in one query rather than one
    /// per pane, and still reports the workspace as holding nothing alive.
    func testWorkspaceRuntimeStatusReadsRetainedEndedPanesInOneQuery() throws {
        let fixture = try makeRetainedEndedPaneFixture(workspaceCount: 1, panesPerWorkspace: 200)
        let workspace = try XCTUnwrap(fixture.workspaces.first)

        let baseline = TerminalDatabaseConnection.shared.workUnitCount
        let startedAt = Date()
        let status = try fixture.orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
        let elapsed = Date().timeIntervalSince(startedAt)
        let reads = TerminalDatabaseConnection.shared.workUnitCount - baseline
        print("MEASURE workspaceRuntimeStatus panes=200 terminalDatabaseReads=\(reads) elapsedMS=\(String(format: "%.1f", elapsed * 1000))")

        XCTAssertFalse(status.hasTrackedRuntimeIndicators, "every pane's session has ended, so nothing in the workspace is live runtime")
        XCTAssertLessThanOrEqual(reads, 2, "the retained sessions are classified from one batched read, whatever the pane count")
    }

    /// The overview's shape: the daemon classifies every workspace's rows against one read taken for the
    /// whole build, so a refresh costs the same query whether the device holds two retained panes or two
    /// hundred.
    func testOverviewClassifiesEveryWorkspacesRetainedPanesInOneQuery() throws {
        let fixture = try makeRetainedEndedPaneFixture(workspaceCount: 2, panesPerWorkspace: 100)
        let rowsByWorkspace = try fixture.workspaces.map { workspace in
            (
                workspace: workspace, runningProcesses: try fixture.store.runningProcesses(workspaceID: workspace.id),
                agentWindows: try fixture.store.agentWindows(workspaceID: workspace.id), windows: try fixture.store.windows(workspaceID: workspace.id)
            )
        }

        let baseline = TerminalDatabaseConnection.shared.workUnitCount
        let startedAt = Date()
        let endedSessions = try fixture.orchestrator.endedTerminalSessions(
            agentWindows: rowsByWorkspace.flatMap(\.agentWindows), windows: rowsByWorkspace.flatMap(\.windows))
        let verdicts = rowsByWorkspace.map { rows in
            fixture.orchestrator.hasTrackedRuntimeIndicators(
                runningProcesses: rows.runningProcesses, agentWindows: rows.agentWindows, windows: rows.windows, endedSessions: endedSessions)
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let reads = TerminalDatabaseConnection.shared.workUnitCount - baseline
        print(
            "MEASURE overviewTrackedRuntime windows=\(rowsByWorkspace.reduce(0) { $0 + $1.windows.count }) terminalDatabaseReads=\(reads) elapsedMS=\(String(format: "%.1f", elapsed * 1000))"
        )

        XCTAssertEqual(verdicts, [false, false], "both workspaces hold only retained ended panes")
        XCTAssertLessThanOrEqual(reads, 1, "one read serves the whole build")
    }
}

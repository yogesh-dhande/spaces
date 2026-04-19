import Foundation
import XCTest

@testable import streamctl

final class TerminalWindowLaunchTests: XCTestCase {
    func testLaunchWorkspaceOpensConfiguredTerminalWindows() throws {
        let (orchestrator, store, workspace, mockIterm) = try makeTerminalWindowOrchestrator()
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { config in
            config.terminalWindows = [
                TerminalWindowTemplate(name: "Shell"),
                TerminalWindowTemplate(name: "Logs", command: #"python -m http.server --directory "Preview Assets""#),
            ]
        }

        try withMockCommands(["yabai": Self.mockYabaiScript]) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
        }

        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 2)
        XCTAssertEqual(mockIterm.openedCommands.count, 2)
        XCTAssertTrue(mockIterm.openedCommands[0].localizedStandardContains("exec"))
        XCTAssertEqual(
            mockIterm.openedCommands[1],
            #"cd "\#(workspace.dir)" && python -m http.server --directory 'Preview Assets'"#)

        let terminalWindows = try store.windows(workspaceID: workspace.id).filter { $0.role == "terminal" }
        XCTAssertEqual(terminalWindows.map { $0.title }, ["Shell", "Logs"])
    }

    func testLaunchWorkspacePreservesLegacyShellTerminalCommands() throws {
        let (orchestrator, _, workspace, mockIterm) = try makeTerminalWindowOrchestrator()
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { config in
            config.terminalWindows = [
                TerminalWindowTemplate(name: "Logs", command: "tail -f log/development.log && echo done")
            ]
        }

        try withMockCommands(["yabai": Self.mockYabaiScript]) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
        }

        XCTAssertEqual(
            mockIterm.openedCommands,
            [#"cd "\#(workspace.dir)" && tail -f log/development.log && echo done"#])
    }

    func testWorkspaceSettingsPersistTerminalWindows() throws {
        let (orchestrator, _, workspace, _) = try makeTerminalWindowOrchestrator()

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { config in
            config.terminalWindows = [TerminalWindowTemplate(name: "Shell", command: "pwd")]
        }

        let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id)
        XCTAssertEqual(settings?.terminalWindows, [TerminalWindowTemplate(name: "Shell", command: "pwd")])
    }

    private func makeTerminalWindowOrchestrator() throws -> (MuxyOrchestrator, SQLiteStore, WorkspaceRecord, MockIterm2Adapter) {
        let store = try makeTemporaryStore()
        let projectDir = try makeTempDirectory()
        let workspaceRoot = try makeTempDirectory()
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        mockIterm.pairedTmux = mockTmux
        let orchestrator = MuxyOrchestrator(
            store: store, workspacesRootDirectory: workspaceRoot, iterm: mockIterm, tmux: mockTmux)
        let project = makeProjectRecord(dir: projectDir.path)
        try store.upsert(project: project)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        return (orchestrator, store, workspace, mockIterm)
    }

    private func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
        let tempDir = try makeTempDirectory()
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for (name, script) in commands {
            let path = tempDir.appendingPathComponent(name)
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        setenv("PATH", "\(tempDir.path):\(originalPath)", 1)
        defer { setenv("PATH", originalPath, 1) }
        try run()
    }

    private static let mockYabaiScript = """
        #!/bin/bash
        if [[ "$1" == "-m" && "$2" == "query" && "$3" == "--windows" && "$4" == "--window" ]]; then
          if [[ -n "$YABAI_FOCUSED_WINDOW_JSON" ]]; then
            printf '%s\n' "$YABAI_FOCUSED_WINDOW_JSON"
          else
            printf '{}\n'
          fi
          exit 0
        fi

        if [[ "$1" == "-m" && "$2" == "query" && "$3" == "--windows" ]]; then
          if [[ -n "$YABAI_WINDOWS_JSON" ]]; then
            printf '%s\n' "$YABAI_WINDOWS_JSON"
          else
            printf '[]\n'
          fi
          exit 0
        fi

        exit 0
        """
}

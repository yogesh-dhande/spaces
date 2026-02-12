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
}

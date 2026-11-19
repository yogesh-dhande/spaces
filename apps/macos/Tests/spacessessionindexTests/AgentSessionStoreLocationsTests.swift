import Foundation
import Testing

@testable import spacessessionindex

@Suite struct AgentSessionStoreLocationsTests {
    @Test func storeRootsResolveFromTheHomeDirectory() {
        let locations = AgentSessionStoreLocations(home: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        #expect(locations.claudeCodeProjects.path == "/Users/test/.claude/projects")
        #expect(locations.codexSessions.path == "/Users/test/.codex/sessions")
        #expect(locations.codexArchivedSessions.path == "/Users/test/.codex/archived_sessions")
        #expect(locations.codexSessionIndex.path == "/Users/test/.codex/session_index.jsonl")
        #expect(locations.openCodeDatabase.path == "/Users/test/.local/share/opencode/opencode.db")
        #expect(locations.ampThreads.path == "/Users/test/.local/share/amp/threads")
        #expect(locations.copilotSessionState.path == "/Users/test/.copilot/session-state")
        #expect(locations.piSessions.path == "/Users/test/.pi/agent/sessions")
    }
}

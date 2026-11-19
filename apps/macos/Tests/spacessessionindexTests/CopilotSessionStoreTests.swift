import Foundation
import Testing
import spacesterminalcore

@testable import spacessessionindex

@Suite struct CopilotSessionStoreTests {
    private let root = SessionFixtures.url("copilot/session-state")
    private let id = "cccccccc-0000-4000-8000-000000000001"

    private func source() throws -> AgentSessionSource { try #require(try CopilotSessionStore.discover(sessionStateRoot: root).first) }

    @Test func discoveryPairsTheTranscriptWithItsWorkspaceFile() throws {
        let source = try source()
        #expect(source.id == id)
        #expect(source.files.map(\.kind) == [.transcript, .metadata])
        #expect(source.sizeBytes == source.files.reduce(0) { $0 + $1.size })
        #expect(CodingAgent.resumeCommand(launchCommand: "copilot", sessionKey: source.sessionKey) == "copilot --resume \(id)")
    }

    @Test func onlyThePromptAndTheRepliesAreSearchable() throws {
        let transcript = try #require(try source().files.first)
        let result = try CopilotSessionStore.read(transcript, from: 0)
        #expect(
            SessionFixtures.texts(result) == ["Rename the config keys to snake case. lemur-prompt", "Renamed the keys in config.yaml. koala-reply"])
        #expect(result.metadata.workingDirectory == "/Users/test/service")
        #expect(result.metadata.firstUserPrompt == "Rename the config keys to snake case. lemur-prompt")
    }

    @Test func theTitleIsTheWorkspaceName() throws {
        let workspace = try #require(try source().files.last)
        let result = try CopilotSessionStore.read(workspace, from: 0)
        #expect(result.metadata.title == "Config keys: snake case")
        #expect(result.metadata.workingDirectory == "/Users/test/service")
        #expect(result.messages.isEmpty)
        #expect(result.nextState == .complete)
    }
}

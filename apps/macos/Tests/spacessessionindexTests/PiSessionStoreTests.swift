import Foundation
import Testing
import spacesterminalcore

@testable import spacessessionindex

@Suite struct PiSessionStoreTests {
    private let root = SessionFixtures.url("pi/sessions")

    private func source() throws -> AgentSessionSource { try #require(try PiSessionStore.discover(sessionsRoot: root).first) }

    @Test func theResumeKeyIsTheTranscriptPath() throws {
        let source = try source()
        #expect(source.sessionKey == source.files[0].path)
        #expect(source.sessionKey.hasSuffix("_01a10000-0000-7000-8000-000000000001.jsonl"))
        #expect(CodingAgent.resumeCommand(launchCommand: "pi", sessionKey: source.sessionKey).hasPrefix("pi --session "))
    }

    @Test func onlyUserAndAssistantTextIsSearchable() throws {
        let result = try PiSessionStore.read(try #require(try source().files.first), from: 0)
        #expect(SessionFixtures.texts(result) == ["Add a dark mode toggle. otter-prompt", "Added the toggle in Settings. beaver-reply"])
    }

    @Test func metadataComesFromTheHeaderAndSessionInfo() throws {
        let metadata = try PiSessionStore.read(try #require(try source().files.first), from: 0).metadata
        #expect(metadata.workingDirectory == "/Users/test/app")
        #expect(metadata.title == "Dark mode toggle")
        #expect(metadata.firstUserPrompt == "Add a dark mode toggle. otter-prompt")
    }
}

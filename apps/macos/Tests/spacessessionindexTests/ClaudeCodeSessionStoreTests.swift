import Foundation
import Testing
import spacesterminalcore

@testable import spacessessionindex

@Suite struct ClaudeCodeSessionStoreTests {
    private let projects = SessionFixtures.url("claude/projects")
    private let mainID = "aaaaaaaa-0000-4000-8000-000000000001"

    private func source(_ id: String) throws -> AgentSessionSource {
        try #require(try ClaudeCodeSessionStore.discover(projectsRoot: projects).first { $0.id == id })
    }

    @Test func discoveryFoldsSubagentTranscriptsIntoTheirParentSession() throws {
        let sources = try ClaudeCodeSessionStore.discover(projectsRoot: projects)
        #expect(sources.count == 2)
        let parent = try source(mainID)
        #expect(parent.files.map(\.kind) == [.transcript, .subagentTranscript])
        #expect(parent.sizeBytes == parent.files.reduce(0) { $0 + $1.size })
        #expect(parent.sessionKey == mainID)
        #expect(CodingAgent.resumeCommand(launchCommand: "claude", sessionKey: parent.sessionKey) == "claude --resume \(mainID)")
    }

    @Test func discoveryOfAMissingStoreFindsNothing() throws {
        #expect(try ClaudeCodeSessionStore.discover(projectsRoot: projects.appendingPathComponent("absent")).isEmpty)
    }

    @Test func onlyWhatTheUserTypedAndTheAgentSaidIsSearchable() throws {
        let transcript = try #require(try source(mainID).files.first)
        let result = try ClaudeCodeSessionStore.read(transcript, from: 0)
        #expect(
            SessionFixtures.texts(result) == [
                "Where is the retry logic for uploads? zebrafish-prompt", "The retry logic lives in UploadQueue. pelican-reply",
                "Now add jitter to it. narwhal-followup",
            ])
        #expect(result.messages.map(\.role) == [.user, .assistant, .user])
    }

    @Test func sessionMetadataComesFromTheTranscript() throws {
        let transcript = try #require(try source(mainID).files.first)
        let metadata = try ClaudeCodeSessionStore.read(transcript, from: 0).metadata
        #expect(metadata.title == "Upload retry jitter")
        #expect(metadata.workingDirectory == "/Users/test/app")
        #expect(metadata.firstUserPrompt == "Where is the retry logic for uploads? zebrafish-prompt")
        #expect(metadata.isOneShot == false)
        #expect(metadata.lastActivity == AgentSessionTimestamp.parse(iso8601: "2026-01-10T10:05:01.000Z"))
    }

    @Test func subagentTextIsSearchableAsTheParentButSpeaksForNoSessionMetadata() throws {
        let subagent = try #require(try source(mainID).files.last)
        let result = try ClaudeCodeSessionStore.read(subagent, from: 0)
        #expect(SessionFixtures.texts(result).contains { $0.contains("subagent-finding-marker") })
        #expect(result.metadata.firstUserPrompt == nil)
        #expect(result.metadata.workingDirectory == nil)
        #expect(result.metadata.title == nil)
        #expect(result.metadata.lastActivity == AgentSessionTimestamp.parse(iso8601: "2026-01-10T10:02:00.000Z"))
    }

    @Test func printModeRunsAreOneShot() throws {
        let transcript = try #require(try source("bbbbbbbb-0000-4000-8000-000000000002").files.first)
        #expect(try ClaudeCodeSessionStore.read(transcript, from: 0).metadata.isOneShot)
    }

    @Test func appendedRecordsAreReadFromTheSavedOffsetAndAPartialLineWaits() throws {
        let copy = try SessionFixtures.writableCopy(of: "claude/projects/-Users-test-app/\(mainID).jsonl")
        let first = try ClaudeCodeSessionStore.read(try SessionFixtures.stat(copy, kind: .transcript), from: 0)
        guard case .byteOffset(let offset) = first.nextState else {
            Issue.record("expected a byte offset")
            return
        }
        #expect(offset == (try SessionFixtures.stat(copy, kind: .transcript)).size)

        let complete =
            #"{"type":"assistant","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"added later"}]},"timestamp":"2026-01-10T11:00:00.000Z"}"#
        let partial = #"{"type":"assistant","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"not yet"#
        try SessionFixtures.append(complete + "\n" + partial, to: copy)

        let second = try ClaudeCodeSessionStore.read(try SessionFixtures.stat(copy, kind: .transcript), from: offset)
        #expect(SessionFixtures.texts(second) == ["added later"])
        guard case .byteOffset(let next) = second.nextState else {
            Issue.record("expected a byte offset")
            return
        }
        #expect(next == offset + Int64(complete.utf8.count + 1))

        try SessionFixtures.append(#"."}]},"timestamp":"2026-01-10T11:00:01.000Z"}"# + "\n", to: copy)
        let third = try ClaudeCodeSessionStore.read(try SessionFixtures.stat(copy, kind: .transcript), from: next)
        #expect(SessionFixtures.texts(third) == ["not yet."])
    }
}

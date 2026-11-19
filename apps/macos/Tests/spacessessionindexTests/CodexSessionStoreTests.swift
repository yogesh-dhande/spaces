import Foundation
import Testing
import spacesterminalcore

@testable import spacessessionindex

@Suite struct CodexSessionStoreTests {
    private let sessions = SessionFixtures.url("codex/sessions")
    private let archived = SessionFixtures.url("codex/no-archived-sessions")

    private func source(_ suffix: String) throws -> AgentSessionSource {
        try #require(try CodexSessionStore.discover(sessionsRoot: sessions, archivedRoot: archived).first { $0.id.hasSuffix(suffix) })
    }

    @Test func discoveryFindsPlainAndCompressedRollouts() throws {
        let sources = try CodexSessionStore.discover(sessionsRoot: sessions, archivedRoot: archived)
        #expect(sources.count == 4)
        #expect(try source("0001").files.map(\.kind) == [.transcript])
        #expect(try source("0003").files.map(\.kind) == [.compressedTranscript])
        #expect(try source("0001").sessionKey == "01a00000-0000-7000-8000-000000000001")
        #expect(
            CodingAgent.resumeCommand(launchCommand: "codex", sessionKey: try source("0001").sessionKey)
                == "codex resume 01a00000-0000-7000-8000-000000000001")
    }

    @Test func messagesComeFromCompletedItemsNotInjectedContextOrToolOutput() throws {
        let file = try #require(try source("0001").files.first)
        let result = try CodexSessionStore.read(file, from: 0)
        #expect(
            SessionFixtures.texts(result) == [
                "Add pagination to the orders endpoint. axolotl-prompt", "Added cursor pagination to OrdersController. capybara-reply",
            ])
        #expect(result.messages.map(\.role) == [.user, .assistant])
    }

    @Test func metadataComesFromTheSessionMetaLine() throws {
        let file = try #require(try source("0001").files.first)
        let metadata = try CodexSessionStore.read(file, from: 0).metadata
        #expect(metadata.workingDirectory == "/Users/test/api")
        #expect(metadata.firstUserPrompt == "Add pagination to the orders endpoint. axolotl-prompt")
        #expect(metadata.isOneShot == false)
        #expect(metadata.title == nil)
    }

    @Test func execAndReviewRunsAreOneShot() throws {
        for suffix in ["0002", "0004"] {
            let file = try #require(try source(suffix).files.first)
            #expect(try CodexSessionStore.read(file, from: 0).metadata.isOneShot, "rollout \(suffix)")
        }
    }

    @Test func desktopAppSessionsAreInteractive() throws {
        let file = try #require(try source("0003").files.first)
        #expect(try CodexSessionStore.read(file, from: 0).metadata.isOneShot == false)
    }

    @Test func compressedRolloutsAreDecompressedAndImagesAreNotText() throws {
        let file = try #require(try source("0003").files.first)
        let result = try CodexSessionStore.read(file, from: 0)
        #expect(
            SessionFixtures.texts(result) == [
                "Rename the settings panel. quokka-compressed-prompt", "Renamed it to Preferences. wombat-compressed-reply",
            ])
        #expect(result.metadata.workingDirectory == "/Users/test/web")
        #expect(result.nextState == .complete)
    }

    @Test func aCorruptCompressedFileFailsInsteadOfYieldingGarbage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spacessessionindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = directory.appendingPathComponent("rollout-x.jsonl.zst")
        try Data("not a zstd frame at all".utf8).write(to: corrupt)
        let file = try SessionFixtures.stat(corrupt, kind: .compressedTranscript)
        #expect(throws: AgentSessionReadError.self) { try CodexSessionStore.read(file, from: 0) }
    }

    @Test func aTruncatedCompressedFileFails() throws {
        let original = try Data(contentsOf: try #require(try source("0003").files.first).path.asFileURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spacessessionindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let truncated = directory.appendingPathComponent("rollout-y.jsonl.zst")
        try original.prefix(original.count - 8).write(to: truncated)
        let file = try SessionFixtures.stat(truncated, kind: .compressedTranscript)
        #expect(throws: AgentSessionReadError.self) { try CodexSessionStore.read(file, from: 0) }
    }

    @Test func appendedEventsAreReadFromTheSavedOffset() throws {
        let copy = try SessionFixtures.writableCopy(
            of: "codex/sessions/2026/01/10/rollout-2026-01-10T10-00-00-01a00000-0000-7000-8000-000000000001.jsonl")
        let first = try CodexSessionStore.read(try SessionFixtures.stat(copy, kind: .transcript), from: 0)
        guard case .byteOffset(let offset) = first.nextState else {
            Issue.record("expected a byte offset")
            return
        }

        let line =
            #"{"timestamp":"2026-01-10T10:30:00.000Z","ordinal":8,"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"m2","content":[{"type":"text","text":"Thanks, ship it."}]}}}"#
        try SessionFixtures.append(line + "\n", to: copy)
        let second = try CodexSessionStore.read(try SessionFixtures.stat(copy, kind: .transcript), from: offset)
        #expect(SessionFixtures.texts(second) == ["Thanks, ship it."])
        // The session_meta line is behind the offset, so an incremental read reports no directory; the
        // caller keeps the one it already holds.
        #expect(second.metadata.workingDirectory == nil)
        #expect(first.metadata.merging(second.metadata).workingDirectory == "/Users/test/api")
    }

    @Test func threadNamesTakeTheLatestEntryPerThread() throws {
        let names = try CodexSessionStore.threadNames(indexFile: SessionFixtures.url("codex/session_index.jsonl"))
        #expect(names["01a00000-0000-7000-8000-000000000001"] == "Orders pagination")
        #expect(names["01a00000-0000-7000-8000-000000000003"] == "Settings panel rename")
        #expect(names.count == 2)
    }
}

extension String { fileprivate var asFileURL: URL { URL(fileURLWithPath: self) } }

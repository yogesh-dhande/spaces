import Foundation
import Testing
import spacesterminalcore

@testable import spacessessionindex

@Suite struct AmpThreadStoreTests {
    private let threads = SessionFixtures.url("amp/threads")

    private func read(_ id: String) throws -> (AgentSessionSource, AgentSessionReadResult) {
        let source = try #require(try AmpThreadStore.discover(threadsRoot: threads).first { $0.id == id })
        return (source, try AmpThreadStore.read(try #require(source.files.first)))
    }

    @Test func discoveryFindsEachThreadFile() throws {
        let sources = try AmpThreadStore.discover(threadsRoot: threads)
        #expect(Set(sources.map(\.id)) == ["T-019c0000-0000-7000-8000-000000000001", "T-019c0000-0000-7000-8000-000000000002"])
        #expect(sources.allSatisfy { $0.files.map(\.kind) == [.wholeFileDocument] })
        let source = try #require(sources.first { $0.id.hasSuffix("0001") })
        #expect(
            CodingAgent.resumeCommand(launchCommand: "amp", sessionKey: source.sessionKey)
                == "amp threads continue T-019c0000-0000-7000-8000-000000000001")
    }

    @Test func onlyUserAndAssistantTextIsSearchable() throws {
        let (_, result) = try read("T-019c0000-0000-7000-8000-000000000001")
        #expect(SessionFixtures.texts(result) == ["Tidy the release script. platypus-prompt", "I simplified release.sh. tapir-reply"])
        #expect(result.nextState == .complete)
    }

    @Test func metadataComesFromTheThreadDocument() throws {
        let (_, result) = try read("T-019c0000-0000-7000-8000-000000000001")
        #expect(result.metadata.title == "Tidy the release script")
        #expect(result.metadata.workingDirectory == "/Users/test/tools")
        #expect(result.metadata.firstUserPrompt == "Tidy the release script. platypus-prompt")
        #expect(result.metadata.isOneShot == false)
    }

    @Test func aThreadWithoutATitleHasNone() throws {
        let (_, result) = try read("T-019c0000-0000-7000-8000-000000000002")
        #expect(result.metadata.title == nil)
        #expect(SessionFixtures.texts(result) == ["/review"])
    }
}

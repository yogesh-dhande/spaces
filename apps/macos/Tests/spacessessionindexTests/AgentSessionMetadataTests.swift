import Foundation
import Testing

@testable import spacessessionindex

@Suite struct AgentSessionMetadataTests {
    @Test func laterReadsKeepWhereTheSessionBeganAndTakeNewTitlesAndActivity() {
        let earlier = AgentSessionMetadata(
            title: "Old", workingDirectory: "/a", firstUserPrompt: "first", lastActivity: Date(timeIntervalSince1970: 10))
        let later = AgentSessionMetadata(
            title: "New", workingDirectory: "/b", firstUserPrompt: "second", lastActivity: Date(timeIntervalSince1970: 20))
        let merged = earlier.merging(later)
        #expect(merged.title == "New")
        #expect(merged.workingDirectory == "/a")
        #expect(merged.firstUserPrompt == "first")
        #expect(merged.lastActivity == Date(timeIntervalSince1970: 20))
    }

    @Test func aReadThatSawNoTitleKeepsTheKnownOne() {
        let merged = AgentSessionMetadata(title: "Known").merging(AgentSessionMetadata())
        #expect(merged.title == "Known")
    }

    @Test func aSessionEverSeenAsOneShotStaysOneShot() {
        #expect(AgentSessionMetadata(isOneShot: true).merging(AgentSessionMetadata()).isOneShot)
        #expect(AgentSessionMetadata().merging(AgentSessionMetadata(isOneShot: true)).isOneShot)
    }
}

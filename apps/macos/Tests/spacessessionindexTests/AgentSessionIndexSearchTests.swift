import Foundation
import Testing
import spacesterminalcore

@testable import spacessessionindex

@Suite struct AgentSessionIndexSearchTests {
    private func keys(_ page: AgentSessionSearchPage) -> [String] { page.results.map(\.sessionKey) }

    private func refreshedIndex(_ home: SessionIndexTestHome) throws -> AgentSessionIndex {
        let index = try home.makeIndex()
        _ = try index.refresh()
        return index
    }

    @Test func promptsAndRepliesOfEveryAgentAreFoundAndToolTextIsNot() throws {
        let home = try SessionIndexTestHome()
        try home.installAllFixtureStores()
        let index = try home.makeIndex()
        let summary = try index.refresh()
        #expect(summary.sessionsFailed == 0)

        let searchable = [
            "zebrafish-prompt", "pelican-reply", "narwhal-followup", "axolotl-prompt", "capybara-reply", "quokka-compressed-prompt",
            "wombat-compressed-reply", "lemur-prompt", "koala-reply", "otter-prompt", "beaver-reply", "platypus-prompt", "tapir-reply",
            "ferret-prompt", "heron-reply", "gecko-prompt",
        ]
        for marker in searchable { #expect(try index.search(query: marker).results.count == 1, "\(marker) should be found once") }
        let hidden = [
            "hidden-thinking-marker", "hidden-tool-output-marker", "hidden-tool-input-marker", "hidden-meta-marker", "hidden-injected-marker",
            "hidden-system-prompt-marker", "streaming-partial-marker", "oneshot-claude-marker", "oneshot-opencode-marker",
        ]
        for marker in hidden { #expect(try index.search(query: marker).results.isEmpty, "\(marker) should not be searchable") }
    }

    @Test func eachResultCarriesTheFieldsTheListNeeds() throws {
        let home = try SessionIndexTestHome()
        try home.installAllFixtureStores()
        let index = try refreshedIndex(home)
        let results = try index.search(query: "").results
        let byKey = Dictionary(uniqueKeysWithValues: results.map { ($0.sessionKey, $0) })

        #expect(byKey["aaaaaaaa-0000-4000-8000-000000000001"]?.title == "Upload retry jitter")
        #expect(byKey["aaaaaaaa-0000-4000-8000-000000000001"]?.agent == .claudeCode)
        #expect(byKey["aaaaaaaa-0000-4000-8000-000000000001"]?.workingDirectory == "/Users/test/app")
        #expect(byKey["01a00000-0000-7000-8000-000000000001"]?.title == "Orders pagination")
        #expect(byKey["01a00000-0000-7000-8000-000000000003"]?.title == "Settings panel rename")
        #expect(byKey["cccccccc-0000-4000-8000-000000000001"]?.title == "Config keys: snake case")
        #expect(byKey["T-019c0000-0000-7000-8000-000000000001"]?.title == "Tidy the release script")
        #expect(byKey["ses_root1"]?.title == "Fix flaky login test")
        // A pi session is resumed by its transcript path.
        let pi = try #require(results.first { $0.agent == .pi })
        #expect(pi.sessionKey.hasSuffix("01a10000-0000-7000-8000-000000000001.jsonl"))
        #expect(pi.title == "Dark mode toggle")
        // opencode's placeholder title means none, so the first prompt stands in.
        #expect(byKey["ses_new1"]?.title == "Plan the migration. gecko-prompt")
        #expect(byKey.values.allSatisfy { $0.sizeBytes > 0 && $0.excerpt == nil })
        // One-shot runs are not listed at all.
        #expect(byKey["bbbbbbbb-0000-4000-8000-000000000002"] == nil)
        #expect(byKey["ses_run1"] == nil)
    }

    @Test func aSessionWithoutATitleUsesItsFirstPromptAsOneTrimmedLine() throws {
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession("untitled", texts: ["\n  First line of the prompt  \nsecond line", "ok"])
        let index = try refreshedIndex(home)
        #expect(try index.search(query: "").results.map(\.title) == ["First line of the prompt"])
    }

    @Test func subagentTextFindsTheParentSession() throws {
        let home = try SessionIndexTestHome()
        try home.installAllFixtureStores()
        let index = try refreshedIndex(home)
        let results = try index.search(query: "subagent-finding-marker").results
        #expect(results.map(\.sessionKey) == ["aaaaaaaa-0000-4000-8000-000000000001"])
        #expect(results.first?.excerpt?.contains("BackoffPolicy") == true)
    }

    @Test func allWordsMustOccurWithinOneTurnAPromptAndItsReplies() throws {
        let home = try SessionIndexTestHome()
        // Two turns: [prompt zebra + reply quartz], [prompt giraffe + reply basalt].
        try home.writeClaudeSession("s1", texts: ["a prompt about zebra", "a reply about quartz", "a prompt about giraffe", "a reply about basalt"])
        let index = try refreshedIndex(home)

        #expect(keys(try index.search(query: "zebra quartz")) == ["s1"])
        #expect(keys(try index.search(query: "giraffe basalt")) == ["s1"])
        #expect(keys(try index.search(query: "zebra giraffe")).isEmpty)
        #expect(keys(try index.search(query: "quartz giraffe")).isEmpty)
        #expect(keys(try index.search(query: "\"prompt about zebra\"")) == ["s1"])
        #expect(try index.search(query: "quartz").results.first?.excerpt?.contains("zebra") == true)
    }

    @Test func everyWordMustMatchEachBareWordIsAPrefixAndQuotesMeanAPhrase() throws {
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession("s1", texts: ["alpha handoff protocol", "reply one"], startingAt: Date(timeIntervalSince1970: 1_768_000_000))
        try home.writeClaudeSession("s2", texts: ["handoff alpha notes", "reply two"], startingAt: Date(timeIntervalSince1970: 1_768_001_000))
        try home.writeClaudeSession("s3", texts: ["unrelated café menu", "reply three"], startingAt: Date(timeIntervalSince1970: 1_768_002_000))
        let index = try refreshedIndex(home)

        #expect(Set(keys(try index.search(query: "hand"))) == ["s1", "s2"])
        #expect(Set(keys(try index.search(query: "HANDOFF"))) == ["s1", "s2"])
        #expect(Set(keys(try index.search(query: "handoff alpha"))) == ["s1", "s2"])
        #expect(keys(try index.search(query: "alpha protocol")) == ["s1"])
        #expect(keys(try index.search(query: "alpha protocol notes")).isEmpty)
        #expect(keys(try index.search(query: "\"alpha handoff\"")) == ["s1"])
        #expect(keys(try index.search(query: "\"handoff alpha\"")) == ["s2"])
        #expect(keys(try index.search(query: "\"alpha handoff\" proto")) == ["s1"])
        #expect(keys(try index.search(query: "cafe")) == ["s3"])
        #expect(keys(try index.search(query: "CAFÉ")) == ["s3"])
        // A prefix matches from the start of a word only.
        #expect(keys(try index.search(query: "off")).isEmpty)
        #expect(keys(try index.search(query: "zzz")).isEmpty)
    }

    @Test func fullTextSyntaxInTheQueryIsHarmlessAndNeverAnError() throws {
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession("s1", texts: ["the near title and column words", "reply"])
        let index = try refreshedIndex(home)
        let hostile = [
            "foo AND", "OR foo", "NOT", "\"unbalanced", "\"", "\"\"", "*", "^foo", "title:foo", "text:foo", "session:1", "NEAR(a b)", "NEAR/2", "(((",
            ")))", "a*b", "-foo", "foo -bar", "{text}:foo", "text : foo", "'", "foo\"bar", "a OR b AND c NOT d", "\\", ";", "DROP TABLE sessions",
            "\u{0}", "😀",
        ]
        for query in hostile {
            _ = try index.search(query: query)
            _ = try index.search(query: query, page: 1)
        }
        // Operators and column names are ordinary words: they match the text that contains them.
        #expect(keys(try index.search(query: "near title")) == ["s1"])
        #expect(keys(try index.search(query: "NEAR near title")) == ["s1"])
        #expect(keys(try index.search(query: "text:column")) == [])
        #expect(try index.search(query: "***").results.isEmpty)
    }

    @Test func sessionsAreOrderedByTheirMostRecentMatchingMessage() throws {
        let home = try SessionIndexTestHome()
        let early = Date(timeIntervalSince1970: 1_768_000_000)
        let late = Date(timeIntervalSince1970: 1_768_100_000)
        let a = try home.writeClaudeSession("a", texts: ["marker from a", "reply"], startingAt: early)
        try home.writeClaudeSession("b", texts: ["marker from b", "reply"], startingAt: late)
        let index = try refreshedIndex(home)
        #expect(keys(try index.search(query: "marker")) == ["b", "a"])

        // A later message in `a` that does not match makes `a` the most recently active session, but
        // its most recent match is still the older one.
        try home.append(
            SessionIndexTestHome.claudeLine(role: "user", text: "something else entirely", at: late.addingTimeInterval(500)) + "\n", to: a)
        _ = try index.refresh()
        #expect(keys(try index.search(query: "marker")) == ["b", "a"])
        #expect(keys(try index.search(query: "")) == ["a", "b"])

        // A new matching message in `a` makes it the most recent match.
        try home.append(
            SessionIndexTestHome.claudeLine(role: "assistant", text: "another marker in a", at: late.addingTimeInterval(600)) + "\n", to: a)
        _ = try index.refresh()
        #expect(keys(try index.search(query: "marker")) == ["a", "b"])
        #expect(try index.search(query: "marker").results.first?.excerpt?.contains("another marker") == true)
    }

    /// A session whose old match sits beside a recent unrelated turn, written to the transcript in one go.
    private func writeSession(_ home: SessionIndexTestHome, _ name: String, turns: [(text: String, at: Double)]) throws {
        let url = home.claudeTranscript(session: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = turns.map { SessionIndexTestHome.claudeLine(role: "user", text: $0.text, at: Date(timeIntervalSince1970: $0.at)) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try home.setModified(Date(timeIntervalSince1970: turns.map(\.at).max() ?? 0), of: url)
    }

    private static let jan1 = 1_767_225_600.0
    private static let jan10 = 1_768_003_200.0
    private static let jan20 = 1_768_867_200.0

    @Test func aSessionIndexedLaterDoesNotOutrankANewerMatchBecauseOfItsOtherTurns() throws {
        let home = try SessionIndexTestHome()
        // `a` matched on Jan 1 but has an unrelated turn on Jan 20, so it is indexed after `b` (matched Jan 10).
        try writeSession(home, "a", turns: [("marker from a", Self.jan1), ("unrelated later turn", Self.jan20)])
        try writeSession(home, "b", turns: [("marker from b", Self.jan10)])
        let index = try refreshedIndex(home)

        #expect(keys(try index.search(query: "marker")) == ["b", "a"])
    }

    @Test func aWholeSessionRebuildDoesNotPromoteAnOldMatch() throws {
        let home = try SessionIndexTestHome()
        try writeSession(
            home, "a", turns: [("marker from a", Self.jan1), ("unrelated later turn", Self.jan20), ("one more later turn", Self.jan20 + 10)])
        try writeSession(home, "b", turns: [("marker from b", Self.jan10)])
        let index = try refreshedIndex(home)

        // The shorter file is a shrunk transcript, so `a` is read again from the start.
        try writeSession(home, "a", turns: [("marker from a", Self.jan1), ("unrelated later turn", Self.jan20)])
        #expect(try index.refresh().sessionsRead == 1)

        #expect(keys(try index.search(query: "marker")) == ["b", "a"])
    }

    @Test func turnsWithTheSameTimestampAreAllIndexed() throws {
        let home = try SessionIndexTestHome()
        for name in ["a", "b", "c"] { try writeSession(home, name, turns: [("marker from \(name)", Self.jan10)]) }
        let index = try refreshedIndex(home)

        #expect(Set(keys(try index.search(query: "marker"))) == ["a", "b", "c"])
        #expect(try home.indexedTurnRowCount() == 3)
    }

    @Test func eachSessionAppearsOnceHoweverManyMessagesMatch() throws {
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession("s1", texts: ["repeat one", "repeat two", "repeat three", "repeat four"])
        let index = try refreshedIndex(home)
        #expect(keys(try index.search(query: "repeat")) == ["s1"])
        #expect(try index.search(query: "repeat").results.first?.excerpt?.contains("repeat four") == true)
    }

    @Test func resultsArriveTwentyAtATimeNewestFirstWithoutOverlap() throws {
        let home = try SessionIndexTestHome()
        let base = Date(timeIntervalSince1970: 1_768_000_000)
        for number in 0..<25 {
            try home.writeClaudeSession(
                "s\(String(format: "%02d", number))", texts: ["shared term", "reply"], startingAt: base.addingTimeInterval(Double(number) * 100))
        }
        let index = try refreshedIndex(home)
        let newestFirst = (0..<25).reversed().map { "s\(String(format: "%02d", $0))" }

        for query in ["shared", ""] {
            let first = try index.search(query: query, page: 0)
            let second = try index.search(query: query, page: 1)
            let third = try index.search(query: query, page: 2)
            #expect(keys(first) == Array(newestFirst.prefix(20)), "query \"\(query)\"")
            #expect(first.hasMore)
            #expect(keys(second) == Array(newestFirst.suffix(5)), "query \"\(query)\"")
            #expect(!second.hasMore)
            #expect(third.results.isEmpty && !third.hasMore)
        }
    }

    @Test func anAgentFilterRestrictsKeywordSearchAndListing() throws {
        let home = try SessionIndexTestHome()
        try home.installAllFixtureStores()
        let index = try refreshedIndex(home)

        func agents(_ page: AgentSessionSearchPage) -> Set<CodingAgent> { Set(page.results.map(\.agent)) }
        #expect(agents(try index.search(query: "the")).count == 6)
        for query in ["the", ""] {
            #expect(agents(try index.search(query: query, agents: [.opencode])) == [.opencode], "query \"\(query)\"")
            #expect(agents(try index.search(query: query, agents: [.pi, .amp])) == [.pi, .amp], "query \"\(query)\"")
            // Nil and empty both mean every agent.
            #expect(try index.search(query: query, agents: []) == (try index.search(query: query)))
            #expect(try index.search(query: query, agents: nil) == (try index.search(query: query)))
        }
        #expect(try index.search(query: "ferret-prompt", agents: [.opencode]).results.count == 1)
        #expect(try index.search(query: "ferret-prompt", agents: [.claudeCode, .codex]).results.isEmpty)
    }

    @Test func anAgentFilterThatMatchesNothingReturnsAnEmptyPage() throws {
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession("s1", texts: ["hello there", "reply"])
        let index = try refreshedIndex(home)
        for query in ["hello", ""] {
            let page = try index.search(query: query, agents: [.pi])
            #expect(page.results.isEmpty && !page.hasMore, "query \"\(query)\"")
        }
    }

    @Test func pagingWorksWithinAnAgentFilter() throws {
        let home = try SessionIndexTestHome()
        let base = Date(timeIntervalSince1970: 1_768_000_000)
        for number in 0..<25 {
            try home.writeClaudeSession(
                "s\(String(format: "%02d", number))", texts: ["shared term", "reply"], startingAt: base.addingTimeInterval(Double(number) * 100))
        }
        try home.copyFixture("amp/threads", to: home.locations.ampThreads)
        let index = try refreshedIndex(home)

        for query in ["shared", ""] {
            let first = try index.search(query: query, page: 0, agents: [.claudeCode])
            let second = try index.search(query: query, page: 1, agents: [.claudeCode])
            #expect(first.results.count == 20 && first.hasMore, "query \"\(query)\"")
            #expect(second.results.count == 5 && !second.hasMore, "query \"\(query)\"")
            #expect(Set(keys(first)).isDisjoint(with: Set(keys(second))))
        }
        #expect(try index.search(query: "", page: 1).results.count == 7)
    }

    @Test func aCleanTwentyResultsHasNoMorePage() throws {
        let home = try SessionIndexTestHome()
        for number in 0..<20 {
            try home.writeClaudeSession(
                "s\(number)", texts: ["exactly twenty", "reply"], startingAt: Date(timeIntervalSince1970: 1_768_000_000 + Double(number) * 100))
        }
        let index = try refreshedIndex(home)
        let page = try index.search(query: "twenty")
        #expect(page.results.count == 20 && !page.hasMore)
        #expect(try index.search(query: "").hasMore == false)
    }

    @Test func nothingIsListedBeforeTheFirstRefresh() throws {
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession("s1", texts: ["hello", "world"])
        let index = try home.makeIndex()
        #expect(try index.indexedSessionCount() == 0)
        #expect(try index.search(query: "").results.isEmpty)
        _ = try index.refresh()
        #expect(try index.indexedSessionCount() == 1)
    }
}

import Foundation
import Testing
import spacesterminalcore

@testable import spacessessionindex

/// The folder filter limits both the blank-query listing and the full-text search to the conversations
/// that ran in a folder, so a project's conversations can be searched without reading the others.
@Suite struct AgentSessionFolderFilterTests {
    private let queries = ["", "falcon"]
    private let codexThread = "01a00000-0000-7000-8000-000000000501"

    /// One Claude Code conversation per folder (nil for a store that records none), newest first in the order given,
    /// plus a Codex conversation in `/work/api`. Every conversation mentions "falcon".
    private func indexedHome(folders: [(key: String, cwd: String?)]) throws -> (SessionIndexTestHome, AgentSessionIndex) {
        let home = try SessionIndexTestHome()
        let newest = Date(timeIntervalSince1970: 1_768_000_000)
        for (offset, folder) in folders.enumerated() {
            let start = newest.addingTimeInterval(Double(-3600 * offset))
            let cwdField = folder.cwd.map { #","cwd":\#(SessionIndexTestHome.jsonString($0))"# } ?? ""
            let user =
                #"{"type":"user","message":{"role":"user","content":"falcon in \#(folder.key)"},"timestamp":"\#(SessionIndexTestHome.iso8601(start))","entrypoint":"cli"\#(cwdField)}"#
            let reply =
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]},"timestamp":"\#(SessionIndexTestHome.iso8601(start.addingTimeInterval(1)))","entrypoint":"cli"\#(cwdField)}"#
            let url = home.claudeTranscript(session: folder.key)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((user + "\n" + reply + "\n").utf8).write(to: url)
        }
        try home.writeCodexRollout(at: home.codexRollout(thread: codexThread), thread: codexThread, prompt: "falcon in codex")
        let index = try home.makeIndex()
        _ = try index.refresh()
        return (home, index)
    }

    private let folders: [(key: String, cwd: String?)] = [
        ("foo", "/a/foo"), ("foo-deep", "/a/foo/sub/x"), ("foobar", "/a/foobar"), ("foo-nested", "/a/foo/nested/work"), ("percent", "/a/100%_done/x"),
        ("percent-lookalike", "/a/100xxdone/x"), ("unknown", nil), ("elsewhere", "/b/else"),
    ]

    private func keys(_ index: AgentSessionIndex, _ query: String, _ filter: AgentSessionFolderFilter?, agents: Set<CodingAgent>? = nil) throws
        -> Set<String>
    { Set(try index.search(query: query, agents: agents, folders: filter).results.map(\.sessionKey)) }

    @Test func aFolderContainsItselfAndWhatIsUnderItButNotASiblingWithTheSamePrefix() throws {
        let (home, index) = try indexedHome(folders: folders)
        defer { withExtendedLifetime(home) {} }
        for query in queries {
            #expect(
                try keys(index, query, .init(includedFolders: ["/a/foo"]), agents: [.claudeCode]) == ["foo", "foo-deep", "foo-nested"], "\(query)")
            #expect(
                try keys(index, query, .init(includedFolders: ["/a/foo/"]), agents: [.claudeCode]) == ["foo", "foo-deep", "foo-nested"], "\(query)")
        }
    }

    @Test func folderNamesAreMatchedLiterallyNotAsPatterns() throws {
        let (home, index) = try indexedHome(folders: folders)
        defer { withExtendedLifetime(home) {} }
        for query in queries { #expect(try keys(index, query, .init(includedFolders: ["/a/100%_done"])) == ["percent"], "\(query)") }
    }

    @Test func anExcludedFolderRemovesItsConversationsFromAnIncludedOne() throws {
        let (home, index) = try indexedHome(folders: folders)
        defer { withExtendedLifetime(home) {} }
        for query in queries {
            let filter = AgentSessionFolderFilter(includedFolders: ["/a/foo"], excludedFolders: ["/a/foo/nested"])
            #expect(try keys(index, query, filter) == ["foo", "foo-deep"], "\(query)")
        }
    }

    @Test func nilIncludedFoldersMatchesEveryKnownFolderAndUnknownFolderIsOptIn() throws {
        let (home, index) = try indexedHome(folders: folders)
        defer { withExtendedLifetime(home) {} }
        let known: Set = ["foo", "foo-deep", "foobar", "foo-nested", "percent", "percent-lookalike", "elsewhere", codexThread]
        for query in queries {
            #expect(try keys(index, query, .init(includedFolders: nil)) == known, "\(query)")
            #expect(try keys(index, query, .init(includedFolders: nil, includesUnknownFolder: true)) == known.union(["unknown"]), "\(query)")
            #expect(
                try keys(index, query, .init(includedFolders: ["/a/foo"], includesUnknownFolder: true)) == [
                    "foo", "foo-deep", "foo-nested", "unknown",
                ], "\(query)")
            #expect(try keys(index, query, .init(includedFolders: ["/a/foo"])) == ["foo", "foo-deep", "foo-nested"], "\(query)")
        }
    }

    @Test func includedKeysMatchWhateverTheirFolderAndExcludedKeysNeverDo() throws {
        let (home, index) = try indexedHome(folders: folders)
        defer { withExtendedLifetime(home) {} }
        for query in queries {
            let filter = AgentSessionFolderFilter(
                includedFolders: ["/a/foo"], excludedFolders: ["/a/foo/nested"], includedSessionKeys: ["elsewhere", "foo-nested"],
                excludedSessionKeys: ["foo", "elsewhere"])
            #expect(try keys(index, query, filter) == ["foo-deep", "foo-nested", "elsewhere"], "Included keys outrank exclusions: \(query)")
        }
    }

    @Test func theFolderFilterCombinesWithTheAgentFilter() throws {
        let (home, index) = try indexedHome(folders: folders)
        defer { withExtendedLifetime(home) {} }
        for query in queries {
            let filter = AgentSessionFolderFilter(includedFolders: ["/work/api", "/a/foo"])
            #expect(try keys(index, query, filter, agents: [.codex]) == [codexThread], "\(query)")
            #expect(try keys(index, query, filter, agents: [.claudeCode]) == ["foo", "foo-deep", "foo-nested"], "\(query)")
            #expect(try keys(index, query, filter) == ["foo", "foo-deep", "foo-nested", codexThread], "\(query)")
        }
    }

    @Test func filteredResultsPageLikeUnfilteredOnes() throws {
        let many: [(key: String, cwd: String?)] = (0..<90).map { (key: "s\($0)", cwd: $0 % 3 == 0 ? "/keep/\($0)" : "/drop/\($0)") }
        let (home, index) = try indexedHome(folders: many)
        defer { withExtendedLifetime(home) {} }
        for query in queries {
            let filter = AgentSessionFolderFilter(includedFolders: ["/keep"])
            let first = try index.search(query: query, page: 0, folders: filter)
            let second = try index.search(query: query, page: 1, folders: filter)
            #expect(first.results.count == 20 && first.hasMore, "\(query)")
            #expect(second.results.count == 10 && !second.hasMore, "\(query)")
            #expect(
                Set((first.results + second.results).map(\.sessionKey)) == Set(many.filter { $0.cwd?.hasPrefix("/keep") == true }.map(\.key)),
                "\(query)")
        }
    }
}

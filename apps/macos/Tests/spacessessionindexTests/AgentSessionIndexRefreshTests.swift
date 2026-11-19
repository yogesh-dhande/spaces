import Foundation
import Testing
import spacesterminalcore

@testable import spacessessionindex

#if os(Linux)
    import CSQLite3
#else
    import SQLite3
#endif

@Suite struct AgentSessionIndexRefreshTests {
    private func keys(_ page: AgentSessionSearchPage) -> [String] { page.results.map(\.sessionKey) }

    private func threeSessions(_ home: SessionIndexTestHome) throws -> [URL] {
        try (1...3).map { number in
            try home.writeClaudeSession(
                "s\(number)", texts: ["question \(number) about ferrets", "answer \(number) about ferrets"],
                startingAt: Date(timeIntervalSince1970: 1_768_000_000 + Double(number) * 1000))
        }
    }

    private func userLine(_ text: String, at seconds: Double) -> String {
        SessionIndexTestHome.claudeLine(role: "user", text: text, at: Date(timeIntervalSince1970: seconds)) + "\n"
    }

    private func assistantLine(_ text: String, at seconds: Double) -> String {
        SessionIndexTestHome.claudeLine(role: "assistant", text: text, at: Date(timeIntervalSince1970: seconds)) + "\n"
    }

    @Test func aRefreshOverUnchangedStoresReadsNoContent() throws {
        let home = try SessionIndexTestHome()
        _ = try threeSessions(home)
        try home.installOpenCodeFixture()
        let index = try home.makeIndex()
        let first = try index.refresh()
        // Three Claude turns, two opencode turns for ses_root1 (its child session's prompt starts one), one for ses_new1.
        #expect(first.sessionsRead == 6 && first.turnsWritten == 3 + 3)

        let second = try index.refresh()
        #expect(second.sessionsDiscovered == 6)
        #expect(second.sessionsRead == 0)
        #expect(second.turnsWritten == 0)
        #expect(second.sessionsRemoved == 0)
    }

    @Test func aPassOverUnchangedStoresStatsNoImmutableFileAndListsNoDirectory() throws {
        let home = try SessionIndexTestHome()
        let compressed = SessionFixtures.url("codex/sessions/2026/01/12/rollout-2026-01-12T08-00-00-01a00000-0000-7000-8000-000000000003.jsonl.zst")
        let day = home.locations.codexSessions.appendingPathComponent("2026/01/10", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        for number in 1...5 {
            try FileManager.default.copyItem(
                at: compressed, to: day.appendingPathComponent("rollout-2026-01-10T10-00-00-01a00000-0000-7000-8000-00000000010\(number).jsonl.zst"))
        }
        try FileManager.default.createDirectory(at: home.locations.codexArchivedSessions, withIntermediateDirectories: true)
        for number in 1...3 {
            try FileManager.default.copyItem(
                at: compressed,
                to: home.locations.codexArchivedSessions.appendingPathComponent(
                    "rollout-2026-01-09T10-00-00-01a00000-0000-7000-8000-00000000050\(number).jsonl.zst"))
        }
        let plain = home.codexRollout(thread: "01a00000-0000-7000-8000-000000000201")
        try
            (SessionIndexTestHome.codexMetaLine(thread: "01a00000-0000-7000-8000-000000000201") + "\n"
            + SessionIndexTestHome.codexMessageLine(kind: "UserMessage", text: "plain rollout", at: Date(timeIntervalSince1970: 1_768_000_001)) + "\n")
            .write(to: plain, atomically: true, encoding: .utf8)
        let index = try home.makeIndex()

        let first = try index.refresh()
        #expect(first.sessionsRead == 9)
        #expect(first.filesStatted >= 9 && first.directoriesListed > 0)

        // Only the plain rollout can still grow; the five compressed ones and the three archived ones are
        // not stat-ed again, and no directory's modification time moved, so none is listed.
        let second = try index.refresh()
        #expect(second.sessionsRead == 0)
        // The plain rollout, Codex's session_index.jsonl, and opencode's database and write-ahead log.
        #expect(second.filesStatted == 1 + 1 + 2)
        #expect(second.directoriesListed == 0)
        #expect(second.directoriesStatted > 0)
    }

    @Test func anArchivedCodexConversationIsSearchableAndStaysIndexedWhenArchivingMovesIt() throws {
        let home = try SessionIndexTestHome()
        let thread = "01a00000-0000-7000-8000-000000000401"
        let archivedOnly = "01a00000-0000-7000-8000-000000000402"
        try home.writeCodexRollout(at: home.codexArchivedRollout(thread: archivedOnly), thread: archivedOnly, prompt: "already archived marmot")
        let active = try home.writeCodexRollout(at: home.codexRollout(thread: thread), thread: thread, prompt: "soon archived badger")
        let index = try home.makeIndex()
        #expect(try index.refresh().sessionsRead == 2)
        #expect(try index.search(query: "marmot").results.map(\.sessionKey) == [archivedOnly])

        // Archiving moves the rollout; the conversation must not be removed or indexed twice.
        let archived = home.codexArchivedRollout(thread: thread)
        try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: active, to: archived)
        let summary = try index.refresh()
        #expect(summary.sessionsRemoved == 0)
        #expect(try index.indexedSessionCount() == 2)
        #expect(try home.indexedTurnRowCount() == 2)
        #expect(try index.search(query: "badger").results.map(\.sessionKey) == [thread])
    }

    @Test func aConversationInBothCodexLocationsIsIndexedOnceFromTheActiveCopy() throws {
        let home = try SessionIndexTestHome()
        let thread = "01a00000-0000-7000-8000-000000000403"
        try home.writeCodexRollout(at: home.codexRollout(thread: thread), thread: thread, prompt: "active copy lemur")
        try home.writeCodexRollout(at: home.codexArchivedRollout(thread: thread), thread: thread, prompt: "archived copy tapir")
        let index = try home.makeIndex()
        #expect(try index.refresh().sessionsDiscovered == 1)
        #expect(try index.search(query: "lemur").results.count == 1)
        #expect(try index.search(query: "tapir").results.isEmpty)
    }

    @Test func aNewFileInAnOldDirectoryIsStillFound() throws {
        let home = try SessionIndexTestHome()
        let first = home.codexRollout(thread: "01a00000-0000-7000-8000-000000000301")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        let meta = SessionIndexTestHome.codexMetaLine(thread: "01a00000-0000-7000-8000-000000000301") + "\n"
        try
            (meta + SessionIndexTestHome.codexMessageLine(kind: "UserMessage", text: "first rollout", at: Date(timeIntervalSince1970: 1_768_000_001))
            + "\n").write(to: first, atomically: true, encoding: .utf8)
        // An old modification time, so adding a file visibly moves it however coarse the clock is.
        try home.setModified(Date(timeIntervalSince1970: 1_700_000_000), of: first.deletingLastPathComponent())
        let index = try home.makeIndex()
        _ = try index.refresh()
        #expect(try index.refresh().directoriesListed == 0)

        let second = home.codexRollout(thread: "01a00000-0000-7000-8000-000000000302")
        try
            (SessionIndexTestHome.codexMetaLine(thread: "01a00000-0000-7000-8000-000000000302") + "\n"
            + SessionIndexTestHome.codexMessageLine(kind: "UserMessage", text: "second rollout", at: Date(timeIntervalSince1970: 1_768_000_002))
            + "\n").write(to: second, atomically: true, encoding: .utf8)
        let summary = try index.refresh()
        #expect(summary.directoriesListed == 1)
        #expect(summary.sessionsRead == 1)
        #expect(try index.search(query: "second rollout").results.count == 1)
    }

    @Test func aSubagentFileAddedLaterIsFolded() throws {
        let home = try SessionIndexTestHome()
        try home.copyFixture("claude/projects", to: home.locations.claudeCodeProjects)
        let index = try home.makeIndex()
        _ = try index.refresh()
        #expect(try index.search(query: "later-subagent-marker").results.isEmpty)

        let subagents = home.locations.claudeCodeProjects.appendingPathComponent(
            "-Users-test-app/aaaaaaaa-0000-4000-8000-000000000001/subagents", isDirectory: true)
        try (SessionIndexTestHome.claudeLine(role: "assistant", text: "later-subagent-marker", at: Date(timeIntervalSince1970: 1_768_500_000)) + "\n")
            .write(to: subagents.appendingPathComponent("agent-b22.jsonl"), atomically: true, encoding: .utf8)
        _ = try index.refresh()
        #expect(try index.search(query: "later-subagent-marker").results.map(\.sessionKey) == ["aaaaaaaa-0000-4000-8000-000000000001"])
    }

    @Test func anAppendOfANewPromptIndexesOnlyTheNewTurn() throws {
        let home = try SessionIndexTestHome()
        let files = try threeSessions(home)
        let index = try home.makeIndex()
        _ = try index.refresh()
        let rowsBefore = try home.indexedTurnRowCount()

        try home.append(
            userLine("a brand new question about pelicans", at: 1_768_900_000)
                + assistantLine("a brand new answer about pelicans", at: 1_768_900_001), to: files[1])
        let summary = try index.refresh()
        #expect(summary.sessionsRead == 1)
        #expect(summary.turnsWritten == 1)
        #expect(try home.indexedTurnRowCount() == rowsBefore + 1)
        #expect(keys(try index.search(query: "pelicans")) == ["s2"])
        #expect(Set(keys(try index.search(query: "ferrets"))) == ["s1", "s2", "s3"])
    }

    @Test func newRepliesContinueTheLatestTurnByReplacingItsRow() throws {
        let home = try SessionIndexTestHome()
        let files = try threeSessions(home)
        let index = try home.makeIndex()
        _ = try index.refresh()
        let rowsBefore = try home.indexedTurnRowCount()

        try home.append(assistantLine("and a late follow up about badgers", at: 1_768_900_000), to: files[0])
        let summary = try index.refresh()
        #expect(summary.sessionsRead == 1 && summary.turnsWritten == 1)
        #expect(try home.indexedTurnRowCount() == rowsBefore)
        // The old text is still there, in the same turn as the new, and the session is now the newest match.
        #expect(keys(try index.search(query: "question badgers")) == ["s1"])
        #expect(keys(try index.search(query: "ferrets")).first == "s1")
        #expect(try index.search(query: "badgers").results.first?.excerpt?.contains("badgers") == true)
    }

    @Test func repliesAppendedToTheParentContinueTheParentTurnNotAFoldedSubagentTurn() throws {
        let home = try SessionIndexTestHome()
        let parent = try home.writeClaudeSession(
            "p", texts: ["parent prompt alpha", "parent reply one"], startingAt: Date(timeIntervalSince1970: 1_768_000_000))
        let subagents = parent.deletingLastPathComponent().appendingPathComponent("p/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        // The subagent's turn is the session's latest, which is what a per-session "latest turn" would extend.
        try (userLine("child briefing beta", at: 1_768_002_000) + assistantLine("child reply", at: 1_768_002_001)).write(
            to: subagents.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)
        let index = try home.makeIndex()
        _ = try index.refresh()

        try home.append(assistantLine("parent reply gamma", at: 1_768_003_000), to: parent)
        _ = try index.refresh()

        #expect(keys(try index.search(query: "alpha gamma")) == ["p"])
        #expect(try index.search(query: "beta gamma").results.isEmpty)
        #expect(keys(try index.search(query: "beta child")) == ["p"])
    }

    @Test func aLineStillBeingWrittenIsIndexedOnceItIsComplete() throws {
        let home = try SessionIndexTestHome()
        let files = try threeSessions(home)
        let index = try home.makeIndex()
        _ = try index.refresh()

        let line = SessionIndexTestHome.claudeLine(role: "user", text: "half written otter question", at: Date(timeIntervalSince1970: 1_768_900_000))
        try home.append(String(line.prefix(40)), to: files[0])
        #expect(try index.refresh().turnsWritten == 0)
        try home.append(String(line.dropFirst(40)) + "\n", to: files[0])
        #expect(try index.refresh().turnsWritten == 1)
        #expect(keys(try index.search(query: "otter")) == ["s1"])
    }

    @Test func aSessionWhoseFilesAreGoneIsRemoved() throws {
        let home = try SessionIndexTestHome()
        let files = try threeSessions(home)
        let index = try home.makeIndex()
        _ = try index.refresh()

        try FileManager.default.removeItem(at: files[2])
        let summary = try index.refresh()
        #expect(summary.sessionsRemoved == 1)
        #expect(Set(keys(try index.search(query: "ferrets"))) == ["s1", "s2"])
        #expect(try index.indexedSessionCount() == 2)
        #expect(try home.indexedTurnRowCount() == 2)
    }

    @Test func aReplacedOrShrunkTranscriptIsReadAgainWholeWithoutDuplicates() throws {
        let home = try SessionIndexTestHome()
        _ = try threeSessions(home)
        let index = try home.makeIndex()
        _ = try index.refresh()

        try home.writeClaudeSession("s2", texts: ["rewritten about badgers"], startingAt: Date(timeIntervalSince1970: 1_768_950_000))
        let summary = try index.refresh()
        #expect(summary.sessionsRead == 1 && summary.turnsWritten == 1)
        #expect(keys(try index.search(query: "badgers")) == ["s2"])
        #expect(Set(keys(try index.search(query: "ferrets"))) == ["s1", "s3"])
        #expect(try home.indexedTurnRowCount() == 3)
        // A session read again whole is the most recently active one, so it matches newest.
        try home.append(userLine("more ferrets", at: 1_768_960_000), to: home.claudeTranscript(session: "s2"))
        _ = try index.refresh()
        #expect(keys(try index.search(query: "ferrets")).first == "s2")
    }

    @Test func aRewrittenWholeFileThreadReplacesItsTurns() throws {
        let home = try SessionIndexTestHome()
        try home.copyFixture("amp/threads", to: home.locations.ampThreads)
        let index = try home.makeIndex()
        _ = try index.refresh()
        let rowsBefore = try home.indexedTurnRowCount()

        let thread = home.locations.ampThreads.appendingPathComponent("T-019c0000-0000-7000-8000-000000000001.json")
        let original = try String(contentsOf: thread, encoding: .utf8)
        try original.replacingOccurrences(of: "tapir-reply", with: "tapir-reply and an edited-marker").write(
            to: thread, atomically: true, encoding: .utf8)
        let summary = try index.refresh()
        #expect(summary.sessionsRead == 1 && summary.turnsWritten == 1)
        #expect(try home.indexedTurnRowCount() == rowsBefore)
        #expect(try index.search(query: "edited-marker").results.count == 1)
    }

    @Test func oneShotRunsAreNeverIndexed() throws {
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession("batch", texts: ["scripted prompt wolverine", "scripted reply"], oneShot: true)
        try home.writeClaudeSession(
            "chat", texts: ["interactive prompt", "interactive reply"], startingAt: Date(timeIntervalSince1970: 1_768_100_000))
        let thread = "01a00000-0000-7000-8000-0000000000aa"
        let rollout = home.codexRollout(thread: thread)
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try
            (SessionIndexTestHome.codexMetaLine(thread: thread, source: "exec") + "\n"
            + SessionIndexTestHome.codexMessageLine(kind: "UserMessage", text: "codex exec wolverine", at: Date(timeIntervalSince1970: 1_768_000_001))
            + "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let index = try home.makeIndex()
        _ = try index.refresh()

        #expect(try index.search(query: "wolverine").results.isEmpty)
        #expect(keys(try index.search(query: "")) == ["chat"])
        // Appending to a one-shot run later still adds nothing.
        try home.append(
            SessionIndexTestHome.claudeLine(role: "user", text: "wolverine again", at: Date(timeIntervalSince1970: 1_768_200_000), oneShot: true)
                + "\n", to: home.claudeTranscript(session: "batch"))
        _ = try index.refresh()
        #expect(try index.search(query: "wolverine").results.isEmpty)
        #expect(try home.indexedTurnRowCount() == 1)
    }

    @Test func aRolloutThatCodexCompressedResumesWhereTheIndexLeftOff() throws {
        let home = try SessionIndexTestHome()
        let thread = "01a00000-0000-7000-8000-000000000003"
        let compressedFixture = SessionFixtures.url("codex/sessions/2026/01/12/rollout-2026-01-12T08-00-00-\(thread).jsonl.zst")
        let stream = try ZstdByteChunks(path: compressedFixture.path)
        var decompressed = Data()
        while let chunk = try stream.nextChunk() { decompressed.append(chunk) }
        let lines = decompressed.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        try #require(lines.count == 3)

        // While Codex is still writing, the index sees the plain file up to its second line: the prompt.
        let plain = home.codexRollout(thread: thread)
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines[0] + [10] + lines[1] + [10]).write(to: plain)
        let index = try home.makeIndex()
        #expect(try index.refresh().turnsWritten == 1)

        // The plain file is replaced by its compressed form, whose extra line is the reply: it continues
        // the prompt's turn, so the turn is rewritten rather than a second one added.
        try FileManager.default.removeItem(at: plain)
        let compressed = home.codexRollout(thread: thread, compressed: true)
        try FileManager.default.copyItem(at: compressedFixture, to: compressed)
        let summary = try index.refresh()
        #expect(summary.sessionsRead == 1)
        #expect(summary.turnsWritten == 1)
        #expect(try home.indexedTurnRowCount() == 1)
        #expect(try index.search(query: "quokka-compressed-prompt wombat-compressed-reply").results.count == 1)
        #expect(try index.indexedSessionCount() == 1)

        // The compressed file is immutable, so later passes leave it alone.
        #expect(try index.refresh().sessionsRead == 0)
    }

    @Test func anOpenCodeUpdateInTheSameMillisecondAsTheLastOneIsNotMissedOrDuplicated() throws {
        let home = try SessionIndexTestHome()
        try home.installOpenCodeFixture()
        let index = try home.makeIndex()
        _ = try index.refresh()
        let rowsBefore = try home.indexedTurnRowCount()
        #expect(rowsBefore == 3)

        // The newest part of ses_root1's tree was updated at 1768000031000; add another at that instant.
        try home.withOpenCodeDatabase { handle in
            let sql = """
                INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES
                ('prt_11', 'msg_4', 'ses_child1', 1768000031000, 1768000031000,
                 '{"type":"text","text":"same-millisecond-marker","time":{"start":1768000030500,"end":1768000031000}}')
                """
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        let summary = try index.refresh()
        #expect(summary.sessionsRead == 1)
        #expect(summary.turnsWritten == 2)
        #expect(try home.indexedTurnRowCount() == rowsBefore)
        #expect(try index.search(query: "same-millisecond-marker").results.map(\.sessionKey) == ["ses_root1"])
        #expect(try index.search(query: "ferret-prompt").results.count == 1)
        #expect(try index.refresh().sessionsRead == 0)
    }

    @Test func aCancelInsideASessionsReadOrWriteLeavesNothingOfItAndTheNextPassIndexesItWhole() throws {
        // Cancelling at the second check lands in the transcript read; at the fourth, among the turn writes.
        for cancelAt in [2, 4] {
            let home = try SessionIndexTestHome()
            try home.writeClaudeSession("big", texts: (0..<40).map { "turn heron \($0)" })
            let index = try home.makeIndex()
            var checks = 0
            let summary = try index.refresh {
                checks += 1
                return checks >= cancelAt
            }
            #expect(summary.wasCancelled && summary.sessionsRead == 0, "cancel at check \(cancelAt)")
            #expect(try index.search(query: "heron").results.isEmpty)
            #expect(try index.refresh().sessionsRead == 1)
            #expect(try index.search(query: "heron").results.map(\.sessionKey) == ["big"])
        }
    }

    @Test func anOpenCodeChildSessionsTurnsDoNotInterleaveWithTheParents() throws {
        let home = try SessionIndexTestHome()
        try home.installOpenCodeFixture()
        // The parent's reply lands after the child session ran, so the chronological rows interleave:
        // parent prompt, child prompt, child reply, parent reply.
        try home.withOpenCodeDatabase { handle in
            let sql = "UPDATE part SET time_created = 1768000040000, time_updated = 1768000040000 WHERE id = 'prt_05'"
            #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        let index = try home.makeIndex()
        _ = try index.refresh()

        #expect(try index.search(query: "ferret-prompt heron-reply").results.map(\.sessionKey) == ["ses_root1"])
        #expect(try index.search(query: "child-briefing-marker child-finding-marker").results.map(\.sessionKey) == ["ses_root1"])
        #expect(try index.search(query: "child-briefing-marker heron-reply").results.isEmpty)
    }

    @Test func searchesSeeEachCommittedBatchWhileTheBuildIsStillRunning() throws {
        let home = try SessionIndexTestHome()
        for (offset, word) in ["alpha", "bravo", "charlie"].enumerated() {
            try home.writeClaudeSession(
                word, texts: ["the \(word) session", "reply"], startingAt: Date(timeIntervalSince1970: 1_768_000_000 + Double(offset) * 1000))
        }
        let index = try home.makeIndex(batchSessionLimit: 1)
        var seenWithOneCommitted: [String]?
        let summary = try index.refresh {
            let committed = (try? index.indexedSessionCount()) ?? 0
            if seenWithOneCommitted == nil, committed == 1 {
                seenWithOneCommitted = keys((try? index.search(query: "")) ?? AgentSessionSearchPage(results: [], hasMore: false))
            }
            return committed >= 2
        }
        // The newest session was committed before the second session started; the build is cut short.
        #expect(seenWithOneCommitted == ["charlie"])
        #expect(summary.wasCancelled && summary.sessionsRead == 2)
        #expect(index.progress == AgentSessionIndexProgress(processed: 2, total: 3, isRefreshing: false))
        #expect(keys(try index.search(query: "")) == ["charlie", "bravo"])

        let resumed = try index.refresh()
        #expect(resumed.sessionsRead == 1 && !resumed.wasCancelled)
        #expect(try index.indexedSessionCount() == 3)
    }

    @Test func codexNamesReachEverySessionWhenTheFirstBuildIsInterruptedAndTheDaemonRestarts() throws {
        let home = try SessionIndexTestHome()
        let threads = (1...3).map { "01a00000-0000-7000-8000-0000000004\(String(format: "%02d", $0))" }
        for (offset, thread) in threads.enumerated() {
            let rollout = try home.writeCodexRollout(at: home.codexRollout(thread: thread), thread: thread, prompt: "prompt \(offset)")
            try home.setModified(Date(timeIntervalSince1970: 1_768_000_000 + Double(offset) * 1000), of: rollout)
        }
        try FileManager.default.createDirectory(at: home.locations.codexSessionIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try threads.enumerated().map { #"{"id":"\#($1)","thread_name":"Name \#($0)","updated_at":"2026-01-10T10:20:00.000000Z"}"# + "\n" }.joined()
            .write(to: home.locations.codexSessionIndex, atomically: true, encoding: .utf8)

        let interrupted = try home.makeIndex(batchSessionLimit: 1)
        let cancelled = try interrupted.refresh { ((try? interrupted.indexedSessionCount()) ?? 0) >= 1 }
        #expect(cancelled.wasCancelled)

        let restarted = try home.makeIndex(batchSessionLimit: 1)
        #expect(!(try restarted.refresh().wasCancelled))
        let titles = Dictionary(uniqueKeysWithValues: try restarted.search(query: "").results.map { ($0.sessionKey, $0.title) })
        for (offset, thread) in threads.enumerated() { #expect(titles[thread] == "Name \(offset)") }
    }

    @Test func progressCountsTheSessionsThatNeedReading() throws {
        let home = try SessionIndexTestHome()
        _ = try threeSessions(home)
        let index = try home.makeIndex()
        #expect(index.progress == AgentSessionIndexProgress())
        _ = try index.refresh()
        #expect(index.progress == AgentSessionIndexProgress(processed: 3, total: 3, isRefreshing: false))
        _ = try index.refresh()
        #expect(index.progress == AgentSessionIndexProgress(processed: 0, total: 0, isRefreshing: false))
    }

    @Test func aStoreThatCannotBeListedKeepsItsSessionsInTheIndex() throws {
        let home = try SessionIndexTestHome()
        try home.copyFixture("amp/threads", to: home.locations.ampThreads)
        let index = try home.makeIndex()
        _ = try index.refresh()
        #expect(try index.indexedSessionCount() == 2)

        // A threads path that is a file cannot be listed; a missing one is simply empty.
        try FileManager.default.removeItem(at: home.locations.ampThreads)
        try Data().write(to: home.locations.ampThreads)
        let summary = try index.refresh()
        #expect(summary.sessionsRemoved == 0)
        #expect(try index.indexedSessionCount() == 2)

        try FileManager.default.removeItem(at: home.locations.ampThreads)
        #expect(try index.refresh().sessionsRemoved == 2)
    }

    // MARK: - The cache file

    private func permissions(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? -1) & 0o777
    }

    @Test func theIndexFilesAreReadableByTheOwnerOnly() throws {
        let previousMask = umask(0o022)
        defer { umask(previousMask) }
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession("s1", texts: ["a private prompt", "a private reply"])
        let index = try home.makeIndex()
        _ = try index.refresh()
        _ = try index.search(query: "private")

        // The connections stay open, so the write-ahead log and shared-memory files exist.
        for suffix in ["", "-wal", "-shm"] { #expect(try permissions(home.indexURL.path + suffix) == 0o600, "\(suffix)") }
    }

    @Test func anExistingIndexWithWiderPermissionsIsTightenedWithoutRebuilding() throws {
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession("s1", texts: ["a private prompt", "a private reply"])
        do {
            let first = try home.makeIndex()
            #expect(try first.refresh().sessionsRead == 1)
        }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: home.indexURL.path + suffix) {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: home.indexURL.path + suffix)
        }

        let reopened = try home.makeIndex()
        _ = try reopened.search(query: "private")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: home.indexURL.path + suffix) {
            #expect(try permissions(home.indexURL.path + suffix) == 0o600, "\(suffix)")
        }
        #expect(try reopened.refresh().sessionsRead == 0)
    }

    @Test func anIndexOfAnotherFormatVersionIsRebuiltFromTheStores() throws {
        let home = try SessionIndexTestHome()
        _ = try threeSessions(home)
        do {
            let index = try home.makeIndex()
            _ = try index.refresh()
        }
        let database = try SessionIndexDatabase(path: home.indexURL.path, readOnly: false)
        try database.execute("PRAGMA user_version = 999")

        let rebuilt = try home.makeIndex()
        #expect(try rebuilt.indexedSessionCount() == 0)
        _ = try rebuilt.refresh()
        #expect(try rebuilt.indexedSessionCount() == 3)
        #expect(try home.indexedTurnRowCount() == 3)
    }

    @Test func anUnreadableIndexFileIsRebuiltFromTheStores() throws {
        let home = try SessionIndexTestHome()
        _ = try threeSessions(home)
        try FileManager.default.createDirectory(at: home.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not a database".utf8).write(to: home.indexURL)

        let index = try home.makeIndex()
        _ = try index.refresh()
        #expect(Set(keys(try index.search(query: "ferrets"))) == ["s1", "s2", "s3"])
    }

    @Test func theIndexSurvivesReopeningWithoutReadingTheStoresAgain() throws {
        let home = try SessionIndexTestHome()
        _ = try threeSessions(home)
        do {
            let index = try home.makeIndex()
            _ = try index.refresh()
        }
        let reopened = try home.makeIndex()
        #expect(try reopened.indexedSessionCount() == 3)
        let summary = try reopened.refresh()
        #expect(summary.sessionsRead == 0 && summary.turnsWritten == 0)
    }

    @Test func statisticsCountSessionsAndTurnsPerAgent() throws {
        let home = try SessionIndexTestHome()
        _ = try threeSessions(home)
        try home.installOpenCodeFixture()
        let index = try home.makeIndex()
        _ = try index.refresh()
        let statistics = try index.statistics()
        #expect(statistics.sessions == [.claudeCode: 3, .opencode: 2])
        #expect(statistics.turns == [.claudeCode: 3, .opencode: 3])
    }

    @Test func fullTextSearchIsAvailableInThisSQLiteBuild() throws {
        let home = try SessionIndexTestHome()
        let index = try home.makeIndex()
        #expect(try index.indexedSessionCount() == 0)
    }
}

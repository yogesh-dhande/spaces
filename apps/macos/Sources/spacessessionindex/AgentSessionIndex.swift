import Foundation
import spacesterminalcore

/// A searchable index of the prompts and replies in every coding agent's session store on this device.
///
/// The index lives in one SQLite file and is a derived cache of the stores: it is never the only copy of
/// anything, so a file with a different format version or one that cannot be read is deleted and rebuilt
/// from the stores, not repaired or migrated.
///
/// `refresh()` brings the index up to date with the stores and is the only writer. `search` reads through
/// its own connection, so searches and a running refresh never block each other, and a search during the
/// first build sees every batch committed so far.
///
/// Searchable rows are turns (a user prompt plus the replies after it), so all of a query's words must
/// occur within one turn.
public final class AgentSessionIndex: @unchecked Sendable {
    let locations: AgentSessionStoreLocations
    /// Sessions indexed between commits. A commit makes the batch visible to searches; the bound also
    /// keeps the write transaction (and the WAL) small during the first build.
    let batchSessionLimit: Int
    let writer: SessionIndexWriter
    let refreshLock = NSLock()

    // State a refresh pass keeps between passes, guarded by `refreshLock`. A pass that finds nothing
    // changed would otherwise re-list every directory, re-load every session row and re-query opencode.
    let fileSystem = SessionStoreFileSystem(remembersListings: true)
    var storedSessions: [StoredSession.Key: StoredSession]?
    var openCodeSnapshot: (signature: [Double], sources: [AgentSessionSource])?

    private let reader: SessionIndexDatabase
    private let readerLock = NSLock()
    private let progressLock = NSLock()
    private var currentProgress = AgentSessionIndexProgress()

    public convenience init(indexURL: URL, locations: AgentSessionStoreLocations) throws {
        try self.init(indexURL: indexURL, locations: locations, batchSessionLimit: 100)
    }

    init(indexURL: URL, locations: AgentSessionStoreLocations, batchSessionLimit: Int) throws {
        self.locations = locations
        self.batchSessionLimit = batchSessionLimit
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try Self.openWriteDatabase(at: indexURL)
        writer = try SessionIndexWriter(database: database)
        reader = try SessionIndexDatabase(path: indexURL.path, readOnly: true)
    }

    /// Progress of the refresh pass running now, or of the last one.
    public var progress: AgentSessionIndexProgress {
        progressLock.lock()
        defer { progressLock.unlock() }
        return currentProgress
    }

    func updateProgress(_ update: (inout AgentSessionIndexProgress) -> Void) {
        progressLock.lock()
        update(&currentProgress)
        progressLock.unlock()
    }

    /// How many sessions can be searched now; zero means nothing has been indexed yet.
    public func indexedSessionCount() throws -> Int {
        readerLock.lock()
        defer { readerLock.unlock() }
        let statement = try reader.prepare("SELECT COUNT(*) FROM sessions WHERE is_one_shot = 0 AND turn_count > 0")
        return try statement.step() ? Int(statement.int64(0)) : 0
    }

    /// Searchable sessions and turns per agent.
    public func statistics() throws -> AgentSessionIndexStatistics {
        readerLock.lock()
        defer { readerLock.unlock() }
        let statement = try reader.prepare(
            "SELECT agent, COUNT(*), SUM(turn_count) FROM sessions WHERE is_one_shot = 0 AND turn_count > 0 GROUP BY agent")
        var statistics = AgentSessionIndexStatistics()
        while try statement.step() {
            guard let agent = statement.text(0).flatMap(CodingAgent.init(rawValue:)) else { continue }
            statistics.sessions[agent] = Int(statement.int64(1))
            statistics.turns[agent] = Int(statement.int64(2))
        }
        return statistics
    }

    /// One page of sessions matching `query`, most recently matched first. A blank query lists every
    /// session by last activity instead. `agents` restricts the results to those agents; nil or empty
    /// means all of them. `folders` restricts them to the sessions it matches; nil means every session.
    ///
    /// Results are ordered by each session's most recent matching turn. FTS rowids encode the time of
    /// a turn's newest message (see `TurnRowID`), so one scan in descending rowid order meets sessions newest
    /// match first and can stop as soon as the page is full, where sorting all matches would take seconds
    /// for a common word. The scan reads only rowids and joins each to its session by primary key; on a
    /// heavy user's index one recent session can hold thousands of the first matches for a common word, so
    /// the cost per scanned row decides the latency (about 0.2 microseconds here, against about 1 with an
    /// UNINDEXED session column and about 5 with `snippet()` in the scan). An agent filter is applied in
    /// that same join, as is a folder filter, so a rare agent or folder makes the scan deeper, never wrong.
    /// Excerpts are cut afterwards from
    /// the text of the 20 results (`SessionExcerpt`). Paging is stateless: page N rescans from the top and
    /// keeps the last 20 of the first (N+1) x 20 distinct sessions.
    public func search(query: String, page: Int = 0, agents: Set<CodingAgent>? = nil, folders: AgentSessionFolderFilter? = nil) throws
        -> AgentSessionSearchPage
    {
        precondition(page >= 0)
        let agentNames = (agents ?? []).map(\.rawValue).sorted()
        switch SessionSearchQuery(query) {
        case .listAll: return try listSessions(page: page, agentNames: agentNames, folders: folders)
        case .matchesNothing: return AgentSessionSearchPage(results: [], hasMore: false)
        case .match(let expression, let tokens):
            return try searchSessions(matching: expression, tokens: tokens, page: page, agentNames: agentNames, folders: folders)
        }
    }

    private static func agentPlaceholders(_ names: [String], firstIndex: Int) -> String {
        names.indices.map { "?\(firstIndex + $0)" }.joined(separator: ", ")
    }

    private func listSessions(page: Int, agentNames: [String], folders: AgentSessionFolderFilter?) throws -> AgentSessionSearchPage {
        readerLock.lock()
        defer { readerLock.unlock() }
        let agentClause = agentNames.isEmpty ? "" : "AND agent IN (\(Self.agentPlaceholders(agentNames, firstIndex: 3)))"
        let folderCondition = folders?.sqlCondition(firstParameter: 3 + agentNames.count)
        let folderClause = folderCondition.map { "AND \($0.sql)" } ?? ""
        let statement = try reader.prepare(
            """
            SELECT agent, session_key, title, first_prompt, cwd, last_active, size_bytes FROM sessions
            WHERE is_one_shot = 0 AND turn_count > 0 \(agentClause) \(folderClause)
            ORDER BY last_active DESC, id DESC LIMIT ?1 OFFSET ?2
            """)
        statement.bind(1, .int(Int64(AgentSessionSearchPage.pageSize + 1)))
        statement.bind(2, .int(Int64(page * AgentSessionSearchPage.pageSize)))
        for (offset, name) in agentNames.enumerated() { statement.bind(Int32(3 + offset), .text(name)) }
        for (offset, text) in (folderCondition?.bindings ?? []).enumerated() { statement.bind(Int32(3 + agentNames.count + offset), .text(text)) }
        var results: [AgentSessionSearchResult] = []
        while try statement.step() { if let result = Self.result(from: statement, excerpt: nil) { results.append(result) } }
        let hasMore = results.count > AgentSessionSearchPage.pageSize
        return AgentSessionSearchPage(results: Array(results.prefix(AgentSessionSearchPage.pageSize)), hasMore: hasMore)
    }

    private func searchSessions(matching expression: String, tokens: [String], page: Int, agentNames: [String], folders: AgentSessionFolderFilter?)
        throws -> AgentSessionSearchPage
    {
        readerLock.lock()
        defer { readerLock.unlock() }
        let pageSize = AgentSessionSearchPage.pageSize
        let wanted = (page + 1) * pageSize + 1
        // CROSS JOIN pins the order: the FTS scan drives and each match probes `turns` (and `sessions`).
        // Left to itself the planner may drive from `turns` and re-run the MATCH for every turn. `sessions`
        // is joined once for the agent and folder filters together.
        let folderCondition = folders?.sqlCondition(alias: "s", firstParameter: 2 + agentNames.count)
        var sessionConditions: [String] = []
        if !agentNames.isEmpty { sessionConditions.append("s.agent IN (\(Self.agentPlaceholders(agentNames, firstIndex: 2)))") }
        if let folderCondition { sessionConditions.append(folderCondition.sql) }
        let sessionJoin =
            sessionConditions.isEmpty ? "" : "CROSS JOIN sessions s ON s.id = m.session_id AND " + sessionConditions.joined(separator: " AND ")
        let scan = try reader.prepare(
            """
            SELECT m.session_id, t.rowid FROM turn_text t CROSS JOIN turns m ON m.rowid = t.rowid \(sessionJoin)
            WHERE t.turn_text MATCH ?1 ORDER BY t.rowid DESC
            """)
        scan.bind(1, .text(expression))
        for (offset, name) in agentNames.enumerated() { scan.bind(Int32(2 + offset), .text(name)) }
        for (offset, text) in (folderCondition?.bindings ?? []).enumerated() { scan.bind(Int32(2 + agentNames.count + offset), .text(text)) }
        defer { scan.reset() }
        var matches: [(sessionID: Int64, turnRowID: Int64)] = []
        var seen: Set<Int64> = []
        while matches.count < wanted, try scan.step() {
            let sessionID = scan.int64(0)
            if seen.insert(sessionID).inserted { matches.append((sessionID, scan.int64(1))) }
        }

        let sessionLookup = try reader.prepare(
            "SELECT agent, session_key, title, first_prompt, cwd, last_active, size_bytes FROM sessions WHERE id = ?1")
        let textLookup = try reader.prepare("SELECT text FROM turn_text WHERE rowid = ?1")
        var results: [AgentSessionSearchResult] = []
        for (sessionID, turnRowID) in matches.dropFirst(page * pageSize).prefix(pageSize) {
            textLookup.bind(1, .int(turnRowID))
            let text = try textLookup.step() ? textLookup.text(0) ?? "" : ""
            textLookup.reset()
            sessionLookup.bind(1, .int(sessionID))
            defer { sessionLookup.reset() }
            if try sessionLookup.step(), let result = Self.result(from: sessionLookup, excerpt: SessionExcerpt.make(from: text, matching: tokens)) {
                results.append(result)
            }
        }
        return AgentSessionSearchPage(results: results, hasMore: matches.count > (page + 1) * pageSize)
    }

    /// Reads a row shaped `agent, session_key, title, first_prompt, cwd, last_active, size_bytes`.
    private static func result(from row: SessionIndexStatement, excerpt: String?) -> AgentSessionSearchResult? {
        guard let agent = row.text(0).flatMap(CodingAgent.init(rawValue:)), let sessionKey = row.text(1) else { return nil }
        let agentTitle = row.text(2).flatMap { $0.isEmpty ? nil : singleLine($0) }
        return AgentSessionSearchResult(
            agent: agent, sessionKey: sessionKey, title: agentTitle ?? firstLine(of: row.text(3) ?? ""), workingDirectory: row.text(4),
            lastActive: Date(timeIntervalSince1970: row.double(5)), sizeBytes: row.int64(6), excerpt: excerpt)
    }

    private static let maximumTitleLength = 200

    /// The first non-blank line, trimmed: a pasted prompt is many lines and a title is one.
    private static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(maximumTitleLength))
    }

    private static func singleLine(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: - Opening

    private struct FormatMismatch: Error {}

    /// The writer connection to a current index, creating or recreating the file when the existing one is
    /// absent, from another format version, or unreadable.
    private static func openWriteDatabase(at url: URL) throws -> SessionIndexDatabase {
        if FileManager.default.fileExists(atPath: url.path), let existing = try? openCurrent(at: url) { return existing }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let database = try SessionIndexDatabase(path: url.path, readOnly: false)
        try configure(database)
        try database.execute("BEGIN")
        for statement in SessionIndexSchema.createStatements { try database.execute(statement) }
        try database.execute("PRAGMA user_version = \(SessionIndexSchema.formatVersion)")
        try database.execute("COMMIT")
        return database
    }

    private static func openCurrent(at url: URL) throws -> SessionIndexDatabase {
        let database = try SessionIndexDatabase(path: url.path, readOnly: false)
        guard try database.userVersion() == SessionIndexSchema.formatVersion, try database.hasTable("sessions") else { throw FormatMismatch() }
        try configure(database)
        // Touch each table so a damaged file fails here, not in the middle of a search.
        for table in ["sessions", "source_files", "turns", "turn_text"] {
            let probe = try database.prepare("SELECT 1 FROM \(table) LIMIT 1")
            _ = try probe.step()
        }
        return database
    }

    private static func configure(_ database: SessionIndexDatabase) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        // Losing the last commits in a crash only means re-reading them from the stores.
        try database.execute("PRAGMA synchronous = NORMAL")
    }
}

/// Searchable sessions and the turns indexed for them, per agent.
public struct AgentSessionIndexStatistics: Sendable, Equatable {
    public var sessions: [CodingAgent: Int] = [:]
    public var turns: [CodingAgent: Int] = [:]

    public init() {}
}

import Foundation
import spacesterminalcore

/// The refresh pass's writes to the index database, over its one read-write connection.
final class SessionIndexWriter {
    private let database: SessionIndexDatabase
    private let insertText: SessionIndexStatement
    private let insertTurnRow: SessionIndexStatement
    private let turnRowExists: SessionIndexStatement
    private let deleteText: SessionIndexStatement
    private let deleteTurnRows: SessionIndexStatement
    private let deleteOneText: SessionIndexStatement
    private let deleteOneTurnRow: SessionIndexStatement
    private let latestTurnRow: SessionIndexStatement
    private let turnText: SessionIndexStatement
    private let insertSession: SessionIndexStatement
    private let updateSession: SessionIndexStatement
    private let deleteSession: SessionIndexStatement
    private let upsertFile: SessionIndexStatement
    private let deleteFile: SessionIndexStatement
    private let deleteFiles: SessionIndexStatement
    private let setSessionTitle: SessionIndexStatement
    private let readMeta: SessionIndexStatement
    private let writeMeta: SessionIndexStatement

    init(database: SessionIndexDatabase) throws {
        self.database = database
        insertText = try database.prepare("INSERT INTO turn_text (rowid, text) VALUES (?1, ?2)")
        insertTurnRow = try database.prepare("INSERT INTO turns (rowid, session_id, transcript) VALUES (?1, ?2, ?3)")
        turnRowExists = try database.prepare("SELECT 1 FROM turns WHERE rowid = ?1")
        deleteText = try database.prepare("DELETE FROM turn_text WHERE rowid IN (SELECT rowid FROM turns WHERE session_id = ?1)")
        deleteTurnRows = try database.prepare("DELETE FROM turns WHERE session_id = ?1")
        deleteOneText = try database.prepare("DELETE FROM turn_text WHERE rowid = ?1")
        deleteOneTurnRow = try database.prepare("DELETE FROM turns WHERE rowid = ?1")
        latestTurnRow = try database.prepare("SELECT MAX(rowid) FROM turns WHERE session_id = ?1 AND transcript = ?2")
        turnText = try database.prepare("SELECT text FROM turn_text WHERE rowid = ?1")
        insertSession = try database.prepare(
            "INSERT INTO sessions (agent, source_id, session_key, last_active, size_bytes) VALUES (?1, ?2, ?3, 0, 0)")
        updateSession = try database.prepare(
            """
            UPDATE sessions SET title = ?2, first_prompt = ?3, cwd = ?4, last_active = ?5, size_bytes = ?6,
                is_one_shot = ?7, turn_count = ?8 WHERE id = ?1
            """)
        deleteSession = try database.prepare("DELETE FROM sessions WHERE id = ?1")
        upsertFile = try database.prepare(
            "INSERT OR REPLACE INTO source_files (session_id, path, size, modified_at, inode, read_offset) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
        deleteFile = try database.prepare("DELETE FROM source_files WHERE session_id = ?1 AND path = ?2")
        deleteFiles = try database.prepare("DELETE FROM source_files WHERE session_id = ?1")
        setSessionTitle = try database.prepare("UPDATE sessions SET title = ?2 WHERE id = ?1 AND IFNULL(title, '') != ?2")
        readMeta = try database.prepare("SELECT value FROM index_meta WHERE key = ?1")
        writeMeta = try database.prepare("INSERT OR REPLACE INTO index_meta (key, value) VALUES (?1, ?2)")
    }

    func begin() throws { try database.execute("BEGIN IMMEDIATE") }
    func commit() throws { try database.execute("COMMIT") }
    func rollback() { try? database.execute("ROLLBACK") }

    func loadSessions() throws -> [StoredSession.Key: StoredSession] {
        var sessions: [StoredSession.Key: StoredSession] = [:]
        var keysByID: [Int64: StoredSession.Key] = [:]
        let sessionRows = try database.prepare(
            "SELECT id, agent, source_id, title, first_prompt, cwd, last_active, is_one_shot, turn_count FROM sessions")
        while try sessionRows.step() {
            guard let agent = sessionRows.text(1).flatMap(CodingAgent.init(rawValue:)), let sourceID = sessionRows.text(2) else { continue }
            let key = StoredSession.Key(agent: agent, sourceID: sourceID)
            let id = sessionRows.int64(0)
            keysByID[id] = key
            sessions[key] = StoredSession(
                id: id,
                metadata: AgentSessionMetadata(
                    title: sessionRows.text(3), workingDirectory: sessionRows.text(5), firstUserPrompt: sessionRows.text(4),
                    lastActivity: Date(timeIntervalSince1970: sessionRows.double(6)), isOneShot: sessionRows.int64(7) != 0),
                turnCount: Int(sessionRows.int64(8)), files: [:])
        }
        let fileRows = try database.prepare("SELECT session_id, path, size, modified_at, inode, read_offset FROM source_files")
        while try fileRows.step() {
            guard let key = keysByID[fileRows.int64(0)], let path = fileRows.text(1) else { continue }
            let offsetIsNull = fileRows.text(5) == nil
            sessions[key]?.files[path] = StoredSession.File(
                path: path, size: fileRows.int64(2), modifiedAt: fileRows.double(3), inode: fileRows.int64(4),
                readOffset: offsetIsNull ? nil : fileRows.int64(5))
        }
        return sessions
    }

    func addSession(agent: CodingAgent, sourceID: String, sessionKey: String) throws -> Int64 {
        try insertSession.run([.text(agent.rawValue), .text(sourceID), .text(sessionKey)])
        return database.lastInsertRowID
    }

    func saveSession(id: Int64, metadata: AgentSessionMetadata, lastActive: Date, sizeBytes: Int64, turnCount: Int) throws {
        try updateSession.run([
            .int(id), metadata.title.map { .text($0) } ?? .null, metadata.firstUserPrompt.map { .text($0) } ?? .null,
            metadata.workingDirectory.map { .text($0) } ?? .null, .double(lastActive.timeIntervalSince1970), .int(sizeBytes),
            .int(metadata.isOneShot ? 1 : 0), .int(Int64(turnCount)),
        ])
    }

    /// Adds a turn last active at `date`, at the first free rowid from that time on (see `TurnRowID`).
    func addTurn(_ text: String, sessionID: Int64, transcript: Int64, at date: Date) throws {
        var rowID = TurnRowID.firstCandidate(for: date)
        while try isTaken(rowID) { rowID += 1 }
        try insertText.run([.int(rowID), .text(text)])
        try insertTurnRow.run([.int(rowID), .int(sessionID), .int(transcript)])
    }

    private func isTaken(_ rowID: Int64) throws -> Bool {
        turnRowExists.bind(1, .int(rowID))
        defer { turnRowExists.reset() }
        return try turnRowExists.step()
    }

    /// The newest turn of one of the session's transcripts, which a continuation of that transcript extends.
    func latestTurn(sessionID: Int64, transcript: Int64) throws -> (rowID: Int64, text: String)? {
        latestTurnRow.bind(1, .int(sessionID))
        latestTurnRow.bind(2, .int(transcript))
        defer { latestTurnRow.reset() }
        guard try latestTurnRow.step(), !latestTurnRow.isNull(0) else { return nil }
        let rowID = latestTurnRow.int64(0)
        turnText.bind(1, .int(rowID))
        defer { turnText.reset() }
        return try turnText.step() ? (rowID, turnText.text(0) ?? "") : nil
    }

    func removeTurn(rowID: Int64) throws {
        try deleteOneText.run([.int(rowID)])
        try deleteOneTurnRow.run([.int(rowID)])
    }

    func removeTurns(sessionID: Int64) throws {
        try deleteText.run([.int(sessionID)])
        try deleteTurnRows.run([.int(sessionID)])
    }

    func removeSession(id: Int64) throws {
        try removeTurns(sessionID: id)
        try deleteFiles.run([.int(id)])
        try deleteSession.run([.int(id)])
    }

    func saveFile(sessionID: Int64, _ file: StoredSession.File) throws {
        try upsertFile.run([
            .int(sessionID), .text(file.path), .int(file.size), .double(file.modifiedAt), .int(file.inode), file.readOffset.map { .int($0) } ?? .null,
        ])
    }

    func removeFile(sessionID: Int64, path: String) throws { try deleteFile.run([.int(sessionID), .text(path)]) }

    func removeFiles(sessionID: Int64) throws { try deleteFiles.run([.int(sessionID)]) }

    func setTitle(_ title: String, sessionID: Int64) throws { try setSessionTitle.run([.int(sessionID), .text(title)]) }

    func meta(_ key: String) throws -> String? {
        readMeta.bind(1, .text(key))
        defer { readMeta.reset() }
        return try readMeta.step() ? readMeta.text(0) : nil
    }

    func setMeta(_ key: String, _ value: String) throws { try writeMeta.run([.text(key), .text(value)]) }
}

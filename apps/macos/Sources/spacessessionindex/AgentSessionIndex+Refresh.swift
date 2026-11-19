import Foundation
import spacesterminalcore

extension AgentSessionIndex {
    /// Bytes of turn text after which a batch is committed even if it holds fewer than
    /// `batchSessionLimit` sessions, so a few enormous sessions cannot grow one transaction without bound.
    private static let batchTextByteLimit = 2 << 20

    /// Runs `refresh` on a dedicated thread at background priority and suspends until it finishes. This is
    /// the path the daemon takes; cancelling the calling task cancels the pass between sessions.
    public func refreshInBackground() async throws -> AgentSessionRefreshSummary {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    BackgroundPriority.lowerCurrentThread()
                    continuation.resume(with: Result { try self.refresh(isCancelled: { cancellation.isSet }) })
                }
                thread.stackSize = 4 << 20
                thread.start()
            }
        } onCancel: {
            cancellation.set()
        }
    }

    /// One pass: discover every store, compare each session's files with what was last read, read only
    /// what changed, and drop sessions whose files are gone.
    ///
    /// A pass over unchanged stores reads no content and does only the file system work that can notice a
    /// change: it stats the directories (listing only those whose modification time moved), the files
    /// that can still grow, and opencode's database files. Work is committed in batches so searches see
    /// progress, and `isCancelled` is consulted between sessions; a cancelled pass keeps what it committed
    /// and the next pass resumes from there.
    ///
    /// FTS rowids encode message time (`TurnRowID`) for `search`'s newest-first scan, so the order sessions
    /// are written in does not matter. A turn that is continued is deleted and reinserted with its new
    /// text at the rowid of its new latest message.
    public func refresh(isCancelled: () -> Bool = { false }) throws -> AgentSessionRefreshSummary {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        var summary = AgentSessionRefreshSummary()
        fileSystem.resetCounters()
        let stored: [StoredSession.Key: StoredSession]
        if let cached = storedSessions {
            stored = cached
        } else {
            stored = try writer.loadSessions()
            fileSystem.immutableFiles = Self.compressedFiles(in: stored)
        }
        let (discovered, unreadableAgents) = discoverSources()
        summary.sessionsDiscovered = discovered.count

        var work: [(source: AgentSessionSource, plan: SessionRefreshPlan, stored: StoredSession?)] = []
        var knownDiscovered = 0
        for (key, source) in discovered {
            let known = stored[key]
            if known != nil { knownDiscovered += 1 }
            if let plan = SessionRefreshPlan.make(source: source, stored: known) { work.append((source, plan, known)) }
        }
        // Newest first, so a search during the first build already finds the sessions people most likely want.
        // Result order does not depend on this: rowids encode message time (see `TurnRowID`).
        work.sort { $0.source.lastModified > $1.source.lastModified }
        // Every stored session was discovered on almost every pass, which the count shows without a scan.
        let removals = knownDiscovered == stored.count ? [:] : stored.filter { discovered[$0.key] == nil && !unreadableAgents.contains($0.key.agent) }

        let codexNames = try loadCodexNamesIfChanged()
        summary.filesStatted = fileSystem.filesStatted
        summary.directoriesStatted = fileSystem.directoriesStatted
        summary.directoriesListed = fileSystem.directoriesListed
        updateProgress { $0 = AgentSessionIndexProgress(processed: 0, total: work.count, isRefreshing: true) }
        defer { updateProgress { $0.isRefreshing = false } }
        storedSessions = stored
        guard !work.isEmpty || !removals.isEmpty || codexNames != nil else { return summary }

        try writer.begin()
        do {
            for (key, removal) in removals {
                try writer.removeSession(id: removal.id)
                storedSessions?[key] = nil
                summary.sessionsRemoved += 1
            }
            if let codexNames {
                for (key, session) in stored where key.agent == .codex {
                    if let name = codexNames.names[key.sourceID] { try writer.setTitle(name, sessionID: session.id) }
                }
                // Titles changed under the cached rows; the next pass reloads them.
                storedSessions = nil
            }
            var uncommittedSessions = 0
            var uncommittedBytes = 0
            for (offset, unit) in work.enumerated() {
                if isCancelled() {
                    summary.wasCancelled = true
                    break
                }
                let plan = unit.plan
                let results: [AgentSessionReadResult]
                do { results = try withAutoreleasePool { try read(unit.source, plan: plan, isCancelled: isCancelled) } } catch AgentSessionReadError
                    .cancelled
                {
                    summary.wasCancelled = true
                    break
                } catch {
                    summary.sessionsFailed += 1
                    updateProgress { $0.processed = offset + 1 }
                    continue
                }
                let written: (session: StoredSession, turns: Int, bytes: Int)
                do {
                    written = try apply(
                        results, of: unit.source, plan: plan, stored: unit.stored, codexTitle: codexNames?.names[unit.source.id],
                        isCancelled: isCancelled)
                } catch AgentSessionReadError.cancelled {
                    // A session is written whole or not at all, so a cancel inside one drops the batch it was
                    // part of; the next pass redoes it.
                    writer.rollback()
                    storedSessions = nil
                    summary.wasCancelled = true
                    return summary
                }
                if storedSessions != nil {
                    storedSessions?[StoredSession.Key(agent: unit.source.agent, sourceID: unit.source.id)] = written.session
                    for file in unit.source.files where file.kind == .compressedTranscript { fileSystem.immutableFiles[file.path] = file }
                }
                summary.sessionsRead += 1
                summary.turnsWritten += written.turns
                uncommittedSessions += 1
                uncommittedBytes += written.bytes
                updateProgress { $0.processed = offset + 1 }
                if uncommittedSessions >= batchSessionLimit || uncommittedBytes >= Self.batchTextByteLimit {
                    try writer.commit()
                    try writer.begin()
                    uncommittedSessions = 0
                    uncommittedBytes = 0
                }
            }
            try writer.commit()
            // The names file counts as read only once every session was indexed against it: a cancelled pass
            // leaves sessions unwritten, and the next pass (possibly after a restart) must load the names again.
            if let codexNames, !summary.wasCancelled {
                try writer.begin()
                try writer.setMeta(Self.codexIndexStatKey, codexNames.stat)
                try writer.commit()
            }
        } catch {
            writer.rollback()
            storedSessions = nil
            throw error
        }
        return summary
    }

    // MARK: - Discovery

    /// Stats of the compressed rollouts the index has read. They are never rewritten, so discovery reuses
    /// these instead of stat-ing thousands of files on every pass.
    private static func compressedFiles(in sessions: [StoredSession.Key: StoredSession]) -> [String: AgentSessionFile] {
        var files: [String: AgentSessionFile] = [:]
        for session in sessions.values {
            for (path, file) in session.files where path.hasSuffix(".jsonl.zst") {
                files[path] = AgentSessionFile(
                    path: path, kind: .compressedTranscript, size: file.size, modifiedAt: Date(timeIntervalSince1970: file.modifiedAt),
                    inode: UInt64(bitPattern: file.inode))
            }
        }
        return files
    }

    /// Every session in every store, keyed by agent and id, and the agents whose store could not be listed.
    /// A store that fails to list (permissions, a database mid-write) is unknown, not empty, so its sessions
    /// are left in the index instead of being removed.
    private func discoverSources() -> ([StoredSession.Key: AgentSessionSource], Set<CodingAgent>) {
        let fileSystem = fileSystem
        let stores: [(CodingAgent, () throws -> [AgentSessionSource])] = [
            (.claudeCode, { try ClaudeCodeSessionStore.discover(projectsRoot: self.locations.claudeCodeProjects, fileSystem: fileSystem) }),
            (
                .codex,
                {
                    try CodexSessionStore.discover(
                        sessionsRoot: self.locations.codexSessions, archivedRoot: self.locations.codexArchivedSessions, fileSystem: fileSystem)
                }
            ), (.opencode, { try self.discoverOpenCode() }),
            (.amp, { try AmpThreadStore.discover(threadsRoot: self.locations.ampThreads, fileSystem: fileSystem) }),
            (.copilot, { try CopilotSessionStore.discover(sessionStateRoot: self.locations.copilotSessionState, fileSystem: fileSystem) }),
            (.pi, { try PiSessionStore.discover(sessionsRoot: self.locations.piSessions, fileSystem: fileSystem) }),
        ]
        var sources: [StoredSession.Key: AgentSessionSource] = [:]
        var unreadable: Set<CodingAgent> = []
        for (agent, discover) in stores {
            guard let found = withAutoreleasePool({ try? discover() }) else {
                unreadable.insert(agent)
                continue
            }
            for source in found {
                let key = StoredSession.Key(agent: agent, sourceID: source.id)
                // While Codex compresses a rollout both files exist for a moment; the plain one is complete,
                // the compressed one may still be being written.
                if let existing = sources[key], existing.files.first?.kind != .compressedTranscript { continue }
                sources[key] = source
            }
        }
        return (sources, unreadable)
    }

    /// opencode's sessions are rows of one database, and listing them scans its message and part tables.
    /// Every write to the database lands in it or its write-ahead log, so while neither file's size or
    /// modification time has moved the previous listing still stands.
    private func discoverOpenCode() throws -> [AgentSessionSource] {
        let database = locations.openCodeDatabase
        var signature: [Double] = []
        for url in [database, URL(fileURLWithPath: database.path + "-wal")] {
            let file = fileSystem.statIfPresent(url)
            signature.append(contentsOf: [Double(file?.size ?? -1), file?.modifiedAt.timeIntervalSince1970 ?? -1])
        }
        if let snapshot = openCodeSnapshot, snapshot.signature == signature { return snapshot.sources }
        let sources = try OpenCodeSessionStore(databasePath: database.path).discover()
        openCodeSnapshot = (signature, sources)
        return sources
    }

    // MARK: - Codex thread names

    private static let codexIndexStatKey = "codex_session_index_stat"

    /// Codex records a thread's name only in `session_index.jsonl`, not in the rollout, so the file is
    /// re-read when its size or modification time differs from the last pass; nil means unchanged.
    private func loadCodexNamesIfChanged() throws -> (names: [String: String], stat: String)? {
        let url = locations.codexSessionIndex
        let file = fileSystem.statIfPresent(url)
        let stat = "\(file?.size ?? 0):\(file?.modifiedAt.timeIntervalSince1970 ?? 0)"
        if try writer.meta(Self.codexIndexStatKey) == stat { return nil }
        return (try CodexSessionStore.threadNames(indexFile: url), stat)
    }

    // MARK: - Reading

    private func read(_ source: AgentSessionSource, plan: SessionRefreshPlan, isCancelled: () -> Bool) throws -> [AgentSessionReadResult] {
        if source.agent == .opencode {
            return [try OpenCodeSessionStore(databasePath: locations.openCodeDatabase.path).read(sessionID: source.id, sinceWatermark: 0)]
        }
        return try plan.reads.map { read in
            switch source.agent {
            case .claudeCode: try ClaudeCodeSessionStore.read(read.file, from: read.offset, isCancelled: isCancelled)
            case .codex: try CodexSessionStore.read(read.file, from: read.offset, isCancelled: isCancelled)
            case .amp: try AmpThreadStore.read(read.file)
            case .copilot: try CopilotSessionStore.read(read.file, from: read.offset, isCancelled: isCancelled)
            case .pi: try PiSessionStore.read(read.file, from: read.offset, isCancelled: isCancelled)
            case .opencode: preconditionFailure("opencode is read by session id above")
            }
        }
    }

    // MARK: - Writing

    /// Writes one session's read results and returns the session as now stored, the rows written, and
    /// the turn text bytes inserted.
    private func apply(
        _ results: [AgentSessionReadResult], of source: AgentSessionSource, plan: SessionRefreshPlan, stored: StoredSession?, codexTitle: String?,
        isCancelled: () -> Bool
    ) throws -> (session: StoredSession, turns: Int, bytes: Int) {
        let sessionID: Int64
        var metadata: AgentSessionMetadata
        var turnCount: Int
        var files: [String: StoredSession.File]
        if let stored {
            sessionID = stored.id
            if plan.rebuild {
                try writer.removeTurns(sessionID: sessionID)
                try writer.removeFiles(sessionID: sessionID)
                // Codex's title lives outside the rollout, so a rebuild keeps the stored one.
                metadata = AgentSessionMetadata(title: source.agent == .codex ? stored.metadata.title : nil)
                turnCount = 0
                files = [:]
            } else {
                metadata = stored.metadata
                turnCount = stored.turnCount
                files = stored.files
            }
        } else {
            sessionID = try writer.addSession(agent: source.agent, sourceID: source.id, sessionKey: source.sessionKey)
            metadata = AgentSessionMetadata()
            turnCount = 0
            files = [:]
        }
        for path in plan.supersededPaths {
            try writer.removeFile(sessionID: sessionID, path: path)
            files[path] = nil
        }

        for result in results { metadata = metadata.merging(result.metadata) }
        if let codexTitle { metadata.title = codexTitle }

        // A one-shot run is kept as a row so its files are not read again, but contributes no turns.
        if metadata.isOneShot && turnCount > 0 {
            try writer.removeTurns(sessionID: sessionID)
            turnCount = 0
        }
        var written = 0
        var writtenBytes = 0
        if !metadata.isOneShot {
            // Each transcript is grouped on its own: a folded subagent transcript's turns are not the
            // parent's, and a continuation extends a turn of the transcript it was appended to. An opencode
            // session is one read whose messages interleave its child sessions', so each originating
            // session is a transcript of its own.
            var transcripts: [(path: String, modifiedAt: Date, messages: [AgentSessionMessage])] = []
            for (offset, result) in results.enumerated() {
                if source.agent == .opencode {
                    var originOrder: [String] = []
                    var byOrigin: [String: [AgentSessionMessage]] = [:]
                    for message in result.messages {
                        let origin = message.originSessionID ?? source.id
                        if byOrigin[origin] == nil { originOrder.append(origin) }
                        byOrigin[origin, default: []].append(message)
                    }
                    transcripts += originOrder.map { (SessionRefreshPlan.openCodePath(sessionID: $0), source.lastModified, byOrigin[$0] ?? []) }
                } else {
                    transcripts.append((plan.reads[offset].file.path, plan.reads[offset].file.modifiedAt, result.messages))
                }
            }
            for (path, modifiedAt, messages) in transcripts {
                var grouped = SessionTurns()
                messages.forEach { grouped.add($0) }
                var turns = grouped.turns
                guard !turns.isEmpty else { continue }
                let transcript = TranscriptKey.make(path: path)
                if grouped.continuesPreviousTurn, let latest = try writer.latestTurn(sessionID: sessionID, transcript: transcript) {
                    try writer.removeTurn(rowID: latest.rowID)
                    turns[0].text = latest.text + "\n\n" + turns[0].text
                    // The turn keeps the later of its old and new times.
                    turns[0].latest = max(TurnRowID.date(of: latest.rowID), turns[0].latest ?? modifiedAt)
                    turnCount -= 1
                }
                for turn in turns {
                    if isCancelled() { throw AgentSessionReadError.cancelled }
                    try writer.addTurn(turn.text, sessionID: sessionID, transcript: transcript, at: turn.latest ?? modifiedAt)
                    writtenBytes += turn.text.utf8.count
                }
                written += turns.count
                turnCount += turns.count
            }
        }

        if source.agent == .opencode {
            let file = StoredSession.File(
                path: SessionRefreshPlan.openCodePath(sessionID: source.id), size: source.sizeBytes,
                modifiedAt: source.lastModified.timeIntervalSince1970, inode: 0, readOffset: nil)
            try writer.saveFile(sessionID: sessionID, file)
            files[file.path] = file
        } else {
            for (read, result) in zip(plan.reads, results) {
                var offset: Int64?
                if case .byteOffset(let end) = result.nextState { offset = end }
                let file = StoredSession.File(
                    path: read.file.path, size: read.file.size, modifiedAt: read.file.modifiedAt.timeIntervalSince1970,
                    inode: Int64(bitPattern: read.file.inode), readOffset: offset)
                try writer.saveFile(sessionID: sessionID, file)
                files[file.path] = file
            }
        }
        let lastActive = metadata.lastActivity ?? source.lastModified
        try writer.saveSession(id: sessionID, metadata: metadata, lastActive: lastActive, sizeBytes: source.sizeBytes, turnCount: turnCount)
        // What a reload from the database would produce, so the cached rows match it.
        metadata.lastActivity = lastActive
        return (StoredSession(id: sessionID, metadata: metadata, turnCount: turnCount, files: files), written, writtenBytes)
    }
}

/// Lets a cancelled task stop a refresh running on another thread.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

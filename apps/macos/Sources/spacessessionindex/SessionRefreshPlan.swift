import Foundation

/// What a refresh pass has to read to bring one session's index entry up to date.
struct SessionRefreshPlan {
    struct Read {
        let file: AgentSessionFile
        let offset: Int64
    }

    /// Delete the session's indexed messages and read every file from the start, because the previous
    /// reads can no longer be extended: a file was replaced, shrank, or is a document rewritten in place.
    let rebuild: Bool
    let reads: [Read]
    /// Stored files superseded by one in `reads` (a plain rollout that became `.jsonl.zst`).
    let supersededPaths: [String]

    /// opencode has no files, so its stat facts are filed under a synthetic path.
    static func openCodePath(sessionID: String) -> String { "opencode:\(sessionID)" }

    /// The plan for `source`, or nil when its files are unchanged since they were last read.
    static func make(source: AgentSessionSource, stored: StoredSession?) -> SessionRefreshPlan? {
        guard let stored else {
            return SessionRefreshPlan(rebuild: false, reads: source.files.map { Read(file: $0, offset: 0) }, supersededPaths: [])
        }
        if source.agent == .opencode {
            let path = openCodePath(sessionID: source.id)
            if let known = stored.files[path], known.size == source.sizeBytes, known.modifiedAt == source.lastModified.timeIntervalSince1970 {
                return nil
            }
            // Never an incremental read: a part row updated in the same millisecond as the last one read is
            // indistinguishable by watermark, and sessions are small enough to read whole.
            return SessionRefreshPlan(rebuild: true, reads: [], supersededPaths: [])
        }

        // Nearly every session on nearly every pass: all files as last read. Checked first so that case
        // does not copy the stored file table.
        if source.files.count == stored.files.count, source.files.allSatisfy({ stored.files[$0.path]?.matches($0) == true }) { return nil }

        var unseen = stored.files
        var reads: [Read] = []
        var superseded: [String] = []
        var rebuild = false
        for file in source.files {
            if let known = unseen.removeValue(forKey: file.path) {
                if known.matches(file) { continue }
                switch file.kind {
                case .transcript, .subagentTranscript:
                    if known.inode != Int64(bitPattern: file.inode) || file.size < (known.readOffset ?? 0) {
                        rebuild = true
                    } else {
                        reads.append(Read(file: file, offset: known.readOffset ?? 0))
                    }
                case .metadata: reads.append(Read(file: file, offset: 0))
                case .compressedTranscript, .wholeFileDocument: rebuild = true
                }
            } else if file.kind == .compressedTranscript, file.path.hasSuffix(".zst"), let plain = unseen[String(file.path.dropLast(".zst".count))],
                let offset = plain.readOffset
            {
                // Codex compressed a rollout already indexed: only what was appended after `offset` is new.
                unseen.removeValue(forKey: plain.path)
                superseded.append(plain.path)
                reads.append(Read(file: file, offset: offset))
            } else {
                reads.append(Read(file: file, offset: 0))
            }
        }
        if !unseen.isEmpty { rebuild = true }
        if rebuild { return SessionRefreshPlan(rebuild: true, reads: source.files.map { Read(file: $0, offset: 0) }, supersededPaths: []) }
        if reads.isEmpty { return nil }
        return SessionRefreshPlan(rebuild: false, reads: reads, supersededPaths: superseded)
    }
}

import Foundation
import spacesterminalcore

/// Codex's store: `sessions/YYYY/MM/DD/rollout-<timestamp>-<thread id>.jsonl`, which Codex later
/// compresses in place to `.jsonl.zst`.
///
/// Records read: `session_meta` (the thread id, working directory and `source`) and the `item_completed`
/// events whose item is a `UserMessage` or `AgentMessage`. The `response_item` records are not read: their
/// user messages include the AGENTS.md and environment context Codex injects, and every real message is
/// also reported as an `item_completed` event, so reading both would double count.
///
/// A rollout whose `source` is `exec` (`codex exec`) or a subagent (`codex review` and Codex's own review
/// threads) is a one-shot run. `cli` and `vscode` (the Codex desktop app) are interactive.
public enum CodexSessionStore {
    /// Command and file-change items carry whole tool outputs and dominate a rollout's size, so only the
    /// lines of the two message items (and the first line) are decoded.
    private static let needles = ["\"item\":{\"type\":\"UserMessage\"", "\"item\":{\"type\":\"AgentMessage\"", "\"type\":\"session_meta\""]

    public static func discover(sessionsRoot: URL, archivedRoot: URL) throws -> [AgentSessionSource] {
        try discover(sessionsRoot: sessionsRoot, archivedRoot: archivedRoot, fileSystem: SessionStoreFileSystem())
    }

    /// Active rollouts and the ones Codex moved to `archived_sessions`, one source per thread. When a
    /// thread has both (a move caught half way, or a copy), the active rollout wins. An unreadable root
    /// throws, so the caller keeps every Codex session rather than concluding the unlistable ones are gone.
    static func discover(sessionsRoot: URL, archivedRoot: URL, fileSystem: SessionStoreFileSystem) throws -> [AgentSessionSource] {
        var sources = try walk(root: sessionsRoot, fileSystem: fileSystem)
        let active = Set(sources.map(\.id))
        sources += try walk(root: archivedRoot, fileSystem: fileSystem).filter { !active.contains($0.id) }
        return sources
    }

    private static func walk(root: URL, fileSystem: SessionStoreFileSystem) throws -> [AgentSessionSource] {
        var sources: [AgentSessionSource] = []
        var pending = [root.path]
        while let directory = pending.popLast() {
            let entries = try fileSystem.list(path: directory)
            // Compressed rollouts already read never change, so while the directory is unchanged their
            // sources are reused and only the files that can still grow are looked at.
            let remembered = fileSystem.rememberedSources(inDirectory: directory)
            if let remembered { sources.append(contentsOf: remembered) }
            var compressed: [AgentSessionSource] = []
            for entry in entries {
                let path = directory + "/" + entry.name
                if entry.isDirectory {
                    pending.append(path)
                    continue
                }
                if remembered != nil, entry.name.utf8.suffix(".zst".utf8.count).elementsEqual(".zst".utf8) { continue }
                guard let source = try source(named: entry.name, at: path, fileSystem: fileSystem) else { continue }
                sources.append(source)
                if source.files[0].kind == .compressedTranscript { compressed.append(source) }
            }
            if remembered == nil, !compressed.isEmpty, compressed.allSatisfy({ fileSystem.immutableFiles[$0.files[0].path] != nil }) {
                fileSystem.remember(compressed, inDirectory: directory)
            }
        }
        return sources
    }

    /// Works on the UTF-8 view of the name: a pass walks every rollout (thousands), and character-wise
    /// `String` operations were a large part of the pass.
    private static func source(named name: String, at path: String, fileSystem: SessionStoreFileSystem) throws -> AgentSessionSource? {
        let kind: AgentSessionFile.Kind
        let extensionLength: Int
        if name.utf8.suffix(".jsonl.zst".utf8.count).elementsEqual(".jsonl.zst".utf8) {
            kind = .compressedTranscript
            extensionLength = ".jsonl.zst".utf8.count
        } else if name.utf8.suffix(".jsonl".utf8.count).elementsEqual(".jsonl".utf8) {
            kind = .transcript
            extensionLength = ".jsonl".utf8.count
        } else {
            return nil
        }
        // `rollout-<timestamp>-<thread id>`: the thread id is the trailing UUID.
        let stem = name.utf8.dropLast(extensionLength)
        guard stem.starts(with: "rollout-".utf8), stem.count > 36, let threadID = String(stem.suffix(36)), UUID(uuidString: threadID) != nil else {
            return nil
        }
        return AgentSessionSource(agent: .codex, id: threadID, sessionKey: threadID, files: [try fileSystem.stat(path: path, kind: kind)])
    }

    public static func read(_ file: AgentSessionFile, from offset: Int64, isCancelled: () -> Bool = { false }) throws -> AgentSessionReadResult {
        try JSONLTranscriptReader.read(file, from: offset, needles: needles, isCancelled: isCancelled) { record, accumulator in
            guard let payload = record.object("payload") else { return }
            let timestamp = AgentSessionTimestamp.parse(iso8601: record.string("timestamp"))
            switch (record.string("type"), payload.string("type")) {
            case ("session_meta", _):
                if accumulator.metadata.workingDirectory == nil { accumulator.metadata.workingDirectory = payload.string("cwd") }
                if isOneShot(source: payload["source"]) { accumulator.metadata.isOneShot = true }
            case ("event_msg", "item_completed"):
                guard let item = payload.object("item") else { return }
                let role: AgentSessionMessage.Role
                switch item.string("type") {
                case "UserMessage": role = .user
                case "AgentMessage": role = .assistant
                default: return
                }
                accumulator.addMessage(role, text: item.textBlocks("content").joined(separator: "\n\n"), timestamp: timestamp)
            default: break
            }
        }
    }

    /// Thread names from `session_index.jsonl`, by thread id. A thread renamed later has several entries;
    /// the last one wins. The file is small and rewritten rather than tailed, so it is read whole.
    public static func threadNames(indexFile: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: indexFile.path) else { return [:] }
        var names: [String: String] = [:]
        var source = try FileByteChunks(path: indexFile.path, offset: 0)
        _ = try JSONLineScanner(startOffset: 0).scan(&source) { line in
            guard let entry = JSONLine.object(line), let id = entry.string("id"), let name = entry.string("thread_name"), !name.isEmpty else {
                return
            }
            names[id] = name
        }
        return names
    }

    /// `source` is the string `cli`, `exec` or `vscode`, or an object such as `{"subagent":"review"}`.
    private static func isOneShot(source: Any?) -> Bool {
        if let name = source as? String { return name == "exec" }
        return source is JSONObject
    }
}

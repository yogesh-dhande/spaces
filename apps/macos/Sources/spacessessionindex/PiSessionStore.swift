import Foundation
import spacesterminalcore

/// pi's store: `sessions/<encoded cwd>/<timestamp>_<session id>.jsonl`, append-only. The resume key is the
/// transcript's path (`pi --session <path>`).
///
/// Records read: the `session` header (the working directory), `session_info` (the name set with
/// `--name`), and `message` records whose `message.role` is `user` or `assistant` (their `text` blocks;
/// `system` and `toolResult` messages, thinking and tool calls are not read).
///
/// pi writes no marker that distinguishes `pi -p` from an interactive session, so no pi session is
/// treated as a one-shot run.
public enum PiSessionStore {
    private static let needles = ["\"type\":\"message\"", "\"type\":\"session\"", "\"type\":\"session_info\""]

    public static func discover(sessionsRoot: URL) throws -> [AgentSessionSource] {
        try discover(sessionsRoot: sessionsRoot, fileSystem: SessionStoreFileSystem())
    }

    static func discover(sessionsRoot: URL, fileSystem: SessionStoreFileSystem) throws -> [AgentSessionSource] {
        var sources: [AgentSessionSource] = []
        for directory in try fileSystem.list(sessionsRoot) where directory.isDirectory {
            let directoryURL = sessionsRoot.appendingPathComponent(directory.name, isDirectory: true)
            for entry in try fileSystem.list(directoryURL) where !entry.isDirectory && entry.name.hasSuffix(".jsonl") {
                let url = directoryURL.appendingPathComponent(entry.name)
                sources.append(
                    AgentSessionSource(agent: .pi, id: url.path, sessionKey: url.path, files: [try fileSystem.stat(url, kind: .transcript)]))
            }
        }
        return sources
    }

    public static func read(_ file: AgentSessionFile, from offset: Int64, isCancelled: () -> Bool = { false }) throws -> AgentSessionReadResult {
        try JSONLTranscriptReader.read(file, from: offset, needles: needles, isCancelled: isCancelled) { record, accumulator in
            let timestamp = AgentSessionTimestamp.parse(iso8601: record.string("timestamp"))
            switch record.string("type") {
            case "session": if accumulator.metadata.workingDirectory == nil { accumulator.metadata.workingDirectory = record.string("cwd") }
            case "session_info": if let name = record.string("name"), !name.isEmpty { accumulator.metadata.title = name }
            case "message":
                guard let message = record.object("message"), let role = AgentSessionMessage.Role(rawValue: message.string("role") ?? "") else {
                    return
                }
                let text = message.string("content") ?? message.textBlocks("content").joined(separator: "\n\n")
                accumulator.addMessage(role, text: text, timestamp: timestamp)
            default: break
            }
        }
    }
}

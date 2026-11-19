import Foundation
import Yams
import spacesterminalcore

/// Copilot CLI's store: one directory per session, `session-state/<session id>/`, holding the append-only
/// `events.jsonl` transcript and a `workspace.yaml` with the session's `name` and `cwd`.
///
/// Events read: `user.message` and `assistant.message` (their `content`; a user message's
/// `transformedContent` is the prompt wrapped in injected context and is not read, and an assistant
/// message that only requests tools has empty content), and `session.start` for the working directory.
/// The title is `workspace.yaml`'s `name`, which Copilot derives from the first prompt unless the user
/// named the session.
///
/// Copilot writes no marker that distinguishes `copilot -p` from an interactive session (their event
/// streams differ only in timing), so no Copilot session is treated as a one-shot run.
public enum CopilotSessionStore {
    private static let needles = ["\"type\":\"user.message\"", "\"type\":\"assistant.message\"", "\"type\":\"session.start\""]

    public static func discover(sessionStateRoot: URL) throws -> [AgentSessionSource] {
        try discover(sessionStateRoot: sessionStateRoot, fileSystem: SessionStoreFileSystem())
    }

    static func discover(sessionStateRoot: URL, fileSystem: SessionStoreFileSystem) throws -> [AgentSessionSource] {
        var sources: [AgentSessionSource] = []
        for session in try fileSystem.list(sessionStateRoot) where session.isDirectory {
            let directory = sessionStateRoot.appendingPathComponent(session.name, isDirectory: true)
            let names = Set(try fileSystem.list(directory).map(\.name))
            guard names.contains("events.jsonl") else { continue }
            var files = [try fileSystem.stat(directory.appendingPathComponent("events.jsonl"), kind: .transcript)]
            if names.contains("workspace.yaml") {
                files.append(try fileSystem.stat(directory.appendingPathComponent("workspace.yaml"), kind: .metadata))
            }
            sources.append(AgentSessionSource(agent: .copilot, id: session.name, sessionKey: session.name, files: files))
        }
        return sources
    }

    /// Reads `events.jsonl` from `offset`, or `workspace.yaml` entirely.
    public static func read(_ file: AgentSessionFile, from offset: Int64, isCancelled: () -> Bool = { false }) throws -> AgentSessionReadResult {
        if file.kind == .metadata { return try readWorkspace(file) }
        return try JSONLTranscriptReader.read(file, from: offset, needles: needles, isCancelled: isCancelled) { record, accumulator in
            let timestamp = AgentSessionTimestamp.parse(iso8601: record.string("timestamp"))
            let data = record.object("data")
            switch record.string("type") {
            case "session.start":
                if accumulator.metadata.workingDirectory == nil { accumulator.metadata.workingDirectory = data?.object("context")?.string("cwd") }
            case "user.message": accumulator.addMessage(.user, text: data?.string("content") ?? "", timestamp: timestamp)
            case "assistant.message": accumulator.addMessage(.assistant, text: data?.string("content") ?? "", timestamp: timestamp)
            default: break
            }
        }
    }

    private static func readWorkspace(_ file: AgentSessionFile) throws -> AgentSessionReadResult {
        guard let yaml = FileManager.default.contents(atPath: file.path).flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw AgentSessionReadError.cannotOpen(file.path)
        }
        guard let workspace = try Yams.load(yaml: yaml) as? [String: Any] else { throw AgentSessionReadError.malformedDocument(file.path) }
        var accumulator = SessionReadAccumulator()
        if let name = workspace["name"] as? String, !name.isEmpty { accumulator.metadata.title = name }
        accumulator.metadata.workingDirectory = workspace["cwd"] as? String
        return accumulator.result(nextState: .complete)
    }
}

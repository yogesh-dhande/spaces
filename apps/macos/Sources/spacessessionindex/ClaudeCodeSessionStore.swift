import Foundation
import spacesterminalcore

/// Claude Code's store: `<projects>/<encoded cwd>/<session uuid>.jsonl`, with the transcripts of the
/// subagents a session launched in `<session uuid>/subagents/agent-*.jsonl`.
///
/// Records read: `user` and `assistant` (their `text` blocks), `ai-title` (the session title; Claude Code
/// rewrites it when the user renames the session). A record's `entrypoint` of `sdk-cli` marks a
/// non-interactive (`claude -p`) run.
public enum ClaudeCodeSessionStore {
    private static let needles = ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"ai-title\""]

    /// Text Claude Code writes into user records that the user did not type: slash-command and shell
    /// wrappers, background-task notifications, hook and fork boilerplate.
    private static let injectedPrefixes = [
        "<task-notification>", "<command-message>", "<command-name>", "<local-command-stdout>", "<local-command-caveat>", "<bash-input>",
        "<bash-stdout>", "<bash-stderr>", "<system-reminder>", "<fork-boilerplate>", "[Request interrupted by user",
    ]

    static func discover(projectsRoot: URL, fileSystem: SessionStoreFileSystem) throws -> [AgentSessionSource] {
        var sources: [AgentSessionSource] = []
        for project in try fileSystem.list(projectsRoot) where project.isDirectory {
            let projectURL = projectsRoot.appendingPathComponent(project.name, isDirectory: true)
            let entries = try fileSystem.list(projectURL)
            let directories = Set(entries.lazy.filter(\.isDirectory).map(\.name))
            for entry in entries where !entry.isDirectory && entry.name.hasSuffix(".jsonl") {
                let sessionID = String(entry.name.dropLast(".jsonl".count))
                var files = [try fileSystem.stat(projectURL.appendingPathComponent(entry.name), kind: .transcript)]
                if directories.contains(sessionID) {
                    let subagents = projectURL.appendingPathComponent(sessionID, isDirectory: true).appendingPathComponent(
                        "subagents", isDirectory: true)
                    // Sorted so a session's files are always read in the same order.
                    for subagent in try fileSystem.list(subagents).sorted(by: { $0.name < $1.name })
                    where !subagent.isDirectory && subagent.name.hasSuffix(".jsonl") {
                        files.append(try fileSystem.stat(subagents.appendingPathComponent(subagent.name), kind: .subagentTranscript))
                    }
                }
                sources.append(AgentSessionSource(agent: .claudeCode, id: sessionID, sessionKey: sessionID, files: files))
            }
        }
        return sources
    }

    public static func discover(projectsRoot: URL) throws -> [AgentSessionSource] {
        try discover(projectsRoot: projectsRoot, fileSystem: SessionStoreFileSystem())
    }

    /// Reads a main or subagent transcript from `offset`. A subagent transcript's messages are searchable
    /// as its parent's, but it speaks for neither the user nor the session: its first "user" message is
    /// the parent agent's briefing, so it contributes no title, prompt, directory or one-shot verdict.
    public static func read(_ file: AgentSessionFile, from offset: Int64, isCancelled: () -> Bool = { false }) throws -> AgentSessionReadResult {
        let isSubagent = file.kind == .subagentTranscript
        let result = try JSONLTranscriptReader.read(file, from: offset, needles: needles, isCancelled: isCancelled) { record, accumulator in
            guard let type = record.string("type") else { return }
            let timestamp = AgentSessionTimestamp.parse(iso8601: record.string("timestamp"))
            switch type {
            case "ai-title": if !isSubagent, let title = record.string("aiTitle"), !title.isEmpty { accumulator.metadata.title = title }
            case "user", "assistant":
                if !isSubagent {
                    if record.string("entrypoint") == "sdk-cli" { accumulator.metadata.isOneShot = true }
                    if accumulator.metadata.workingDirectory == nil { accumulator.metadata.workingDirectory = record.string("cwd") }
                }
                guard let text = messageText(of: record, type: type) else {
                    accumulator.noteActivity(timestamp)
                    return
                }
                accumulator.addMessage(type == "user" ? .user : .assistant, text: text, timestamp: timestamp)
            default: break
            }
        }
        guard isSubagent else { return result }
        var metadata = AgentSessionMetadata()
        metadata.lastActivity = result.metadata.lastActivity
        return AgentSessionReadResult(messages: result.messages, metadata: metadata, nextState: result.nextState)
    }

    /// The searchable text of a user or assistant record, nil when the record carries none: tool-result
    /// carriers, meta and compaction records, API error placeholders, injected wrappers.
    private static func messageText(of record: JSONObject, type: String) -> String? {
        guard let message = record.object("message") else { return nil }
        if type == "user" {
            if record.bool("isMeta") == true || record.bool("isCompactSummary") == true || record["toolUseResult"] != nil { return nil }
        } else if record.bool("isApiErrorMessage") == true || message.string("model") == "<synthetic>" {
            return nil
        }
        let blocks: [String]
        if let text = message.string("content") { blocks = [text] } else { blocks = message.textBlocks("content") }
        let kept = blocks.filter { block in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            return !injectedPrefixes.contains { trimmed.hasPrefix($0) }
        }
        return kept.isEmpty ? nil : kept.joined(separator: "\n\n")
    }
}

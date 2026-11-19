import Foundation
import spacesterminalcore

/// Where each supported agent keeps its sessions on one device, resolved from the user's home directory.
///
/// Agent-specific environment overrides (`CODEX_HOME`, `COPILOT_HOME`, `PI_CODING_AGENT_DIR`, `XDG_*`) are
/// not read, for the same reason `CodingAgent.configDirectoryURL` does not read them: they name a location
/// the user's shell chose, which the daemon's environment need not share.
public struct AgentSessionStoreLocations: Sendable, Equatable {
    public let home: URL

    public init(home: URL) { self.home = home }

    /// `<project dir>/<session id>.jsonl`, with each session's subagent transcripts under
    /// `<project dir>/<session id>/subagents/`.
    public var claudeCodeProjects: URL { CodingAgent.claudeCode.configDirectoryURL(home: home).appendingPathComponent("projects", isDirectory: true) }

    /// `YYYY/MM/DD/rollout-<timestamp>-<thread id>.jsonl[.zst]`.
    public var codexSessions: URL { CodingAgent.codex.configDirectoryURL(home: home).appendingPathComponent("sessions", isDirectory: true) }

    /// Where Codex moves an archived conversation: one flat directory of `rollout-<timestamp>-<thread id>.jsonl[.zst]`.
    public var codexArchivedSessions: URL {
        CodingAgent.codex.configDirectoryURL(home: home).appendingPathComponent("archived_sessions", isDirectory: true)
    }

    /// Thread names the user (or Codex) gave threads, one JSON object per line.
    public var codexSessionIndex: URL { CodingAgent.codex.configDirectoryURL(home: home).appendingPathComponent("session_index.jsonl") }

    /// opencode keeps sessions in a SQLite database under the XDG data directory, not under its config
    /// directory (`CodingAgent.configDirectoryURL` names the latter).
    public var openCodeDatabase: URL { home.appendingPathComponent(".local/share/opencode/opencode.db") }

    /// `<thread id>.json`, one whole-file JSON document per thread, under the XDG data directory.
    public var ampThreads: URL { home.appendingPathComponent(".local/share/amp/threads", isDirectory: true) }

    /// `<session id>/events.jsonl` next to `<session id>/workspace.yaml`.
    public var copilotSessionState: URL {
        CodingAgent.copilot.configDirectoryURL(home: home).appendingPathComponent("session-state", isDirectory: true)
    }

    /// `<encoded cwd>/<timestamp>_<session id>.jsonl`.
    public var piSessions: URL { CodingAgent.pi.configDirectoryURL(home: home).appendingPathComponent("sessions", isDirectory: true) }
}

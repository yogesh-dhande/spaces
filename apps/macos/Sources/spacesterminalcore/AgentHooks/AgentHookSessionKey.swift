import Foundation

/// Reads the signaling agent's own conversation id out of the hook payload it hands the Spaces CLI.
///
/// Every supported agent can resume a past conversation by id, and that id is the one thing Spaces
/// cannot reconstruct afterwards: a terminal row stores the wrapped launch command, never the
/// conversation the agent opened inside it. So it is captured while the agent is alive, from the
/// payload its hooks already deliver.
///
/// Claude Code and Codex both write a JSON object to the hook command's stdin carrying the id as a
/// top-level `session_id`, verified against claude 2.1.269 and codex-cli 0.153.4, whose hook payload
/// deliberately mirrors Claude Code's shape. Codex names the same value "session id" in its startup
/// banner and in the rollout file it writes, so it is the id a resume addresses. Neither agent puts
/// the id anywhere else a hook can read: the hook process's environment carries no variable holding
/// it (Claude Code exports `CLAUDE_CODE_SESSION_ID`, but a child process inherits it, so a terminal
/// launched from inside a Claude Code session would report that session's id for whatever agent
/// actually runs in it).
///
/// opencode is the exception: its plugin is JavaScript running inside opencode, receives the id on
/// the event object rather than on stdin, and passes it to the CLI as `--agent-session`.
public enum AgentHookSessionKey {
    /// The top-level JSON key both stdin-delivering agents use.
    static let payloadKey = "session_id"

    /// The conversation id carried by a hook's stdin `payload`, or nil when there is none. An absent,
    /// empty, non-JSON, or non-object payload simply means "no id": the signal it accompanies must
    /// still be recorded, so nothing here throws.
    public static func sessionKey(inHookPayload payload: Data?) -> String? {
        guard let payload, !payload.isEmpty, let object = try? JSONSerialization.jsonObject(with: payload), let fields = object as? [String: Any],
            let value = fields[payloadKey] as? String
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

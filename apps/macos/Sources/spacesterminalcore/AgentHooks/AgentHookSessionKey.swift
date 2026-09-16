import Foundation

/// What one hook signal reports about the signaling agent's own conversation id.
///
/// Three states rather than an optional id, because "I have nothing to say about my conversation" and
/// "the conversation I hold cannot be resumed yet" are different instructions to the agent row. The
/// first leaves the stored id alone, so an agent that reports its id once keeps it across every later
/// signal. The second supersedes the stored id with nothing: the agent has moved on to a conversation
/// a resume cannot address, so the id the row holds names a conversation the agent has left. Claude
/// Code's `/clear` is exactly that moment, and collapsing the two onto one "no id" is what would leave
/// a later restore relaunching `--resume` against the conversation the user deliberately walked away
/// from.
public enum AgentHookSessionKeyReport: Equatable, Sendable {
    /// The signal names no conversation at all.
    case unreported
    /// The signal names a conversation that is not resumable yet, so whatever the row holds is stale.
    case pending
    /// The signal names a conversation a resume can rejoin.
    case resumable(String)
}

/// Reads the signaling agent's own conversation id out of the hook payload it hands the Spaces CLI,
/// and says whether that conversation is one a resume can find yet.
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
/// An id names a conversation a resume can find only once the agent has written that conversation's
/// transcript, and the same payload says where: `transcript_path`. Claude Code hands out the id at
/// `SessionStart`, before the first turn has produced anything to persist, so an agent sitting at a
/// fresh prompt carries an id that `claude --resume` answers with "No conversation found". The same
/// payload after a resume, or after any completed turn, names a file that is already there. So a
/// payload naming a transcript reports `resumable` only when that file exists and `pending` otherwise,
/// and the CLI runs on the device the agent runs on, which is what makes the check meaningful. Codex
/// is consistent under the same rule: its rollout file is what `codex resume` reads. A payload
/// carrying no transcript path is reported `resumable` as it stands, as is an id passed explicitly as
/// `--agent-session`: opencode's plugin reports an id only once opencode holds a session for it.
public enum AgentHookSessionKey {
    /// The top-level JSON key both stdin-delivering agents use.
    static let payloadKey = "session_id"

    /// The top-level JSON key naming the file the reported conversation is persisted to.
    static let transcriptPathKey = "transcript_path"

    /// What a hook's stdin `payload` reports about the agent's conversation. An absent, empty,
    /// non-JSON, or non-object payload is `unreported`: the signal it accompanies must still be
    /// recorded, so nothing here throws. `transcriptExists` is the file probe, injectable for tests.
    public static func report(inHookPayload payload: Data?, transcriptExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> AgentHookSessionKeyReport
    {
        guard let payload, !payload.isEmpty, let object = try? JSONSerialization.jsonObject(with: payload), let fields = object as? [String: Any],
            let value = fields[payloadKey] as? String
        else { return .unreported }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unreported }
        guard let transcriptPath = normalizedTranscriptPath(inFields: fields) else { return .resumable(trimmed) }
        return transcriptExists(transcriptPath) ? .resumable(trimmed) : .pending
    }

    /// The transcript path the payload names, or nil when it names none to check against.
    private static func normalizedTranscriptPath(inFields fields: [String: Any]) -> String? {
        guard let value = fields[transcriptPathKey] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

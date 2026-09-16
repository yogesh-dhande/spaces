import Foundation
import Testing

@testable import spacesterminalcore

/// The payload fixtures are the real hook payloads captured from the installed CLIs (claude 2.1.269,
/// codex-cli 0.153.4), with the ids and paths rewritten. Both agents deliver the same shape, so the
/// same key serves both; Codex's `session_id` is the id its own `resume` takes. The file probe is
/// injected over a fixed set of paths, so no test reads the real filesystem.
struct AgentHookSessionKeyTests {
    private func payload(_ json: String) -> Data { Data(json.utf8) }

    private func existing(_ paths: String...) -> (String) -> Bool {
        let set = Set(paths)
        return { set.contains($0) }
    }

    private var nothingExists: (String) -> Bool { { _ in false } }

    private let claudeTranscript = "/home/user/.claude/projects/a/b.jsonl"
    private let codexRollout = "/home/user/.codex/sessions/2026/09/11/rollout.jsonl"

    private func claudeSessionStart(source: String) -> Data {
        payload(
            """
            {"session_id":"ad826684-73f8-4748-88b4-a77c064bb1fb","transcript_path":"\(claudeTranscript)",\
            "cwd":"/repo/workspaces/feature","hook_event_name":"SessionStart","source":"\(source)"}
            """)
    }

    private var codexStop: Data {
        payload(
            """
            {"session_id":"01a0938f-30fb-7ca1-83b0-915dcf9f9d3f","turn_id":"01a0938f-311e-70b2-8037-7583c47698d3",\
            "transcript_path":"\(codexRollout)","cwd":"/repo/workspaces/feature",\
            "hook_event_name":"Stop","model":"gpt-6-astra","permission_mode":"bypassPermissions","stop_hook_active":false,\
            "last_assistant_message":"done"}
            """)
    }

    @Test func reportsAClaudeCodeConversationAsResumableOnceItsTranscriptIsWritten() {
        #expect(
            AgentHookSessionKey.report(inHookPayload: claudeSessionStart(source: "startup"), transcriptExists: existing(claudeTranscript))
                == .resumable("ad826684-73f8-4748-88b4-a77c064bb1fb"))
    }

    /// A fresh Claude Code session hands out its id at `SessionStart`, before the first turn has written
    /// anything to resume, and `/clear` opens exactly such a session in place of the one the user left.
    /// Reporting the id would leave the agent's row addressing a conversation `claude --resume` cannot
    /// find; reporting nothing would leave it addressing the abandoned one. So it reports `pending`,
    /// which is what tells the row to drop what it holds.
    @Test func reportsAConversationWhoseTranscriptIsMissingAsPending() {
        #expect(AgentHookSessionKey.report(inHookPayload: claudeSessionStart(source: "startup"), transcriptExists: nothingExists) == .pending)
        #expect(AgentHookSessionKey.report(inHookPayload: claudeSessionStart(source: "clear"), transcriptExists: nothingExists) == .pending)
    }

    /// An agent relaunched by session restore fires `SessionStart` with `source` `resume` against the
    /// transcript it rejoined, so its id stays resumable even if the user quits before typing anything.
    @Test func reportsAResumedSessionStartAsResumable() {
        #expect(
            AgentHookSessionKey.report(inHookPayload: claudeSessionStart(source: "resume"), transcriptExists: existing(claudeTranscript))
                == .resumable("ad826684-73f8-4748-88b4-a77c064bb1fb"))
    }

    /// Codex's `Stop` payload carries a per-turn `turn_id` beside the conversation's `session_id`.
    /// Resuming addresses the conversation, so the turn id must never be mistaken for it. Codex reads the
    /// same transcript rule against the rollout file its own `resume` takes.
    @Test func reportsTheCodexConversationRatherThanItsTurnID() {
        #expect(
            AgentHookSessionKey.report(inHookPayload: codexStop, transcriptExists: existing(codexRollout))
                == .resumable("01a0938f-30fb-7ca1-83b0-915dcf9f9d3f"))
        #expect(AgentHookSessionKey.report(inHookPayload: codexStop, transcriptExists: nothingExists) == .pending)
    }

    /// Only a payload that names a transcript is checked against one. An agent reporting an id with no
    /// path attached is taken at its word.
    @Test func reportsAnIDResumableWhenThePayloadNamesNoTranscript() {
        let noPath = payload(#"{"session_id":"ad826684-73f8-4748-88b4-a77c064bb1fb","hook_event_name":"Stop"}"#)
        let blankPath = payload(#"{"session_id":"ad826684-73f8-4748-88b4-a77c064bb1fb","transcript_path":"   "}"#)
        let nonStringPath = payload(#"{"session_id":"ad826684-73f8-4748-88b4-a77c064bb1fb","transcript_path":7}"#)
        let expected = AgentHookSessionKeyReport.resumable("ad826684-73f8-4748-88b4-a77c064bb1fb")

        #expect(AgentHookSessionKey.report(inHookPayload: noPath, transcriptExists: nothingExists) == expected)
        #expect(AgentHookSessionKey.report(inHookPayload: blankPath, transcriptExists: nothingExists) == expected)
        #expect(AgentHookSessionKey.report(inHookPayload: nonStringPath, transcriptExists: nothingExists) == expected)
    }

    /// A signal raised outside a hook has no payload at all, and an agent could deliver one without an
    /// id or without JSON. None of those is an error: the lifecycle signal still has to be recorded, and
    /// none of them says anything about the conversation the row holds.
    @Test func reportsNothingWhenThePayloadNamesNoConversation() {
        let anythingExists: (String) -> Bool = { _ in true }

        #expect(AgentHookSessionKey.report(inHookPayload: nil, transcriptExists: anythingExists) == .unreported)
        #expect(AgentHookSessionKey.report(inHookPayload: Data(), transcriptExists: anythingExists) == .unreported)
        #expect(AgentHookSessionKey.report(inHookPayload: payload("not json at all"), transcriptExists: anythingExists) == .unreported)
        #expect(AgentHookSessionKey.report(inHookPayload: payload("[\"session_id\"]"), transcriptExists: anythingExists) == .unreported)
        #expect(AgentHookSessionKey.report(inHookPayload: payload(#"{"hook_event_name":"Stop"}"#), transcriptExists: anythingExists) == .unreported)
        #expect(AgentHookSessionKey.report(inHookPayload: payload(#"{"session_id":"   "}"#), transcriptExists: anythingExists) == .unreported)
        #expect(AgentHookSessionKey.report(inHookPayload: payload(#"{"session_id":42}"#), transcriptExists: anythingExists) == .unreported)
    }
}

import Foundation
import Testing

@testable import spacesterminalcore

/// The payload fixtures are the real hook payloads captured from the installed CLIs (claude 2.1.269,
/// codex-cli 0.153.4), with the ids and paths rewritten. Both agents deliver the same shape, so the
/// same key serves both; Codex's `session_id` is the id its own `resume` takes.
struct AgentHookSessionKeyTests {
    private func payload(_ json: String) -> Data { Data(json.utf8) }

    @Test func readsTheSessionIDFromAClaudeCodePayload() {
        let claudeSessionStart = payload(
            """
            {"session_id":"ad826684-73f8-4748-88b4-a77c064bb1fb","transcript_path":"/home/user/.claude/projects/a/b.jsonl",\
            "cwd":"/repo/workspaces/feature","hook_event_name":"SessionStart","source":"startup"}
            """)

        #expect(AgentHookSessionKey.sessionKey(inHookPayload: claudeSessionStart) == "ad826684-73f8-4748-88b4-a77c064bb1fb")
    }

    /// Codex's `Stop` payload carries a per-turn `turn_id` beside the conversation's `session_id`.
    /// Resuming addresses the conversation, so the turn id must never be mistaken for it.
    @Test func readsTheSessionIDFromACodexPayloadCarryingATurnID() {
        let codexStop = payload(
            """
            {"session_id":"01a0938f-30fb-7ca1-83b0-915dcf9f9d3f","turn_id":"01a0938f-311e-70b2-8037-7583c47698d3",\
            "transcript_path":"/home/user/.codex/sessions/2026/09/11/rollout.jsonl","cwd":"/repo/workspaces/feature",\
            "hook_event_name":"Stop","model":"gpt-6-astra","permission_mode":"bypassPermissions","stop_hook_active":false,\
            "last_assistant_message":"done"}
            """)

        #expect(AgentHookSessionKey.sessionKey(inHookPayload: codexStop) == "01a0938f-30fb-7ca1-83b0-915dcf9f9d3f")
    }

    /// A signal raised outside a hook has no payload at all, and an agent could deliver one without an
    /// id or without JSON. None of those is an error: the lifecycle signal still has to be recorded.
    @Test func reportsNoKeyWhenThePayloadCarriesNone() {
        #expect(AgentHookSessionKey.sessionKey(inHookPayload: nil) == nil)
        #expect(AgentHookSessionKey.sessionKey(inHookPayload: Data()) == nil)
        #expect(AgentHookSessionKey.sessionKey(inHookPayload: payload("not json at all")) == nil)
        #expect(AgentHookSessionKey.sessionKey(inHookPayload: payload("[\"session_id\"]")) == nil)
        #expect(AgentHookSessionKey.sessionKey(inHookPayload: payload(#"{"hook_event_name":"Stop"}"#)) == nil)
        #expect(AgentHookSessionKey.sessionKey(inHookPayload: payload(#"{"session_id":"   "}"#)) == nil)
        #expect(AgentHookSessionKey.sessionKey(inHookPayload: payload(#"{"session_id":42}"#)) == nil)
    }
}

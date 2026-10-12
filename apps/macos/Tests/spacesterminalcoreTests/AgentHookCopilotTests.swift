import Foundation
import Testing

@testable import spacesterminalcore

/// Copilot's hook contract (verified against copilot 1.0.91 to 1.0.95): camelCase JSON on stdin with a
/// `sessionId`, entries without matchers, and a `notification` hook that fires for every notification
/// type. The fixtures follow the payloads those releases deliver, with ids rewritten.
struct AgentHookCopilotTests {
    private func payload(_ json: String) -> Data { Data(json.utf8) }

    private func notification(_ type: String) -> Data {
        payload(
            """
            {"sessionId":"6f1c2f6e-0000-4000-8000-000000000001","timestamp":1790000000000,"cwd":"/repo",\
            "notification_type":"\(type)","title":"Permission needed","message":"Run ls?"}
            """)
    }

    // MARK: - Bindings

    @Test func bindingsMapCopilotEventsOntoLifecycleSignals() {
        let signals = Dictionary(uniqueKeysWithValues: CodingAgent.copilot.jsonEventBindings.map { ($0.eventName, $0.event) })
        #expect(
            signals == [
                "sessionStart": .initialize, "userPromptSubmitted": .working, "preToolUse": .working, "postToolUse": .working,
                "postToolUseFailure": .working, "notification": .blocked, "agentStop": .done, "sessionEnd": .exit,
            ])
    }

    /// `permissionRequest` runs before Copilot's permission service decides, so it fires for requests that
    /// are never shown and would raise a block that never ends.
    @Test func permissionRequestAndSubagentEventsAreNotBound() {
        let names = Set(CodingAgent.copilot.jsonEventBindings.map(\.eventName))
        for unbound in ["permissionRequest", "subagentStart", "subagentStop", "userPromptTransformed"] { #expect(!names.contains(unbound)) }
    }

    /// A non-zero exit from a `preToolUse` hook denies the tool, so the command must exit 0 whatever
    /// happens to the signal.
    @Test func copilotHookCommandsAlwaysExitZeroAndPrintNothing() {
        let command = AgentHookCommand.signalCommand(event: .working, spacesExecutablePath: "/usr/local/bin/spaces", agent: .copilot)
        #expect(command.contains(">/dev/null 2>&1 || true"))
        #expect(command.contains("agent signal working --agent copilot"))
        #expect(AgentHookCommand.isSpacesOwned(command))
    }

    @Test func otherAgentsCommandsNameNoAgent() {
        let command = AgentHookCommand.signalCommand(event: .done, spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(!command.contains("--agent"))
    }

    // MARK: - Conversation id

    @Test func theSessionIDIsReadFromCopilotsCamelCaseField() {
        let hook = payload(#"{"sessionId":"6f1c2f6e-0000-4000-8000-000000000001","timestamp":1,"cwd":"/repo","source":"resume"}"#)
        #expect(AgentHookSessionKey.report(inHookPayload: hook, agent: .copilot) == .resumable("6f1c2f6e-0000-4000-8000-000000000001"))
    }

    @Test func copilotPayloadsAreNotReadThroughClaudesSnakeCaseField() {
        let hook = payload(#"{"sessionId":"abc"}"#)
        #expect(AgentHookSessionKey.report(inHookPayload: hook) == .unreported)
        #expect(AgentHookSessionKey.report(inHookPayload: payload(#"{"session_id":"abc"}"#), agent: .copilot) == .unreported)
    }

    // MARK: - Notification filter

    @Test func onlyPermissionAndQuestionNotificationsAreBlocks() {
        #expect(AgentHookCopilotPayload.reportsBlock(inHookPayload: notification("permission_prompt")))
        #expect(AgentHookCopilotPayload.reportsBlock(inHookPayload: notification("elicitation_dialog")))
        for background in ["agent_idle", "agent_completed", "shell_completed", "shell_detached_completed", "something_new"] {
            #expect(!AgentHookCopilotPayload.reportsBlock(inHookPayload: notification(background)), "\(background)")
        }
    }

    @Test func aNotificationWithoutAReadableTypeIsNotABlock() {
        #expect(!AgentHookCopilotPayload.reportsBlock(inHookPayload: nil))
        #expect(!AgentHookCopilotPayload.reportsBlock(inHookPayload: Data()))
        #expect(!AgentHookCopilotPayload.reportsBlock(inHookPayload: payload("not json")))
        #expect(!AgentHookCopilotPayload.reportsBlock(inHookPayload: payload(#"{"sessionId":"abc"}"#)))
        #expect(!AgentHookCopilotPayload.reportsBlock(inHookPayload: payload(#"{"notification_type":7}"#)))
    }

    // MARK: - Phantom sessionEnd

    /// `copilot --resume <id>` creates and tears down a throwaway session while it starts, so a
    /// `sessionEnd` arrives for a session id the row never saw.
    @Test func aSessionEndCountsOnlyForTheConversationTheRowLearned() {
        let row = "6f1c2f6e-0000-4000-8000-000000000001"
        #expect(CodingAgent.copilot.exitSignalCounts(reportedKey: .resumable(row), rowSessionKey: row))
        #expect(!CodingAgent.copilot.exitSignalCounts(reportedKey: .resumable("phantom"), rowSessionKey: row))
        #expect(!CodingAgent.copilot.exitSignalCounts(reportedKey: .resumable("phantom"), rowSessionKey: nil))
        #expect(!CodingAgent.copilot.exitSignalCounts(reportedKey: .unreported, rowSessionKey: row))
    }

    @Test func otherAgentsExitsAlwaysCount() {
        for agent in [CodingAgent.claudeCode, .codex, .opencode] {
            #expect(agent.exitSignalCounts(reportedKey: .unreported, rowSessionKey: nil))
            #expect(agent.exitSignalCounts(reportedKey: .resumable("a"), rowSessionKey: "b"))
        }
    }

    @Test func theSignalPayloadCarriesTheSignalingAgent() throws {
        let sent = TerminalServiceProfileAgentSignalPayload(
            workspaceID: "w", terminalSessionID: "s", event: "exit", agentSessionKey: .resumable("abc"), agent: .copilot)
        let decoded = try JSONDecoder().decode(TerminalServiceProfileAgentSignalPayload.self, from: JSONEncoder().encode(sent))
        #expect(decoded.agent == .copilot)

        let unknown = #"{"workspaceID":"w","terminalSessionID":"s","event":"exit","agent":"futureagent"}"#
        #expect(try JSONDecoder().decode(TerminalServiceProfileAgentSignalPayload.self, from: Data(unknown.utf8)).agent == nil)
    }
}

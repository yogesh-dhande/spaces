import Foundation
import Testing

@testable import spacesterminalcore
@testable import spacesui

/// What a Coding Agents row offers and says in each state, and what the trust confirmation shows. A row
/// carries a button only when Spaces has a step to take, so the one button on the card is always the one
/// that fixes something.
@Suite @MainActor struct CodingAgentsViewTests {
    private func agent(_ kind: CodingAgent, available: Bool = true, installState: AgentHookInstallState) -> AgentHookStatus {
        AgentHookStatus(kind: kind, displayName: kind.displayName, available: available, installState: installState)
    }

    @Test func eachStateOffersTheOneStepSpacesCanTake() {
        #expect(CodingAgentsView.rowAction(for: agent(.claudeCode, installState: .notInstalled)) == .install)
        #expect(CodingAgentsView.rowAction(for: agent(.claudeCode, installState: .outdated)) == .update)
        #expect(CodingAgentsView.rowAction(for: agent(.codex, installState: .awaitingTrust)) == .trust)
    }

    /// Current hooks need nothing, switched-off hooks are the user's to turn back on in the agent, and an
    /// agent that is not detected has nothing to install into, so none of these rows shows a button.
    @Test func rowsWithNothingForSpacesToDoShowNoButton() {
        #expect(CodingAgentsView.rowAction(for: agent(.codex, installState: .current)) == nil)
        #expect(CodingAgentsView.rowAction(for: agent(.codex, installState: .disabledByAgent)) == nil)
        #expect(CodingAgentsView.rowAction(for: agent(.opencode, available: false, installState: .notInstalled)) == nil)
        #expect(CodingAgentsView.rowAction(for: nil) == nil)
    }

    @Test func actionTitlesNameTheStepAndItsProgress() {
        #expect(CodingAgentsView.actionTitle(.install, agentName: "Codex", inProgress: false) == "Install")
        #expect(CodingAgentsView.actionTitle(.update, agentName: "Codex", inProgress: false) == "Update")
        #expect(CodingAgentsView.actionTitle(.trust, agentName: "Codex", inProgress: false) == "Trust in Codex…")
        #expect(CodingAgentsView.actionTitle(.trust, agentName: "Codex", inProgress: true) == "Trusting…")
    }

    @Test func captionsSayWhoHasToActForTheCodexStates() {
        func caption(_ state: AgentHookInstallState) -> String {
            CodingAgentsView.captionText(status: agent(.codex, installState: state), failureMessage: nil, isLoading: false)
        }
        #expect(caption(.awaitingTrust) == "Detected, hooks installed but not yet trusted in Codex")
        #expect(caption(.disabledByAgent) == "Detected, hooks switched off in Codex. Turn them back on in Codex to restore agent status.")
        #expect(caption(.current) == "Detected, hooks installed")
    }

    /// Codex's own reason leads, without a doubled full stop, followed by both ways past it.
    @Test func aRefusedTrustReadsAsCodexsReasonAndTheWaysPastIt() {
        #expect(
            CodingAgentsView.trustFailureCaption(agentName: "Codex", reason: "codex app-server did not answer in time")
                == "Codex didn't record the trust: codex app-server did not answer in time. Update Codex, or open it in a terminal and trust the hooks there."
        )
        #expect(
            CodingAgentsView.trustFailureCaption(agentName: "Codex", reason: "Codex was not detected on this machine.")
                == "Codex didn't record the trust: Codex was not detected on this machine. Update Codex, or open it in a terminal and trust the hooks there."
        )
    }

    /// A refused trust explains the row only while the hooks still wait for it. The user trusts them in
    /// Codex instead, the watched config reloads as current, and the refusal is gone for good: switching
    /// the hooks off later reads as switched off, not as the old refusal.
    @Test func aRefusedTrustIsForgottenOnceAFreshStatusNoLongerAwaitsTrust() {
        let refusal = CodingAgentsView.trustFailureCaption(agentName: "Codex", reason: "codex app-server did not answer in time")
        var failures: [CodingAgent: CodingAgentsView.RowFailure] = [.codex: .init(action: .trust, message: refusal)]

        failures = CodingAgentsView.standingFailures(failures, after: [agent(.codex, installState: .awaitingTrust)])
        #expect(failures[.codex]?.message == refusal, "Still awaiting trust, so the refusal still explains the row")

        failures = CodingAgentsView.standingFailures(failures, after: [agent(.codex, installState: .current)])
        failures = CodingAgentsView.standingFailures(failures, after: [agent(.codex, installState: .disabledByAgent)])

        #expect(failures[.codex] == nil)
        #expect(
            CodingAgentsView.captionText(
                status: agent(.codex, installState: .disabledByAgent), failureMessage: failures[.codex]?.message, isLoading: false)
                == "Detected, hooks switched off in Codex. Turn them back on in Codex to restore agent status.")
    }

    /// A failed install or update stands for as long as the hooks are short of current, whatever state
    /// they pass through, and goes once they are current. A status that does not cover the agent, as
    /// when the device could not be reached, says nothing about it and leaves its failure alone.
    @Test func aFailedInstallStandsUntilTheHooksAreCurrent() {
        let failures: [CodingAgent: CodingAgentsView.RowFailure] = [
            .codex: .init(action: .update, message: "invalid Codex configuration"),
            .claudeCode: .init(action: .trust, message: "Claude Code does not ask to trust its hooks."),
        ]

        #expect(CodingAgentsView.standingFailures(failures, after: [agent(.codex, installState: .disabledByAgent)]) == failures)
        #expect(CodingAgentsView.standingFailures(failures, after: []) == failures)
        #expect(Set(CodingAgentsView.standingFailures(failures, after: [agent(.codex, installState: .current)]).keys) == [.claudeCode])
    }

    /// The warning line and Stop Server button belong to a Codex row only while its device reports the
    /// shared server running; the row's own action is unaffected.
    @Test func theStopServerLineAndButtonAppearOnlyWhileTheServerRuns() {
        func codex(running: Bool?, state: AgentHookInstallState = .current) -> AgentHookStatus {
            AgentHookStatus(kind: .codex, displayName: "Codex", available: true, installState: state, sharedServerRunning: running)
        }

        #expect(CodingAgentsView.showsSharedServerStop(status: codex(running: true)))
        #expect(!CodingAgentsView.showsSharedServerStop(status: codex(running: false)))
        #expect(!CodingAgentsView.showsSharedServerStop(status: codex(running: nil)))
        #expect(!CodingAgentsView.showsSharedServerStop(status: agent(.claudeCode, installState: .current)))
        #expect(!CodingAgentsView.showsSharedServerStop(status: nil))
        #expect(CodingAgentsView.sharedServerNote == "Background server running: Codex sessions on it can't report to Spaces.")
        #expect(CodingAgentsView.rowAction(for: codex(running: true, state: .awaitingTrust)) == .trust)
        #expect(CodingAgentsView.rowAction(for: codex(running: true)) == nil)
        #expect(CodingAgentsView.actionTitle(.stopServer, agentName: "Codex", inProgress: false) == "Stop Server")
        #expect(CodingAgentsView.captionText(status: codex(running: true), failureMessage: nil, isLoading: false) == "Detected, hooks installed")
    }

    /// A refused stop stands only while the server still reads as running, and leaves other failures alone.
    @Test func aRefusedStopStandsUntilTheServerNoLongerRuns() {
        func codex(running: Bool?) -> AgentHookStatus {
            AgentHookStatus(kind: .codex, displayName: "Codex", available: true, installState: .current, sharedServerRunning: running)
        }
        let refusal = CodingAgentsView.stopFailureCaption(agentName: "Codex", reason: "it did not exit")
        let failures: [CodingAgent: CodingAgentsView.RowFailure] = [.codex: .init(action: .stopServer, message: refusal)]

        #expect(CodingAgentsView.standingFailures(failures, after: [codex(running: true)]) == failures)
        #expect(CodingAgentsView.standingFailures(failures, after: []) == failures)
        #expect(CodingAgentsView.standingFailures(failures, after: [codex(running: false)]).isEmpty)
        #expect(CodingAgentsView.standingFailures(failures, after: [codex(running: nil)]).isEmpty)
        #expect(refusal == "Codex didn't stop its background server: it did not exit")
    }

    @Test func theStopConfirmationNamesTheDeviceAndTheKeptConversations() {
        let confirmation = CodexServerStopConfirmation(deviceName: "This Mac")

        #expect(confirmation.title == "Stop Codex's background server?")
        #expect(
            confirmation.message
                == "This ends the Codex sessions running on it on This Mac. Their conversations are kept, and you can resume them in a Spaces terminal."
        )
        #expect(confirmation.confirmButtonTitle == "Stop Server")
    }

    /// The trust is consent to exactly what the sheet lists, so it names the device, counts the commands,
    /// and carries each one as the device reported it.
    @Test func theConfirmationListsTheExactCommandsAndCountsThem() {
        let entries = [
            AgentHookEntry(eventName: "SessionStart", command: "'/Applications/Spaces.app/Contents/Resources/spaces' agent signal init"),
            AgentHookEntry(eventName: "Stop", command: "'/Applications/Spaces.app/Contents/Resources/spaces' agent signal done"),
        ]

        let confirmation = AgentHookTrustConfirmation(agentName: "Codex", deviceName: "This Mac", entries: entries)

        #expect(confirmation.title == "Trust Spaces' hooks in Codex on This Mac?")
        #expect(
            confirmation.message
                == "Codex will run these 2 commands at points in every Codex session, in every folder, so Spaces can show when an agent is working, blocked, or done."
        )
        #expect(confirmation.entries == entries)
        #expect(confirmation.confirmButtonTitle == "Trust 2 Hooks")
        #expect(AgentHookTrustConfirmation(agentName: "Codex", deviceName: "studio", entries: [entries[0]]).confirmButtonTitle == "Trust 1 Hook")
    }
}

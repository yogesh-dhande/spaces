import Foundation
import Testing

@testable import spacesclientcore
@testable import spacesterminalcore
@testable import spacesui

/// The launch gate for the coding-agents setup step. Spaces never writes an agent's config without
/// being asked, so this decides only whether to *offer* the install.
@Suite @MainActor struct SetupFlowControllerTests {
    private let currentVersion = 7

    private func agent(_ kind: CodingAgent, available: Bool, installState: AgentHookInstallState) -> AgentHookStatus {
        AgentHookStatus(kind: kind, displayName: kind.displayName, available: available, installState: installState)
    }

    private func requires(_ localAgents: [AgentHookStatus]?, dismissed: Int?) -> Bool {
        SetupFlowController.requiresCodingAgentsSetup(localAgents: localAgents, dismissedHookVersion: dismissed, currentHookVersion: currentVersion)
    }

    @Test func launchWaitExceedsTheAgentStatusRequestTimeout() {
        #expect(SetupFlowController.localAgentStatusTimeout > .seconds(SpacesDeviceClient.agentHooksStatusRequestTimeoutSeconds))
    }

    @Test func stepIsOfferedWhenADetectedAgentNeedsHooks() {
        #expect(requires([agent(.claudeCode, available: true, installState: .notInstalled)], dismissed: nil))
        #expect(requires([agent(.claudeCode, available: true, installState: .outdated)], dismissed: nil))
        // One agent needing attention is enough, even beside agents that are already current.
        #expect(
            requires(
                [agent(.claudeCode, available: true, installState: .current), agent(.codex, available: true, installState: .outdated)], dismissed: nil
            ))
    }

    @Test func stepIsSkippedWhenThereIsNothingToOffer() {
        #expect(!requires([], dismissed: nil))
        #expect(!requires([agent(.claudeCode, available: true, installState: .current)], dismissed: nil))
        // An agent whose CLI is not on this machine is not worth prompting about, whatever its config says.
        #expect(!requires([agent(.opencode, available: false, installState: .notInstalled)], dismissed: nil))
    }

    /// A dismissal is scoped to the hook version it was made against. Skipping is respected until a
    /// Spaces release actually changes the hooks it wants to write — then the user is asked once more.
    @Test func dismissalSuppressesOnlyTheHookVersionItWasMadeAgainst() {
        let needsHooks = [agent(.claudeCode, available: true, installState: .notInstalled)]

        #expect(!requires(needsHooks, dismissed: currentVersion))
        #expect(requires(needsHooks, dismissed: currentVersion - 1))
        #expect(requires(needsHooks, dismissed: nil))
    }

    /// An unreachable local daemon reports nothing, not "nothing to do". The step is omitted so launch
    /// never hangs — and the caller must not record a dismissal, or a daemon that happened to be down
    /// at first launch would suppress the step forever.
    @Test func anUnreachableDaemonOmitsTheStepWithoutDismissingIt() {
        #expect(!requires(nil, dismissed: nil))
        #expect(!requires(nil, dismissed: currentVersion - 1))
    }

    /// Only a dismissal skips the probe, because it is the only answer a probe could not overturn.
    @Test func theProbeIsSkippedOnceDismissedForThisHookVersion() {
        #expect(!SetupFlowController.shouldProbeLocalAgents(dismissedHookVersion: currentVersion, currentHookVersion: currentVersion))
        #expect(SetupFlowController.shouldProbeLocalAgents(dismissedHookVersion: currentVersion - 1, currentHookVersion: currentVersion))
        #expect(SetupFlowController.shouldProbeLocalAgents(dismissedHookVersion: nil, currentHookVersion: currentVersion))
    }

    /// "Nothing to install today" must never harden into "never ask again". A launch that finds no
    /// actionable agent leaves the gate open — it records no dismissal — so a user who installs a
    /// coding agent afterwards is still offered the step. Whether the machine had no agent at all or
    /// only agents already carrying current hooks, the next launch must still probe and still offer.
    @Test func aLaunchWithNothingToInstallStillOffersTheStepAfterAnAgentArrives() {
        for quietLaunch in [[], [agent(.claudeCode, available: true, installState: .current)]] {
            #expect(SetupFlowController.shouldProbeLocalAgents(dismissedHookVersion: nil, currentHookVersion: currentVersion))
            #expect(!requires(quietLaunch, dismissed: nil))
        }

        // The user has since installed Codex. Nothing was ever dismissed, so the step is offered.
        #expect(SetupFlowController.shouldProbeLocalAgents(dismissedHookVersion: nil, currentHookVersion: currentVersion))
        #expect(requires([agent(.codex, available: true, installState: .notInstalled)], dismissed: nil))
    }

    /// Skip means skip. A dismissal covers the hook version, not the set of agents installed when it
    /// was made, so an agent installed afterwards does not reopen the step — Settings still offers it.
    @Test func aDismissalIsNotReopenedByANewlyInstalledAgent() {
        #expect(!SetupFlowController.shouldProbeLocalAgents(dismissedHookVersion: currentVersion, currentHookVersion: currentVersion))
        #expect(!requires([agent(.codex, available: true, installState: .notInstalled)], dismissed: currentVersion))
    }

    // MARK: - Local summary

    @Test func summaryReportsWhenEveryDetectedAgentIsCurrent() {
        let summary = CodingAgentsView.localSummary(status: [
            agent(.claudeCode, available: true, installState: .current), agent(.codex, available: false, installState: .notInstalled),  // undetected agents do not count against "done"
        ])
        #expect(summary.allDetectedCurrent)
        #expect(!summary.hasActionableAgent)
    }

    @Test func summaryReportsAnAgentNeedingAttention() {
        let summary = CodingAgentsView.localSummary(status: [
            agent(.claudeCode, available: true, installState: .current), agent(.codex, available: true, installState: .outdated),
        ])
        #expect(!summary.allDetectedCurrent)
        #expect(summary.hasActionableAgent)
    }

    /// No detected agent is not "everything is current" — there is nothing that finished installing,
    /// so the step's button must not read "Done".
    @Test func summaryDoesNotClaimDoneWhenNoAgentIsDetected() {
        let summary = CodingAgentsView.localSummary(status: [agent(.opencode, available: false, installState: .notInstalled)])
        #expect(!summary.allDetectedCurrent)
        #expect(!summary.hasActionableAgent)
    }
}

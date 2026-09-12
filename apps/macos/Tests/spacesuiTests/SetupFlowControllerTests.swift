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
    /// Hooks an agent has not been told to trust, and hooks it was told to stop running, both report
    /// nothing, so the step stays on offer and the button does not read "Done" even though the remedy
    /// is the user's to apply inside the agent rather than an install Spaces can run.
    @Test func hooksTheAgentIsNotRunningStillCountAsUnfinished() {
        for state in [AgentHookInstallState.awaitingTrust, .disabledByAgent] {
            #expect(requires([agent(.codex, available: true, installState: state)], dismissed: nil))

            let summary = CodingAgentsView.localSummary(status: [
                agent(.claudeCode, available: true, installState: .current), agent(.codex, available: true, installState: state),
            ])
            #expect(!summary.allDetectedCurrent)
            #expect(summary.hasActionableAgent)
        }
    }

    /// The rows watch the agent's own config while any of them is in a state the agent's own writes
    /// reach. Watching too little leaves a row reporting a task the user has finished, or reporting
    /// green after they switched the hooks off; watching past that keeps reloading a device over files
    /// nothing is reading.
    @Test func rowsTheAgentItselfCanChangeAreWorthWatchingItsConfigFor() {
        // Approving the review, switching the hooks off, switching them back on, and turning
        // `features.hooks` off and on (which is what moves current entries to outdated) are all Codex
        // writes.
        for state in [AgentHookInstallState.current, .outdated, .awaitingTrust, .disabledByAgent] {
            #expect(CodingAgentsView.needsAgentConfigWatch(status: [agent(.codex, available: true, installState: state)]))
        }
        // Nothing but an install leaves this one, and the view reloads after its own install.
        #expect(!CodingAgentsView.needsAgentConfigWatch(status: [agent(.codex, available: true, installState: .notInstalled)]))
        // An agent that is not on this machine has no config worth watching, whatever its rows say.
        #expect(!CodingAgentsView.needsAgentConfigWatch(status: [agent(.codex, available: false, installState: .awaitingTrust)]))
        #expect(!CodingAgentsView.needsAgentConfigWatch(status: []))
        // The watch covers Codex's own config directory, so no other agent's row arms it.
        #expect(!CodingAgentsView.needsAgentConfigWatch(status: [agent(.claudeCode, available: true, installState: .current)]))
        // One Codex row is enough, beside agents whose rows it says nothing about.
        #expect(
            CodingAgentsView.needsAgentConfigWatch(status: [
                agent(.claudeCode, available: true, installState: .notInstalled), agent(.codex, available: true, installState: .awaitingTrust),
            ]))
    }

    /// `codex features disable hooks` leaves the entries in place and turns the row from current to
    /// outdated, and `codex features enable hooks` turns it back. Both are writes to `config.toml`, so
    /// the row has to stay watched while it sits at outdated: dropping the watch there is what would
    /// leave the row, and the setup step's Done state, stale until the section is reopened.
    @Test func aRowTurnedOutdatedByTheAgentKeepsWatchingItsWayBack() {
        let directory = "/Users/someone/.codex"
        let targets = AgentConfigWatchTargets(configDirectory: directory, linkedFiles: [], directories: [directory])
        func rowsWatchAndReload(at state: AgentHookInstallState) -> Bool {
            CodingAgentsView.needsAgentConfigWatch(status: [agent(.codex, available: true, installState: state)])
                && CodingAgentsView.isRelevantConfigChange(paths: ["\(directory)/config.toml"], mustRescan: false, targets: targets)
        }

        // Hooks are on and trusted, the feature is switched off, and it is switched on again. Every leg
        // of that round trip is reached by the watch the previous leg leaves armed.
        #expect(rowsWatchAndReload(at: .current))
        #expect(rowsWatchAndReload(at: .outdated))
        #expect(rowsWatchAndReload(at: .current))
    }

    /// The watch is on whole directories and FSEvents reports everything under them, so a running Codex
    /// writing transcripts, journals, and lock files must not cost a reload apiece.
    @Test func onlyTheTwoFilesTheRowsReadAreWorthAReload() {
        let directory = "/Users/someone/.codex"
        let linked = "/Users/someone/dotfiles/codex/spaces-config.toml"
        let plain = AgentConfigWatchTargets(configDirectory: directory, linkedFiles: [], directories: [directory])
        func isRelevant(_ paths: [String], mustRescan: Bool = false, targets: AgentConfigWatchTargets = plain) -> Bool {
            CodingAgentsView.isRelevantConfigChange(paths: paths, mustRescan: mustRescan, targets: targets)
        }

        #expect(isRelevant(["\(directory)/config.toml"]))
        #expect(isRelevant(["\(directory)/hooks.json"]))
        // Codex replaces config.toml by rename, and a rename can be reported at the directory itself.
        #expect(isRelevant([directory]))
        // The noise a session generates while the user is being asked to review the hooks.
        #expect(
            !isRelevant([
                "\(directory)/sessions/2026/09/11/rollout.jsonl", "\(directory)/history.db-wal", "\(directory)/history.db-shm",
                "\(directory)/log/codex-tui.log", "\(directory)/.config.toml.lock",
            ]))
        // A file of the right name somewhere else under the directory is a different file.
        #expect(!isRelevant(["\(directory)/projects/config.toml"]))
        // One relevant path in a noisy batch still counts.
        #expect(isRelevant(["\(directory)/history.db-wal", "\(directory)/config.toml"]))
        // The watcher reports mustRescan when its paths cannot be trusted, so the reload decides instead.
        #expect(isRelevant([], mustRescan: true))
        #expect(!isRelevant([]))

        // A link destination counts at its own path and at the directory holding it; the rest of the
        // dotfiles repository around it does not.
        let dotfiles = "/Users/someone/dotfiles/codex"
        let linkedTargets = AgentConfigWatchTargets(configDirectory: directory, linkedFiles: [linked], directories: [directory, dotfiles])
        #expect(isRelevant([linked], targets: linkedTargets))
        #expect(isRelevant([dotfiles], targets: linkedTargets))
        #expect(!isRelevant(["\(dotfiles)/.git/index"], targets: linkedTargets))
        #expect(!isRelevant([linked]))
    }

    /// A config file symlinked into a dotfiles repository is replaced where it really lives, and a
    /// `~/.codex` reached through a link is reported by FSEvents under its real name, so the watch has
    /// to resolve both the way the filesystem does.
    @Test func linkedConfigFilesAndLinkedConfigDirectoriesAreWatchedWhereTheyReallyLive() throws {
        let fileManager = FileManager.default
        /// What FSEvents reports: every symlink resolved, `/private` prefix kept.
        func real(_ url: URL) -> String {
            guard let resolved = realpath(url.path, nil) else { return url.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-watch-\(UUID().uuidString)")
        let codexDirectory = root.appendingPathComponent(".codex")
        let dotfiles = root.appendingPathComponent("dotfiles/codex")
        try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let linked = dotfiles.appendingPathComponent("spaces-config.toml")
        try Data("[hooks.state]\n".utf8).write(to: linked)
        try fileManager.createSymbolicLink(at: codexDirectory.appendingPathComponent("config.toml"), withDestinationURL: linked)
        // hooks.json stays where a machine with no dotfiles repository keeps it.
        try Data("{}".utf8).write(to: codexDirectory.appendingPathComponent("hooks.json"))

        let targets = CodingAgentsView.agentConfigWatchTargets(configDirectory: codexDirectory.path, fileManager: fileManager)
        #expect(targets.configDirectory == real(codexDirectory))
        #expect(targets.linkedFiles == [real(linked)])
        #expect(targets.directories == [real(codexDirectory), real(dotfiles)])
        // The write the watch exists to catch lands on the real file, not on the link.
        #expect(CodingAgentsView.isRelevantConfigChange(paths: [real(linked)], mustRescan: false, targets: targets))
        // The file that is not a link is still covered by the config directory.
        #expect(CodingAgentsView.isRelevantConfigChange(paths: ["\(real(codexDirectory))/hooks.json"], mustRescan: false, targets: targets))

        // The same config directory reached through a link of its own: the targets name the real one,
        // so the paths FSEvents reports still match.
        let alias = root.appendingPathComponent("codex-home-link")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: codexDirectory)
        let aliasTargets = CodingAgentsView.agentConfigWatchTargets(configDirectory: alias.path, fileManager: fileManager)
        #expect(aliasTargets.configDirectory == real(codexDirectory))
        #expect(aliasTargets.directories == [real(codexDirectory), real(dotfiles)])
        #expect(CodingAgentsView.isRelevantConfigChange(paths: ["\(real(codexDirectory))/hooks.json"], mustRescan: false, targets: aliasTargets))
        #expect(CodingAgentsView.isRelevantConfigChange(paths: [real(linked)], mustRescan: false, targets: aliasTargets))
    }

    @Test func summaryDoesNotClaimDoneWhenNoAgentIsDetected() {
        let summary = CodingAgentsView.localSummary(status: [agent(.opencode, available: false, installState: .notInstalled)])
        #expect(!summary.allDetectedCurrent)
        #expect(!summary.hasActionableAgent)
    }
}

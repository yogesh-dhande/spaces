import Testing
import spacesclientcore
import spacesterminalcore

@testable import spacesui

/// Coverage for the pure decisions behind `CompatibilityBlockView` and `AppKitController`'s
/// compatibility-block reconciliation: the nil-status conservative verdict->remedy fallback, the "no
/// block needed" case, the Check-for-Updates eligibility gate, the clear/rerender/leave-alone decision for
/// a visible block whose device's verdict/status just changed, and the remedy->copy/button table. None of
/// these touch AppKit, so they run without instantiating any view.
@Suite struct CompatibilityBlockContentTests {
    // MARK: - blockRemedy

    @Test func nilStatusFallsBackToVerdictAloneAndNeverOffersAnAction() {
        // No status means no installed-version fact to justify `.applyStagedUpdate`; the fallback can
        // only carry the verdict itself forward, never conjure a staged-update or "nothing to do" story.
        #expect(CompatibilityBlockView.blockRemedy(verdict: .clientTooOld, status: nil) == .updateClient(daemonVersion: nil))
        #expect(CompatibilityBlockView.blockRemedy(verdict: .daemonTooOld, status: nil) == .installUpdateOnDevice(daemonVersion: nil))
    }

    @Test func statusPresentDefersEntirelyToDaemonUpdateRemedy() {
        // Once a status is available, the raw verdict plays no further role — `DaemonUpdateRemedy` owns
        // the decision, including upgrading a `.daemonTooOld` verdict to `.applyStagedUpdate` when a
        // newer build is staged on disk, and carrying both concrete versions along with it.
        let staged = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version - 1)
        #expect(
            CompatibilityBlockView.blockRemedy(verdict: .daemonTooOld, status: staged)
                == .applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0"))

        let nothingStaged = makeStatus(version: "0.1.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version - 1)
        #expect(CompatibilityBlockView.blockRemedy(verdict: .daemonTooOld, status: nothingStaged) == .installUpdateOnDevice(daemonVersion: "0.1.0"))
    }

    @Test func compatibleUpToDateStatusNeedsNoBlock() {
        // A daemon that is wire-compatible and has nothing staged needs no block at all — the sidebar
        // caption and silent handoff handle the "update pending" case before it ever reaches this view.
        let compatible = makeStatus(version: "0.2.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version)
        #expect(CompatibilityBlockView.blockRemedy(verdict: .compatible, status: compatible) == nil)
    }

    // MARK: - Check-for-Updates eligibility

    @Test func checkForUpdatesActionIsOfferedOnlyForTheLocalDeviceWithAnUpdaterAvailable() {
        #expect(AppKitController.shouldOfferCheckForUpdatesAction(isLocalDevice: true, updaterAvailable: true))
        #expect(!AppKitController.shouldOfferCheckForUpdatesAction(isLocalDevice: true, updaterAvailable: false))
        #expect(!AppKitController.shouldOfferCheckForUpdatesAction(isLocalDevice: false, updaterAvailable: true))
        #expect(!AppKitController.shouldOfferCheckForUpdatesAction(isLocalDevice: false, updaterAvailable: false))
    }

    // MARK: - Update-over-SSH eligibility

    @Test func updateOverSSHIsOfferedOnlyForARemoteLinuxDeviceWhosePairingStoredSSHDetails() {
        #expect(AppKitController.shouldOfferUpdateOverSSH(isLocalDevice: false, isLinuxDaemon: true, hasSSHDetails: true))
        // A link-paired Linux device stores no SSH host, so there is nothing to run the installer against.
        #expect(!AppKitController.shouldOfferUpdateOverSSH(isLocalDevice: false, isLinuxDaemon: true, hasSSHDetails: false))
        // Macs are out regardless: this Mac updates through Sparkle, and a remote Mac's staged update
        // applies over the Device API — neither has a headless installer artifact to run over SSH.
        #expect(!AppKitController.shouldOfferUpdateOverSSH(isLocalDevice: false, isLinuxDaemon: false, hasSSHDetails: true))
        #expect(!AppKitController.shouldOfferUpdateOverSSH(isLocalDevice: true, isLinuxDaemon: false, hasSSHDetails: true))
        #expect(!AppKitController.shouldOfferUpdateOverSSH(isLocalDevice: true, isLinuxDaemon: true, hasSSHDetails: true))
    }

    // MARK: - reconcileCompatibilityBlockAction

    @Test func staleInstallGuidanceDropsTheBlockOnceADeviceReportsAStagedUpdateWhileStillIncompatible() {
        // The block told the user to "open Spaces on that Mac and install the update"; they did, and the
        // daemon is still on the old build (still incompatible) but now reports the update it just
        // staged. Spaces applies that itself, so the stale install-it-yourself guidance must go and
        // nothing must replace it.
        let staged = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version - 1)
        let action = AppKitController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: true, renderedRemedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), verdict: .daemonTooOld, status: staged,
            stagedApplyDidNotLand: false)
        #expect(action == .clear)
    }

    @Test func staleInstallGuidanceRerendersAsTryAgainOnceTheStagedApplyDidNotLand() {
        let staged = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version - 1)
        let action = AppKitController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: true, renderedRemedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), verdict: .daemonTooOld, status: staged,
            stagedApplyDidNotLand: true)
        #expect(action == .rerender(.applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0")))
    }

    @Test func aRetriedStagedApplyTakesItsOwnBlockBackDownEvenThoughTheRemedyIsUnchanged() {
        // Try Again clears the failure mark and re-requests the apply. The device's facts have not moved
        // yet, so the remedy is identical — the block must still come down, or the user would be left
        // reading a failure report about a request that is in flight again.
        let staged = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version - 1)
        let action = AppKitController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: true, renderedRemedy: .applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0"), verdict: .daemonTooOld,
            status: staged, stagedApplyDidNotLand: false)
        #expect(action == .clear)
    }

    @Test func stagedUpdateBlockClearsOnceTheDeviceReportsCompatible() {
        let compatible = makeStatus(version: "0.2.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version)
        let action = AppKitController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: true, renderedRemedy: .applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0"), verdict: .compatible,
            status: compatible, stagedApplyDidNotLand: true)
        #expect(action == .clear)
    }

    @Test func unchangedRemedyIsLeftAlone() {
        // Rebuilding the card on every sidebar tick would be wasteful and would fight anything transient
        // in the pane (e.g. focus), so an identical remedy must not trigger a re-render.
        let nothingStaged = makeStatus(version: "0.1.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version - 1)
        let action = AppKitController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: true, renderedRemedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), verdict: .daemonTooOld, status: nothingStaged,
            stagedApplyDidNotLand: false)
        #expect(action == .leaveAlone)
    }

    @Test func aDeviceThatDoesNotOwnTheVisibleBlockIsLeftAlone() {
        // A background refresh for some other device's section must never touch a block that belongs to
        // a different device, even when that other device's own facts would otherwise call for a
        // re-render.
        let staged = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version - 1)
        let action = AppKitController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: false, renderedRemedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), verdict: .daemonTooOld, status: staged,
            stagedApplyDidNotLand: true)
        #expect(action == .leaveAlone)
    }

    // MARK: - Whether a block is rendered at all

    @Test func aStagedUpdateIsShownOnlyOnABlockedDeviceWhoseApplyDidNotLand() {
        // The auto-applied case is the whole point: Spaces asks the device to apply the staged build the
        // moment it sees it, so until that request has demonstrably not landed there is nothing for the
        // user to do and no block to show.
        let staged = CompatibilityBlockView.BlockRemedy.applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0")
        #expect(!AppKitController.shouldRenderCompatibilityBlock(remedy: staged, verdictIsCompatible: false, stagedApplyDidNotLand: false))
        #expect(AppKitController.shouldRenderCompatibilityBlock(remedy: staged, verdictIsCompatible: false, stagedApplyDidNotLand: true))
        // And a full-pane block is reserved for a device the app cannot use: a compatible device whose
        // apply did not land keeps working, so it never gets one — the dialog is its whole surface.
        #expect(!AppKitController.shouldRenderCompatibilityBlock(remedy: staged, verdictIsCompatible: true, stagedApplyDidNotLand: true))
        #expect(!AppKitController.shouldRenderCompatibilityBlock(remedy: staged, verdictIsCompatible: true, stagedApplyDidNotLand: false))

        // Every other remedy only ever arises from an incompatible verdict and is the user's to resolve,
        // so it is always shown.
        for remedy in [CompatibilityBlockView.BlockRemedy.installUpdateOnDevice(daemonVersion: "0.1.0"), .updateClient(daemonVersion: "0.3.0")] {
            #expect(AppKitController.shouldRenderCompatibilityBlock(remedy: remedy, verdictIsCompatible: false, stagedApplyDidNotLand: false))
            #expect(AppKitController.shouldRenderCompatibilityBlock(remedy: remedy, verdictIsCompatible: false, stagedApplyDidNotLand: true))
        }
    }

    @Test func aCompatibleDeviceNeverGetsABlockForAStagedUpdateThatDidNotLand() {
        // Reached through the reconcile path too, not only through the render gate: a compatible device
        // that stages an update the app then fails to apply must not have a block pushed into its pane.
        let staged = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version)
        let action = AppKitController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: true, renderedRemedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), verdict: .compatible, status: staged,
            stagedApplyDidNotLand: true)
        #expect(action == .clear)
    }

    // MARK: - Remedy -> copy/button table

    @Test func applyStagedUpdateOffersTryAgainAndNamesBothVersionsOnEveryKindOfDevice() {
        // Rendered only after the apply did not land, so its copy reports what has not happened and hands
        // back a retry — on Linux alongside the command that applies the build on the device by hand.
        let macContent = CompatibilityBlockView.content(
            remedy: .applyStagedUpdate(daemonVersion: "0.8.7", installedVersion: "0.9.2"), deviceName: "lantern", isLocalDevice: false,
            isLinuxDaemon: false, clientVersion: "0.9.2", canCheckForUpdates: false, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(macContent.title == "lantern's daemon didn't pick up the update")
        #expect(macContent.actionButtonTitle == "Try Again")
        #expect(macContent.installerCommand == nil)
        #expect(macContent.detail.contains("Spaces 0.9.2 is installed on lantern"))
        #expect(macContent.detail.contains("still running 0.8.7"))
        #expect(macContent.detail.contains("Nothing running on lantern was interrupted."))
        #expect(macContent.detail.contains("Open Spaces on lantern"))
        #expect(!macContent.showsProgress)

        let linuxContent = CompatibilityBlockView.content(
            remedy: .applyStagedUpdate(daemonVersion: "0.8.7", installedVersion: "0.9.2"), deviceName: "build-box", isLocalDevice: false,
            isLinuxDaemon: true, clientVersion: "0.9.2", canCheckForUpdates: false, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(linuxContent.actionButtonTitle == "Try Again")
        #expect(linuxContent.installerCommand == CompatibilityBlockView.linuxApplyStagedUpdateCommand)

        let localContent = CompatibilityBlockView.content(
            remedy: .applyStagedUpdate(daemonVersion: "0.8.7", installedVersion: "0.9.2"), deviceName: "This Mac", isLocalDevice: true,
            isLinuxDaemon: false, clientVersion: "0.9.2", canCheckForUpdates: true, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(localContent.actionButtonTitle == "Try Again")
        #expect(localContent.installerCommand == nil)
        #expect(localContent.detail.contains("Restart Local Daemon"))
    }

    @Test func theStagedApplyReportNeverCallsTheApplyAFailure() {
        // A daemon that is slow to restart and one that refused look identical from here, so the copy
        // states what has not happened rather than delivering a verdict.
        let variants: [(isLocalDevice: Bool, isLinuxDaemon: Bool)] = [(false, false), (false, true), (true, false)]
        for variant in variants {
            let copy = CompatibilityBlockView.stagedApplyDidNotLandCopy(
                deviceName: "lantern", stagedVersion: "0.9.2", runningVersion: "0.8.7", isLocalDevice: variant.isLocalDevice,
                isLinuxDaemon: variant.isLinuxDaemon)
            let text = "\(copy.title) \(copy.body) \(copy.instruction)".lowercased()
            #expect(!text.contains("fail"))
            #expect(!text.contains("error"))
        }
    }

    @Test func onlyALinuxDeviceGetsACommandToRun() {
        #expect(
            CompatibilityBlockView.stagedApplyDidNotLandCopy(
                deviceName: "build-box", stagedVersion: "0.9.2", runningVersion: "0.8.7", isLocalDevice: false, isLinuxDaemon: true
            ).command == CompatibilityBlockView.linuxApplyStagedUpdateCommand)
        #expect(
            CompatibilityBlockView.stagedApplyDidNotLandCopy(
                deviceName: "lantern", stagedVersion: "0.9.2", runningVersion: "0.8.7", isLocalDevice: false, isLinuxDaemon: false
            ).command == nil)
        #expect(
            CompatibilityBlockView.stagedApplyDidNotLandCopy(
                deviceName: "This Mac", stagedVersion: "0.9.2", runningVersion: "0.8.7", isLocalDevice: true, isLinuxDaemon: false
            ).command == nil)
    }

    @Test func installUpdateOnDeviceOnLinuxShowsTheInstallerCommandAndNoButton() {
        let content = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "build-box", isLocalDevice: false, isLinuxDaemon: true,
            clientVersion: "0.2.0", canCheckForUpdates: false, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(content.actionButtonTitle == nil)
        #expect(content.installerCommand != nil)
        #expect(content.installerCommand == SpacesLinuxInstaller.installCommand(version: "0.2.0"))
    }

    @Test func installUpdateOnDeviceOnLinuxOffersUpdateOverSSHWithoutDroppingTheCopyableCommand() {
        // The button is the convenience; the one-liner remains the guaranteed path, so a failed or
        // refused SSH run still leaves the user able to run the installer on the device by hand.
        let content = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "build-box", isLocalDevice: false, isLinuxDaemon: true,
            clientVersion: "0.2.0", canCheckForUpdates: false, canUpdateOverSSH: true, isUpdatingOverSSH: false)
        #expect(content.actionButtonTitle == "Update over SSH")
        #expect(content.installerCommand == SpacesLinuxInstaller.installCommand(version: "0.2.0"))
        #expect(!content.showsProgress)
        #expect(content.detail.contains("over SSH"))
        #expect(content.detail.contains("preserved"))
    }

    @Test func aRunningUpdateOverSSHShowsProgressInsteadOfTheButton() {
        // Re-offering the button while the installer is running would invite a second overlapping run.
        let content = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "build-box", isLocalDevice: false, isLinuxDaemon: true,
            clientVersion: "0.2.0", canCheckForUpdates: false, canUpdateOverSSH: true, isUpdatingOverSSH: true)
        #expect(content.actionButtonTitle == nil)
        #expect(content.showsProgress)
        #expect(content.detail.contains("Updating Spaces on build-box"))
        #expect(content.installerCommand == SpacesLinuxInstaller.installCommand(version: "0.2.0"))
    }

    @Test func onlyARunningUpdateOverSSHShowsProgress() {
        let quiescentVariants: [(label: String, isLocalDevice: Bool, isLinuxDaemon: Bool, canUpdateOverSSH: Bool)] = [
            ("Linux without SSH details", false, true, false), ("Linux with SSH details", false, true, true), ("remote Mac", false, false, false),
            ("local Mac", true, false, false),
        ]
        for variant in quiescentVariants {
            let content = CompatibilityBlockView.content(
                remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "build-box", isLocalDevice: variant.isLocalDevice,
                isLinuxDaemon: variant.isLinuxDaemon, clientVersion: "0.2.0", canCheckForUpdates: true, canUpdateOverSSH: variant.canUpdateOverSSH,
                isUpdatingOverSSH: false)
            #expect(!content.showsProgress, "\(variant.label) must not show a spinner with nothing running")
        }
    }

    @Test func installUpdateOnDeviceOnARemoteMacShowsNeitherInstallerNorButton() {
        let content = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "Yogesh's MacBook Pro", isLocalDevice: false, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: false, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(content.actionButtonTitle == nil)
        #expect(content.installerCommand == nil)
        // Even if this Mac happens to have an updater (irrelevant — it isn't the device that's behind),
        // the eligibility gate is keyed on `isLocalDevice`, so `canCheckForUpdates` alone must not offer
        // the button for a device that isn't local.
        let contentWithUpdaterAvailable = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "Yogesh's MacBook Pro", isLocalDevice: false, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: true, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(contentWithUpdaterAvailable.actionButtonTitle == nil)
    }

    @Test func installUpdateOnDeviceOnTheLocalMacOffersCheckForUpdatesOnlyWhenAvailable() {
        let withUpdater = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "This Mac", isLocalDevice: true, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: true, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(withUpdater.actionButtonTitle == "Check for Updates…")
        #expect(withUpdater.installerCommand == nil)

        let withoutUpdater = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "This Mac", isLocalDevice: true, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: false, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(withoutUpdater.actionButtonTitle == nil)
        #expect(withoutUpdater.installerCommand == nil)
    }

    @Test func updateClientNeverOffersAButtonOrInstallerRegardlessOfPlatform() {
        let content = CompatibilityBlockView.content(
            remedy: .updateClient(daemonVersion: "0.3.0"), deviceName: "Yogesh's Mac", isLocalDevice: false, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: true, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(content.actionButtonTitle == nil)
        #expect(content.installerCommand == nil)
    }

    // The block explains a wire-protocol mismatch, so its copy must blame the connection protocol and
    // never a comparison against this app's own build. The two are on unrelated release trains, which
    // makes such a comparison meaningless in general — and plainly absurd in the common case this test
    // pins, where both sides report the same marketing version (every development build) and the old
    // copy read "running Spaces 0.1.0, older than this app needs (Spaces 0.1.0)".
    @Test func installGuidanceBlamesTheConnectionProtocolNeverThisAppsVersion() {
        let variants: [(label: String, isLocalDevice: Bool, isLinuxDaemon: Bool)] = [
            ("Linux daemon", false, true), ("local Mac", true, false), ("remote Mac", false, false),
        ]
        for variant in variants {
            let content = CompatibilityBlockView.content(
                remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "build-box", isLocalDevice: variant.isLocalDevice,
                isLinuxDaemon: variant.isLinuxDaemon, clientVersion: "0.1.0", canCheckForUpdates: false, canUpdateOverSSH: false,
                isUpdatingOverSSH: false)
            #expect(content.detail.contains("older connection protocol than this app"), "\(variant.label) must name the protocol as the reason")
            #expect(!content.detail.contains("than this app needs"), "\(variant.label) must not state a version requirement")
            // The daemon's build appears once, as identifying context. A second occurrence would mean
            // this app's version is being named as the bar the daemon fails to clear.
            #expect(
                content.detail.components(separatedBy: "0.1.0").count - 1 == 1,
                "\(variant.label) must name a version only as context, never as a comparison")
        }
    }

    @Test func versionsAppearInCopyOnlyWhenNonEmptyAndNeverAsTheLiteralWordNil() {
        let withVersions = CompatibilityBlockView.content(
            remedy: .applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0"), deviceName: "Yogesh's Mac", isLocalDevice: false,
            isLinuxDaemon: false, clientVersion: "0.2.0", canCheckForUpdates: false, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(withVersions.detail.contains("0.1.0"))
        #expect(withVersions.detail.contains("0.2.0"))
        #expect(!withVersions.detail.lowercased().contains("nil"))

        let withoutDaemonVersion = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: nil), deviceName: "build-box", isLocalDevice: false, isLinuxDaemon: true,
            clientVersion: "0.2.0", canCheckForUpdates: false, canUpdateOverSSH: false, isUpdatingOverSSH: false)
        #expect(!withoutDaemonVersion.detail.lowercased().contains("nil"))
    }

    private func makeStatus(version: String, installedVersion: String?, protocolVersion: Int) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: version, installedVersion: installedVersion, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: protocolVersion
        )
    }
}

import Testing
import spacesclientcore
import spacesterminalcore

@testable import spacesui

/// Coverage for the pure decisions behind `CompatibilityBlockView`: the nil-status conservative
/// verdict->remedy fallback, the "no block needed" case, the Check-for-Updates eligibility gate, and the
/// remedy->copy/button table. None of these touch AppKit, so they run without instantiating any view.
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

    // MARK: - Remedy -> copy/button table

    @Test func applyStagedUpdateOffersTheUpdateDaemonButtonOnBothMacOSAndLinux() {
        let macContent = CompatibilityBlockView.content(
            remedy: .applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0"), deviceName: "Yogesh's Mac", isLocalDevice: false,
            isLinuxDaemon: false, clientVersion: "0.2.0", canCheckForUpdates: false)
        #expect(macContent.actionButtonTitle == "Update Daemon")
        #expect(macContent.installerCommand == nil)

        let linuxContent = CompatibilityBlockView.content(
            remedy: .applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0"), deviceName: "build-box", isLocalDevice: false,
            isLinuxDaemon: true, clientVersion: "0.2.0", canCheckForUpdates: false)
        #expect(linuxContent.actionButtonTitle == "Update Daemon")
        #expect(linuxContent.installerCommand == nil)
    }

    @Test func installUpdateOnDeviceOnLinuxShowsTheInstallerCommandAndNoButton() {
        let content = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "build-box", isLocalDevice: false, isLinuxDaemon: true,
            clientVersion: "0.2.0", canCheckForUpdates: false)
        #expect(content.actionButtonTitle == nil)
        #expect(content.installerCommand != nil)
        #expect(content.installerCommand == SpacesLinuxInstaller.installCommand(version: "0.2.0"))
    }

    @Test func installUpdateOnDeviceOnARemoteMacShowsNeitherInstallerNorButton() {
        let content = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "Yogesh's MacBook Pro", isLocalDevice: false, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: false)
        #expect(content.actionButtonTitle == nil)
        #expect(content.installerCommand == nil)
        // Even if this Mac happens to have an updater (irrelevant — it isn't the device that's behind),
        // the eligibility gate is keyed on `isLocalDevice`, so `canCheckForUpdates` alone must not offer
        // the button for a device that isn't local.
        let contentWithUpdaterAvailable = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "Yogesh's MacBook Pro", isLocalDevice: false, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: true)
        #expect(contentWithUpdaterAvailable.actionButtonTitle == nil)
    }

    @Test func installUpdateOnDeviceOnTheLocalMacOffersCheckForUpdatesOnlyWhenAvailable() {
        let withUpdater = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "This Mac", isLocalDevice: true, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: true)
        #expect(withUpdater.actionButtonTitle == "Check for Updates…")
        #expect(withUpdater.installerCommand == nil)

        let withoutUpdater = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: "0.1.0"), deviceName: "This Mac", isLocalDevice: true, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: false)
        #expect(withoutUpdater.actionButtonTitle == nil)
        #expect(withoutUpdater.installerCommand == nil)
    }

    @Test func updateClientNeverOffersAButtonOrInstallerRegardlessOfPlatform() {
        let content = CompatibilityBlockView.content(
            remedy: .updateClient(daemonVersion: "0.3.0"), deviceName: "Yogesh's Mac", isLocalDevice: false, isLinuxDaemon: false,
            clientVersion: "0.2.0", canCheckForUpdates: true)
        #expect(content.actionButtonTitle == nil)
        #expect(content.installerCommand == nil)
    }

    @Test func versionsAppearInCopyOnlyWhenNonEmptyAndNeverAsTheLiteralWordNil() {
        let withVersions = CompatibilityBlockView.content(
            remedy: .applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0"), deviceName: "Yogesh's Mac", isLocalDevice: false,
            isLinuxDaemon: false, clientVersion: "0.2.0", canCheckForUpdates: false)
        #expect(withVersions.detail.contains("0.1.0"))
        #expect(withVersions.detail.contains("0.2.0"))
        #expect(!withVersions.detail.lowercased().contains("nil"))

        let withoutDaemonVersion = CompatibilityBlockView.content(
            remedy: .installUpdateOnDevice(daemonVersion: nil), deviceName: "build-box", isLocalDevice: false, isLinuxDaemon: true,
            clientVersion: "0.2.0", canCheckForUpdates: false)
        #expect(!withoutDaemonVersion.detail.lowercased().contains("nil"))
    }

    private func makeStatus(version: String, installedVersion: String?, protocolVersion: Int) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: version, installedVersion: installedVersion, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: protocolVersion
        )
    }
}

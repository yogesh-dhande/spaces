import Foundation
import Testing
import spacesterminalcore

@testable import spacesui

/// What the Mac shows for a device that updates itself: the block's copy for each state, which remedy
/// the block takes, when the sidebar header offers Update, and how an attempt the Mac started plays out
/// across a device restarting out of reach.
@Suite struct DaemonSelfUpdateBlockTests {
    private func content(_ presentation: DaemonSelfUpdatePresentation, channel: DaemonUpdateChannel = .stable, isBlocked: Bool = false)
        -> CompatibilityBlockView.Content
    {
        CompatibilityBlockView.content(
            remedy: .selfUpdate(presentation, channel: channel, isBlocked: isBlocked), deviceName: "build-box", isLocalDevice: false,
            isLinuxDaemon: true, clientVersion: "0.24.0", canCheckForUpdates: false, canUpdateOverSSH: false, isUpdatingOverSSH: false)
    }

    private func status(
        version: String = "0.23.0", protocolVersion: Int = SpacesWireProtocol.version, selfUpdate: DaemonSelfUpdateStatus? = nil
    ) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: version, installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: protocolVersion,
            operatingSystem: "Linux", selfUpdate: selfUpdate)
    }

    // MARK: - Block content

    @Test func availableOffersTheUpdateInTheAccentWithTheChannelAndVersions() {
        let block = content(.available(from: "0.23.0", to: "0.24.0"), channel: .prerelease)
        #expect(block.eyebrow == DaemonSelfUpdateCopy.availableTitle)
        #expect(block.eyebrowTone == .accent)
        #expect(block.versionPair == CompatibilityBlockView.VersionPair(from: "0.23.0", to: "0.24.0"))
        #expect(block.whoLine == "build-box · pre-release updates")
        #expect(block.body == "build-box downloads and installs Spaces 0.24.0 itself. Nothing it's running stops.")
        #expect(block.actionButtonTitle == "Update build-box")
        #expect(block.progressBar == nil)
        #expect(block.installerCommand == nil)
    }

    @Test func aBlockedDaemonKeepsTheCantConnectEyebrowAndOffersTheSameUpdate() {
        let block = content(.available(from: "0.1.0", to: "0.24.0"), isBlocked: true)
        #expect(block.eyebrow == "CAN'T CONNECT — DAEMON NEEDS AN UPDATE")
        #expect(block.eyebrowTone == .warning)
        #expect(block.versionPair == CompatibilityBlockView.VersionPair(from: "0.1.0", to: "0.24.0"))
        #expect(block.actionButtonTitle == "Update build-box")
        // Never the SSH or run-this-yourself guidance.
        #expect(block.installerCommand == nil)
    }

    @Test func downloadingShowsMeasuredProgressWhenTheSizeIsKnown() {
        let block = content(.downloading(from: "0.23.0", to: "0.24.0", received: 12_400_000, total: 38_000_000))
        #expect(block.eyebrow == "Updating build-box")
        #expect(block.whoLine == "Downloading 12.4 of 38.0 MB")
        #expect(block.footnote == DaemonSelfUpdateCopy.downloadingFootnote)
        #expect(block.body.isEmpty)
        #expect(block.actionButtonTitle == nil)
        guard case .determinate(let fraction)? = block.progressBar else {
            Issue.record("expected a determinate bar")
            return
        }
        #expect(abs(fraction - 12.4 / 38.0) < 0.0001)
    }

    @Test func downloadingWithoutATotalShowsAnIndeterminateBar() {
        let block = content(.downloading(from: "0.23.0", to: "0.24.0", received: 12_400_000, total: nil))
        #expect(block.whoLine == "Downloading 12.4 MB")
        #expect(block.progressBar == .indeterminate)
    }

    @Test func installingAndRestartingShowTheirSentenceOverAnIndeterminateBar() {
        let installing = content(.installing(from: "0.23.0", to: "0.24.0"))
        #expect(installing.eyebrow == "Updating build-box")
        #expect(installing.body == "Checking the signature and installing 0.24.0.")
        #expect(installing.progressBar == .indeterminate)
        #expect(installing.actionButtonTitle == nil)

        let restarting = content(.restarting(from: "0.23.0", to: "0.24.0"))
        #expect(restarting.eyebrow == "Updating build-box")
        #expect(restarting.body == "Restarting on 0.24.0. Its terminals keep running.")
        #expect(restarting.progressBar == .indeterminate)
        #expect(restarting.actionButtonTitle == nil)
    }

    @Test func stillRestartingAndFailedAreOrangeAndOfferTryAgain() {
        let slow = content(.stillRestarting(from: "0.23.0", to: "0.24.0"))
        #expect(slow.eyebrow == "Still restarting")
        #expect(slow.eyebrowTone == .warning)
        #expect(slow.body == "build-box hasn't come back on 0.24.0 yet. Its terminals keep running.")
        #expect(slow.actionButtonTitle == "Try Again")
        #expect(slow.progressBar == nil)

        let failed = content(.failed(from: "0.23.0", to: "0.24.0", reason: "The download was cut off."))
        #expect(failed.eyebrow == "Update didn't finish")
        #expect(failed.eyebrowTone == .warning)
        #expect(failed.body == "The download was cut off.")
        #expect(failed.actionButtonTitle == "Try Again")
    }

    // MARK: - Remedy choice

    private let available = DaemonSelfUpdatePresentation.available(from: "0.23.0", to: "0.24.0")

    @Test func aBlockedSelfUpdatingDaemonTakesTheSelfUpdateRemedyInsteadOfInstallGuidance() {
        let blocked = status(version: "0.1.0", protocolVersion: SpacesWireProtocol.version - 1, selfUpdate: DaemonSelfUpdateStatus(channel: .stable))
        let facts = CompatibilityBlockView.SelfUpdateFacts(presentation: .available(from: "0.1.0", to: "0.24.0"), channel: .stable)
        #expect(
            CompatibilityBlockView.blockRemedy(verdict: .daemonTooOld, status: blocked, selfUpdate: facts)
                == .selfUpdate(.available(from: "0.1.0", to: "0.24.0"), channel: .stable, isBlocked: true))
    }

    @Test func aBlockedDaemonWithoutASelfUpdateKeepsTheInstallGuidance() {
        let old = status(version: "0.1.0", protocolVersion: SpacesWireProtocol.version - 1)
        #expect(
            CompatibilityBlockView.blockRemedy(verdict: .daemonTooOld, status: old, selfUpdate: nil) == .installUpdateOnDevice(daemonVersion: "0.1.0"))
        let idle = CompatibilityBlockView.SelfUpdateFacts(presentation: .none, channel: .stable)
        #expect(
            CompatibilityBlockView.blockRemedy(verdict: .daemonTooOld, status: old, selfUpdate: idle) == .installUpdateOnDevice(daemonVersion: "0.1.0"))
    }

    @Test func aCompatibleDeviceGetsTheBlockOnlyWhileItsSelfUpdateHasSomethingToShow() {
        let current = status(selfUpdate: DaemonSelfUpdateStatus(channel: .stable, availableVersion: "0.24.0"))
        let facts = CompatibilityBlockView.SelfUpdateFacts(presentation: available, channel: .stable)
        #expect(
            CompatibilityBlockView.blockRemedy(verdict: .compatible, status: current, selfUpdate: facts)
                == .selfUpdate(available, channel: .stable, isBlocked: false))
        #expect(CompatibilityBlockView.blockRemedy(verdict: .compatible, status: current, selfUpdate: nil) == nil)
    }

    @Test func aDeviceAwayMidRestartKeepsTheBlockWithoutAVerdict() {
        let facts = CompatibilityBlockView.SelfUpdateFacts(presentation: .restarting(from: "0.23.0", to: "0.24.0"), channel: .stable)
        #expect(
            CompatibilityBlockView.blockRemedy(verdict: nil, status: nil, selfUpdate: facts)
                == .selfUpdate(.restarting(from: "0.23.0", to: "0.24.0"), channel: .stable, isBlocked: false))
    }

    @Test func aSelfUpdateNeverHidesAnAppThatMustUpdateOrABuildAlreadyStaged() {
        let facts = CompatibilityBlockView.SelfUpdateFacts(presentation: available, channel: .stable)
        let newer = status(version: "0.30.0", protocolVersion: SpacesWireProtocol.version + 1, selfUpdate: DaemonSelfUpdateStatus(channel: .stable))
        #expect(
            CompatibilityBlockView.blockRemedy(verdict: .clientTooOld, status: newer, selfUpdate: facts) == .updateClient(daemonVersion: "0.30.0"))

        let staged = TerminalServiceDaemonStatus(
            version: "0.1.0", installedVersion: "0.2.0", certificateFingerprint: nil, activeSessionCount: 0,
            protocolVersion: SpacesWireProtocol.version - 1)
        #expect(
            CompatibilityBlockView.blockRemedy(verdict: .daemonTooOld, status: staged, selfUpdate: facts)
                == .applyStagedUpdate(daemonVersion: "0.1.0", installedVersion: "0.2.0"))
    }

    // MARK: - Reconciling a visible block

    @Test func theSelfUpdateBlockRerendersAsTheUpdateAdvancesAndClearsWhenItEnds() {
        let rendered = CompatibilityBlockView.BlockRemedy.selfUpdate(.installing(from: "0.23.0", to: "0.24.0"), channel: .stable, isBlocked: false)
        let restarting = CompatibilityBlockView.SelfUpdateFacts(presentation: .restarting(from: "0.23.0", to: "0.24.0"), channel: .stable)
        // The device is away, so there is no verdict and no status; the block must still follow it.
        let advanced = DaemonUpdateController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: true, renderedRemedy: rendered, verdict: nil, status: nil, stagedApplyDidNotLand: false, selfUpdate: restarting)
        #expect(advanced == .rerender(.selfUpdate(.restarting(from: "0.23.0", to: "0.24.0"), channel: .stable, isBlocked: false)))

        let unchanged = DaemonUpdateController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: true, renderedRemedy: rendered, verdict: .compatible, status: status(),
            stagedApplyDidNotLand: false,
            selfUpdate: CompatibilityBlockView.SelfUpdateFacts(presentation: .installing(from: "0.23.0", to: "0.24.0"), channel: .stable))
        #expect(unchanged == .leaveAlone)

        // The device came back on the new build: no presentation, no block.
        let finished = DaemonUpdateController.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: true, renderedRemedy: rendered, verdict: .compatible, status: status(version: "0.24.0"),
            stagedApplyDidNotLand: false, selfUpdate: nil)
        #expect(finished == .clear)
    }

    // MARK: - Sidebar header

    @Test func theHeaderOffersUpdateOnlyForAUsableDeviceWithSomethingToShow() {
        typealias Status = SidebarDeviceSectionStatus
        #expect(Status.offersSelfUpdate(compatibility: .compatible, presentation: available))
        #expect(Status.offersSelfUpdate(compatibility: .compatible, presentation: .downloading(from: "0.23.0", to: "0.24.0", received: 1, total: 2)))
        #expect(Status.offersSelfUpdate(compatibility: .compatible, presentation: .failed(from: "0.23.0", to: "0.24.0", reason: "x")))
        #expect(!Status.offersSelfUpdate(compatibility: .compatible, presentation: .none))
        // An incompatible device has its Resolve button, and an away one has no verdict.
        #expect(!Status.offersSelfUpdate(compatibility: .daemonTooOld, presentation: available))
        #expect(!Status.offersSelfUpdate(compatibility: nil, presentation: available))
    }

    // MARK: - Attempts

    private func updatableStatus(version: String = "0.23.0", progress: DaemonSelfUpdateProgress? = nil) -> TerminalServiceDaemonStatus {
        status(version: version, selfUpdate: DaemonSelfUpdateStatus(channel: .stable, availableVersion: "0.24.0", progress: progress))
    }

    @Test func aDeviceThatStaysAwayMovesFromRestartingToStillRestartingAfterTwoMinutes() {
        var tracker = DaemonSelfUpdateAttemptTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        tracker.begin(deviceID: "box", targetVersion: "0.24.0", status: updatableStatus())

        // The sidebar drops the status when the device stops answering; the Mac's own copy carries on.
        let away = tracker.presentation(deviceID: "box", liveStatus: nil, isReachable: false, now: start)
        #expect(away == .restarting(from: "0.23.0", to: "0.24.0"))
        #expect(tracker.stillRestartingDeadline(deviceID: "box") == start.addingTimeInterval(DaemonSelfUpdatePresentation.stillRestartingAfter))

        // Time passing does not move the clock that started at the first Restarting.
        let later = tracker.presentation(deviceID: "box", liveStatus: nil, isReachable: false, now: start.addingTimeInterval(121))
        #expect(later == .stillRestarting(from: "0.23.0", to: "0.24.0"))
    }

    @Test func anAttemptEndsWhenTheDeviceReportsTheNewVersion() {
        var tracker = DaemonSelfUpdateAttemptTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        tracker.begin(deviceID: "box", targetVersion: "0.24.0", status: updatableStatus())
        #expect(tracker.hasAttempt(deviceID: "box"))

        let done = tracker.presentation(deviceID: "box", liveStatus: updatableStatus(version: "0.24.0"), isReachable: true, now: now)
        #expect(done == .none)
        #expect(!tracker.hasAttempt(deviceID: "box"))
    }

    @Test func aRetryThatInstallsADifferentVersionStillEndsTheAttempt() {
        var tracker = DaemonSelfUpdateAttemptTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        // The first try aimed at a pre-release; the device then moved to stable and the retry runs 0.24.0.
        tracker.begin(deviceID: "box", targetVersion: "0.25.0", status: updatableStatus())
        let retrying = updatableStatus(progress: DaemonSelfUpdateProgress(targetVersion: "0.24.0", step: .downloading, receivedBytes: 1, totalBytes: 2))
        #expect(
            tracker.presentation(deviceID: "box", liveStatus: retrying, isReachable: true, now: now)
                == .downloading(from: "0.23.0", to: "0.24.0", received: 1, total: 2))

        let back = tracker.presentation(deviceID: "box", liveStatus: updatableStatus(version: "0.24.0"), isReachable: true, now: now)
        #expect(back == .none)
        #expect(!tracker.hasAttempt(deviceID: "box"))
    }

    @Test func anUpdateStartedElsewhereIsFollowedThroughTheOutageFromItsFirstStep() {
        var tracker = DaemonSelfUpdateAttemptTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        // Another client started the run; this Mac sees it installing and then never sees Restarting.
        let installing = updatableStatus(progress: DaemonSelfUpdateProgress(targetVersion: "0.24.0", step: .installing))
        #expect(tracker.presentation(deviceID: "box", liveStatus: installing, isReachable: true, now: start) == .installing(from: "0.23.0", to: "0.24.0"))
        #expect(tracker.hasAttempt(deviceID: "box"))

        let away = tracker.presentation(deviceID: "box", liveStatus: nil, isReachable: false, now: start.addingTimeInterval(1))
        #expect(away == .restarting(from: "0.23.0", to: "0.24.0"))
        let later = tracker.presentation(deviceID: "box", liveStatus: nil, isReachable: false, now: start.addingTimeInterval(122))
        #expect(later == .stillRestarting(from: "0.23.0", to: "0.24.0"))
    }

    @Test func tryAgainOnADeviceThatIsStillAwayRestartsTheWait() {
        var tracker = DaemonSelfUpdateAttemptTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        tracker.begin(deviceID: "box", targetVersion: "0.24.0", status: updatableStatus())
        _ = tracker.presentation(deviceID: "box", liveStatus: nil, isReachable: false, now: start)

        let retry = start.addingTimeInterval(130)
        tracker.resetRestartingSince(deviceID: "box", now: retry)
        let after = tracker.presentation(deviceID: "box", liveStatus: nil, isReachable: false, now: retry.addingTimeInterval(5))
        #expect(after == .restarting(from: "0.23.0", to: "0.24.0"))
    }

    @Test func aRestartTheDaemonReportsWithoutAnAttemptIsStillWatched() {
        var tracker = DaemonSelfUpdateAttemptTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let restarting = updatableStatus(progress: DaemonSelfUpdateProgress(targetVersion: "0.24.0", step: .restarting))
        #expect(!tracker.hasAttempt(deviceID: "box"))

        let shown = tracker.presentation(deviceID: "box", liveStatus: restarting, isReachable: true, now: now)
        #expect(shown == .restarting(from: "0.23.0", to: "0.24.0"))
        #expect(tracker.hasAttempt(deviceID: "box"))
        #expect(tracker.stillRestartingDeadline(deviceID: "box") != nil)
    }

    @Test func onlyAnUpdateInMotionKeepsThePollRunning() {
        #expect(DaemonSelfUpdatePresentation.downloading(from: "a", to: "b", received: 0, total: nil).isInFlight)
        #expect(DaemonSelfUpdatePresentation.installing(from: "a", to: "b").isInFlight)
        #expect(DaemonSelfUpdatePresentation.restarting(from: "a", to: "b").isInFlight)
        #expect(DaemonSelfUpdatePresentation.stillRestarting(from: "a", to: "b").isInFlight)
        #expect(!DaemonSelfUpdatePresentation.available(from: "a", to: "b").isInFlight)
        #expect(!DaemonSelfUpdatePresentation.failed(from: "a", to: "b", reason: "x").isInFlight)
        #expect(!DaemonSelfUpdatePresentation.none.isInFlight)
    }
}

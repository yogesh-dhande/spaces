import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// The host chrome the daemon-update domain needs in order to present or clear the compatibility
/// block: reading the block (if any) currently on screen and the device facts that drive it, and
/// swapping the detail pane between the block, the resolved selection, and the neutral placeholder.
/// `AppKitController` conforms via its existing methods/properties below.
@MainActor
protocol CompatibilityBlockPresenting: AnyObject {
    var detailPane: DetailPane { get }
    var visibleCompatibilityBlockRemedy: CompatibilityBlockView.BlockRemedy? { get }
    var visibleCompatibilityBlockDeviceID: String? { get }
    func deviceCompatibility(forDeviceID deviceID: String) -> SpacesWireCompatibility?
    func deviceDaemonStatus(forDeviceID deviceID: String) -> TerminalServiceDaemonStatus?
    func deviceRecord(forDeviceID deviceID: String) -> SpacesPairedDeviceRecord?
    func deviceSection(id deviceID: String) -> DeviceModelStore.DeviceSection?
    func presentDetailPane(_ pane: DetailPane, presentation: DetailPanePresentation)
    func refreshSelection()
    func showPlaceholder(message: String, presentation: DetailPanePresentation)
    func showCompatibilityBlock(deviceID: String, verdict: SpacesWireCompatibility, presentation: DetailPanePresentation)
    func showError(_ error: Error)
    func showDeviceNotLoadedError()
}

extension AppKitController: CompatibilityBlockPresenting {}

/// Owns the staged-apply / SSH-update domain: the silent daemon exec-in-place handoff Spaces requests
/// the moment a device reports a build staged on disk, the watchdog that tells the user when that
/// handoff does not land, and the Linux "Update over SSH" installer run. Extracted from
/// `AppKitController` as a behavior-preserving move (part of the ongoing decomposition of that type);
/// `AppKitController` holds this as `daemonUpdate` and reaches it as `host.daemonUpdate` from other
/// files (`SidebarController`, `DevicePairingController`) that need to feed it fresh device facts or
/// drop its state for a device they stop tracking.
@MainActor final class DaemonUpdateController {
    /// Typed as the protocol, not `AppKitController`, so the controller is constructible against a fake
    /// presenter in unit tests; device facts are read through it rather than from `DeviceModelStore`
    /// directly because the host's accessors go through `SidebarController`'s indexed lookups.
    unowned let host: any CompatibilityBlockPresenting
    /// Triggers the host's sidebar reload with a forced remote refresh, the one flavor every call site
    /// in this domain needs: it always follows a daemon restart request or SSH update run, both of
    /// which only a fresh remote pull can reflect.
    let requestSidebarReload: () -> Void

    init(host: any CompatibilityBlockPresenting, requestSidebarReload: @escaping () -> Void) {
        self.host = host
        self.requestSidebarReload = requestSidebarReload
    }

    /// One device's attempt to apply one staged build. Every piece of staged-apply state is keyed by
    /// this pair rather than by device alone, so a device that later stages a different build gets a
    /// fresh request and a fresh verdict instead of inheriting the previous build's.
    struct DaemonStagedApplyAttempt: Hashable {
        let deviceID: String
        let stagedVersion: String
    }
    /// The attempts a silent daemon handoff has already been fired for this app run (see
    /// `maybeRequestSilentDaemonHandoff`), so a status refresh never re-requests one that is already on
    /// its way. The Try Again action deliberately bypasses this — the user asking again is new
    /// information, a repeated status report is not.
    private var silentDaemonHandoffRequestedAttempts: Set<DaemonStagedApplyAttempt> = []
    /// The attempts whose watchdog expired with the device still reporting the same staged build not
    /// running. A blocked device's block reads this to offer Try Again, and nothing renders an
    /// `.applyStagedUpdate` block without it. Retired by `retireStagedApplyState` once the device stops
    /// waiting on that build, and by `forgetDaemonUpdateProgress` on removal.
    private var stagedApplyDidNotLandAttempts: Set<DaemonStagedApplyAttempt> = []
    /// The in-flight staged-apply watchdog per device, carrying the staged build it is waiting for so a
    /// later attempt replaces an earlier one instead of racing it and so an expiring watchdog can tell
    /// its own attempt from a newer one. At most one per device: a device waits on one staged build.
    private var stagedApplyWatchdogs: [String: (stagedVersion: String, task: Task<Void, Never>)] = [:]
    /// Devices whose compatibility-block "Update over SSH" installer run is in flight, so the block
    /// renders a spinner instead of re-offering the button. Entries are dropped by
    /// `updateRemoteDaemonOverSSH` on failure and by `reconcileCompatibilityBlock` once a fresh verdict
    /// for the device stops calling for `.installUpdateOnDevice`, so a finished run can never pin a
    /// spinner permanently. Not private: `AppKitController.showCompatibilityBlock` reads it to render
    /// the block's spinner/button state.
    var daemonSSHUpdateInProgressDeviceIDs: Set<String> = []

    /// What `reconcileCompatibilityBlock` should do with the visible compatibility block for the device
    /// whose verdict/status just changed: drop it (the device needs no block any more), rebuild it with a
    /// different remedy (the device still needs a block, but the wire facts driving its copy/action have
    /// moved on), or leave the rendered block exactly as it is.
    enum CompatibilityBlockReconciliation: Equatable {
        case clear
        case rerender(CompatibilityBlockView.BlockRemedy)
        case leaveAlone
    }

    /// Pure "should the visible compatibility block change" decision, factored out so it is testable
    /// without AppKit. `isVisibleBlockDevice` mirrors the identity check every caller needs — a device
    /// that doesn't own the currently-rendered block never touches it. Otherwise this always re-derives
    /// the remedy through `CompatibilityBlockView.blockRemedy(verdict:status:)`, the same function
    /// `showCompatibilityBlock` renders from, so the two can never disagree about what a given
    /// verdict/status pair means: a `nil` verdict (unknown/offline) or a compatible verdict both produce
    /// no remedy and therefore `.clear`.
    nonisolated static func reconcileCompatibilityBlockAction(
        isVisibleBlockDevice: Bool, renderedRemedy: CompatibilityBlockView.BlockRemedy, verdict: SpacesWireCompatibility?,
        status: TerminalServiceDaemonStatus?, stagedApplyDidNotLand: Bool
    ) -> CompatibilityBlockReconciliation {
        guard isVisibleBlockDevice else { return .leaveAlone }
        guard let verdict, let newRemedy = CompatibilityBlockView.blockRemedy(verdict: verdict, status: status) else { return .clear }
        // Ahead of the equality check, so clearing the failure mark (Try Again) takes the block down even
        // though the remedy itself is unchanged.
        guard
            AppKitController.shouldRenderCompatibilityBlock(
                remedy: newRemedy, verdictIsCompatible: verdict.isCompatible, stagedApplyDidNotLand: stagedApplyDidNotLand)
        else { return .clear }
        return newRemedy == renderedRemedy ? .leaveAlone : .rerender(newRemedy)
    }

    /// Reconciles the visible compatibility block (if any) against `deviceID`'s current verdict/status:
    /// drops an obsolete block and re-resolves the detail pane once the device needs none (it is
    /// compatible again after a restart updated its daemon, or its staged update is one Spaces is
    /// applying by itself), or re-renders the block once the device still needs one under a different
    /// remedy, without the user having to navigate away and back. Called from every apply path after a
    /// reload updates a section's verdict/status. See `reconcileCompatibilityBlockAction` for the pure
    /// decision.
    func reconcileCompatibilityBlock(deviceID: String) {
        let verdict = host.deviceCompatibility(forDeviceID: deviceID)
        let status = host.deviceDaemonStatus(forDeviceID: deviceID)
        // Runs ahead of the visible-block guard: an SSH update or a staged apply started from here
        // outlives whatever the detail pane is showing, so their state has to be retired from the
        // device's own facts rather than from the pane's. Only a verdict clears anything — an absent
        // verdict is the device being offline, which is exactly what a daemon mid-handoff looks like.
        if let verdict {
            let remedy = CompatibilityBlockView.blockRemedy(verdict: verdict, status: status)
            if remedy?.isInstallUpdateOnDevice != true { daemonSSHUpdateInProgressDeviceIDs.remove(deviceID) }
            retireStagedApplyState(deviceID: deviceID, currentStagedVersion: remedy?.stagedVersion)
        }
        guard let renderedRemedy = host.visibleCompatibilityBlockRemedy else { return }
        let action = Self.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: host.visibleCompatibilityBlockDeviceID == deviceID, renderedRemedy: renderedRemedy, verdict: verdict, status: status,
            stagedApplyDidNotLand: stagedApplyDidNotLand(deviceID: deviceID, status: status))
        switch action {
        case .leaveAlone: return
        case .clear:
            // The block was established above to be this device's; `refreshSelection` re-resolves the
            // pane from the selection. When it resolves nothing it renders nothing — reconciliation
            // never navigates — and `presentDetailPane(.none)` records the pane without touching the
            // container, so a recovery with no selection to return to has to paint the neutral
            // placeholder itself or the retired block's views would stay on screen behind an empty
            // pane record.
            host.presentDetailPane(.none, presentation: .backgroundRefresh)
            host.refreshSelection()
            if host.detailPane == .none { host.showPlaceholder(message: "Select a project or workspace.", presentation: .backgroundRefresh) }
        case .rerender:
            // `verdict` is guaranteed non-nil here: `.rerender` only comes from `blockRemedy` returning a
            // remedy, which itself requires a non-optional verdict.
            guard let verdict else { return }
            host.showCompatibilityBlock(deviceID: deviceID, verdict: verdict, presentation: .backgroundRefresh)
        }
    }

    /// Requests the device's daemon exec-in-place handoff through the `requestDaemonRestart` RPC (the
    /// daemon quiesces sessions, applies any update staged on disk, and re-execs at the same pid, so
    /// running terminals, agents, and processes survive), then reloads the sidebar after a short delay
    /// so the app re-handshakes against the new build. Silent on both success and failure: whether the
    /// staged build is running is a fact the device reports, so `startStagedApplyWatchdog` reads it back
    /// from the device rather than this app reporting on its own request — a refused RPC and a daemon
    /// that never comes back are the same outcome to the user, and a rejected request is often just a
    /// daemon already mid-handoff. A remote Linux daemon too old for this app has nothing staged to
    /// restart into, so it is updated by re-running the version-pinned installer instead:
    /// `updateRemoteDaemonOverSSH` runs it from here for a device whose pairing stored SSH details, and
    /// the compatibility block's copyable one-liner covers a device without them. Either way the
    /// installer pokes the live daemon for the same in-place handoff this RPC triggers.
    private func fireDaemonRestartRequest(device: SpacesPairedDeviceRecord) {
        Task { @MainActor [weak self] in
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SpacesDeviceClient.requestDaemonRestart(context: DeviceRequestContext(device: device))
                }.value
            } catch {
                return
            }
            guard let self else { return }
            // Give the daemon a moment to complete the handoff, then re-handshake.
            try? await Task.sleep(for: .seconds(2))
            self.requestSidebarReload()
        }
    }

    /// The staged build a silent daemon handoff should ask `status`'s device to apply, or `nil` when
    /// there is nothing to ask for. Factored out so it is testable without a device record or the RPC.
    ///
    /// It defers entirely to `DaemonUpdateRemedy`, so what Spaces does silently and what a block would
    /// otherwise say can never disagree. Wire compatibility is deliberately not part of the decision:
    /// the restart RPC rides the frozen wire core, so it reaches a daemon this app cannot otherwise talk
    /// to, and applying the staged build is precisely what closes that gap — leaving an incompatible
    /// device to a button would make the user click through what the app can already do.
    nonisolated static func silentDaemonHandoffStagedVersion(status: TerminalServiceDaemonStatus?) -> String? {
        guard let status, case .applyStagedUpdate(let stagedVersion) = DaemonUpdateRemedy.remedy(for: status) else { return nil }
        return stagedVersion
    }

    /// Whether `status` still reports the exact staged build a handoff was requested for — the device
    /// saying, in its own terms, that the apply has not happened. Reuses the fire rule so what Spaces
    /// asks for and what it checks for cannot drift.
    nonisolated static func stagedApplyIsStillPending(status: TerminalServiceDaemonStatus?, stagedVersion: String) -> Bool {
        silentDaemonHandoffStagedVersion(status: status) == stagedVersion
    }

    /// What an expiring staged-apply watchdog does about the attempt it was watching, named for the
    /// action rather than for the device's state so the rule is the whole decision.
    enum StagedApplyWatchdogResolution: Equatable {
        /// The device itself reports the same build still staged and not running: mark the attempt and
        /// tell the user, which is also what puts Try Again on a blocked device's block.
        case reportDidNotLand
        /// Nothing the device reports decides this attempt — it is not answering (a daemon mid-handoff
        /// and an unreachable device look identical), or its facts have moved on to another build. The
        /// request is left un-judged, so the once-per-build rule it spent is handed back and the device's
        /// next report can ask for the apply again.
        case rearmAutomaticRequest
    }

    /// The watchdog's whole decision, pure so both halves of it are directly testable.
    nonisolated static func stagedApplyWatchdogResolution(status: TerminalServiceDaemonStatus?, stagedVersion: String)
        -> StagedApplyWatchdogResolution
    { stagedApplyIsStillPending(status: status, stagedVersion: stagedVersion) ? .reportDidNotLand : .rearmAutomaticRequest }

    /// Silently requests a daemon exec-in-place handoff when a device reports a staged update (the
    /// device's own installed-vs-running comparison; never this app's build version), instead of waiting
    /// for the daemon's own next restart. Called from every path where a fresh
    /// `TerminalServiceDaemonStatus` lands for a device (local snapshot apply, remote pull, remote push
    /// subscription) and from the cold-start path where local bootstrap fails wire-incompatible before any
    /// snapshot can land a status (`showLocalDaemonCompatibilityBlock`). Deduped per attempt so a repeated
    /// status report never re-requests a handoff that is already on its way; `startStagedApplyWatchdog`
    /// owns what happens if it does not arrive.
    func maybeRequestSilentDaemonHandoff(deviceID: String, status: TerminalServiceDaemonStatus?) {
        guard let stagedVersion = Self.silentDaemonHandoffStagedVersion(status: status) else { return }
        let attempt = DaemonStagedApplyAttempt(deviceID: deviceID, stagedVersion: stagedVersion)
        guard !silentDaemonHandoffRequestedAttempts.contains(attempt) else { return }
        silentDaemonHandoffRequestedAttempts.insert(attempt)
        guard let device = host.deviceRecord(forDeviceID: deviceID) else { return }
        fireDaemonRestartRequest(device: device)
        startStagedApplyWatchdog(deviceID: deviceID, stagedVersion: stagedVersion)
    }

    /// How long a requested staged apply gets before Spaces tells the user it has not happened. Long
    /// enough to cover a handoff that replays a device's session transcripts, short enough that a device
    /// that will not come back is not left silently pending.
    private static let stagedApplyWatchdogDelay: Duration = .seconds(30)

    /// Whether the block for `deviceID` may render: true only once the staged apply this app requested
    /// has been marked as not landed. Not private: `AppKitController.showCompatibilityBlock` (which stays
    /// on the host, since rendering the block is host chrome) reads it via `daemonUpdate`.
    func stagedApplyDidNotLand(deviceID: String, status: TerminalServiceDaemonStatus?) -> Bool {
        guard let stagedVersion = Self.silentDaemonHandoffStagedVersion(status: status) else { return false }
        return stagedApplyDidNotLandAttempts.contains(DaemonStagedApplyAttempt(deviceID: deviceID, stagedVersion: stagedVersion))
    }

    /// Watches a requested staged apply and, if the device still reports the same build staged and not
    /// running once the delay is up, marks the attempt and surfaces it. Replaces any watchdog already
    /// running for the device: only the newest attempt can produce a verdict.
    private func startStagedApplyWatchdog(deviceID: String, stagedVersion: String) {
        stagedApplyWatchdogs[deviceID]?.task.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stagedApplyWatchdogDelay)
            guard !Task.isCancelled, let self else { return }
            self.resolveStagedApplyWatchdog(deviceID: deviceID, stagedVersion: stagedVersion)
        }
        stagedApplyWatchdogs[deviceID] = (stagedVersion, task)
    }

    /// The watchdog's verdict, read from what the device says about itself rather than from what the RPC
    /// returned. A device that is not answering at all reports no status and gets no verdict: that is
    /// exactly what a daemon mid-handoff looks like, and an unreachable device already reads as offline.
    /// It re-arms the automatic request instead, so the device's next report is acted on rather than
    /// deduped away — see the `.rearmAutomaticRequest` branch.
    ///
    /// That rests on the section's status being dropped — not merely left stale — the moment the device
    /// stops answering, which is what makes reading the cached value here honest rather than a verdict on
    /// old evidence. Both classes of device this watchdog covers have a mechanism that notices well
    /// inside the delay above: a blocked device is re-pulled on every `deviceReachabilityWatchdogInterval`
    /// tick (`SidebarController.watchdogShouldPullSection`), and a device the app can still use holds a
    /// live subscription whose stream drops with the daemon (`markRemoteOverviewSectionOffline`). Either
    /// route lands in `applyRemoteDeviceSection`'s failure branch, which clears `daemonStatus` with the
    /// offline transition. So the status read here is either absent or came from a device that was
    /// answering, on the old build, seconds ago.
    ///
    /// Marking the attempt changes no pane. For a blocked device it is what puts Try Again on the block
    /// the user reaches through the sidebar's compatibility action; for a device the app can still use
    /// there is no block, and the dialog below is the whole surface.
    private func resolveStagedApplyWatchdog(deviceID: String, stagedVersion: String) {
        // A watchdog left over from an earlier staged build must not judge the current attempt. It also
        // must not touch the once-only: the attempt it belonged to was superseded by a newer one that is
        // still running, and handing back a mark that names a different build would re-fire that build's
        // request underneath the attempt in flight.
        guard stagedApplyWatchdogs[deviceID]?.stagedVersion == stagedVersion else { return }
        stagedApplyWatchdogs[deviceID] = nil
        let status = host.deviceDaemonStatus(forDeviceID: deviceID)
        let attempt = DaemonStagedApplyAttempt(deviceID: deviceID, stagedVersion: stagedVersion)
        switch Self.stagedApplyWatchdogResolution(status: status, stagedVersion: stagedVersion) {
        case .rearmAutomaticRequest:
            // The once-per-build rule exists to stop a device's repeated status reports from re-requesting
            // a handoff already on its way, and it is spent by an outcome: the build landed, the device
            // moved on to another one, or the report below says the apply did not happen. A wait that
            // decided nothing — the device went quiet, which is exactly what a daemon still replaying its
            // sessions looks like — hands it back instead. Otherwise the attempt would stay consumed with
            // no mark to show for it: the device would come back still blocked on that same staged build
            // with the automatic request deduped away and its block withheld (see
            // `shouldRenderCompatibilityBlock`), leaving nothing to act on until the app was relaunched.
            // Re-firing takes a fresh report of that device still waiting on that same build, so this
            // cannot spin; it only lets the next such report be acted on.
            silentDaemonHandoffRequestedAttempts.remove(attempt)
        case .reportDidNotLand:
            // `.reportDidNotLand` is only reached for a device that reported a status, so the dialog's
            // facts are the device's own.
            guard let status else { return }
            stagedApplyDidNotLandAttempts.insert(attempt)
            presentStagedApplyDidNotLandDialog(deviceID: deviceID, status: status, stagedVersion: stagedVersion)
        }
    }

    /// The one dialog this flow raises, once per attempt: what is installed, what is still running, that
    /// nothing on the device was disturbed, and how to apply the build on that device by hand. Only Try
    /// Again acts; closing it leaves every pane as the user left it.
    private func presentStagedApplyDidNotLandDialog(deviceID: String, status: TerminalServiceDaemonStatus, stagedVersion: String) {
        let copy = CompatibilityBlockView.stagedApplyDidNotLandCopy(
            deviceName: host.deviceSection(id: deviceID)?.deviceName ?? deviceID, stagedVersion: stagedVersion, runningVersion: status.version,
            isLocalDevice: deviceID == SpacesPairedDeviceRecord.localDeviceID, isLinuxDaemon: status.isLinuxDaemon)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = copy.title
        alert.informativeText = copy.command.map { "\(copy.body)\n\n\(copy.instruction)\n\n\($0)" } ?? "\(copy.body)\n\n\(copy.instruction)"
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Close")
        if copy.command != nil { alert.addButton(withTitle: "Copy Command") }
        switch alert.runModal() {
        case .alertFirstButtonReturn: retryStagedApply(deviceID: deviceID)
        case .alertThirdButtonReturn:
            if let command = copy.command {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        default: break
        }
    }

    /// Try Again, from the dialog or from a blocked device's block: re-requests the apply for whatever
    /// the device currently reports staged, clears the mark, and restarts the watchdog, so a second
    /// request that also goes unanswered reports itself the same way the first did. It bypasses the
    /// once-only rule on purpose — the user asking again is new information, a repeated status report is
    /// not. Not private: a blocked device's block calls it directly through `host.showCompatibilityBlock`'s
    /// `onRetryStagedApply` closure.
    func retryStagedApply(deviceID: String) {
        let status = host.deviceDaemonStatus(forDeviceID: deviceID)
        guard let stagedVersion = Self.silentDaemonHandoffStagedVersion(status: status), let device = host.deviceRecord(forDeviceID: deviceID) else {
            host.showDeviceNotLoadedError()
            return
        }
        stagedApplyDidNotLandAttempts.remove(DaemonStagedApplyAttempt(deviceID: deviceID, stagedVersion: stagedVersion))
        fireDaemonRestartRequest(device: device)
        startStagedApplyWatchdog(deviceID: deviceID, stagedVersion: stagedVersion)
        // Takes a visible block back down: with the mark cleared the device is applying an update again,
        // which is not a state the user has to look at.
        reconcileCompatibilityBlock(deviceID: deviceID)
    }

    /// Drops staged-apply state for `deviceID` that its own facts no longer justify: everything when the
    /// device is not waiting on a staged build at all, and everything but the current attempt when it is
    /// waiting on a different one. Called from `reconcileCompatibilityBlock`, i.e. from every path that
    /// lands a fresh verdict/status, so a landed or superseded apply can never pin a block or a watchdog.
    private func retireStagedApplyState(deviceID: String, currentStagedVersion: String?) {
        stagedApplyDidNotLandAttempts = stagedApplyDidNotLandAttempts.filter { $0.deviceID != deviceID || $0.stagedVersion == currentStagedVersion }
        if let watchdog = stagedApplyWatchdogs[deviceID], watchdog.stagedVersion != currentStagedVersion {
            watchdog.task.cancel()
            stagedApplyWatchdogs[deviceID] = nil
        }
    }

    /// The compatibility block's "Update over SSH" action: runs the version-pinned Linux installer on the
    /// device over SSH, which lands the new release and pokes the live daemon into an in-place handoff, so
    /// the device's terminals, agents, and processes survive the update. User-initiated, so a missing
    /// record and a failed installer run are both visible errors rather than silent no-ops. Not private:
    /// a blocked device's block calls it directly through `host.showCompatibilityBlock`'s
    /// `onUpdateOverSSH` closure.
    func updateRemoteDaemonOverSSH(deviceID: String) {
        guard let device = host.deviceRecord(forDeviceID: deviceID), AppKitController.hasSSHDetails(device) else {
            host.showDeviceNotLoadedError()
            return
        }
        guard !daemonSSHUpdateInProgressDeviceIDs.contains(deviceID) else { return }
        daemonSSHUpdateInProgressDeviceIDs.insert(deviceID)
        rerenderCompatibilityBlockIfVisible(deviceID: deviceID)
        Task { @MainActor [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SpacesDevicePairingClient.updateSpacesOnRemoteDevice(device: device, appVersion: AppVersion.short)
                }.value
            } catch {
                guard let self else { return }
                self.daemonSSHUpdateInProgressDeviceIDs.remove(deviceID)
                self.rerenderCompatibilityBlockIfVisible(deviceID: deviceID)
                self.host.showError(error)
                return
            }
            guard let self else { return }
            // Deliberately does not clear the in-progress entry: the installer returns as soon as the
            // daemon accepts the handoff, and for the moments it spends re-execing and replaying sessions
            // it still answers with the old wire version. Dropping the spinner here would put the
            // "Update over SSH" button back mid-update and invite a second run. `reconcileCompatibilityBlock`
            // retires the entry from the device's own next verdict instead.
            try? await Task.sleep(for: .seconds(2))
            self.requestSidebarReload()
        }
    }

    /// Re-renders the compatibility block for `deviceID` when that block is the one on screen, so a
    /// change in this app's own in-progress state reaches the card without disturbing whatever the user
    /// navigated to instead.
    private func rerenderCompatibilityBlockIfVisible(deviceID: String) {
        guard host.visibleCompatibilityBlockDeviceID == deviceID, let verdict = host.deviceCompatibility(forDeviceID: deviceID) else { return }
        host.showCompatibilityBlock(deviceID: deviceID, verdict: verdict, presentation: .backgroundRefresh)
    }

    /// Drops the in-app update state for a device the app is about to stop tracking, so a later pairing
    /// of the same device cannot inherit a spinner, a failure mark, or a watchdog from work that is no
    /// longer observable.
    func forgetDaemonUpdateProgress(deviceID: String) {
        daemonSSHUpdateInProgressDeviceIDs.remove(deviceID)
        silentDaemonHandoffRequestedAttempts = silentDaemonHandoffRequestedAttempts.filter { $0.deviceID != deviceID }
        retireStagedApplyState(deviceID: deviceID, currentStagedVersion: nil)
    }
}

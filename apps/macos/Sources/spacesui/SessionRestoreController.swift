import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// Owns the restore offer on the Mac: what each device is offering, which records this client has
/// already answered, sending the answer, and putting the restored sessions back in the panes their
/// predecessors held.
///
/// The offer reaches the user through two surfaces and this controller drives both. At launch the setup
/// flow hosts it as a step, because the launch sequence is already a sequence of one-time questions and
/// because the answer has to land before the workspace UI restores its layouts. While the app runs, any
/// device can start reporting a record (its daemon crashed, a paired Linux box rebooted), and that
/// arrives as a sheet over the main window.
@MainActor final class SessionRestoreController {
    /// What one device's answer produced.
    enum AnswerOutcome: Equatable {
        /// The device accepted the answer. Carries each captured session id mapped to the session now
        /// running in its place and the rows the device could not relaunch; both empty for Skip.
        case answered(SpacesDeviceRestoredSessionsResult)
        /// The device refused the answer because the record it names is not the one it holds any more: it
        /// captured again, or another client answered first. Not a failure to report, and not an answer
        /// either: whatever the device holds now is offered afresh.
        case superseded
        /// The answer never landed (the device is unreachable, the daemon refused it). Carries what to
        /// tell the user, because the agents they asked for are still waiting on the device.
        case failed(message: String)
    }

    /// What one outcome means for the client: whether to remember the generation as answered, and what
    /// (if anything) the surface has to tell the user before it can close.
    struct AnswerDisposition: Equatable {
        /// Only a device that accepted the answer has cleared its record, and only a cleared record must
        /// not be offered again. Remembering a generation the device still holds would hide the offer for
        /// good; forgetting one it cleared would ask about agents that no longer exist.
        let recordsGeneration: Bool
        /// Non-nil keeps the surface open with this message: the user asked for their agents back and did
        /// not get them, so the answer is theirs to retry or abandon.
        let failureMessage: String?
    }

    nonisolated static func disposition(for outcome: AnswerOutcome) -> AnswerDisposition {
        switch outcome {
        case .answered: AnswerDisposition(recordsGeneration: true, failureMessage: nil)
        // Nothing to retry and nothing to report: the record the user was looking at is gone, and the one
        // that replaced it is presented by the re-check that runs when this surface closes.
        case .superseded: AnswerDisposition(recordsGeneration: false, failureMessage: nil)
        case .failed(let message): AnswerDisposition(recordsGeneration: false, failureMessage: message)
        }
    }

    /// What the whole answer did, which is what decides whether the surface that asked can close.
    enum AnswerCompletion: Equatable {
        case complete
        /// At least one device could not be answered. The surface stays up carrying this message so the
        /// user can try again or Skip instead.
        case failed(message: String)
    }

    /// Where the answer is being made from, which decides how a restored session finds its predecessor's
    /// pane. At launch the panes exist only as persisted layout rows, and rewriting those rows is what
    /// makes the restored session appear in the old slot when the workspace UI restores them moments
    /// later. While the app runs the panes are live, so the restored session is handed the predecessor's
    /// pane through the same path a restart's replacement takes.
    enum PanePlacement {
        case persistedLayouts
        case livePanes
    }

    private unowned let host: AppKitController
    /// The offer the sheet is showing, so a status refresh cannot stack a second sheet on it, and the
    /// answer in flight cannot be answered again.
    private var sheetOffer: SessionRestoreOffer?
    private var sheetWindow: NSWindow?
    /// Retained for the sheet's lifetime: the buttons target it and `NSControl.target` is weak.
    private var sheetView: SessionRestoreOfferView?
    /// Set while an offer is waiting for an unrelated sheet to close. See `waitForTheWindowToPresentTheOffer`.
    private var windowSheetObserver: (any NSObjectProtocol)?
    /// The offer `answer` is in the middle of delivering, which holds its panes for the length of the call.
    /// See `heldSessionIDs`.
    private var inFlightAnswerOffer: SessionRestoreOffer?
    /// Stands in for the fresh daemon-status read in `probedDaemonStatus`, so a test can answer without a
    /// daemon to dial.
    var daemonStatusProbeOverrideForTesting: ((String) -> TerminalServiceDaemonStatus?)?
    /// Every offer `maybePresentOfferSheet` computes, handed over as it is computed. What a surface shows
    /// depends on where inside a device's apply the presentation runs (workspace names come from the
    /// installed overview), and that ordering is only observable at this moment.
    var offerConsideredForTesting: ((SessionRestoreOffer?) -> Void)?

    /// The record the sheet is asking about, or nil when no offer is on screen.
    var offerOnScreen: SessionRestoreOffer? { sheetOffer }

    init(host: AppKitController) { self.host = host }

    // MARK: - Pure answer

    /// Answers one device's record and reports what came back. Written against the two calls rather than
    /// against a device client so the answer's contract (Restore relaunches and maps, Skip discards, a
    /// failure remembers nothing) is testable on its own.
    nonisolated static func performAnswer(
        _ answer: SessionRestoreAnswer, generation: String, restore: (String) throws -> SpacesDeviceRestoredSessionsResult,
        discard: (String) throws -> Void
    ) -> AnswerOutcome {
        do {
            switch answer {
            case .restore: return .answered(try restore(generation))
            case .skip:
                try discard(generation)
                return .answered(.init(newSessionIDsByCapturedSessionID: [:]))
            }
        } catch {
            NSLog("Spaces: could not answer the session restore offer: \(error.localizedDescription)")
            // A refusal on the record's identity is the daemon saying this offer is stale, which is a
            // different thing from an answer that did not land: nothing is wrong, the user is simply
            // looking at a record the device has replaced.
            //
            // Accepted cost of that reading: a reply lost in transport (a timeout, a reset) after the
            // daemon had already relaunched the agents and cleared the record reports a failure, and the
            // user's retry is then refused as stale and read here as superseded. The answer is not
            // idempotent on the daemon by design: replaying a restore's result per generation would mean
            // the daemon keeping a history of answers it has no other use for. What the indeterminate
            // case costs is pane placement and nothing else. The agents are back, they are in the
            // session list, and only the claim on their predecessors' panes is lost, so they appear as
            // ordinary new sessions.
            if case SpacesDeviceClientError.requestRejected(_, .conflict) = error { return .superseded }
            return .failed(message: error.localizedDescription)
        }
    }

    // MARK: - The offer

    /// The offer the launch setup step should show for This Mac, or nil when the local daemon is
    /// offering nothing (or nothing this client has not already answered).
    ///
    /// This Mac only: a paired device may be asleep or unreachable, and launch must not wait on its round
    /// trip. A remote device's record is offered by the sheet as soon as the device reports it.
    func launchOffer(localDaemonStatus: TerminalServiceDaemonStatus?) -> SessionRestoreOffer? {
        SessionRestoreOffer.make(devices: [
            .init(
                deviceID: SpacesPairedDeviceRecord.localDeviceID, deviceName: "This Mac", status: localDaemonStatus,
                answeredGeneration: answeredGenerations()[SpacesPairedDeviceRecord.localDeviceID])
        ])
    }

    /// What to do with an outstanding offer at the moment it is noticed.
    enum OfferPresentation: Equatable {
        /// Put the sheet up now.
        case present
        /// Hold the offered panes and wait: some other sheet (a settings dialog, a confirmation) owns the
        /// window, and a second sheet cannot be attached to it. The wait ends when that sheet does.
        case waitForTheWindow
        /// Not this surface's offer: the launch step owns it until the workspace UI exists, and an answer
        /// already on screen is the one being made.
        case notThisSurface
    }

    /// Decides between the three, given what else owns the window. Pure because the distinction that
    /// matters is easy to get wrong: an offer blocked by an unrelated sheet has to leave something behind
    /// (a hold on its panes, and a re-check when the sheet ends), while an offer the launch step owns
    /// must leave nothing, or a launch would fight its own setup flow for the window.
    nonisolated static func offerPresentation(isMainWindowContentBuilt: Bool, hasLaunchSetupFlow: Bool, isShowingOffer: Bool, hasOtherSheet: Bool)
        -> OfferPresentation
    {
        guard isMainWindowContentBuilt, !hasLaunchSetupFlow, !isShowingOffer else { return .notThisSurface }
        return hasOtherSheet ? .waitForTheWindow : .present
    }

    /// Shows the offer as a sheet when some device reports a record this client has not answered. Called
    /// from every path that installs a device's daemon status, so a device that starts reporting one
    /// while the app is running is offered without the user doing anything.
    func maybePresentOfferSheet() {
        // Holds first, and whatever the answer to "can this be shown right now" turns out to be: the
        // sessions on an outstanding record ended with the daemon that ran them, so this same refresh
        // prunes their panes unless they are held, and a record can be outstanding while another sheet
        // (or an earlier offer) owns the window. See `updateHeldPanes`.
        let offer = currentOffer()
        offerConsideredForTesting?(offer)
        updateHeldPanes(offer: offer)
        dismissSupersededSheet()
        guard let offer else { return }
        switch Self.offerPresentation(
            isMainWindowContentBuilt: host.isMainWindowContentBuilt, hasLaunchSetupFlow: host.setupFlowController != nil,
            isShowingOffer: sheetOffer != nil, hasOtherSheet: host.window?.attachedSheet != nil)
        {
        case .present: presentSheet(offer: offer)
        case .waitForTheWindow: waitForTheWindowToPresentTheOffer()
        case .notThisSurface: break
        }
    }

    /// Takes the sheet down when no device still reports what it is asking about: another client answered
    /// the record, or the device replaced it with a newer capture. Nothing is recorded, exactly as for an
    /// answer the device refuses as stale, and the sheet's own completion raises whatever is outstanding
    /// now. Without this the question stays on screen until the user clicks it and is told it is stale.
    ///
    /// An answer in flight is left alone: the device clears the record as it accepts the answer, so a
    /// status arriving mid-call reports nothing outstanding, and taking the sheet down here would drop the
    /// result the answer is about to show (including the reason, when it failed).
    private func dismissSupersededSheet() {
        guard let presented = sheetOffer, inFlightAnswerOffer == nil, Self.sheetIsSuperseded(presented: presented, reported: reportedRecords()) else {
            return
        }
        endOfferSheet(presented: presented)
    }

    /// Takes the offer off screen and raises whatever is outstanding by then.
    ///
    /// The state is cleared here rather than only in the sheet's completion handler, so what this
    /// controller says it is asking is true from the moment it stops asking, whether or not AppKit has run
    /// the completion yet. The completion handler is the other way a sheet ends (the user answered), and
    /// it recognizes a sheet this took down by the window it holds.
    private func endOfferSheet(presented: SessionRestoreOffer) {
        let sheet = sheetWindow
        sheetOffer = nil
        sheetWindow = nil
        sheetView = nil
        if let sheet { host.window?.endSheet(sheet) }
        presentQueuedOffer(after: presented)
    }

    /// What a device says about its record right now.
    enum ReportedRecord: Equatable {
        case generation(String)
        /// The device answered and holds no record: it was answered, by this client or another one.
        case noRecord
        /// The device has said nothing to go on, because it has no status installed (it dropped off, or it
        /// has not answered yet). Not evidence that the record is gone.
        case unknown
    }

    /// Whether none of the records a sheet is showing is still held by its device. Per (device,
    /// generation) pair rather than by comparing offers: a device that captures again while the sheet is
    /// up supersedes what it shows, while a second device starting to report its own record does not, and
    /// neither does a workspace name arriving between two computations.
    ///
    /// Read from the raw reported record rather than from the offer, which is compatibility-gated: a
    /// device that is updated (or drops off) while its sheet is up still holds the very record the user is
    /// being asked about, and taking the question away because this client cannot talk to it for a moment
    /// would lose the answer for no reason. Only a device that answers and says it holds nothing, or holds
    /// a different generation, settles the question it was asked.
    nonisolated static func sheetIsSuperseded(presented: SessionRestoreOffer, reported: [String: ReportedRecord]) -> Bool {
        presented.devices.allSatisfy { device in
            switch reported[device.deviceID] ?? .unknown {
            case .generation(let generation): generation != device.generation
            case .noRecord: true
            case .unknown: false
            }
        }
    }

    /// What every device on screen reports right now, straight off its status. A device with no section at
    /// all is simply absent, which reads as `.unknown`.
    private func reportedRecords() -> [String: ReportedRecord] {
        Dictionary(
            host.deviceModel.deviceSections.map { section in
                guard let status = section.daemonStatus else { return (section.deviceID, ReportedRecord.unknown) }
                guard let generation = status.restorableSessions.first?.generation else { return (section.deviceID, ReportedRecord.noRecord) }
                return (section.deviceID, ReportedRecord.generation(generation))
            }, uniquingKeysWith: { first, _ in first })
    }

    /// Re-runs the check when the window's current sheet ends, so an offer blocked by an unrelated sheet
    /// is raised as soon as the window is free. Nothing else would raise it: a remote device is
    /// stream-driven and may report nothing again for hours.
    private func waitForTheWindowToPresentTheOffer() {
        guard windowSheetObserver == nil, let window = host.window else { return }
        windowSheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopWaitingForTheWindow()
                self.maybePresentOfferSheet()
            }
        }
    }

    private func stopWaitingForTheWindow() {
        guard let windowSheetObserver else { return }
        NotificationCenter.default.removeObserver(windowSheetObserver)
        self.windowSheetObserver = nil
    }

    /// The sessions whose panes have to outlive the catalogs right now.
    ///
    /// Derived from state rather than accumulated by hold and release calls, because every bug in this
    /// area is a missing release or a missing hold: a record another client answered, or one the device
    /// replaced with a newer capture, drops out of this set by itself on the next status, and a record
    /// that arrives while some sheet owns the window is in it from the moment it is seen. The waiting
    /// pairings are here too: between a Restore landing and the device reporting the new session, the
    /// predecessor's pane is what the restored agent is coming back to.
    /// The answer in flight is the third input because a record stops being reported the moment the device
    /// accepts the answer, while the pairings that take over the hold are only registered when the call
    /// returns. An overview applied in between (the restore call is a long lane, and a partial-failure
    /// dialog is longer) would otherwise recompute this set with the record already gone and no pairing
    /// yet, and prune the very panes the restored agents are coming back to.
    nonisolated static func heldSessionIDs(
        offer: SessionRestoreOffer?, inFlightAnswerOffer: SessionRestoreOffer?, pendingRetargets: [PendingRetarget]
    ) -> Set<String> {
        var held = Set(pendingRetargets.map(\.capturedSessionID))
        for offered in [offer, inFlightAnswerOffer] {
            guard let offered else { continue }
            held.formUnion(offered.devices.flatMap { $0.rows.map(\.sessionID) })
        }
        return held
    }

    /// Recomputes the whole hold set and assigns it. Called wherever the state it is derived from changes:
    /// a device's status arriving, an answer starting or finishing, a pairing being registered or claimed.
    func updateHeldPanes() { updateHeldPanes(offer: currentOffer()) }

    private func updateHeldPanes(offer: SessionRestoreOffer?) {
        host.panelCoordinator.setPanesHeldForRestoreOffer(
            Self.heldSessionIDs(offer: offer, inFlightAnswerOffer: inFlightAnswerOffer, pendingRetargets: Array(pendingRetargets.values)))
    }

    /// What every known device is offering right now, or nil when there is nothing outstanding.
    private func currentOffer() -> SessionRestoreOffer? {
        guard let devices = currentOfferInputs() else { return nil }
        return SessionRestoreOffer.make(devices: devices)
    }

    /// Every device on screen as offer input, or nil when no device reports a record at all.
    ///
    /// The nil short circuit comes before reading the answered records from disk: this runs on every
    /// overview apply for every device, and the steady state is that nothing is offering anything.
    private func currentOfferInputs() -> [SessionRestoreOffer.DeviceInput]? {
        guard host.deviceModel.deviceSections.contains(where: { !($0.daemonStatus?.restorableSessions.isEmpty ?? true) }) else { return nil }
        let answered = answeredGenerations()
        return host.deviceModel.deviceSections.map { section in
            SessionRestoreOffer.DeviceInput(
                deviceID: section.deviceID, deviceName: section.displayName, status: section.daemonStatus,
                workspaceNamesByID: Dictionary(
                    (section.overview?.workspaces ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
                answeredGeneration: answered[section.deviceID])
        }
    }

    /// The offer to raise once a sheet closes, given what the devices report by then.
    ///
    /// A record that arrived while the sheet was up (another device, or a newer capture on the same one)
    /// has to be raised here: a remote device is stream-driven and may report nothing further for a long
    /// time, so waiting for the next status refresh can hide an outstanding offer indefinitely.
    ///
    /// What is never raised again is exactly the records the closing sheet already put in front of the
    /// user, named by `presentedGenerations` as one generation per device. A device that refused the
    /// answer keeps reporting its record, and re-presenting it the instant the sheet closes would put
    /// the user in a loop they cannot leave; it is offered again on that device's next status refresh.
    /// Suppression is per device and per generation rather than by comparing whole offers, so one
    /// device refusing cannot re-raise the records its neighbours answered, a workspace name arriving
    /// between the two computations cannot make the same record look new, and a genuinely newer capture
    /// on a device that was just offered is still raised at once.
    nonisolated static func queuedOffer(devices: [SessionRestoreOffer.DeviceInput], presentedGenerations: [String: String]) -> SessionRestoreOffer? {
        SessionRestoreOffer.make(
            devices: devices.map { device in
                guard let presented = presentedGenerations[device.deviceID] else { return device }
                return SessionRestoreOffer.DeviceInput(
                    deviceID: device.deviceID, deviceName: device.deviceName, status: device.status, workspaceNamesByID: device.workspaceNamesByID,
                    answeredGeneration: presented)
            })
    }

    /// Answers every device in an offer and puts the restored sessions back in their panes. Runs the
    /// device calls off the main actor: Restore relaunches each agent on the device, which is a
    /// long-running lane, and the surface stays on screen reporting progress until it is done.
    @discardableResult func answer(_ answer: SessionRestoreAnswer, offer: SessionRestoreOffer, panePlacement: PanePlacement) async -> AnswerCompletion
    {
        var failureMessages: [String] = []
        // Holds the offered panes for the length of the call, whatever any overview arriving meanwhile
        // makes of the record. See `heldSessionIDs`.
        inFlightAnswerOffer = offer
        updateHeldPanes()
        for device in offer.devices {
            // The offer was built from a status the device may have replaced since: a daemon can be
            // updated while the sheet or the launch step is on screen. Answering across that skew would
            // let the device relaunch the agents and clear its record while this client cannot read what
            // came back, so every answer is preceded by a fresh status read and only a compatible one
            // lets the answer go out. A read that fails or times out is not permission either: the record
            // stays outstanding and is offered again once the device answers.
            guard let status = await probedDaemonStatus(deviceID: device.deviceID) else {
                failureMessages.append(
                    AppKitController.deviceUnreachableError(
                        deviceName: device.deviceName, isLocal: device.deviceID == SpacesPairedDeviceRecord.localDeviceID
                    ).localizedDescription)
                continue
            }
            if let message = DaemonCompatibilityCopy.actionBlockedBody(
                deviceName: device.deviceName, verdict: SpacesWireCompatibility.evaluate(daemonStatus: status))
            {
                failureMessages.append(message)
                continue
            }
            // The stored pairing record is the one source for a device's endpoint and credentials, and it
            // is current in both moments this runs: at launch the setup flow's probe has just bootstrapped
            // the local device into it, and while the app is running every device on screen has one. Its
            // absence is an answer that cannot be delivered, which is the user's to see.
            guard let record = try? host.clientDatabase().pairedDevice(id: device.deviceID) else {
                failureMessages.append(host.deviceUnavailableError(deviceID: device.deviceID).localizedDescription)
                continue
            }
            let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
            let generation = device.generation
            let outcome = await Task.detached(priority: .userInitiated) {
                let context = DeviceRequestContext(device: record, profile: profile)
                return Self.performAnswer(
                    answer, generation: generation, restore: { try SpacesDeviceClient.restoreSessions(generation: $0, context: context) },
                    discard: { try SpacesDeviceClient.discardRestorableSessions(generation: $0, context: context) })
            }.value
            let disposition = Self.disposition(for: outcome)
            if let failureMessage = disposition.failureMessage {
                // The panes stay held and the record stays unanswered: the agents are still on the device,
                // the surface stays up carrying the message, and the user can try again or Skip instead.
                failureMessages.append(failureMessage)
                continue
            }
            if disposition.recordsGeneration { recordAnsweredGeneration(deviceID: device.deviceID, generation: generation) }
            guard case .answered(let restored) = outcome else { continue }
            // Said out loud rather than logged: the user asked for these agents back, the device reported
            // success, and without this the ones that failed simply never appear.
            if let report = Self.restoreFailureReport(restored.failures, device: device) { reportRestoreFailures(report) }
            let restoredSessionIDsByCapturedSessionID = restored.newSessionIDsByCapturedSessionID
            guard !restoredSessionIDsByCapturedSessionID.isEmpty else { continue }
            // The pairing of predecessor to restored session lives here, in the client that answered, and
            // nowhere else: the daemon returns it once and keeps no record of it. Accepted: another Mac
            // watching the same device, or this one relaunched before the overview reports the new
            // sessions, sees the record disappear and the sessions arrive unrelated, so it closes the
            // predecessors as ended sessions and shows the restored agents as new ones. Persisting the
            // pairing on the daemon would be a history of answers it has no other use for, kept for a
            // second Mac on one daemon, which is not how Spaces is used.
            switch panePlacement {
            case .persistedLayouts:
                host.retargetPersistedPanesForRestoredSessions(
                    device: device, restoredSessionIDsByCapturedSessionID: restoredSessionIDsByCapturedSessionID)
            case .livePanes: awaitReportedSessions(device: device, restoredSessionIDsByCapturedSessionID: restoredSessionIDsByCapturedSessionID)
            }
        }
        // The answers just recorded and the pairings just registered are what the hold set is derived
        // from from here on: an answered record stops holding its panes, a restored session's predecessor
        // starts, and a device that refused the answer keeps reporting the record that holds its own.
        inFlightAnswerOffer = nil
        updateHeldPanes()
        // Every answer from the running app asks for a refresh, not just one with panes waiting on it. The
        // restore call answers with the new session ids alone, so the summaries the waiting panes need
        // arrive only with a fresh overview; and a Skip has just released panes whose sessions are gone,
        // which nothing closes until the next authoritative overview prunes them. The launch flow asks for
        // nothing: the workspace UI has not been built yet and loads for itself moments later.
        if panePlacement == .livePanes { host.requestSidebarReload(forceRemoteRefresh: true) }
        return failureMessages.isEmpty ? .complete : .failed(message: failureMessages.joined(separator: "\n"))
    }

    /// The status the answer is judged against, read from the device now.
    ///
    /// One read for both surfaces, and never the section's cached copy. A cached status is as old as the
    /// offer itself, which is the thing in doubt, and the launch step has no section at all, so preferring
    /// the cache would be a check the sheet does and the launch step skips. This is also the one moment a
    /// round-trip is worth its cost: it happens once per device per answer, immediately before a call that
    /// relaunches every agent on the record. Bounded by the same probe timeout the launch's own status
    /// read uses, and nil when the device does not answer in time.
    private func probedDaemonStatus(deviceID: String) async -> TerminalServiceDaemonStatus? {
        if let probe = daemonStatusProbeOverrideForTesting { return probe(deviceID) }
        guard let record = try? host.clientDatabase().pairedDevice(id: deviceID) else { return nil }
        let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
        let read = Task.detached(priority: .userInitiated) { () -> TerminalServiceDaemonStatus? in
            try? SpacesDeviceClient.daemonStatus(context: DeviceRequestContext(device: record, profile: profile))
        }
        return await LaunchProbeWait(
            description: "the restore answer's version check", deadline: ContinuousClock.now.advanced(by: SetupFlowController.localProbeTimeout),
            task: read
        ).value()
    }

    // MARK: - Reporting what could not come back

    /// What to tell the user about the rows a device could not relaunch, or nil when everything came back.
    ///
    /// The device clears its record whatever the relaunches did, so this report is the only word the user
    /// gets: a row that failed because its workspace is gone would fail the same way on every attempt, and
    /// keeping it in the record would offer it again forever.
    ///
    /// Each line is the offer's own row, found by session id, followed by the workspace the list grouped it
    /// under and the device's reason. Worded from the row rather than from anything the device sends, so
    /// the line reads like the entry the user just answered and two sessions of the same agent kind in one
    /// workspace are still told apart.
    nonisolated static func restoreFailureReport(_ failures: [SpacesDeviceRestoredSessionFailure], device: SessionRestoreOffer.DeviceOffer) -> String?
    {
        guard !failures.isEmpty else { return nil }
        let linesBySessionID = Dictionary(
            device.groups.flatMap { group in group.rows.map { ($0.sessionID, "\($0.displayLabel) in \(group.heading)") } },
            uniquingKeysWith: { first, _ in first })
        return failures.map { failure in
            // A failure for a row this offer does not list can only come from a record captured after the
            // surface was built, which the device's own title is the one description of.
            "\(linesBySessionID[failure.sessionID] ?? failure.title): \(failure.message)"
        }.joined(separator: "\n")
    }

    private func reportRestoreFailures(_ report: String) {
        let alert = NSAlert()
        alert.messageText = "Some sessions could not be restored"
        alert.informativeText = report
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Claiming the pane once the device reports the restored session

    /// A restored session whose predecessor's pane is waiting to be handed over.
    struct PendingRetarget: Equatable {
        let deviceID: String
        /// The workspace the captured session belonged to, which is where its pane lives.
        let workspaceID: String
        let capturedSessionID: String
        let restoredSessionID: String
    }

    /// How long a restored session has to turn up in its device's overview before its predecessor's pane
    /// stops waiting for it. The device reports within a refresh of the answer (the local daemon posts its
    /// change notification, a remote pushes on its stream), so this is a bound on a session that never
    /// arrives at all, not a duration anything normally spends. When it elapses the pane is released to
    /// ordinary pruning, which closes it: the session it was keeping a seat for never came.
    static let reportedSessionWindow: Duration = .seconds(30)

    /// Restored sessions waiting on their device to report them, keyed by the restored session id.
    private var pendingRetargets: [String: PendingRetarget] = [:]

    /// Waits for each restored session to be reported rather than claiming its predecessor's pane now,
    /// and answers with the captured sessions whose holds must stay in place for that wait.
    ///
    /// The claim cannot run at answer time. `restoreSessions` returns as soon as the daemon has launched
    /// the sessions, and the device's overview does not carry them yet; a request built from the offer row
    /// alone has no shell and no command, and a pane opened on one degrades into an "unavailable" pane
    /// that never retries. A session's launch configuration lives in the overview and nowhere else, so the
    /// pane waits for the summary and is built from it, exactly as a restart's replacement is.
    func awaitReportedSessions(device: SessionRestoreOffer.DeviceOffer, restoredSessionIDsByCapturedSessionID: [String: String]) {
        var awaited: Set<String> = []
        for row in device.rows {
            guard let restoredSessionID = restoredSessionIDsByCapturedSessionID[row.sessionID] else { continue }
            pendingRetargets[restoredSessionID] = PendingRetarget(
                deviceID: device.deviceID, workspaceID: row.workspaceID, capturedSessionID: row.sessionID, restoredSessionID: restoredSessionID)
            awaited.insert(restoredSessionID)
        }
        guard !awaited.isEmpty else { return }
        // The wait may already be over before it starts: an overview carrying the new sessions can land
        // between the daemon launching them and this registration (an answer that stopped to report its
        // partial failures is long enough), and that overview is then the last one the device sends,
        // because the refresh the answer asks for comes back byte-identical and is dropped as unchanged.
        if let installed = host.deviceSection(id: device.deviceID)?.overview {
            claimPanesForReportedSessions(deviceID: device.deviceID, overview: installed)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.reportedSessionWindow)
            self?.stopAwaitingReportedSessions(restoredSessionIDs: awaited)
        }
    }

    /// Hands over the panes this device's fresh overview has made claimable. Called from the one place
    /// every authoritative overview install passes through, so a restored session is claimed by whichever
    /// refresh first carries it (the answer's own, a poll, or a remote device's stream push).
    func claimPanesForReportedSessions(deviceID: String, overview: SpacesDeviceOverviewPayload) {
        let ready = Self.retargetsReadyToClaim(Array(pendingRetargets.values), deviceID: deviceID, overview: overview)
        guard !ready.isEmpty else { return }
        for retarget in ready {
            pendingRetargets[retarget.restoredSessionID] = nil
            if let request = AppKitController.deviceTerminalOpenRequest(
                workspaceID: retarget.workspaceID, sessionID: retarget.restoredSessionID, overview: overview)
            {
                host.panelCoordinator.retargetPaneForReplacement(replacedSessionID: retarget.capturedSessionID, request: request)
            }
        }
        // The pane now carries the restored session, which every keep-set from here on names, so the
        // predecessor drops out of the hold set this recomputes.
        updateHeldPanes()
    }

    /// Which waiting restored sessions this overview can hand a pane to: the ones this device reports.
    /// A summary is what carries the launch configuration a pane needs, so its arrival is the event the
    /// claim waits for.
    nonisolated static func retargetsReadyToClaim(_ pending: [PendingRetarget], deviceID: String, overview: SpacesDeviceOverviewPayload)
        -> [PendingRetarget]
    {
        let reported = Set(overview.sessions.map(\.id))
        return pending.filter { $0.deviceID == deviceID && reported.contains($0.restoredSessionID) }
    }

    /// Gives up on restored sessions their device never reported, so the panes that were waiting for them
    /// prune like any other pane whose session is gone.
    ///
    /// The prune has to be run here rather than left to the next overview. What brings this wait to its
    /// timeout is a device that has gone quiet (a remote stream that stopped delivering, a daemon that
    /// never came back), which is exactly the case where no further overview arrives to carry the prune,
    /// and the pane would sit there showing a session that ended. Pruning against the overview the app
    /// currently holds needs no epoch check the way the apply sites do: that overview is the newest one
    /// installed for the device, so nothing claimed since can be missing from its keep-set.
    func stopAwaitingReportedSessions(restoredSessionIDs: Set<String>) {
        let abandoned = restoredSessionIDs.compactMap { pendingRetargets.removeValue(forKey: $0) }
        guard !abandoned.isEmpty else { return }
        NSLog("Spaces: restored sessions were never reported by their device, releasing the panes held for them")
        updateHeldPanes()
        for deviceID in Set(abandoned.map(\.deviceID)) {
            // A device with no overview installed has no authoritative catalog to prune against, and its
            // panes are pruned by the first overview it does deliver.
            guard let overview = host.deviceSection(id: deviceID)?.overview else { continue }
            host.panelCoordinator.pruneOpenPanes(
                deviceID: deviceID, catalogSessionIDs: OpenPanePruning.referencedTerminalSessionIDs(overview: overview))
        }
    }

    // MARK: - Sheet

    /// Internal rather than private so a test can put a sheet up without the whole workspace UI behind it.
    func presentSheet(offer: SessionRestoreOffer) {
        guard let window = host.window else { return }
        sheetOffer = offer
        let view = SessionRestoreOfferView(offer: offer, host: host) { [weak self] answer in self?.answerSheet(answer, offer: offer) }
        sheetView = view
        // Sized to hold the offer at its tallest: the list stops growing at
        // `SessionRestoreOfferView.maximumListHeight` and scrolls beyond it, so this fits any record.
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        sheet.contentView = view.view
        sheetWindow = sheet
        window.beginSheet(sheet) { [weak self] _ in
            // Nothing to do when this sheet was already taken down by `endOfferSheet`, which cleared the
            // state and raised the next offer at that moment; running again here would raise it twice.
            guard let self, self.sheetWindow === sheet else { return }
            self.sheetWindow = nil
            self.sheetView = nil
            self.sheetOffer = nil
            self.presentQueuedOffer(after: offer)
        }
    }

    /// Raises whatever is still outstanding once a sheet closes. See `queuedOffer` for why this cannot
    /// wait for the next status refresh, and why the records that sheet showed are not candidates.
    private func presentQueuedOffer(after presented: SessionRestoreOffer) {
        guard host.setupFlowController == nil, sheetOffer == nil, host.window?.attachedSheet == nil, let devices = currentOfferInputs(),
            let queued = Self.queuedOffer(
                devices: devices, presentedGenerations: Dictionary(uniqueKeysWithValues: presented.devices.map { ($0.deviceID, $0.generation) }))
        else { return }
        presentSheet(offer: queued)
    }

    private func answerSheet(_ answer: SessionRestoreAnswer, offer: SessionRestoreOffer) {
        sheetView?.showAnswerInProgress(answer == .restore ? "Restoring..." : "Discarding...")
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A failed answer leaves the sheet up carrying the reason: the agents are still on the device,
            // and closing on a failure would report an answer the user never got.
            if case .failed(let message) = await self.answer(answer, offer: offer, panePlacement: .livePanes) {
                self.sheetView?.showAnswerFailed(message)
                return
            }
            if let sheet = self.sheetWindow { self.host.window?.endSheet(sheet) }
        }
    }

    // MARK: - Answered records

    private func answeredGenerations() -> [String: String] {
        SessionRestoreAnsweredGenerations.decode(try? host.clientDatabase().setting(key: ClientSettingsKey.sessionRestoreAnsweredGenerations))
    }

    /// Remembers that this client answered a device's record, so the same record is not offered again on
    /// the next status refresh. Written only after the device accepted the answer: a device that refused
    /// still has its record, and the user has not been given what they asked for.
    private func recordAnsweredGeneration(deviceID: String, generation: String) {
        guard let database = try? host.clientDatabase() else { return }
        let updated = SessionRestoreAnsweredGenerations.recording(answeredGenerations(), deviceID: deviceID, generation: generation)
        try? database.setSetting(key: ClientSettingsKey.sessionRestoreAnsweredGenerations, value: SessionRestoreAnsweredGenerations.encode(updated))
    }
}

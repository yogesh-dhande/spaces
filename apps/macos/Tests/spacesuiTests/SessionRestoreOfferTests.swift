import Foundation
import Testing
import spacesclientcore
import spacesdevicecore

@testable import spacesterminalcore
@testable import spacesui

/// The restore offer's decisions: what a set of device statuses is offering, how the list reads, what
/// each answer sends, and how a restored session finds its predecessor's pane.
@Suite struct SessionRestoreOfferTests {
    private func summary(
        sessionID: String, workspaceID: String = "ws-1", agentKind: TerminalDetectedAgentKind? = .claudeCode, title: String = "Fix the parser",
        workingDirectory: String = "/repos/spaces-fix", hasResumeKey: Bool = true, generation: String = "gen-1"
    ) -> RestorableSessionSummary {
        RestorableSessionSummary(
            sessionID: sessionID, workspaceID: workspaceID, agentKind: agentKind, title: title, workingDirectory: workingDirectory,
            hasResumeKey: hasResumeKey, generation: generation)
    }

    private func status(_ restorables: [RestorableSessionSummary]) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, restorableSessions: restorables)
    }

    private func localInput(_ status: TerminalServiceDaemonStatus?, workspaceNamesByID: [String: String] = [:], answeredGeneration: String? = nil)
        -> SessionRestoreOffer.DeviceInput
    {
        .init(
            deviceID: "local", deviceName: "This Mac", status: status, workspaceNamesByID: workspaceNamesByID, answeredGeneration: answeredGeneration)
    }

    // MARK: - What is on offer

    /// The steady state: every device is running normally and nothing was left behind, so no surface is
    /// put in front of the user at all.
    @Test func nothingIsOfferedWhenNoDeviceReportsARecord() { #expect(SessionRestoreOffer.make(devices: [localInput(status([]))]) == nil) }

    /// A device that has not reported cannot be offering anything, so an offline or not-yet-handshaken
    /// device is silent rather than treated as empty or as stale.
    @Test func aDeviceThatHasNotReportedOffersNothing() { #expect(SessionRestoreOffer.make(devices: [localInput(nil)]) == nil) }

    /// The shape the launch step asks in: This Mac alone, reporting a record this client has not seen.
    @Test func aReportedRecordIsOffered() throws {
        let offer = try #require(SessionRestoreOffer.make(devices: [localInput(status([summary(sessionID: "s-1")]))]))

        #expect(offer.devices.map(\.deviceID) == ["local"])
        #expect(offer.devices[0].generation == "gen-1")
        #expect(offer.devices[0].rows.map(\.sessionID) == ["s-1"])
        #expect(offer.rowCount == 1)
        // One device needs no device headings in the list.
        #expect(!offer.namesDevices)
    }

    /// A record crosses a release skew that the answer does not: it rides the daemon status, which any
    /// daemon version answers, while `restoreSessions` is a versioned command. Answering an older daemon
    /// would relaunch the agents and clear the record on the device while this client could not read what
    /// came back, so a device is silent until the two speak the same wire version.
    @Test func aDeviceOnADifferentWireVersionOffersNothingUntilItCatchesUp() throws {
        let reported = [summary(sessionID: "s-1")]
        let older = TerminalServiceDaemonStatus(
            version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
            protocolVersion: SpacesWireProtocol.version - 1, restorableSessions: reported)

        #expect(SessionRestoreOffer.make(devices: [localInput(older)]) == nil)

        // The same device once its daemon is updated: the record was never lost, and the status refresh
        // that reports the new daemon offers it.
        let offer = try #require(SessionRestoreOffer.make(devices: [localInput(status(reported))]))
        #expect(offer.rowCount == 1)
    }

    /// The daemon keeps its record until a client answers and re-reports it on every status refresh, so
    /// the answer this client already made is what stops it being asked again.
    @Test func aRecordThisClientAnsweredIsNotOfferedAgain() {
        let reported = status([summary(sessionID: "s-1", generation: "gen-1")])

        #expect(SessionRestoreOffer.make(devices: [localInput(reported, answeredGeneration: "gen-1")]) == nil)
    }

    /// Answering one record says nothing about the next one: a later capture carries its own generation
    /// and is offered even though its predecessor was answered.
    @Test func aLaterRecordIsOfferedAfterAnEarlierOneWasAnswered() throws {
        let reported = status([summary(sessionID: "s-2", generation: "gen-2")])

        let offer = try #require(SessionRestoreOffer.make(devices: [localInput(reported, answeredGeneration: "gen-1")]))

        #expect(offer.devices[0].generation == "gen-2")
    }

    /// Each device answers for its own record, so two devices reporting at once are one offer with two
    /// generations in it, and the list names them.
    @Test func eachDeviceOffersItsOwnRecord() throws {
        let offer = try #require(
            SessionRestoreOffer.make(devices: [
                localInput(status([summary(sessionID: "s-1", generation: "gen-1")])),
                .init(
                    deviceID: "remote", deviceName: "build-box",
                    status: status([summary(sessionID: "s-2", workspaceID: "ws-2", generation: "gen-9")]), answeredGeneration: nil),
            ]))

        #expect(offer.devices.map(\.deviceID) == ["local", "remote"])
        #expect(offer.devices.map(\.generation) == ["gen-1", "gen-9"])
        #expect(offer.rowCount == 2)
        #expect(offer.namesDevices)
    }

    /// A device the user already answered drops out of an offer the other device still carries.
    @Test func onlyTheDevicesWithAnUnansweredRecordAreOffered() throws {
        let offer = try #require(
            SessionRestoreOffer.make(devices: [
                localInput(status([summary(sessionID: "s-1", generation: "gen-1")]), answeredGeneration: "gen-1"),
                .init(
                    deviceID: "remote", deviceName: "build-box", status: status([summary(sessionID: "s-2", generation: "gen-9")]),
                    answeredGeneration: nil),
            ]))

        #expect(offer.devices.map(\.deviceID) == ["remote"])
        #expect(!offer.namesDevices)
    }

    // MARK: - How the list reads

    @Test func rowsAreGroupedByWorkspaceInTheOrderTheDeviceReportedThem() throws {
        let offer = try #require(
            SessionRestoreOffer.make(devices: [
                localInput(
                    status([
                        summary(sessionID: "s-1", workspaceID: "ws-1"), summary(sessionID: "s-2", workspaceID: "ws-2"),
                        summary(sessionID: "s-3", workspaceID: "ws-1"),
                    ]), workspaceNamesByID: ["ws-1": "fix-parser", "ws-2": "docs"])
            ]))

        let groups = offer.devices[0].groups
        #expect(groups.map(\.heading) == ["fix-parser", "docs"])
        #expect(groups.map { $0.rows.map(\.sessionID) } == [["s-1", "s-3"], ["s-2"]])
        #expect(groups[0].rows.allSatisfy { $0.workspaceID == "ws-1" })
    }

    /// The launch step runs before any overview is loaded, so it has no workspace catalog to name a
    /// group with. The group is headed by its sessions' working directory instead, which is what the
    /// user recognizes the work by.
    @Test func aGroupIsHeadedByItsWorkingDirectoryWhenTheWorkspaceCatalogIsNotLoaded() throws {
        let offer = try #require(
            SessionRestoreOffer.make(devices: [
                localInput(status([summary(sessionID: "s-1", workspaceID: "ws-1", workingDirectory: "/repos/spaces-fix")]))
            ]))

        #expect(offer.devices[0].groups.map(\.heading) == ["/repos/spaces-fix"])
    }

    /// An agent that never reported a conversation id cannot be resumed, only relaunched. The list says
    /// so, because it changes what the user gets back.
    @Test func aRowWithoutAResumeKeyStartsANewConversation() throws {
        let offer = try #require(
            SessionRestoreOffer.make(devices: [
                localInput(
                    status([summary(sessionID: "s-1", hasResumeKey: true), summary(sessionID: "s-2", agentKind: .codex, hasResumeKey: false)]))
            ]))

        let rows = offer.devices[0].rows
        #expect(rows.map(\.startsNewConversation) == [false, true])
        #expect(rows.map(\.agentLabel) == ["claude-code", "codex"])
    }

    /// Detection does not always name an agent, and a row that carries no kind still restores; the list
    /// simply has no agent name to show for it.
    @Test func aRowWithNoDetectedAgentCarriesNoAgentLabel() throws {
        let offer = try #require(SessionRestoreOffer.make(devices: [localInput(status([summary(sessionID: "s-1", agentKind: nil)]))]))

        #expect(offer.devices[0].rows[0].agentLabel == nil)
    }

    /// A session Spaces started for a coding agent is titled after that agent, so wording the row as
    /// "<agent>: <title>" would name it twice ("opencode: opencode"). A row whose title says something of
    /// its own keeps both halves.
    @Test func aRowTitledAfterItsOwnAgentIsNamedOnce() throws {
        let offer = try #require(
            SessionRestoreOffer.make(devices: [
                localInput(
                    status([
                        summary(sessionID: "s-1", agentKind: .opencode, title: "opencode"),
                        summary(sessionID: "s-2", agentKind: .claudeCode, title: "Fix the parser"),
                    ]))
            ]))

        #expect(offer.devices[0].rows.map(\.displayLabel) == ["opencode", "claude-code: Fix the parser"])
    }

    /// What the row shows under its name. A group the client has no workspace name for is headed by its
    /// first row's working directory, and repeating that directory on every row of the group says nothing;
    /// a group headed by a workspace name keeps the directory, which is the row's own fact.
    @Test func aRowCaptionIsDroppedWhenItOnlyRepeatsItsGroupHeading() throws {
        let offer = try #require(
            SessionRestoreOffer.make(devices: [
                localInput(status([summary(sessionID: "s-1", workingDirectory: "/repos/spaces-fix")]), workspaceNamesByID: ["ws-1": "fix-parser"])
            ]))
        let row = offer.devices[0].rows[0]

        #expect(SessionRestoreOfferView.rowCaption(row, groupHeading: "fix-parser") == "/repos/spaces-fix")
        #expect(SessionRestoreOfferView.rowCaption(row, groupHeading: "/repos/spaces-fix") == nil)
    }

    // MARK: - Answering

    @Test func restoreRelaunchesTheRecordAndReportsWhereEachSessionLanded() {
        var restoredGenerations: [String] = []
        var discardedGenerations: [String] = []

        let outcome = SessionRestoreController.performAnswer(
            .restore, generation: "gen-1",
            restore: { generation in
                restoredGenerations.append(generation)
                return .init(newSessionIDsByCapturedSessionID: ["s-1": "s-1-restored"])
            }, discard: { discardedGenerations.append($0) })

        #expect(outcome == .answered(.init(newSessionIDsByCapturedSessionID: ["s-1": "s-1-restored"])))
        #expect(restoredGenerations == ["gen-1"])
        #expect(discardedGenerations.isEmpty)
    }

    @Test func skipDiscardsTheRecordAndRestoresNothing() {
        var restoredGenerations: [String] = []
        var discardedGenerations: [String] = []

        let outcome = SessionRestoreController.performAnswer(
            .skip, generation: "gen-1",
            restore: { generation in
                restoredGenerations.append(generation)
                return .init(newSessionIDsByCapturedSessionID: [:])
            }, discard: { discardedGenerations.append($0) })

        #expect(outcome == .answered(.init(newSessionIDsByCapturedSessionID: [:])))
        #expect(discardedGenerations == ["gen-1"])
        #expect(restoredGenerations.isEmpty)
    }

    /// A device that could not be reached leaves the answer unmade, and the error it gave is what the
    /// surface shows: the user asked for their agents back and has not got them.
    @Test func anAnswerTheDeviceCouldNotTakeCarriesItsReason() {
        struct Unreachable: LocalizedError { var errorDescription: String? { "build-box is not reachable." } }

        let outcome = SessionRestoreController.performAnswer(
            .restore, generation: "gen-old", restore: { _ in throw Unreachable() }, discard: { _ in throw Unreachable() })

        #expect(outcome == .failed(message: "build-box is not reachable."))
    }

    // MARK: - When the sheet can be put up

    /// The window can be busy with something else entirely (a settings dialog, a confirmation), and only
    /// one sheet attaches to a window. The offer waits for it rather than being dropped: a remote device
    /// may report nothing again for hours, so a dropped offer is a lost one.
    @Test func anOfferBlockedByAnotherSheetWaitsForTheWindowAndIsThenPresented() {
        let blocked = SessionRestoreController.offerPresentation(
            isMainWindowContentBuilt: true, hasLaunchSetupFlow: false, isShowingOffer: false, hasOtherSheet: true)

        #expect(blocked == .waitForTheWindow)
        // What the sheet-ended signal re-runs, with the window now free.
        #expect(
            SessionRestoreController.offerPresentation(
                isMainWindowContentBuilt: true, hasLaunchSetupFlow: false, isShowingOffer: false, hasOtherSheet: false) == .present)
    }

    /// The two cases that belong to another surface entirely: the launch step owns the offer until the
    /// workspace UI exists, and an offer already on screen is the one being answered.
    @Test func anOfferAnotherSurfaceOwnsIsLeftAlone() {
        #expect(
            SessionRestoreController.offerPresentation(
                isMainWindowContentBuilt: false, hasLaunchSetupFlow: true, isShowingOffer: false, hasOtherSheet: false) == .notThisSurface)
        #expect(
            SessionRestoreController.offerPresentation(
                isMainWindowContentBuilt: true, hasLaunchSetupFlow: false, isShowingOffer: true, hasOtherSheet: false) == .notThisSurface)
    }

    // MARK: - Which panes are held

    /// The hold set is derived from what is outstanding, not accumulated as offers come and go: every row
    /// of every record this client can still answer, plus the predecessors of restored sessions that
    /// their device has not reported yet.
    @Test func everyRowOfAnOutstandingRecordIsHeldAlongWithEveryPairingStillWaiting() throws {
        let offer = try #require(SessionRestoreOffer.make(devices: [localInput(status([summary(sessionID: "s-1"), summary(sessionID: "s-2")]))]))
        let waiting = SessionRestoreController.PendingRetarget(
            deviceID: "local", workspaceID: "ws-1", capturedSessionID: "s-0", restoredSessionID: "s-0-restored")

        #expect(
            SessionRestoreController.heldSessionIDs(offer: offer, inFlightAnswerOffer: nil, pendingRetargets: [waiting]) == ["s-1", "s-2", "s-0"])
    }

    /// And the reason it is derived: a record another client answered, or one the device replaced, stops
    /// being part of the offer and so stops holding anything, with no release call to forget.
    @Test func aRecordThatIsNoLongerOutstandingHoldsNothing() {
        #expect(SessionRestoreController.heldSessionIDs(offer: nil, inFlightAnswerOffer: nil, pendingRetargets: []).isEmpty)
    }

    /// The gap the in-flight offer closes: a device clears its record as it accepts the answer, so an
    /// overview applied while the restore call is still running reports nothing outstanding, and the
    /// pairings that will hold these panes are not registered until the call returns. Without the answer
    /// being an input, that overview would prune the predecessors mid-restore.
    @Test func theOfferBeingAnsweredHoldsItsPanesUntilItsPairingsTakeOver() throws {
        let offer = try #require(SessionRestoreOffer.make(devices: [localInput(status([summary(sessionID: "s-1"), summary(sessionID: "s-2")]))]))

        #expect(SessionRestoreController.heldSessionIDs(offer: nil, inFlightAnswerOffer: offer, pendingRetargets: []) == ["s-1", "s-2"])

        let pairings = [
            SessionRestoreController.PendingRetarget(deviceID: "local", workspaceID: "ws-1", capturedSessionID: "s-1", restoredSessionID: "s-1-new"),
            SessionRestoreController.PendingRetarget(deviceID: "local", workspaceID: "ws-1", capturedSessionID: "s-2", restoredSessionID: "s-2-new"),
        ]
        #expect(SessionRestoreController.heldSessionIDs(offer: nil, inFlightAnswerOffer: nil, pendingRetargets: pairings) == ["s-1", "s-2"])
    }

    // MARK: - A sheet whose record is gone

    /// A sheet asks about the record the device reported when it went up, and that record can be settled
    /// by somebody else: another client answers it, or the device captures again. Both leave the question
    /// on screen asking about something that no longer exists, so the sheet comes down instead of waiting
    /// for the user to click it and be told it is stale.
    @Test func aSheetIsSupersededOnceNoDeviceStillReportsWhatItIsAsking() throws {
        let presented = try #require(SessionRestoreOffer.make(devices: [localInput(status([summary(sessionID: "s-1")]))]))

        #expect(
            SessionRestoreController.sheetIsSuperseded(presented: presented, reported: ["local": .noRecord]),
            "the device answered and holds nothing, so somebody settled this question")
        #expect(
            SessionRestoreController.sheetIsSuperseded(presented: presented, reported: ["local": .generation("gen-2")]),
            "a device that captured again holds a different record, not this one")
        #expect(
            !SessionRestoreController.sheetIsSuperseded(presented: presented, reported: ["local": .generation("gen-1")]),
            "the record is still the one on the device")
    }

    /// A device Spaces cannot read right now still holds the record the sheet is asking about: it dropped
    /// off, or it is being updated. Silence is not an answer, so the question stays up rather than being
    /// taken away from a user who can still answer it once the device is back.
    @Test func aSheetStandsWhileItsDeviceSaysNothing() throws {
        let presented = try #require(SessionRestoreOffer.make(devices: [localInput(status([summary(sessionID: "s-1")]))]))

        #expect(!SessionRestoreController.sheetIsSuperseded(presented: presented, reported: ["local": .unknown]))
        #expect(!SessionRestoreController.sheetIsSuperseded(presented: presented, reported: [:]), "a device with no section at all says nothing")
    }

    /// Per device, so one device settling its record cannot take down a sheet that is still asking about
    /// another device's, and a second device starting to report one does not make the sheet stale either.
    @Test func aSheetStandsWhileAnyOneOfItsRecordsIsStillOutstanding() throws {
        let presented = try #require(
            SessionRestoreOffer.make(devices: [localInput(status([summary(sessionID: "s-1")])), remote(status([summary(sessionID: "s-2")]))]))

        #expect(!SessionRestoreController.sheetIsSuperseded(presented: presented, reported: ["local": .noRecord, "remote": .generation("gen-1")]))
    }

    // MARK: - What each outcome means

    /// An answer that never landed leaves everything as it was: the generation is not recorded, so the
    /// device's record is offered again, and the surface stays up carrying the reason instead of closing
    /// as though the question had been settled.
    @Test func anAnswerThatNeverLandedRecordsNothingAndIsReported() {
        let disposition = SessionRestoreController.disposition(for: .failed(message: "build-box is not reachable."))

        #expect(!disposition.recordsGeneration)
        #expect(disposition.failureMessage == "build-box is not reachable.")
    }

    /// A device refusing the generation is not a failure to retry: it captured again, or another client
    /// answered first. Nothing is recorded (the record on the device is a different one) and nothing is
    /// reported, so the surface closes and the newer record is offered in its place.
    @Test func aRefusalOnTheRecordsIdentityIsNotAnErrorToShow() {
        let outcome = SessionRestoreController.performAnswer(
            .restore, generation: "gen-old",
            restore: { _ in
                throw SpacesDeviceClientError.requestRejected(
                    message: "These sessions have been replaced by a newer record; reload and answer that one.", code: .conflict)
            }, discard: { _ in })

        #expect(outcome == .superseded)
        let disposition = SessionRestoreController.disposition(for: outcome)
        #expect(!disposition.recordsGeneration, "the record this named is gone, and the one that replaced it is unanswered")
        #expect(disposition.failureMessage == nil)
    }

    /// And the answer that did land is the only one the client remembers.
    @Test func onlyAnAcceptedAnswerIsRemembered() {
        let disposition = SessionRestoreController.disposition(for: .answered(.init(newSessionIDsByCapturedSessionID: ["s-1": "s-1-restored"])))

        #expect(disposition.recordsGeneration)
        #expect(disposition.failureMessage == nil)
    }

    // MARK: - Rows that could not come back

    /// A Restore the device answered with only some of the agents relaunched. The record is cleared
    /// either way, so this report is the user's only word about the ones that are not coming: it names
    /// each row the way the list just named it, the workspace it was grouped under, and the device's
    /// reason. Two sessions of the same agent kind in one workspace are the case that decides the
    /// wording: named by kind alone they would produce two lines the user cannot tell apart.
    @Test func aPartlyRestoredRecordIsReportedRowByRow() throws {
        let offer = try #require(
            SessionRestoreOffer.make(devices: [
                localInput(
                    status([
                        summary(sessionID: "s-1", title: "Fix the parser"), summary(sessionID: "s-2", title: "Write the migration"),
                        summary(sessionID: "s-3", workspaceID: "ws-2", agentKind: nil, title: "Untitled"),
                    ]), workspaceNamesByID: ["ws-1": "spaces-fix", "ws-2": "spaces-docs"])
            ]))

        let report = SessionRestoreController.restoreFailureReport(
            [
                .init(sessionID: "s-1", title: "Fix the parser", message: "That workspace no longer exists."),
                .init(sessionID: "s-2", title: "Write the migration", message: "That workspace no longer exists."),
                .init(sessionID: "s-3", title: "Untitled", message: "The workspace could not be started."),
            ], device: offer.devices[0])

        #expect(
            report == """
                claude-code: Fix the parser in spaces-fix: That workspace no longer exists.
                claude-code: Write the migration in spaces-fix: That workspace no longer exists.
                Untitled in spaces-docs: The workspace could not be started.
                """)
    }

    /// The ordinary answer says nothing: every agent came back, and a dialog reporting that would be one
    /// more thing to dismiss on the way into the app.
    @Test func aFullyRestoredRecordIsReportedNowhere() throws {
        let offer = try #require(SessionRestoreOffer.make(devices: [localInput(status([summary(sessionID: "s-1")]))]))

        #expect(SessionRestoreController.restoreFailureReport([], device: offer.devices[0]) == nil)
    }

    // MARK: - What is still outstanding when the sheet closes

    private func remote(_ status: TerminalServiceDaemonStatus?, answeredGeneration: String? = nil) -> SessionRestoreOffer.DeviceInput {
        .init(deviceID: "remote", deviceName: "build-box", status: status, answeredGeneration: answeredGeneration)
    }

    /// A device that starts reporting while the sheet is up has to be offered the moment it closes. A
    /// remote device is stream-driven and may report nothing else for hours, so leaving it to the next
    /// status refresh hides a record indefinitely.
    @Test func aRecordThatArrivedWhileTheSheetWasUpIsOfferedNext() throws {
        let arrived = remote(status([summary(sessionID: "s-2", generation: "gen-9")]))

        let queued = try #require(
            SessionRestoreController.queuedOffer(
                devices: [localInput(nil, answeredGeneration: "gen-1"), arrived], presentedGenerations: ["local": "gen-1"]))

        #expect(queued.devices.map(\.deviceID) == ["remote"])
    }

    /// The records the closing sheet showed are not raised again. A device that refused the answer still
    /// reports its record, and re-presenting it immediately would leave the user no way out of the sheet.
    @Test func theRecordsJustPresentedAreNotRaisedAgainImmediately() {
        let reported = status([summary(sessionID: "s-1")])

        #expect(SessionRestoreController.queuedOffer(devices: [localInput(reported)], presentedGenerations: ["local": "gen-1"]) == nil)
    }

    /// The suppression is per device and per generation, not a comparison of whole offers. One device
    /// refusing its answer while another accepts changes the recomputed offer, and an offer comparison
    /// would read that difference as something new and reopen the sheet on the record the user just
    /// declined.
    @Test func oneDeviceRefusingItsAnswerDoesNotReopenTheSheet() {
        // The Mac refused and still reports; the build box accepted, so its record is gone.
        let devices = [localInput(status([summary(sessionID: "s-1")])), remote(status([]))]

        #expect(SessionRestoreController.queuedOffer(devices: devices, presentedGenerations: ["local": "gen-1", "remote": "gen-9"]) == nil)
    }

    /// Nor does the suppression outlive the record it names: a device that captured again while the sheet
    /// was up is offering something the user has not seen, and it is raised at once.
    @Test func aNewerCaptureOnAJustOfferedDeviceIsRaisedAtOnce() throws {
        let recaptured = localInput(status([summary(sessionID: "s-2", generation: "gen-2")]))

        let queued = try #require(SessionRestoreController.queuedOffer(devices: [recaptured], presentedGenerations: ["local": "gen-1"]))

        #expect(queued.devices[0].generation == "gen-2")
    }

    /// A group heading that only became available between the two computations is not a new record. The
    /// sheet's own offer had no workspace catalog for the device; the recomputed one does, so every
    /// heading differs while the record behind it is the same.
    @Test func aWorkspaceNameArrivingLaterDoesNotReopenTheSheet() {
        let named = localInput(status([summary(sessionID: "s-1")]), workspaceNamesByID: ["ws-1": "spaces-fix"])

        #expect(SessionRestoreController.queuedOffer(devices: [named], presentedGenerations: ["local": "gen-1"]) == nil)
    }

    // MARK: - Remembering what was answered

    @Test func answeredRecordsAreRememberedPerDevice() {
        var generations = SessionRestoreAnsweredGenerations.recording([:], deviceID: "local", generation: "gen-1")
        generations = SessionRestoreAnsweredGenerations.recording(generations, deviceID: "remote", generation: "gen-9")

        let stored = SessionRestoreAnsweredGenerations.encode(generations)

        #expect(SessionRestoreAnsweredGenerations.decode(stored) == ["local": "gen-1", "remote": "gen-9"])
    }

    /// Only the record a device is currently offering can be answered, so a device's entry is replaced
    /// rather than accumulated.
    @Test func aDevicesLaterAnswerReplacesItsEarlierOne() {
        let generations = SessionRestoreAnsweredGenerations.recording(
            SessionRestoreAnsweredGenerations.recording([:], deviceID: "local", generation: "gen-1"), deviceID: "local", generation: "gen-2")

        #expect(generations == ["local": "gen-2"])
    }

    @Test func nothingRememberedReadsAsNothingAnswered() {
        #expect(SessionRestoreAnsweredGenerations.decode(nil).isEmpty)
        #expect(SessionRestoreAnsweredGenerations.decode("not json").isEmpty)
    }

    // MARK: - Landing in the old pane

    private func layoutJSON(sessionIDs: [String]) throws -> String {
        var layout = PanelLayout()
        for (index, sessionID) in sessionIDs.enumerated() {
            layout = PanelLayoutEngine.appendTab(
                tabID: "tab-\(index)", pane: Pane(id: "pane-\(index)", content: .terminalSession(deviceID: "local", sessionID: sessionID)), to: layout
            )
        }
        return String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
    }

    /// A restored session takes over the pane its predecessor held: same pane id, same tab, and the
    /// panel's other panes untouched.
    @Test func aRestoredSessionTakesItsPredecessorsPersistedPane() throws {
        let stored = try layoutJSON(sessionIDs: ["s-1", "s-2"])

        let retargeted = try #require(
            AppKitController.retargetedLayoutJSON(stored, replacing: "s-1", with: .terminalSession(deviceID: "local", sessionID: "s-1-restored")))
        let layout = try JSONDecoder().decode(PanelLayout.self, from: Data(retargeted.utf8))

        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: layout) == ["s-1-restored", "s-2"])
        #expect(PanelLayoutEngine.allPanes(in: layout).map(\.id) == ["pane-0", "pane-1"])
    }

    /// A captured session whose pane is not in this layout leaves it alone, so the caller can ask each
    /// stored layout in turn and land the session in whichever one holds its pane.
    @Test func aLayoutWithoutThePredecessorsPaneIsLeftAlone() throws {
        let stored = try layoutJSON(sessionIDs: ["s-2"])

        #expect(
            AppKitController.retargetedLayoutJSON(stored, replacing: "s-1", with: .terminalSession(deviceID: "local", sessionID: "s-1-restored"))
                == nil)
    }
}

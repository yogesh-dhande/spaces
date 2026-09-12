#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// Collects the generations an answer discarded from inside the answer's `@Sendable` closure, which
    /// cannot capture a mutable local.
    private actor RequestRecorder {
        private var requests: [SpacesDeviceAPIRequest] = []

        func append(_ request: SpacesDeviceAPIRequest) { requests.append(request) }
        func snapshot() -> [SpacesDeviceAPIRequest] { requests }
    }

    /// Holds every request it is asked about until `open()`, so a test can keep one overview fetch in
    /// flight while it drives the model, then let it finish.
    private actor RequestGate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }
    }

    private actor GenerationRecorder {
        private var values: [String] = []

        func append(_ generation: String) { values.append(generation) }
        var recorded: [String] { values }
    }

    /// The restore offer this app makes for the device it is connected to: what it lists, when it says
    /// there is nothing to ask about, and what each answer to it means.
    final class SessionRestoreOfferTests: XCTestCase {

        // MARK: - What the offer lists

        func testListsCapturedSessionsGroupedByWorkspaceUnderTheirWorkspaceNames() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio",
                    status: makeStatus(sessions: [
                        makeSummary(sessionID: "s1", workspaceID: "workspace-a", agentKind: .claudeCode, title: "Fix the parser"),
                        makeSummary(sessionID: "s2", workspaceID: "workspace-b", agentKind: .codex, title: "Port the lane"),
                        makeSummary(sessionID: "s3", workspaceID: "workspace-a", agentKind: .opencode, title: "Write the docs"),
                    ]), workspaceNamesByID: ["workspace-a": "parser-fix", "workspace-b": "lane-port"], answeredGeneration: nil))

            XCTAssertEqual(offer.groups.map(\.heading), ["parser-fix", "lane-port"])
            XCTAssertEqual(offer.groups.map { $0.rows.map(\.sessionID) }, [["s1", "s3"], ["s2"]])
            XCTAssertEqual(offer.generation, "capture-1")
        }

        /// A row is named by the agent that ran it and what it was working on, which is how the report of
        /// what could not be restored names it too.
        func testRowIsLabelledByItsAgentAndTitle() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio",
                    status: makeStatus(sessions: [makeSummary(sessionID: "s1", agentKind: .claudeCode, title: "Fix the parser")]),
                    answeredGeneration: nil))

            XCTAssertEqual(offer.groups.first?.rows.first?.displayLabel, "claude-code: Fix the parser")
        }

        /// Spaces titles the session it starts for an agent after that agent, so naming both would read
        /// "opencode: opencode". Nothing is said twice.
        func testARowTitledAfterItsOwnAgentIsNamedOnce() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio",
                    status: makeStatus(sessions: [makeSummary(sessionID: "s1", agentKind: .opencode, title: "opencode")]), answeredGeneration: nil))

            XCTAssertEqual(offer.groups.first?.rows.first?.displayLabel, "opencode")
        }

        /// Detection never named an agent for this session, so the row is its title alone rather than a
        /// label with an empty kind in front of it.
        func testRowWithoutADetectedAgentIsLabelledByItsTitleAlone() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio",
                    status: makeStatus(sessions: [makeSummary(sessionID: "s1", agentKind: nil, title: "Coding Agent")]), answeredGeneration: nil))

            XCTAssertEqual(offer.groups.first?.rows.first?.displayLabel, "Coding Agent")
        }

        /// The agent reported no conversation id, so restoring runs its command afresh. The list has to
        /// say so: it changes what the user gets back.
        func testRowWithoutAResumableConversationIsMarkedAsStartingANewOne() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio",
                    status: makeStatus(sessions: [
                        makeSummary(sessionID: "s1", hasResumeKey: true), makeSummary(sessionID: "s2", hasResumeKey: false),
                    ]), answeredGeneration: nil))

            XCTAssertEqual(offer.groups.flatMap(\.rows).map(\.startsNewConversation), [false, true])
        }

        /// A record can be reported by the first status of a reconnect, before any overview has named the
        /// device's workspaces. The group still has to be headed by something the user recognizes.
        func testGroupIsHeadedByItsWorkingDirectoryWhenNoWorkspaceNameIsKnown() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio",
                    status: makeStatus(sessions: [makeSummary(sessionID: "s1", workspaceID: "workspace-a", workingDirectory: "/repo/parser-fix")]),
                    answeredGeneration: nil))

            XCTAssertEqual(offer.groups.map(\.heading), ["/repo/parser-fix"])
        }

        // MARK: - When there is nothing to ask about

        func testNoOfferWhenTheDeviceReportsNoRecord() {
            XCTAssertNil(
                SessionRestoreOffer.make(deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: []), answeredGeneration: nil))
        }

        func testNoOfferWhenTheDeviceHasNotReportedYet() {
            XCTAssertNil(SessionRestoreOffer.make(deviceID: "device-1", deviceName: "Studio", status: nil, answeredGeneration: nil))
        }

        /// The device keeps re-reporting its record until some client answers it, so the record this
        /// client already answered must not be raised again on the next refresh.
        func testNoOfferForARecordThisClientAlreadyAnswered() {
            XCTAssertNil(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: [makeSummary(sessionID: "s1")]),
                    answeredGeneration: "capture-1"))
        }

        /// Work cut short again before the offer was answered is a different record, and the user has not
        /// been asked about it.
        func testACaptureNewerThanTheAnsweredOneIsOffered() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: [makeSummary(sessionID: "s1", generation: "capture-2")]),
                    answeredGeneration: "capture-1"))

            XCTAssertEqual(offer.generation, "capture-2")
            XCTAssertEqual(offer.id, "device-1/capture-2")
        }

        /// The record rides the frozen core of the daemon status, so it is readable across a version gap
        /// the answer cannot cross: answering would let the device relaunch the agents and clear its
        /// record while this app could not read what came back.
        func testNoOfferFromADeviceOnADifferentWireVersion() {
            XCTAssertNil(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio",
                    status: makeStatus(sessions: [makeSummary(sessionID: "s1")], protocolVersion: SpacesWireProtocol.version + 1),
                    answeredGeneration: nil))
        }

        // MARK: - Keeping a question that is already on screen

        /// The status fetch failed, or a device switch has not landed yet. Neither says anything about the
        /// record, and withdrawing the question on them would dismiss it with no answer given.
        func testAQuestionOnScreenSurvivesADeviceThatHasNotReported() throws {
            let presented = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: [makeSummary(sessionID: "s1")]), answeredGeneration: nil)
            )

            XCTAssertTrue(SessionRestoreOffer.retainsPresentedOffer(presented: presented, status: nil))
        }

        /// The daemon was updated while the question was on screen. The sheet is where that gap is
        /// reported, so it stays and the answer says why it cannot be given.
        func testAQuestionOnScreenSurvivesADeviceOnADifferentWireVersion() throws {
            let presented = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: [makeSummary(sessionID: "s1")]), answeredGeneration: nil)
            )

            XCTAssertTrue(
                SessionRestoreOffer.retainsPresentedOffer(
                    presented: presented,
                    status: makeStatus(sessions: [makeSummary(sessionID: "s1")], protocolVersion: SpacesWireProtocol.version + 1)))
        }

        func testAQuestionOnScreenSurvivesTheSameRecordBeingReportedAgain() throws {
            let presented = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: [makeSummary(sessionID: "s1")]), answeredGeneration: nil)
            )

            XCTAssertTrue(
                SessionRestoreOffer.retainsPresentedOffer(presented: presented, status: makeStatus(sessions: [makeSummary(sessionID: "s1")])))
        }

        /// Someone answered the record, on this device or from another client. The agents it was about are
        /// decided, so the question goes.
        func testAQuestionOnScreenIsRetiredWhenTheDeviceReportsNoRecord() throws {
            let presented = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: [makeSummary(sessionID: "s1")]), answeredGeneration: nil)
            )

            XCTAssertFalse(SessionRestoreOffer.retainsPresentedOffer(presented: presented, status: makeStatus(sessions: [])))
        }

        func testAQuestionOnScreenIsRetiredWhenTheDeviceReportsADifferentRecord() throws {
            let presented = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: [makeSummary(sessionID: "s1")]), answeredGeneration: nil)
            )

            XCTAssertFalse(
                SessionRestoreOffer.retainsPresentedOffer(
                    presented: presented, status: makeStatus(sessions: [makeSummary(sessionID: "s2", generation: "capture-2")])))
        }

        // MARK: - Answering

        func testRestoreReportsWhatTheDeviceBroughtBack() async {
            let result = SpacesDeviceRestoredSessionsResult(newSessionIDsByCapturedSessionID: ["s1": "s1-new"])
            let outcome = await SessionRestoreAnswering.perform(
                .restore, generation: "capture-1",
                restore: { generation in
                    XCTAssertEqual(generation, "capture-1")
                    return result
                }, discard: { _ in XCTFail("Restore must not discard the record.") })

            XCTAssertEqual(outcome, .answered(result))
            XCTAssertEqual(SessionRestoreAnswering.disposition(for: outcome), .init(recordsGeneration: true, failureMessage: nil))
        }

        func testSkipDiscardsTheRecordItWasShownFor() async {
            let discarded = GenerationRecorder()
            let outcome = await SessionRestoreAnswering.perform(
                .skip, generation: "capture-1",
                restore: { _ in
                    XCTFail("Skip must not relaunch anything.")
                    return .init(newSessionIDsByCapturedSessionID: [:])
                }, discard: { await discarded.append($0) })

            let recorded = await discarded.recorded
            XCTAssertEqual(recorded, ["capture-1"])
            XCTAssertEqual(outcome, .answered(.init(newSessionIDsByCapturedSessionID: [:])))
        }

        /// The device captured again, or another client answered first. Nothing is wrong and nothing is
        /// remembered: whatever the device holds now is offered afresh.
        func testARefusalOnTheRecordsIdentityIsNotAFailure() async {
            let outcome = await SessionRestoreAnswering.perform(
                .restore, generation: "capture-1",
                restore: { _ in throw SpacesDeviceAPIClientError.requestFailed("That record is gone.", code: .conflict) }, discard: { _ in })

            XCTAssertEqual(outcome, .superseded)
            XCTAssertEqual(SessionRestoreAnswering.disposition(for: outcome), .init(recordsGeneration: false, failureMessage: nil))
        }

        /// The agents are still waiting on the device, so the answer is not remembered and the user is
        /// told why, with the offer still on screen to try again or skip instead.
        func testAnAnswerThatNeverLandedRemembersNothingAndReportsWhy() async {
            let outcome = await SessionRestoreAnswering.perform(
                .restore, generation: "capture-1", restore: { _ in throw SpacesDeviceAPIClientError.requestTimedOut }, discard: { _ in })

            XCTAssertEqual(SessionRestoreAnswering.disposition(for: outcome).recordsGeneration, false)
            XCTAssertEqual(
                SessionRestoreAnswering.disposition(for: outcome).failureMessage, SpacesDeviceAPIClientError.requestTimedOut.localizedDescription)
        }

        /// Pairing is the only way through an answer the device will not authenticate, so the outcome keeps
        /// that classification instead of flattening it into a message the sheet would offer to retry.
        func testAnAnswerTheDeviceWillNotAuthenticateIsClassifiedAsSuch() async {
            let outcome = await SessionRestoreAnswering.perform(
                .restore, generation: "capture-1",
                restore: { _ in throw SpacesDeviceAPIClientError.requestFailed("Device is not paired.", code: .unauthorized) }, discard: { _ in })

            guard case .unauthenticated(let recoveryMessage) = outcome else {
                XCTFail("Expected an authentication outcome, got \(outcome).")
                return
            }
            XCTAssertEqual(
                recoveryMessage, SpacesDeviceAPIAuthentication.recoveryMessage(for: SpacesDeviceAPIClientError.transportAuthenticationFailed))
            // Nothing to remember (the device never read the answer) and nothing to say in the sheet: the
            // sheet comes down so the recovery surface it covers is reachable.
            XCTAssertEqual(SessionRestoreAnswering.disposition(for: outcome), .init(recordsGeneration: false, failureMessage: nil))
        }

        // MARK: - What reaches the device

        func testRestoreNamesTheRecordAndReadsWhatCameBack() async throws {
            let recorder = RequestRecorder()
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(
                    ok: true, message: "ok",
                    result: .restoredSessions(
                        .init(
                            newSessionIDsByCapturedSessionID: ["s1": "s1-new"],
                            failures: [SpacesDeviceRestoredSessionFailure(sessionID: "s2", title: "Agent", message: "The workspace is gone.")])))
            }

            let result = try await client.restoreSessions(generation: "capture-1")

            XCTAssertEqual(result.newSessionIDsByCapturedSessionID, ["s1": "s1-new"])
            XCTAssertEqual(result.failures.map(\.sessionID), ["s2"])
            guard case .restoreSessions(let payload)? = await recorder.snapshot().first?.command else {
                XCTFail("Expected a restoreSessions request.")
                return
            }
            XCTAssertEqual(payload.generation, "capture-1")
        }

        func testSkipNamesTheRecordItDiscards() async throws {
            let recorder = RequestRecorder()
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }

            try await client.discardRestorableSessions(generation: "capture-1")

            guard case .discardRestorableSessions(let payload)? = await recorder.snapshot().first?.command else {
                XCTFail("Expected a discardRestorableSessions request.")
                return
            }
            XCTAssertEqual(payload.generation, "capture-1")
        }

        /// The daemon refuses an answer naming a record it no longer holds, and the client hands that
        /// refusal on as the coded error the answer reads as superseded rather than as a failure.
        func testARefusedAnswerThrowsTheDevicesCode() async {
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { _ in
                SpacesDeviceAPIResponse(ok: false, message: "That record is gone.", errorCode: .conflict)
            }

            do {
                _ = try await client.restoreSessions(generation: "capture-1")
                XCTFail("Expected the refusal to throw.")
            } catch { XCTAssertEqual((error as? any SpacesDeviceErrorCodeProviding)?.spacesDeviceErrorCode, .conflict) }
        }

        // MARK: - Reporting what could not come back

        func testEachFailedRowIsNamedTheWayTheListNamedIt() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio",
                    status: makeStatus(sessions: [
                        makeSummary(sessionID: "s1", workspaceID: "workspace-a", agentKind: .claudeCode, title: "Fix the parser"),
                        makeSummary(sessionID: "s2", workspaceID: "workspace-a", agentKind: .claudeCode, title: "Write the docs"),
                    ]), workspaceNamesByID: ["workspace-a": "parser-fix"], answeredGeneration: nil))

            let report = SessionRestoreAnswering.failureReport(
                [SpacesDeviceRestoredSessionFailure(sessionID: "s2", title: "Write the docs", message: "The workspace is gone.")], offer: offer)

            XCTAssertEqual(report, "claude-code: Write the docs in parser-fix: The workspace is gone.")
        }

        /// A failure for a row this offer does not list can only come from a record captured after the
        /// sheet was built, and the device's own title is the one description of it.
        func testAFailedRowTheOfferNeverListedIsNamedByTheDevicesTitle() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: [makeSummary(sessionID: "s1")]), answeredGeneration: nil)
            )

            let report = SessionRestoreAnswering.failureReport(
                [SpacesDeviceRestoredSessionFailure(sessionID: "other", title: "Some agent", message: "The workspace is gone.")], offer: offer)

            XCTAssertEqual(report, "Some agent: The workspace is gone.")
        }

        func testNothingIsReportedWhenEveryAgentCameBack() throws {
            let offer = try XCTUnwrap(
                SessionRestoreOffer.make(
                    deviceID: "device-1", deviceName: "Studio", status: makeStatus(sessions: [makeSummary(sessionID: "s1")]), answeredGeneration: nil)
            )

            XCTAssertNil(SessionRestoreAnswering.failureReport([], offer: offer))
        }

        // MARK: - Remembering what was answered

        func testAnAnsweredRecordIsRememberedPerDevice() throws {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "spaces.mobile.tests.session-restore-\(UUID().uuidString)"))

            XCTAssertNil(SessionRestoreAnsweredGenerationsStore.generation(deviceID: "device-1", defaults: defaults))

            SessionRestoreAnsweredGenerationsStore.record(generation: "capture-1", deviceID: "device-1", defaults: defaults)
            SessionRestoreAnsweredGenerationsStore.record(generation: "capture-9", deviceID: "device-2", defaults: defaults)

            XCTAssertEqual(SessionRestoreAnsweredGenerationsStore.generation(deviceID: "device-1", defaults: defaults), "capture-1")
            XCTAssertEqual(SessionRestoreAnsweredGenerationsStore.generation(deviceID: "device-2", defaults: defaults), "capture-9")

            // Only the record a device is currently offering can be answered, so a device's entry is
            // replaced rather than accumulated.
            SessionRestoreAnsweredGenerationsStore.record(generation: "capture-2", deviceID: "device-1", defaults: defaults)

            XCTAssertEqual(SessionRestoreAnsweredGenerationsStore.generation(deviceID: "device-1", defaults: defaults), "capture-2")
        }

        // MARK: - The device the app is connected to

        /// The trigger: the device reports its record on the daemon status, and every status this app
        /// installs raises or retires the offer without any screen asking for it.
        @MainActor func testAStatusThatStartsReportingARecordRaisesTheOffer() {
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") })
            model.activeDeviceID = "device-1"
            // Unique per run, so an entry left in this simulator's defaults by an earlier run cannot
            // suppress the offer under test.
            let generation = "capture-\(UUID().uuidString)"

            XCTAssertNil(model.sessionRestoreOffer)

            model.daemonStatus = makeStatus(sessions: [makeSummary(sessionID: "s1", title: "Fix the parser", generation: generation)])

            XCTAssertEqual(model.sessionRestoreOffer?.groups.flatMap(\.rows).map(\.title), ["Fix the parser"])

            // The device answered to some client, so it stops reporting the record and the question goes
            // with it.
            model.daemonStatus = makeStatus(sessions: [])

            XCTAssertNil(model.sessionRestoreOffer)
        }

        /// The offer was built from a status the device may have replaced since, so the answer asks the
        /// device what it is running before it changes anything there.
        @MainActor func testAnAnswerReadsTheDevicesVersionBeforeItSendsTheAnswer() async throws {
            let recorder = RequestRecorder()
            let generation = "capture-\(UUID().uuidString)"
            let status = makeStatus(sessions: [makeSummary(sessionID: "s1", generation: generation)])
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { request in
                    await recorder.append(request)
                    switch request.commandName {
                    case "daemonStatus": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(status))
                    case "restoreSessions":
                        return SpacesDeviceAPIResponse(
                            ok: true, message: "ok", result: .restoredSessions(.init(newSessionIDsByCapturedSessionID: ["s1": "s1-new"])))
                    default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                    }
                })
            model.activeDeviceID = "device-1"
            model.daemonStatus = status
            let offer = try XCTUnwrap(model.sessionRestoreOffer)

            let message = await model.answerSessionRestoreOffer(.restore, offer: offer)

            XCTAssertNil(message)
            let commands = await recorder.snapshot().map(\.commandName)
            let statusIndex = try XCTUnwrap(commands.firstIndex(of: "daemonStatus"))
            let restoreIndex = try XCTUnwrap(commands.firstIndex(of: "restoreSessions"))
            XCTAssertLessThan(statusIndex, restoreIndex, "the version check runs before anything changes on the device")
        }

        /// The daemon was updated while the sheet was up, so it is no longer on this app's wire version.
        /// Answering across that skew would let it relaunch the agents and clear its record while this app
        /// cannot read what came back, so nothing is sent and the record stays outstanding.
        @MainActor func testADeviceOnAnotherWireVersionIsToldSoInsteadOfAnswered() async throws {
            let recorder = RequestRecorder()
            let generation = "capture-\(UUID().uuidString)"
            let status = makeStatus(sessions: [makeSummary(sessionID: "s1", generation: generation)])
            let updatedStatus = makeStatus(
                sessions: [makeSummary(sessionID: "s1", generation: generation)], protocolVersion: SpacesWireProtocol.version + 1)
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { request in
                    await recorder.append(request)
                    guard request.commandName == "daemonStatus" else { return SpacesDeviceAPIResponse(ok: true, message: "ok") }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(updatedStatus))
                })
            model.activeDeviceID = "device-1"
            model.daemonStatus = status
            let offer = try XCTUnwrap(model.sessionRestoreOffer)

            let message = await model.answerSessionRestoreOffer(.restore, offer: offer)

            XCTAssertNotNil(message, "the version gap is reported in the sheet the user is looking at")
            let commands = await recorder.snapshot().map(\.commandName)
            XCTAssertFalse(commands.contains("restoreSessions"), "nothing is sent to a device this app cannot read the answer from")
            XCTAssertEqual(model.sessionRestoreOffer?.generation, generation, "the record is still outstanding and still on screen")
            XCTAssertNotEqual(SessionRestoreAnsweredGenerationsStore.generation(deviceID: "device-1"), generation)
        }

        /// The check itself never answered, which is not permission: the record is untouched on a device
        /// this app could not reach, and the sheet says so and stays up.
        @MainActor func testAVersionCheckThatNeverAnsweredReportsTheDeviceAsOffline() async throws {
            let recorder = RequestRecorder()
            let generation = "capture-\(UUID().uuidString)"
            let status = makeStatus(sessions: [makeSummary(sessionID: "s1", generation: generation)])
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { request in
                    await recorder.append(request)
                    throw SpacesDeviceAPIClientError.requestTimedOut
                })
            model.activeDeviceID = "device-1"
            model.daemonStatus = status
            let offer = try XCTUnwrap(model.sessionRestoreOffer)

            let message = await model.answerSessionRestoreOffer(.restore, offer: offer)

            XCTAssertEqual(message, "\(model.connectionSummary) is offline. Reconnect it and try again.")
            let commands = await recorder.snapshot().map(\.commandName)
            XCTAssertFalse(commands.contains("restoreSessions"))
            XCTAssertEqual(model.sessionRestoreOffer?.generation, generation, "the record stays outstanding")
            XCTAssertNotEqual(SessionRestoreAnsweredGenerationsStore.generation(deviceID: "device-1"), generation)
        }

        /// A device that refuses the answer has replaced the record the user was looking at, and it says so
        /// before its own status does. The question must go with the refusal, or the sheet would sit on a
        /// record its device has disowned until some poll happens to report a different one.
        @MainActor func testARefusedAnswerRetiresTheQuestionAndDoesNotRaiseTheSameRecordAgain() async throws {
            let generation = "capture-\(UUID().uuidString)"
            let staleStatus = makeStatus(sessions: [makeSummary(sessionID: "s1", generation: generation)])
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { request in
                    // The device's answer to an offer it has already replaced, and an overview that is
                    // still reporting the replaced record, which is what the refresh below reads. The
                    // version check every answer makes first is answered with the status the offer was
                    // built from: this device is reachable and on this app's version, it simply holds a
                    // different record.
                    if case .restoreSessions = request.command {
                        return SpacesDeviceAPIResponse(ok: false, message: "That record is gone.", errorCode: .conflict)
                    }
                    if request.commandName == "daemonStatus" {
                        return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(staleStatus))
                    }
                    return SpacesDeviceAPIResponse(
                        ok: true, message: "ok",
                        result: .overview(SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [], daemonStatus: staleStatus)))
                })
            model.activeDeviceID = "device-1"
            model.daemonStatus = staleStatus
            let offer = try XCTUnwrap(model.sessionRestoreOffer)

            let message = await model.answerSessionRestoreOffer(.restore, offer: offer)

            XCTAssertNil(message, "a refusal is not a failure to report")
            XCTAssertNil(model.sessionRestoreOffer, "the refused record must not be left on screen")

            // The device goes on reporting the record it refused an answer to until its own next capture
            // lands. None of those statuses may put the user back in the question it just refused.
            model.daemonStatus = staleStatus

            XCTAssertNil(model.sessionRestoreOffer)

            // The record that replaced it is a question the user has not been asked.
            model.daemonStatus = makeStatus(sessions: [makeSummary(sessionID: "s2", generation: "capture-\(UUID().uuidString)")])

            XCTAssertEqual(model.sessionRestoreOffer?.groups.flatMap(\.rows).map(\.sessionID), ["s2"])
        }

        /// The shell asks for one read of the device every time the app comes back to the foreground, which
        /// is what discovers a record made while it was away on a screen that polls nothing. The scene
        /// transition itself belongs to `RootTabView`'s SwiftUI environment and no unit test can deliver it;
        /// what is testable here is the property that makes asking for it free, which is that the read joins
        /// whatever fetch a tab's own poller already has in flight instead of issuing a second one.
        @MainActor func testARefreshIssuedWhileOneIsInFlightJoinsItInsteadOfFetchingAgain() async {
            let recorder = RequestRecorder()
            let overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [], daemonStatus: makeStatus(sessions: []))
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { request in
                    await recorder.append(request)
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                })

            let poll = Task { await model.refresh() }
            let foreground = Task { await model.refresh() }
            await poll.value
            await foreground.value

            let overviewFetches = await recorder.snapshot().filter { $0.commandName == "overview" }
            XCTAssertEqual(overviewFetches.count, 1)
        }

        /// The foreground read is issued after the same transition's endpoint reset, and the reset closes
        /// the shared command channel: a fetch from before it has had its connection pulled out from under
        /// it, so answering the resume with that fetch would return having read nothing. The resume issues
        /// its own request instead.
        @MainActor func testAForegroundResumeFetchesAgainInsteadOfJoiningTheFetchItsResetAborted() async {
            let recorder = RequestRecorder()
            let gate = RequestGate()
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "token"
            settings.certificateFingerprint = "SHA256:session-restore-foreground-read"
            let overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [], daemonStatus: makeStatus(sessions: []))
            let model = SpacesMobileAppModel(
                settings: settings,
                bridgeClient: SpacesDeviceAPIClient(settings: settings) { request in
                    await recorder.append(request)
                    await gate.hold()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                })

            // A poll's fetch, held open on the transport: this is the fetch the reset aborts.
            let poll = Task { await model.refresh() }
            while await recorder.snapshot().isEmpty { await Task.yield() }

            let resume = Task { await model.resumeFromBackground() }
            // Let the resume run its reset and reach its refresh while the fetch above is still held, so
            // what this asserts is the decision that refresh makes about an in-flight fetch rather than a
            // resume that happened to arrive after it finished.
            for _ in 0..<100 { await Task.yield() }
            // Let the held fetch finish, which is the point the resume's refresh decides whether that
            // fetch answered for it.
            await gate.open()
            await poll.value
            await resume.value

            let overviewFetches = await recorder.snapshot().filter { $0.commandName == "overview" }
            XCTAssertEqual(overviewFetches.count, 2, "the resume reads the device itself rather than joining the fetch its reset aborted")
        }

        /// A Restore is answered while a poll issued before it is still in flight, and that poll describes a
        /// device without the relaunched agents. The read the answer asks for issues its own request rather
        /// than being answered by that poll, which is what puts the relaunched sessions in the lists on a
        /// screen whose next poll is far away or never.
        @MainActor func testTheReadAfterARestoreFetchesAgainInsteadOfJoiningAPollFromBeforeTheAnswer() async throws {
            let recorder = RequestRecorder()
            let gate = RequestGate()
            let generation = "capture-\(UUID().uuidString)"
            let status = makeStatus(sessions: [makeSummary(sessionID: "s1", generation: generation)])
            let overview = SpacesDeviceOverviewPayload(projects: [], workspaces: [], sessions: [], daemonStatus: makeStatus(sessions: []))
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { request in
                    await recorder.append(request)
                    switch request.commandName {
                    case "daemonStatus": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(status))
                    case "overview":
                        await gate.hold()
                        return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                    default:
                        return SpacesDeviceAPIResponse(
                            ok: true, message: "ok", result: .restoredSessions(.init(newSessionIDsByCapturedSessionID: ["s1": "s1-new"])))
                    }
                })
            model.activeDeviceID = "device-1"
            model.daemonStatus = status
            let offer = try XCTUnwrap(model.sessionRestoreOffer)

            // A poll's fetch, held open on the transport: this is the overview that predates the answer.
            let poll = Task { await model.refresh() }
            while await recorder.snapshot().isEmpty { await Task.yield() }

            let answering = Task { await model.answerSessionRestoreOffer(.restore, offer: offer) }
            // Let the answer land and reach its read while the poll above is still held, so what this
            // asserts is the decision that read makes about an in-flight fetch.
            for _ in 0..<100 { await Task.yield() }
            await gate.open()
            _ = await answering.value
            await poll.value

            let overviewFetches = await recorder.snapshot().filter { $0.commandName == "overview" }
            XCTAssertEqual(overviewFetches.count, 2, "the answer reads the device itself rather than joining a poll that predates it")
        }

        /// The wiring of the rule above: a question on screen outlives a status this app could not read and
        /// one it cannot answer across, and goes when the device says the record is gone or names another.
        @MainActor func testAQuestionOnScreenOutlivesAFailedStatusAndGoesOnlyWhenTheDeviceSaysSo() {
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") })
            model.activeDeviceID = "device-1"
            let generation = "capture-\(UUID().uuidString)"
            model.daemonStatus = makeStatus(sessions: [makeSummary(sessionID: "s1", generation: generation)])
            XCTAssertEqual(model.sessionRestoreOffer?.generation, generation)

            // A status fetch that failed clears what this app knows about the device and says nothing about
            // the record.
            model.daemonStatus = nil

            XCTAssertEqual(model.sessionRestoreOffer?.generation, generation)

            // A daemon updated out from under the question keeps it too: the answer reports the version gap
            // in place, which it cannot do with the sheet withdrawn.
            model.daemonStatus = makeStatus(
                sessions: [makeSummary(sessionID: "s1", generation: generation)], protocolVersion: SpacesWireProtocol.version + 1)

            XCTAssertEqual(model.sessionRestoreOffer?.generation, generation)

            // Work cut short again replaces the question with the record that replaced it.
            let newerGeneration = "capture-\(UUID().uuidString)"
            model.daemonStatus = makeStatus(sessions: [makeSummary(sessionID: "s2", generation: newerGeneration)])

            XCTAssertEqual(model.sessionRestoreOffer?.generation, newerGeneration)

            // The device reporting no record at all is the record being answered, here or elsewhere.
            model.daemonStatus = makeStatus(sessions: [])

            XCTAssertNil(model.sessionRestoreOffer)
        }

        /// A status is a statement about the device it was read from. Switching devices moves the identity
        /// while the last status this app read is still the previous device's, so nothing about the device
        /// switched to may be derived from it: the next device's question is raised by its own status and
        /// by nothing else.
        @MainActor func testSwitchingDevicesRaisesNoQuestionUntilTheNextDeviceReportsItsOwn() {
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") })
            model.activeDeviceID = "device-a"
            let generationOnA = "capture-\(UUID().uuidString)"
            model.daemonStatus = makeStatus(sessions: [makeSummary(sessionID: "s1", generation: generationOnA)])
            XCTAssertEqual(model.sessionRestoreOffer?.deviceID, "device-a")

            // The switch itself: `selectDevice` clears the previous device's facts and moves the identity,
            // and every one of those assignments re-derives the question. None of them may pair this
            // identity with the sessions the other device reported.
            model.activeDeviceID = "device-b"

            XCTAssertNil(model.sessionRestoreOffer, "a question about one device cannot be asked about another")

            model.overview = nil

            XCTAssertNil(model.sessionRestoreOffer)

            // Device B's own status is what raises device B's question.
            let generationOnB = "capture-\(UUID().uuidString)"
            model.daemonStatus = makeStatus(sessions: [makeSummary(sessionID: "s2", generation: generationOnB)])

            XCTAssertEqual(model.sessionRestoreOffer?.deviceID, "device-b")
            XCTAssertEqual(model.sessionRestoreOffer?.generation, generationOnB)
            XCTAssertEqual(model.sessionRestoreOffer?.groups.flatMap(\.rows).map(\.sessionID), ["s2"])
        }

        /// The device stopped recognizing this app between raising the question and answering it. The sheet
        /// cannot be swiped away and it covers the re-pair the notice asks for, so the question is retired
        /// and the recovery surface raised; the record itself is untouched on the device.
        @MainActor func testAnAnswerTheDeviceWillNotAuthenticateRetiresTheQuestionAndAsksForPairing() async throws {
            let generation = "capture-\(UUID().uuidString)"
            let status = makeStatus(sessions: [makeSummary(sessionID: "s1", generation: generation)])
            let model = SpacesMobileAppModel(
                settings: SpacesMobileConnectionSettings(),
                bridgeClient: SpacesDeviceAPIClient(settings: .init()) { request in
                    if case .restoreSessions = request.command {
                        return SpacesDeviceAPIResponse(ok: false, message: "Device is not paired.", errorCode: .unauthorized)
                    }
                    // The version check every answer makes first still passes: the device revokes this
                    // app between the check and the answer it allowed.
                    if request.commandName == "daemonStatus" {
                        return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(status))
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                })
            model.activeDeviceID = "device-1"
            model.daemonStatus = status
            let offer = try XCTUnwrap(model.sessionRestoreOffer)

            let message = await model.answerSessionRestoreOffer(.restore, offer: offer)

            XCTAssertNil(message, "the sheet does not stay up asking to retry an answer only pairing again can land")
            XCTAssertNil(model.sessionRestoreOffer)
            XCTAssertNotNil(model.connectionNotice, "the re-pair notice is what the retired sheet uncovers")
            XCTAssertTrue(model.isShowingConnectionSettings)
            XCTAssertNotEqual(
                SessionRestoreAnsweredGenerationsStore.generation(deviceID: "device-1"), generation,
                "the device never read the answer, so nothing about this record is remembered")

            // The device goes on reporting the record it never got an answer to. It stays retired until the
            // user pairs again, rather than raising the same sheet over the recovery surface every poll.
            model.daemonStatus = status

            XCTAssertNil(model.sessionRestoreOffer)
        }

        // MARK: - Fixtures

        private func makeSummary(
            sessionID: String, workspaceID: String = "workspace-a", agentKind: TerminalDetectedAgentKind? = .claudeCode, title: String = "Agent",
            workingDirectory: String = "/repo/workspace-a", hasResumeKey: Bool = true, generation: String = "capture-1"
        ) -> RestorableSessionSummary {
            RestorableSessionSummary(
                sessionID: sessionID, workspaceID: workspaceID, agentKind: agentKind, title: title, workingDirectory: workingDirectory,
                hasResumeKey: hasResumeKey, generation: generation)
        }

        private func makeStatus(sessions: [RestorableSessionSummary], protocolVersion: Int = SpacesWireProtocol.version)
            -> TerminalServiceDaemonStatus
        {
            TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: protocolVersion,
                restorableSessions: sessions)
        }
    }
#endif

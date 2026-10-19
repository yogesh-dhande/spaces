import Foundation
import Testing
import spacesdevicecore

@testable import spacesdeviceapi

/// The notifier's behavior against a hand-advanced clock and a recording relay: what buzzes, what only moves
/// the badge, and how failures settle. No test waits on wall-clock time.
@Suite struct SpacesDevicePushNotifierTests {
    private let phone = "phone-1"

    private struct Harness {
        let notifier: SpacesDevicePushNotifier
        let scheduler = ManualPushScheduler()
        let relay = RecordingPushRelay()
        let registrations: InMemoryPushRegistrations

        init(notifyBlocked: Bool = true, notifyFinished: Bool = false) {
            registrations = InMemoryPushRegistrations([
                "phone-1": SpacesDevicePushRegistration(capability: "cap-1", notifyBlocked: notifyBlocked, notifyFinished: notifyFinished)
            ])
            let store = registrations
            notifier = SpacesDevicePushNotifier(
                relay: relay, scheduler: scheduler, relayDeviceID: "device-test", loadRegistrations: { try store.pushRegistrations() },
                clearRegistration: { installationID, capability in
                    _ = try? store.clearPushRegistration(forInstallationID: installationID, matchingCapability: capability)
                })
            notifier.start()
        }
    }

    private func waiting(_ ids: String...) -> SpacesDeviceOverviewPayload { PushOverviewFixture.overview(agents: ids.map { ($0, .waiting) }) }

    @Test func aNewWaitingAgentBuzzesOnceAfterTenSecondsAndMovesTheBadgeFirst() {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 1)
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 1)
        #expect(h.relay.reports.map(\.notify) == [false, false])
        #expect(h.relay.reports.last?.total == 1 && h.relay.reports.last?.blocked == 1)

        h.scheduler.advance(by: 8.9)
        #expect(h.relay.reports.count == 2)
        h.scheduler.advance(by: 0.2)
        #expect(h.relay.reports.count == 3)
        let buzz = h.relay.reports[2]
        #expect(buzz.notify && buzz.total == 1 && buzz.blocked == 1)

        h.scheduler.advance(by: 60)
        #expect(h.relay.reports.count == 3)
    }

    @Test func anAgentDismissedWithinTenSecondsOnlyMovesTheBadge() {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 1)
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 3)
        let key = PushOverviewFixture.agentKey("a", state: .waiting)
        h.notifier.overviewCommitted(PushOverviewFixture.overview(agents: [("a", .waiting)], dismissed: [key]))
        h.scheduler.advance(by: 60)
        #expect(h.relay.reports.map(\.notify) == [false, false, false])
        #expect(h.relay.reports.last?.total == 0)
    }

    @Test func anAgentThatStopsWaitingWithinTenSecondsDoesNotBuzz() {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 4)
        h.notifier.overviewCommitted(PushOverviewFixture.overview(agents: [("a", .spinning)]))
        h.scheduler.advance(by: 60)
        #expect(!h.relay.reports.contains { $0.notify })
    }

    @Test func blockedOffNeverBuzzesForAWaitingAgent() {
        let h = Harness(notifyBlocked: false)
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 60)
        #expect(!h.relay.reports.contains { $0.notify })
        #expect(h.relay.reports.last?.total == 1)
    }

    @Test func finishedOnBuzzesForANewDoneAgentAndOffDoesNot() {
        let on = Harness(notifyBlocked: false, notifyFinished: true)
        on.notifier.overviewCommitted(PushOverviewFixture.overview())
        on.notifier.overviewCommitted(PushOverviewFixture.overview(agents: [("a", .done)]))
        on.scheduler.advance(by: 11)
        #expect(on.relay.reports.last?.notify == true)
        #expect(on.relay.reports.last?.blocked == 0)

        let off = Harness(notifyBlocked: true, notifyFinished: false)
        off.notifier.overviewCommitted(PushOverviewFixture.overview())
        off.notifier.overviewCommitted(PushOverviewFixture.overview(agents: [("a", .done)]))
        off.scheduler.advance(by: 60)
        #expect(!off.relay.reports.contains { $0.notify })
    }

    @Test func severalPendingBuzzesCoalesceIntoOneReport() {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.notifier.overviewCommitted(waiting("a", "b"))
        h.scheduler.advance(by: 60)
        #expect(h.relay.reports.filter(\.notify).count == 1)
        #expect(h.relay.reports.last?.total == 2)
    }

    @Test func aRestartSeedsFromItsFirstOverviewAndNeverBuzzesForExistingAlerts() {
        let h = Harness()
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 60)
        #expect(h.relay.reports.map(\.notify) == [false])
        #expect(h.relay.reports[0].total == 1)

        h.notifier.stop()
        h.notifier.start()
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 60)
        #expect(h.relay.reports.map(\.notify) == [false, false])
    }

    @Test func aHiddenWorkspaceShownAgainOnlyMovesTheBadge() {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview(agents: [("a", .waiting)], workspaceHidden: true))
        h.scheduler.advance(by: 2)
        #expect(h.relay.reports.last?.total == 0)

        h.notifier.overviewCommitted(PushOverviewFixture.overview(agents: [("a", .waiting)]))
        h.scheduler.advance(by: 60)
        #expect(!h.relay.reports.contains { $0.notify })
        #expect(h.relay.reports.last?.total == 1 && h.relay.reports.last?.blocked == 1)
    }

    @Test func aRegistrationThatArrivesBeforeAnyOverviewGetsItsResyncOnceTheSeedLands() throws {
        let h = Harness()
        h.notifier.registrationsChanged()
        h.scheduler.advance(by: 5)
        #expect(h.relay.requests.isEmpty)

        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 2)
        #expect(h.relay.reports.map(\.notify) == [false])
        #expect(h.relay.reports.last?.total == 1)
    }

    @Test func afterATransientFailureTheRetryResendsEvenWhenTheCountsReturnToTheLastAcceptedOnes() {
        let h = Harness(notifyBlocked: false)
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 1)
        #expect(h.relay.reports.map(\.total) == [0])

        // The relay may have stored count 1 before failing the APNs send, so its picture is unknown.
        h.relay.respond { _ in .transientFailure }
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 1)
        #expect(h.relay.reports.map(\.total) == [0, 1])

        h.relay.respond { _ in .delivered }
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 5.1)
        #expect(h.relay.reports.map(\.total) == [0, 1, 0])
    }

    @Test func aQueuedBuzzIsDroppedWhenItsToggleWasTurnedOffBeforeTheFlush() throws {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 1)
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 1)
        h.relay.respond { request in
            if case .report(_, _, _, true) = request { return .transientFailure }
            return .delivered
        }
        h.scheduler.advance(by: 9.5)
        #expect(h.relay.reports.last?.notify == true)

        try h.registrations.setPushRegistration(
            SpacesDevicePushRegistration(capability: "cap-1", notifyBlocked: false, notifyFinished: false), forInstallationID: phone)
        h.notifier.registrationsChanged()
        h.scheduler.advance(by: 60)
        #expect(h.relay.reports.filter(\.notify).count == 1)
    }

    @Test func aReplacementRegistrationReportsOnlyAfterThePendingUnregisterSettles() throws {
        let h = Harness()
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 2)
        #expect(h.relay.requests.count == 1)

        h.relay.holdsUnregisters = true
        _ = try h.registrations.clearPushRegistration(forInstallationID: phone, matchingCapability: nil)
        h.notifier.unregister(installationID: phone, capability: "cap-1")
        try h.registrations.setPushRegistration(
            SpacesDevicePushRegistration(capability: "cap-2", notifyBlocked: true, notifyFinished: false), forInstallationID: phone)
        h.notifier.registrationsChanged()
        h.scheduler.advance(by: 30)
        // Only the unregister is out; the replacement waits, so the relay cannot delete the live counts afterwards.
        #expect(h.relay.requests.count == 2)

        h.relay.completeHeldUnregisters()
        h.scheduler.advance(by: 2)
        #expect(h.relay.requests.count == 3)
        if case .report(let capability, _, _, _) = h.relay.requests[2] { #expect(capability == "cap-2") } else { Issue.record("expected a report") }
    }

    @Test func aFailedFinalRetryAbandonsOnlyTheCountsItSentSoNewerCountsStillReport() {
        let h = Harness(notifyBlocked: false)
        h.relay.respond { _ in .transientFailure }
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 1 + 5 + 30 + 120 - 0.5)
        #expect(h.relay.reports.count == 3)

        // The counts move while the final retry is out, then that retry fails.
        let notifier = h.notifier
        let moved = waiting("a", "b")
        h.relay.respond { _ in
            notifier.overviewCommitted(moved)
            return .transientFailure
        }
        h.scheduler.advance(by: 1)
        #expect(h.relay.reports.count == 4)

        h.relay.respond { _ in .delivered }
        h.scheduler.advance(by: 2)
        #expect(h.relay.reports.count == 5)
        #expect(h.relay.reports.last?.total == 2)
    }

    @Test func anOverviewWhoseRegistrationLoadPredatesAnUnregisterDoesNotBringThePhoneBack() async throws {
        let scheduler = ManualPushScheduler()
        let relay = RecordingPushRelay()
        let registrations = InMemoryPushRegistrations([
            "phone-1": SpacesDevicePushRegistration(capability: "cap-1", notifyBlocked: true, notifyFinished: false)
        ])
        let gate = LoadGate()
        let notifier = SpacesDevicePushNotifier(
            relay: relay, scheduler: scheduler, relayDeviceID: "device-test",
            loadRegistrations: {
                let loaded = try registrations.pushRegistrations()
                gate.holdIfArmed()
                return loaded
            }, clearRegistration: { _, _ in })
        notifier.start()
        notifier.overviewCommitted(PushOverviewFixture.overview())
        scheduler.advance(by: 2)
        #expect(relay.requests.count == 1)

        // An overview's registration load captures the phone, then waits while the phone unregisters.
        gate.arm()
        let overview = waiting("a")
        let racing = Task.detached { notifier.overviewCommitted(overview) }
        gate.waitUntilHeld()
        _ = try registrations.clearPushRegistration(forInstallationID: phone, matchingCapability: nil)
        notifier.unregister(installationID: phone, capability: "cap-1")
        gate.release()
        await racing.value

        scheduler.advance(by: 60)
        #expect(relay.requests == [relay.requests[0], .unregister(capability: "cap-1", deviceID: "device-test")])
        #expect(scheduler.pendingCount == 0)
    }

    @Test func aBurstOfCountChangesIsOneDebouncedReportWithTheLatestCounts() {
        let h = Harness(notifyBlocked: false)
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 5)
        let before = h.relay.reports.count
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 0.3)
        h.notifier.overviewCommitted(waiting("a", "b"))
        h.scheduler.advance(by: 0.3)
        h.notifier.overviewCommitted(waiting("a", "b", "c"))
        h.scheduler.advance(by: 5)
        #expect(h.relay.reports.count == before + 1)
        #expect(h.relay.reports.last?.total == 3 && h.relay.reports.last?.notify == false)
    }

    @Test func aChangeThatLeavesTheCountsAloneSendsNothing() {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 5)
        let before = h.relay.requests.count
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 30)
        #expect(h.relay.requests.count == before)
    }

    @Test func aGoneRegistrationIsClearedAndNothingIsSentAfterwards() {
        let h = Harness()
        h.relay.respond { _ in .registrationDead }
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 2)
        #expect(h.relay.requests.count == 1)
        #expect((try? h.registrations.pushRegistrations().isEmpty) == true)

        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 60)
        #expect(h.relay.requests.count == 1)
    }

    @Test func aTransientFailureRetriesWithBackoffAndTheLatestStateWins() {
        let h = Harness(notifyBlocked: false)
        h.relay.respond { _ in .transientFailure }
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 1)
        #expect(h.relay.reports.count == 1)

        // State moves while the retry waits; the retry carries the newest counts, not the failed ones.
        h.notifier.overviewCommitted(waiting("a", "b"))
        h.relay.respond { _ in .delivered }
        h.scheduler.advance(by: 4.9)
        #expect(h.relay.reports.count == 1)
        h.scheduler.advance(by: 0.2)
        #expect(h.relay.reports.count == 2)
        #expect(h.relay.reports.last?.total == 2)
        h.scheduler.advance(by: 300)
        #expect(h.relay.reports.count == 2)
    }

    @Test func retriesStopAfterTheBackoffScheduleUntilTheCountsChange() {
        let h = Harness(notifyBlocked: false)
        h.relay.respond { _ in .transientFailure }
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 1 + 5 + 30 + 120 + 1)
        #expect(h.relay.reports.count == 4)
        h.scheduler.advance(by: 600)
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 600)
        #expect(h.relay.reports.count == 4)

        h.relay.respond { _ in .delivered }
        h.notifier.overviewCommitted(waiting("a", "b"))
        h.scheduler.advance(by: 2)
        #expect(h.relay.reports.count == 5)
        #expect(h.relay.reports.last?.total == 2)
    }

    @Test func aBuzzThatFailedTransientlyIsDroppedIfItsAlertWentAwayBeforeTheRetry() {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 1)
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 1)
        h.relay.respond { request in
            if case .report(_, _, _, true) = request { return .transientFailure }
            return .delivered
        }
        h.scheduler.advance(by: 9.5)
        #expect(h.relay.reports.last?.notify == true)

        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 60)
        #expect(h.relay.reports.last?.notify == false)
        #expect(h.relay.reports.last?.total == 0)
    }

    @Test func unregisterCallsTheRelayOnceWithThePhonesCapability() {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.scheduler.advance(by: 2)
        h.notifier.unregister(installationID: phone, capability: "cap-1")
        #expect(h.relay.requests.last == .unregister(capability: "cap-1", deviceID: "device-test"))

        h.scheduler.advance(by: 120)
        #expect(h.relay.requests.filter { $0 == .unregister(capability: "cap-1", deviceID: "device-test") }.count == 1)
    }

    @Test func stoppingRetiresEveryTimer() {
        let h = Harness()
        h.notifier.overviewCommitted(PushOverviewFixture.overview())
        h.notifier.overviewCommitted(waiting("a"))
        #expect(h.scheduler.pendingCount > 0)
        h.notifier.stop()
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func aRotatedCapabilityResyncsTheCurrentCountsToTheNewRegistration() throws {
        let h = Harness()
        h.notifier.overviewCommitted(waiting("a"))
        h.scheduler.advance(by: 2)
        #expect(h.relay.reports.count == 1)

        try h.registrations.setPushRegistration(
            SpacesDevicePushRegistration(capability: "cap-2", notifyBlocked: true, notifyFinished: false), forInstallationID: phone)
        h.notifier.registrationsChanged()
        h.scheduler.advance(by: 2)
        #expect(h.relay.reports.count == 2)
        #expect(h.relay.reports.last?.notify == false)
        if case .report(let capability, _, _, _) = h.relay.requests.last { #expect(capability == "cap-2") }
    }
}

@Suite struct SpacesDevicePushAlertEvaluationTests {
    private let both = SpacesDevicePushRegistration(capability: "c", notifyBlocked: true, notifyFinished: true)

    @Test func theFirstOverviewSeedsWithoutRecheckingAnything() {
        let snapshot = SpacesDevicePushAlertSnapshot(overview: PushOverviewFixture.overview(agents: [("a", .waiting)]))
        let evaluation = SpacesDevicePushAlertEvaluation.evaluate(seenKeys: nil, snapshot: snapshot, registration: both)
        #expect(evaluation.recheckKeys.isEmpty)
        #expect(evaluation.counts == SpacesDeviceAlertCounts(total: 1, blockedAgents: 1))
        #expect(evaluation.seenKeys.count == 1)
    }

    @Test func onlyNewKeysOfATogglableKindStartARecheck() {
        let before = SpacesDevicePushAlertSnapshot(overview: PushOverviewFixture.overview(agents: [("a", .waiting)]))
        let after = SpacesDevicePushAlertSnapshot(overview: PushOverviewFixture.overview(agents: [("a", .waiting), ("b", .done), ("c", .spinning)]))
        let evaluation = SpacesDevicePushAlertEvaluation.evaluate(seenKeys: Set(before.kindsByKey.keys), snapshot: after, registration: both)
        #expect(evaluation.recheckKeys == [PushOverviewFixture.agentKey("b", state: .done): .agentDone])
    }

    @Test func aToggleOffKindOnlyMovesTheCounts() {
        let after = SpacesDevicePushAlertSnapshot(overview: PushOverviewFixture.overview(agents: [("a", .waiting), ("b", .done)]))
        let blockedOnly = SpacesDevicePushRegistration(capability: "c", notifyBlocked: true, notifyFinished: false)
        let evaluation = SpacesDevicePushAlertEvaluation.evaluate(seenKeys: [], snapshot: after, registration: blockedOnly)
        #expect(evaluation.recheckKeys.keys.sorted() == [PushOverviewFixture.agentKey("a", state: .waiting)])
        #expect(evaluation.counts == SpacesDeviceAlertCounts(total: 2, blockedAgents: 1))
    }
}

@Suite struct SpacesDevicePushRelayClientTests {
    @Test func theCapabilityTravelsInTheBodyAndNeverInTheArguments() throws {
        let request = SpacesDevicePushRelayRequest.report(
            capability: "secret-capability", deviceID: "device-1", counts: SpacesDeviceAlertCounts(total: 4, blockedAgents: 1), notify: true)
        let arguments = SpacesDevicePushRelayCurlClient.arguments(for: request)
        #expect(!arguments.contains { $0.contains("secret-capability") })
        #expect(arguments.last == "https://push.usespaces.dev/v1/report")
        #expect(arguments.contains("@-"))

        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["capability"] as? String == "secret-capability")
        #expect(body["deviceID"] as? String == "device-1")
        #expect(body["total"] as? Int == 4)
        #expect(body["blockedAgents"] as? Int == 1)
        #expect(body["notify"] as? Bool == true)
    }

    @Test func anUnregisterPostsOnlyTheCapabilityAndDeviceID() throws {
        let request = SpacesDevicePushRelayRequest.unregister(capability: "cap", deviceID: "device-1")
        #expect(SpacesDevicePushRelayCurlClient.arguments(for: request).last == "https://push.usespaces.dev/v1/unregister")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(Set(body.keys) == ["capability", "deviceID"])
    }

    @Test func httpStatusesMapToTheOutcomesTheNotifierActsOn() {
        #expect(SpacesDevicePushRelayOutcome.outcome(forHTTPStatus: 200) == .delivered)
        #expect(SpacesDevicePushRelayOutcome.outcome(forHTTPStatus: 410) == .registrationDead)
        #expect(SpacesDevicePushRelayOutcome.outcome(forHTTPStatus: 401) == .registrationDead)
        #expect(SpacesDevicePushRelayOutcome.outcome(forHTTPStatus: 502) == .transientFailure)
        #expect(SpacesDevicePushRelayOutcome.outcome(forHTTPStatus: 0) == .transientFailure)
        #expect(SpacesDevicePushRelayOutcome.outcome(forHTTPStatus: 400) == .rejected)
    }
}

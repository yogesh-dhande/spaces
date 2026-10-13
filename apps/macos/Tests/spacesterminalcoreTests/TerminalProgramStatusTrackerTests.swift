import Testing

@testable import spacesterminalcore

@Suite struct TerminalProgramStatusTrackerTests {
    private func run(_ steps: [(TerminalProgramStatusState, String)]) -> [TerminalProgramStatusTransition?] {
        var tracker = TerminalProgramStatusTracker()
        return steps.map { tracker.apply(state: $0.0, id: $0.1) }
    }

    @Test func workingThenIdleIsDone() {
        #expect(run([(.working, ""), (.idle, "")]) == [.working, .done])
    }

    /// Codex never sends `done`: it reports idle between turns, and approval prompts are blocked.
    @Test func codexSequenceMapsToWorkingBlockedWorkingDone() {
        #expect(run([(.idle, ""), (.working, ""), (.blocked, ""), (.working, ""), (.idle, "")]) == [nil, .working, .blocked, .working, .done])
    }

    @Test func claudeStyleWorkingThenDone() {
        #expect(run([(.working, ""), (.done, "")]) == [.working, .done])
    }

    @Test func errorShowsAsDone() {
        #expect(run([(.working, ""), (.error, "")]) == [.working, .done])
    }

    /// An agent announcing itself with idle has not finished anything.
    @Test func initialIdleEmitsNothing() {
        #expect(run([(.idle, ""), (.idle, "")]) == [nil, nil])
    }

    @Test func repeatedWorkingEmitsOnce() {
        #expect(run([(.working, ""), (.working, "")]) == [.working, nil])
    }

    @Test func oneRecordFinishingWhileAnotherWorksStaysWorking() {
        #expect(run([(.working, "a"), (.working, "b"), (.done, "a"), (.done, "b")]) == [.working, nil, nil, .done])
    }

    @Test func blockedOutranksWorkingAndResumesToWorking() {
        #expect(run([(.working, "a"), (.working, "b"), (.blocked, "a"), (.working, "a")]) == [.working, nil, .blocked, .working])
    }

    @Test func clearingAParentRemovesItsChildren() {
        var tracker = TerminalProgramStatusTracker()
        _ = tracker.apply(state: .working, id: "build")
        _ = tracker.apply(state: .working, id: "build/test")
        _ = tracker.apply(state: .working, id: "builder")
        #expect(tracker.apply(state: .clear, id: "build") == nil)
        #expect(tracker.recordCount == 1)
        #expect(tracker.apply(state: .idle, id: "builder") == .done)
    }

    @Test func emptyClearRemovesEverything() {
        var tracker = TerminalProgramStatusTracker()
        _ = tracker.apply(state: .working, id: "a")
        _ = tracker.apply(state: .blocked, id: "b/c")
        #expect(tracker.apply(state: .clear, id: "") == .done)
        #expect(tracker.recordCount == 0)
    }

    @Test func clearingAnInactiveTerminalEmitsNothing() {
        #expect(run([(.clear, "")]) == [nil])
    }

    @Test func clearingTheOnlyWorkingRecordIsDone() {
        #expect(run([(.working, "a"), (.clear, "a")]) == [.working, .done])
    }

    @Test func recordCountIsCappedByEvictingTheLeastRecentlyUpdated() {
        var tracker = TerminalProgramStatusTracker()
        _ = tracker.apply(state: .working, id: "oldest")
        for index in 0..<(TerminalProgramStatusTracker.maximumRecordCount - 1) { _ = tracker.apply(state: .idle, id: "id-\(index)") }
        #expect(tracker.recordCount == TerminalProgramStatusTracker.maximumRecordCount)

        // The table is full, so the next new id evicts "oldest", the only active record.
        #expect(tracker.apply(state: .idle, id: "overflow") == .done)
        #expect(tracker.recordCount == TerminalProgramStatusTracker.maximumRecordCount)
    }

    @Test func updatingARecordRefreshesItsRecency() {
        var tracker = TerminalProgramStatusTracker()
        _ = tracker.apply(state: .working, id: "kept")
        for index in 0..<(TerminalProgramStatusTracker.maximumRecordCount - 1) { _ = tracker.apply(state: .idle, id: "id-\(index)") }
        _ = tracker.apply(state: .working, id: "kept")
        _ = tracker.apply(state: .idle, id: "overflow")
        #expect(tracker.apply(state: .idle, id: "kept") == .done)
    }

    @Test func resetForgetsRecordsWithoutReporting() {
        var tracker = TerminalProgramStatusTracker()
        _ = tracker.apply(state: .working, id: "a")
        tracker.reset()
        #expect(tracker.recordCount == 0)
        #expect(tracker.apply(state: .idle, id: "a") == nil)
    }
}

@Suite struct TerminalProgramStatusRelayTests {
    private func agent(_ kind: TerminalDetectedAgentKind) -> TerminalForegroundAgentSnapshot {
        TerminalForegroundAgentSnapshot(
            process: TerminalForegroundProcessSnapshot(pid: 1, executablePath: "/bin/\(kind.rawValue)", executableName: kind.rawValue, argv: [kind.rawValue]),
            detectedAgentKind: kind, displayLabel: kind.displayLabel, displayCommand: kind.rawValue, agentCommand: kind.rawValue)
    }

    @Test func reportsWithoutADetectedAgentAreIgnored() {
        var relay = TerminalProgramStatusRelay()
        #expect(relay.receive(stateValue: TerminalProgramStatusState.working.rawValue, id: "") == nil)
    }

    @Test func aDetectedAgentsTransitionsCarryItsLabel() {
        var relay = TerminalProgramStatusRelay()
        #expect(relay.observeForegroundAgent(agent(.codex)) == nil)
        #expect(
            relay.receive(stateValue: TerminalProgramStatusState.working.rawValue, id: "")
                == .transition(.working, agentLabel: TerminalDetectedAgentKind.codex.displayLabel))
        #expect(
            relay.receive(stateValue: TerminalProgramStatusState.idle.rawValue, id: "")
                == .transition(.done, agentLabel: TerminalDetectedAgentKind.codex.displayLabel))
    }

    @Test func theAgentGoingAwayDropsRecordsAndReportsTheEnd() {
        var relay = TerminalProgramStatusRelay()
        _ = relay.observeForegroundAgent(agent(.claude))
        _ = relay.receive(stateValue: TerminalProgramStatusState.working.rawValue, id: "")
        #expect(relay.observeForegroundAgent(nil) == .agentEnded)
        #expect(relay.receive(stateValue: TerminalProgramStatusState.idle.rawValue, id: "") == nil)
    }

    @Test func aDifferentAgentStartsFromNoRecords() {
        var relay = TerminalProgramStatusRelay()
        _ = relay.observeForegroundAgent(agent(.claude))
        _ = relay.receive(stateValue: TerminalProgramStatusState.working.rawValue, id: "")
        #expect(relay.observeForegroundAgent(agent(.codex)) == .agentEnded)
        // The new agent's idle must not settle the old agent's working record into a done.
        #expect(relay.receive(stateValue: TerminalProgramStatusState.idle.rawValue, id: "") == nil)
    }

    @Test func observingTheSameAgentAgainChangesNothing() {
        var relay = TerminalProgramStatusRelay()
        _ = relay.observeForegroundAgent(agent(.claude))
        _ = relay.receive(stateValue: TerminalProgramStatusState.working.rawValue, id: "")
        #expect(relay.observeForegroundAgent(agent(.claude)) == nil)
        #expect(
            relay.receive(stateValue: TerminalProgramStatusState.done.rawValue, id: "")
                == .transition(.done, agentLabel: TerminalDetectedAgentKind.claude.displayLabel))
    }
}

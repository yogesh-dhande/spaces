import Foundation
import Testing

@testable import spacesui

/// Covers the cycle bookkeeping that scoping introduces: a workspace rotation and a cross-device
/// rotation keep separate cursors and frozen orders, while visits feed one shared recency list.
@Suite struct WindowCycleStateTests {
    @Test func crossDeviceRotationsShareOneRecencyListWhileWorkspacesKeepTheirOwn() {
        var state = WindowCycleState()

        state.recordVisit(
            cursor: "terminal:session-a", globalCursor: "device:mac/workspace:w1/terminal:session-a", workspaceID: "w1", preserveCycleSession: false)
        state.recordVisit(
            cursor: "terminal:session-b", globalCursor: "device:linux/workspace:w2/terminal:session-b", workspaceID: "w2", preserveCycleSession: false
        )

        // Both visits are in the one list every cross-device mode reads, most recent first.
        let globalRecents = ["device:linux/workspace:w2/terminal:session-b", "device:mac/workspace:w1/terminal:session-a"]
        #expect(state.recentCursors(for: .mode(.openSessions)) == globalRecents)
        #expect(state.recentCursors(for: .mode(.alerts)) == globalRecents)
        // Each workspace's own list holds only its own visits.
        #expect(state.recentCursors(for: .workspace("w1")) == ["terminal:session-a"])
        #expect(state.recentCursors(for: .workspace("w2")) == ["terminal:session-b"])
    }

    @Test func revisitingATargetMovesItToTheHeadOfBothLists() {
        var state = WindowCycleState()

        state.recordVisit(cursor: "terminal:a", globalCursor: "device:mac/workspace:w1/terminal:a", workspaceID: "w1", preserveCycleSession: false)
        state.recordVisit(cursor: "terminal:b", globalCursor: "device:mac/workspace:w1/terminal:b", workspaceID: "w1", preserveCycleSession: false)
        state.recordVisit(cursor: "terminal:a", globalCursor: "device:mac/workspace:w1/terminal:a", workspaceID: "w1", preserveCycleSession: false)

        #expect(state.recentCursors(for: .workspace("w1")) == ["terminal:a", "terminal:b"])
        #expect(state.recentCursors(for: .mode(.openSessions)) == ["device:mac/workspace:w1/terminal:a", "device:mac/workspace:w1/terminal:b"])
    }

    @Test func cyclingInAModeLeavesTheWorkspaceRotationWhereItWas() {
        var state = WindowCycleState()
        state.recordVisit(cursor: "terminal:a", globalCursor: "device:mac/workspace:w1/terminal:a", workspaceID: "w1", preserveCycleSession: false)
        state.recordCycleLanding(scope: .workspace("w1"), orderedCursors: ["terminal:a", "terminal:b"], index: 1)

        state.recordCycleLanding(
            scope: .mode(.alerts), orderedCursors: ["device:mac/workspace:w2/agent:x", "device:mac/workspace:w2/agent:y"], index: 1)

        #expect(state.cursor(for: .workspace("w1")) == "terminal:b")
        #expect(state.cursor(for: .mode(.alerts)) == "device:mac/workspace:w2/agent:y")
        // Each mode is its own rotation, so stepping the mode starts from that mode's own cursor.
        #expect(state.cursor(for: .mode(.allAgents)) == nil)
    }

    @Test func aFrozenCrossDeviceRotationSurvivesTheSetReorderingMidSequence() {
        var state = WindowCycleState()
        let ordered = ["device:mac/workspace:w1/agent:a", "device:mac/workspace:w1/agent:b", "device:linux/workspace:w2/agent:c"]
        state.recordCycleLanding(scope: .mode(.alerts), orderedCursors: ordered, index: 0)

        // An agent reporting a new state re-sorts the set: `c` is now newest and leads the rebuilt list.
        let rebuilt = ["device:linux/workspace:w2/agent:c", "device:mac/workspace:w1/agent:a", "device:mac/workspace:w1/agent:b"]
        let session = state.validCycleSession(for: .mode(.alerts))
        let ordering = WorkspaceWindowCycle.cycleOrdering(cursors: rebuilt, currentIndex: 1, session: session, recentCursors: [])

        #expect(ordering.indices.map { rebuilt[$0] } == ordered)
        #expect(ordering.currentIndex == 0)
    }

    @Test func aFrozenRotationWalksOnWhileTheAnsweredAgentIsStillACandidate() {
        var state = WindowCycleState()
        let ordered = ["device:mac/workspace:w1/agent:a", "device:mac/workspace:w1/agent:b", "device:mac/workspace:w1/agent:c"]
        state.recordCycleLanding(scope: .mode(.alerts), orderedCursors: ordered, index: 0)
        let session = state.validCycleSession(for: .mode(.alerts))

        // The user answered `a`, so it is working and Alerts no longer admits it; the set the burst
        // is handed retains it and re-sorts around its newer state change.
        let retained = ["device:mac/workspace:w1/agent:a", "device:mac/workspace:w1/agent:c", "device:mac/workspace:w1/agent:b"]
        let kept = WorkspaceWindowCycle.cycleOrdering(cursors: retained, currentIndex: 0, session: session, recentCursors: [])
        #expect(kept.indices.map { retained[$0] } == ordered)
        let nextIndex = WorkspaceWindowCycle.nextIndex(orderedCount: kept.indices.count, orderedCurrentIndex: kept.currentIndex, delta: 1)
        #expect(retained[kept.indices[nextIndex]] == ordered[1])

        // Dropping it instead costs the burst its rotation: a frozen cursor with no candidate rebuilds
        // the order, and the two agents left come back in the rebuilt set's order rather than the
        // frozen one's.
        let dropped = ["device:mac/workspace:w1/agent:c", "device:mac/workspace:w1/agent:b"]
        let rebuilt = WorkspaceWindowCycle.cycleOrdering(cursors: dropped, currentIndex: nil, session: session, recentCursors: [])
        #expect(rebuilt.indices.map { dropped[$0] } == dropped)
        #expect(rebuilt.indices.map { dropped[$0] } != ordered.filter(dropped.contains))
    }

    @Test func aFrozenRotationExpiresWithItsBurst() {
        var state = WindowCycleState()
        state.recordCycleLanding(
            scope: .mode(.alerts), orderedCursors: ["a", "b"], index: 0,
            at: Date().addingTimeInterval(-(WorkspaceWindowCycle.cycleSessionTimeout + 1)))

        #expect(state.validCycleSession(for: .mode(.alerts)) == nil)
    }

    @Test func aVisitThatDidNotComeFromCyclingEndsEveryFrozenRotation() {
        var state = WindowCycleState()
        state.recordCycleLanding(scope: .mode(.alerts), orderedCursors: ["a", "b"], index: 0)
        state.recordCycleLanding(scope: .workspace("w1"), orderedCursors: ["terminal:a", "terminal:b"], index: 0)

        state.recordVisit(cursor: "terminal:b", globalCursor: "device:mac/workspace:w1/terminal:b", workspaceID: "w1", preserveCycleSession: true)
        #expect(state.validCycleSession(for: .mode(.alerts)) != nil)
        #expect(state.validCycleSession(for: .workspace("w1")) != nil)

        state.recordVisit(cursor: "terminal:b", globalCursor: "device:mac/workspace:w1/terminal:b", workspaceID: "w1", preserveCycleSession: false)
        #expect(state.validCycleSession(for: .mode(.alerts)) == nil)
        #expect(state.validCycleSession(for: .workspace("w1")) == nil)
    }

    @Test func aWorkspaceVisitWithNoKnownDeviceStaysOutOfTheSharedList() {
        var state = WindowCycleState()

        state.recordVisit(cursor: "terminal:a", globalCursor: nil, workspaceID: "w1", preserveCycleSession: false)

        #expect(state.recentCursors(for: .workspace("w1")) == ["terminal:a"])
        #expect(state.recentCursors(for: .mode(.openSessions)).isEmpty)
    }
}

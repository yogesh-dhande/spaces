import Foundation
import Testing

@testable import spacesui

struct WorkspaceWindowCycleTests {
    @Test func nextIndexAdvancesAndWrapsFromCurrent() {
        // 3 targets, currently at index 0: next → 1, previous → 2 (wraps).
        #expect(WorkspaceWindowCycle.nextIndex(orderedCount: 3, orderedCurrentIndex: 0, delta: 1) == 1)
        #expect(WorkspaceWindowCycle.nextIndex(orderedCount: 3, orderedCurrentIndex: 0, delta: -1) == 2)
        #expect(WorkspaceWindowCycle.nextIndex(orderedCount: 3, orderedCurrentIndex: 2, delta: 1) == 0)
    }

    @Test func nextIndexWithoutCurrentStartsAtEndsByDirection() {
        #expect(WorkspaceWindowCycle.nextIndex(orderedCount: 2, orderedCurrentIndex: nil, delta: 1) == 0)
        #expect(WorkspaceWindowCycle.nextIndex(orderedCount: 2, orderedCurrentIndex: nil, delta: -1) == 1)
    }

    @Test func cycleOrderingUsesNaturalOrderWithoutSession() {
        let cursors = ["browser:a", "process:1", "agent:x"]
        let ordering = WorkspaceWindowCycle.cycleOrdering(cursors: cursors, currentIndex: 0, session: nil)
        #expect(ordering.indices == [0, 1, 2])
        #expect(ordering.currentIndex == 0)
    }

    @Test func cycleOrderingUsesMRUOrderWithCurrentFirstWithoutSession() {
        let cursors = ["browser:a", "process:1", "agent:x", "terminal:shell"]
        let ordering = WorkspaceWindowCycle.cycleOrdering(
            cursors: cursors, currentIndex: 1, session: nil, recentCursors: ["agent:x", "browser:a", "process:1"])

        #expect(ordering.indices == [1, 2, 0, 3])
        #expect(ordering.currentIndex == 0)
    }

    @Test func cycleOrderingAppendsTargetsMissingFromMRUInNaturalOrder() {
        let cursors = ["browser:a", "process:1", "agent:x", "terminal:shell"]
        let ordering = WorkspaceWindowCycle.cycleOrdering(cursors: cursors, currentIndex: nil, session: nil, recentCursors: ["agent:x"])

        #expect(ordering.indices == [2, 0, 1, 3])
        #expect(ordering.currentIndex == nil)
    }

    @Test func cycleOrderingPreservesActiveSessionRotation() {
        // A live session remembers a rotation that differs from natural order; cycling keeps it.
        let cursors = ["a", "b", "c"]
        let session = WorkspaceWindowCycle.CycleSession(
            orderedCursors: ["c", "a", "b"], currentIndex: 0, lastUsedAt: Date(timeIntervalSinceReferenceDate: 0))
        let ordering = WorkspaceWindowCycle.cycleOrdering(cursors: cursors, currentIndex: 2, session: session, recentCursors: ["b", "a", "c"])
        // Session order ["c","a","b"] maps to indices [2,0,1]; current (cursor "c", index 2) is first.
        #expect(ordering.indices == [2, 0, 1])
        #expect(ordering.currentIndex == 0)
    }

    @Test func cycleOrderingFallsBackWhenSessionCursorsNoLongerMatch() {
        // The remembered session references a cursor that is gone, so the natural order is used.
        let cursors = ["a", "b"]
        let session = WorkspaceWindowCycle.CycleSession(
            orderedCursors: ["a", "gone"], currentIndex: 0, lastUsedAt: Date(timeIntervalSinceReferenceDate: 0))
        let ordering = WorkspaceWindowCycle.cycleOrdering(cursors: cursors, currentIndex: nil, session: session)
        #expect(ordering.indices == [0, 1])
    }
}

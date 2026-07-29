import Foundation
import Testing

@testable import spacesterminalghostty

/// The window itself is exercised end to end against a real PTY by the Linux bell suite; these pin the
/// rule a daemon handoff depends on, which no live session can reach: a session rebuilt around a fresh
/// coalescer has to keep absorbing bells that belong to the alert its clients are already showing.
@Suite struct TerminalBellCoalescerTests {
    @Test func aSeededWindowAbsorbsABellThatFallsInsideIt() {
        var coalescer = TerminalBellCoalescer()
        let publishedBefore = Date(timeIntervalSinceReferenceDate: 1_000_000)
        coalescer.seedLastAdvanced(at: publishedBefore)

        #expect(coalescer.ring(at: publishedBefore.addingTimeInterval(5)) == nil)
    }

    @Test func aSeededWindowLetsABellAfterItAdvanceTheTimestamp() {
        var coalescer = TerminalBellCoalescer()
        let publishedBefore = Date(timeIntervalSinceReferenceDate: 1_000_000)
        coalescer.seedLastAdvanced(at: publishedBefore)

        let next = publishedBefore.addingTimeInterval(TerminalBellCoalescer.defaultQuietWindow + 1)
        #expect(coalescer.ring(at: next) == next)
    }

    /// A session with no persisted bell — or one whose timestamp did not parse — seeds nothing, so the
    /// first bell after the handoff is a new alert rather than being swallowed.
    @Test func seedingNothingLeavesTheWindowOpen() {
        var coalescer = TerminalBellCoalescer()
        coalescer.seedLastAdvanced(at: nil)

        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(coalescer.ring(at: now) == now)
    }
}

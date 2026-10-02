import Testing

@testable import spacesterminalcore

@Suite struct TerminalResizeCoalescerTests {
    private let current = TerminalResizeCoalescer.Size(columns: 132, rows: 59)

    @Test func aSingleResizeIsAppliedWhenTheWindowSettles() {
        var coalescer = TerminalResizeCoalescer()
        let target = TerminalResizeCoalescer.Size(columns: 100, rows: 40)

        #expect(coalescer.request(target, current: current) == .armTimer)
        #expect(coalescer.settle(current: current) == target)
    }

    @Test func aBurstAppliesOnlyTheLastSizeAndArmsOneTimer() {
        var coalescer = TerminalResizeCoalescer()
        let last = TerminalResizeCoalescer.Size(columns: 90, rows: 30)

        #expect(coalescer.request(.init(columns: 132, rows: 2), current: current) == .armTimer)
        #expect(coalescer.request(.init(columns: 100, rows: 40), current: current) == .coalesced)
        #expect(coalescer.request(last, current: current) == .coalesced)
        #expect(coalescer.settle(current: current) == last)
    }

    @Test func aBurstThatReturnsToTheCurrentSizeAppliesNothing() {
        var coalescer = TerminalResizeCoalescer()

        #expect(coalescer.request(.init(columns: 132, rows: 2), current: current) == .armTimer)
        #expect(coalescer.request(current, current: current) == .coalesced)
        #expect(coalescer.settle(current: current) == nil)
    }

    @Test func aRequestForTheCurrentSizeWithNothingWaitingOpensNoWindow() {
        var coalescer = TerminalResizeCoalescer()

        #expect(coalescer.request(current, current: current) == .alreadyCurrent)
        #expect(!coalescer.hasOpenWindow)
    }

    @Test func aRequestAfterTheWindowSettlesOpensANewOne() {
        var coalescer = TerminalResizeCoalescer()
        let shrunk = TerminalResizeCoalescer.Size(columns: 132, rows: 2)

        #expect(coalescer.request(shrunk, current: current) == .armTimer)
        #expect(coalescer.settle(current: current) == shrunk)
        #expect(coalescer.request(current, current: shrunk) == .armTimer)
        #expect(coalescer.settle(current: shrunk) == current)
    }

    @Test func discardingThePendingSizeClosesTheWindowAndAppliesNothing() {
        var coalescer = TerminalResizeCoalescer()
        let shrunk = TerminalResizeCoalescer.Size(columns: 132, rows: 2)

        #expect(coalescer.request(shrunk, current: current) == .armTimer)
        coalescer.discardPending()
        #expect(!coalescer.hasOpenWindow)
        #expect(coalescer.settle(current: current) == nil)
        #expect(coalescer.request(shrunk, current: current) == .armTimer)
    }
}

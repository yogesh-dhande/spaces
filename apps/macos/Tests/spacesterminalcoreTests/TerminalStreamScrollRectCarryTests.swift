import XCTest

@testable import spacesterminalcore

final class TerminalStreamScrollRectCarryTests: XCTestCase {
    private func rect(_ rowStart: Int) -> GhosttyRenderScrollRectOperation {
        GhosttyRenderScrollRectOperation(rowStart: rowStart, rowCount: 1, columnStart: 0, columnCount: 10, deltaRows: 1, deltaColumns: 0)
    }

    func testFoldPreservesOrderAcrossMultipleFolds() {
        var carry = TerminalStreamScrollRectCarry()
        carry.fold(rects: [rect(1), rect(2)], overflowed: false)
        carry.fold(rects: [rect(3)], overflowed: false)

        XCTAssertEqual(carry.rects, [rect(1), rect(2), rect(3)])
        XCTAssertFalse(carry.overflowed)
    }

    func testDrainReturnsCarriedThenNewAndResets() {
        var carry = TerminalStreamScrollRectCarry()
        carry.fold(rects: [rect(1), rect(2)], overflowed: false)

        let (drainedRects, drainedOverflowed) = carry.drain(mergingWith: [rect(3), rect(4)], overflowed: false)

        XCTAssertEqual(drainedRects, [rect(1), rect(2), rect(3), rect(4)])
        XCTAssertFalse(drainedOverflowed)
        XCTAssertEqual(carry.rects, [])
        XCTAssertFalse(carry.overflowed)
    }

    func testOverflowFlagOrsFromEitherSide() {
        var foldedSide = TerminalStreamScrollRectCarry()
        foldedSide.fold(rects: [rect(1)], overflowed: true)
        let (_, foldedSideOverflowed) = foldedSide.drain(mergingWith: [rect(2)], overflowed: false)
        XCTAssertTrue(foldedSideOverflowed)

        var newSide = TerminalStreamScrollRectCarry()
        newSide.fold(rects: [rect(1)], overflowed: false)
        let (_, newSideOverflowed) = newSide.drain(mergingWith: [rect(2)], overflowed: true)
        XCTAssertTrue(newSideOverflowed)
    }

    func testExceedingMaxCarriedRectsPoisonsAndSubsequentDrainReportsOverflowedThenResetsClean() {
        var carry = TerminalStreamScrollRectCarry()
        let overflowingBatch = (0..<(TerminalStreamScrollRectCarry.maxCarriedRects + 1)).map { rect($0) }
        carry.fold(rects: overflowingBatch, overflowed: false)

        XCTAssertEqual(carry.rects, [])
        XCTAssertTrue(carry.overflowed)

        let (drainedRects, drainedOverflowed) = carry.drain(mergingWith: [], overflowed: false)
        XCTAssertEqual(drainedRects, [])
        XCTAssertTrue(drainedOverflowed)

        // The carry is clean after the drain: a subsequent fold/drain cycle with no overflow reports false.
        carry.fold(rects: [rect(1)], overflowed: false)
        let (secondDrainedRects, secondDrainedOverflowed) = carry.drain(mergingWith: [], overflowed: false)
        XCTAssertEqual(secondDrainedRects, [rect(1)])
        XCTAssertFalse(secondDrainedOverflowed)
    }

    func testFoldAtExactlyMaxCarriedRectsDoesNotPoison() {
        var carry = TerminalStreamScrollRectCarry()
        let exactBatch = (0..<TerminalStreamScrollRectCarry.maxCarriedRects).map { rect($0) }
        carry.fold(rects: exactBatch, overflowed: false)

        XCTAssertEqual(carry.rects, exactBatch)
        XCTAssertFalse(carry.overflowed)
    }
}

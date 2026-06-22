import XCTest

@testable import spacesterminalcore

final class TerminalScrollDeltaNormalizerTests: XCTestCase {
    func testScrollModifiersEncodeGhosttyPrecisionAndMomentumBits() {
        XCTAssertEqual(TerminalScrollModifiers.make(hasPreciseDeltas: true, momentumPhase: .changed), 0b0000_0111)
        XCTAssertEqual(TerminalScrollModifiers.make(hasPreciseDeltas: true, momentumPhase: .ended), 0b0000_1001)
        XCTAssertEqual(TerminalScrollModifiers.make(hasPreciseDeltas: true, momentumPhase: .cancelled), 0b0000_1011)
        XCTAssertEqual(TerminalScrollModifiers.make(hasPreciseDeltas: true, momentumPhase: .mayBegin), 0b0000_1101)
        XCTAssertEqual(TerminalScrollModifiers.make(hasPreciseDeltas: true, momentumPhase: .none), 0b0000_0001)
        XCTAssertEqual(TerminalScrollModifiers.make(hasPreciseDeltas: false, momentumPhase: .none), 0)
    }

    func testScrollModifiersIdentifyPreciseDeltas() {
        XCTAssertTrue(TerminalScrollModifiers.hasPreciseDeltas(0b0000_0001))
        XCTAssertTrue(TerminalScrollModifiers.hasPreciseDeltas(0b0000_0111))
        XCTAssertFalse(TerminalScrollModifiers.hasPreciseDeltas(0b0000_0110))
    }

    func testPreciseScrollAccumulatesUntilCellHeight() {
        var normalizer = TerminalScrollDeltaNormalizer(cellHeight: 18)

        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: 8, scrollMods: 1), 0)
        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: 9, scrollMods: 1), 0)
        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: 1, scrollMods: 1), -1)
        XCTAssertEqual(normalizer.pendingVerticalDelta, 0)
    }

    func testPreciseScrollCarriesFractionalRemainder() {
        var normalizer = TerminalScrollDeltaNormalizer(cellHeight: 18)

        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: 20, scrollMods: 1), -1)
        XCTAssertEqual(normalizer.pendingVerticalDelta, 2)
        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: 16, scrollMods: 1), -1)
        XCTAssertEqual(normalizer.pendingVerticalDelta, 0)
    }

    func testPreciseScrollDirectionMatchesTerminalViewportConvention() {
        var normalizer = TerminalScrollDeltaNormalizer(cellHeight: 18)

        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: 18, scrollMods: 1), -1)
        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: -18, scrollMods: 1), 1)
    }

    func testDiscreteScrollUsesGhosttyDefaultMultiplier() {
        var normalizer = TerminalScrollDeltaNormalizer(cellHeight: 18)

        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: 1, scrollMods: 0), -3)
        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: -1, scrollMods: 0), 3)
    }

    func testSmallDiscreteScrollIsAtLeastOneWheelTick() {
        var normalizer = TerminalScrollDeltaNormalizer(cellHeight: 18)

        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: 0.1, scrollMods: 0), -3)
        XCTAssertEqual(normalizer.terminalViewportDeltaRows(vertical: -0.1, scrollMods: 0), 3)
    }
}

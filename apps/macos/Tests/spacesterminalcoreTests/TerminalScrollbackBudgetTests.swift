import XCTest

@testable import spacesterminalcore

final class TerminalScrollbackBudgetTests: XCTestCase {
    func testDefaultMaxBytesIsTenMegabytes() { XCTAssertEqual(TerminalScrollbackBudget.defaultMaxBytes, 10_000_000) }

    func testDefaultMaxBytesCanHoldLargeRemoteScrollFixture() {
        let fixtureLineCount = 6000
        let conservativeBytesPerLine = 120

        XCTAssertGreaterThan(TerminalScrollbackBudget.defaultMaxBytes, fixtureLineCount * conservativeBytesPerLine)
    }
}

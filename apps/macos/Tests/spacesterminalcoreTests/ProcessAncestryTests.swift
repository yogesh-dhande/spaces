import Foundation
import XCTest

@testable import spacesterminalcore

final class ProcessAncestryTests: XCTestCase {
    func testChildProcessIsDescendantOfTestProcessAndNotTheReverse() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        XCTAssertTrue(ProcessAncestry.isDescendant(child.processIdentifier, of: getpid()))
        XCTAssertFalse(ProcessAncestry.isDescendant(getpid(), of: child.processIdentifier))
    }

    func testTestProcessIsNotDescendantOfAnUnrelatedProcess() throws {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer {
            unrelated.terminate()
            unrelated.waitUntilExit()
        }
        XCTAssertFalse(ProcessAncestry.isDescendant(getpid(), of: unrelated.processIdentifier))
    }

    func testWalkStopsAtPidOneAndNeverTreatsItAsATerminalShell() {
        // 500 -> 400 -> 1 -> 0: the root ends the chain, and pid 1 is never accepted as the ancestor.
        let parents: [Int32: Int32] = [500: 400, 400: 1, 1: 0]
        XCTAssertFalse(ProcessAncestry.isDescendant(500, of: 300, parentPID: { parents[$0] }))
        XCTAssertFalse(ProcessAncestry.isDescendant(500, of: 1, parentPID: { parents[$0] }))
        XCTAssertTrue(ProcessAncestry.isDescendant(500, of: 400, parentPID: { parents[$0] }))
    }

    func testWalkIsBoundedSoACyclicOrVeryDeepChainAnswersNo() {
        let cycle: [Int32: Int32] = [10: 20, 20: 10]
        XCTAssertFalse(ProcessAncestry.isDescendant(10, of: 99, parentPID: { cycle[$0] }))

        // Pid n's parent is n + 1, so the ancestor at n + depth is reached only within the bound.
        XCTAssertTrue(ProcessAncestry.isDescendant(100, of: 100 + Int32(ProcessAncestry.maximumDepth) - 1, parentPID: { $0 + 1 }))
        XCTAssertFalse(ProcessAncestry.isDescendant(100, of: 100 + Int32(ProcessAncestry.maximumDepth), parentPID: { $0 + 1 }))
    }

    func testProcStatParentIsReadAfterTheLastClosingParenthesis() {
        XCTAssertEqual(ProcessAncestry.parentPID(inProcStat: "123 (bash) S 45 123 123 0 -1"), 45)
        XCTAssertEqual(ProcessAncestry.parentPID(inProcStat: "123 (a) (b c) S 45 1 1"), 45)
        XCTAssertNil(ProcessAncestry.parentPID(inProcStat: "123 (broken"))
    }

    func testRealParentPIDOfTestProcessIsReadable() { XCTAssertEqual(ProcessAncestry.parentPID(of: getpid()), getppid()) }
}

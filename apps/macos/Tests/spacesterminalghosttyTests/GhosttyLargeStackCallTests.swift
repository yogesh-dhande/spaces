import Foundation
import XCTest

@testable import spacesterminalghostty

final class GhosttyLargeStackCallTests: XCTestCase {
    func testReturnsClosureValue() throws {
        let value = try runOnDedicatedLargeStackThread { 42 }
        XCTAssertEqual(value, 42)
    }

    func testPropagatesThrownError() {
        struct MarkerError: Error, Equatable {}
        XCTAssertThrowsError(try runOnDedicatedLargeStackThread { () -> Int in throw MarkerError() }) { error in
            XCTAssertEqual(error as? MarkerError, MarkerError())
        }
    }

    /// Confirms the helper actually grants extra stack rather than merely calling through: this
    /// recursion depth was verified (in a standalone probe, not part of this suite) to crash with
    /// SIGBUS on a 512 KB stack, the size a libdispatch workqueue thread gets, and to complete
    /// cleanly on an 8 MB stack while using on the order of 1-2 MB. That is the same failure mode
    /// `runOnDedicatedLargeStackThread` exists to prevent for Ghostty's session/app creation calls.
    func testCompletesWorkNeedingSubstantiallyMoreStackThanADispatchWorkerProvides() throws {
        let depth = 12000
        let result = try runOnDedicatedLargeStackThread { Self.deepRecursiveChecksum(remaining: depth, accumulator: 0) }
        XCTAssertEqual(result, depth)
    }

    /// Recurses `remaining` times, keeping a handful of local values alive at each level (so the
    /// compiler cannot discard the stack frame they live in), then unwinds back to `accumulator +
    /// remaining`. The specific arithmetic is not the point: what matters is that this many stack
    /// frames survive when run through the helper.
    private static func deepRecursiveChecksum(remaining: Int, accumulator: Int) -> Int {
        guard remaining > 0 else { return accumulator }
        let a = remaining, b = remaining &* 2, c = remaining &* 3, d = remaining &* 5
        let e = remaining &* 7, f = remaining &* 11, g = remaining &* 13, h = remaining &* 17
        _ = (a, b, c, d, e, f, g, h)
        return deepRecursiveChecksum(remaining: remaining - 1, accumulator: accumulator + 1)
    }
}

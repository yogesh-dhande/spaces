import XCTest

@testable import workspacecore

final class PerKeyGateTests: XCTestCase {
    private struct BusyError: Error, Equatable {}

    // Tests that re-entering the same key while it is already held throws the busy error.
    func testReenteringSameKeyWhileHeldThrows() {
        let gate = PerKeyGate()

        XCTAssertThrowsError(
            try gate.withKey("workspace-1", busyError: { BusyError() }) { try gate.withKey("workspace-1", busyError: { BusyError() }) {} }
        ) { error in XCTAssertTrue(error is BusyError) }
    }

    // Tests that a key can be reacquired after a successful operation releases it.
    func testKeyIsReleasedAfterSuccessfulOperation() throws {
        let gate = PerKeyGate()

        try gate.withKey("workspace-1", busyError: { BusyError() }) {}
        try gate.withKey("workspace-1", busyError: { BusyError() }) {}
    }

    // Tests that a key is released even when the held operation throws, so it can be reacquired.
    func testKeyIsReleasedAfterOperationThrows() {
        struct OperationError: Error {}
        let gate = PerKeyGate()

        XCTAssertThrowsError(try gate.withKey("workspace-1", busyError: { BusyError() }) { throw OperationError() })

        XCTAssertNoThrow(try gate.withKey("workspace-1", busyError: { BusyError() }) {})
    }

    // Tests that different keys are independent: holding one key does not block another.
    func testDifferentKeysAreIndependent() throws {
        let gate = PerKeyGate()

        try gate.withKey("workspace-a", busyError: { BusyError() }) { try gate.withKey("workspace-b", busyError: { BusyError() }) {} }
    }

    // Tests that the operation's return value propagates through withKey.
    func testOperationReturnValuePropagates() throws {
        let gate = PerKeyGate()

        let result = try gate.withKey("workspace-1", busyError: { BusyError() }) { 42 }

        XCTAssertEqual(result, 42)
    }
}

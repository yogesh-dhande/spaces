import XCTest

@testable import workspacecore

final class PerKeyGateTests: XCTestCase {
    private struct BusyError: Error, Equatable {}

    func testReenteringSameKeyWhileHeldThrows() {
        let gate = PerKeyGate()

        XCTAssertThrowsError(
            try gate.withKey("workspace-1", busyError: { BusyError() }) { try gate.withKey("workspace-1", busyError: { BusyError() }) {} }
        ) { error in XCTAssertTrue(error is BusyError) }
    }

    func testKeyIsReleasedAfterSuccessfulOperation() throws {
        let gate = PerKeyGate()

        try gate.withKey("workspace-1", busyError: { BusyError() }) {}
        try gate.withKey("workspace-1", busyError: { BusyError() }) {}
    }

    func testKeyIsReleasedAfterOperationThrows() {
        struct OperationError: Error {}
        let gate = PerKeyGate()

        XCTAssertThrowsError(try gate.withKey("workspace-1", busyError: { BusyError() }) { throw OperationError() })

        XCTAssertNoThrow(try gate.withKey("workspace-1", busyError: { BusyError() }) {})
    }

    func testDifferentKeysAreIndependent() throws {
        let gate = PerKeyGate()

        try gate.withKey("workspace-a", busyError: { BusyError() }) { try gate.withKey("workspace-b", busyError: { BusyError() }) {} }
    }

    func testOperationReturnValuePropagates() throws {
        let gate = PerKeyGate()

        let result = try gate.withKey("workspace-1", busyError: { BusyError() }) { 42 }

        XCTAssertEqual(result, 42)
    }
}

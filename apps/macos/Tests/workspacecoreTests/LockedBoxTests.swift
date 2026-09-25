import XCTest

@testable import workspacecore

final class LockedBoxTests: XCTestCase {
    func testInitialValueIsReturnedByGet() {
        let box = LockedBox<Int>(7)

        XCTAssertEqual(box.get(), 7)
    }

    func testSetRoundTripsThroughGet() {
        let box = LockedBox<String?>(nil)

        box.set("hello")

        XCTAssertEqual(box.get(), "hello")
    }
}

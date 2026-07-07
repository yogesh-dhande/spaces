import XCTest

@testable import workspacecore

final class LockedBoxTests: XCTestCase {
    // Tests that a freshly created box returns the value it was initialized with.
    func testInitialValueIsReturnedByGet() {
        let box = LockedBox<Int>(7)

        XCTAssertEqual(box.get(), 7)
    }

    // Tests that a value written with set is returned by a subsequent get.
    func testSetRoundTripsThroughGet() {
        let box = LockedBox<String?>(nil)

        box.set("hello")

        XCTAssertEqual(box.get(), "hello")
    }
}

import Foundation
import Testing

import spacesterminalcore

/// Deliberately a Swift Testing suite, and registered in both the macOS and Linux lanes, because those
/// are the two lanes whose test-host detection has no margin and they rely on different signals: macOS
/// Swift Testing runs under `swiftpm-testing-helper` with no `.xctest` among its arguments, so only the
/// linked-in `XCTestCase` class marks it; Linux has no Objective-C runtime at all, so only `argv[0]`
/// ending in `.xctest` marks it. Either signal disappearing drops profile resolution's refusal for that
/// whole lane. An XCTest case cannot cover this — it satisfies the other checks anyway.
@Suite struct SpacesTestHostDetectionTests {
    @Test func testHostIsRecognisedInThisLane() {
        #expect(SpacesTestHost.isRunningUnderXCTest())
    }
}

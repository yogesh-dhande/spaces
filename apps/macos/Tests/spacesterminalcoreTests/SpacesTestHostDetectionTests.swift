import Foundation
import Testing

import spacesterminalcore

/// Deliberately a Swift Testing suite rather than an XCTest case: that lane is the one whose test-host
/// detection has no margin. It runs under `swiftpm-testing-helper`, with no `.xctest` bundle in the
/// process arguments and none in `Bundle.allBundles`, so only the linked-in `XCTestCase` class marks it
/// as a test host — and that single signal is what makes profile resolution refuse the installed profile
/// for every suite in the lane. An XCTest case cannot cover this: it satisfies the other checks anyway.
@Suite struct SpacesTestHostDetectionTests {
    @Test func swiftTestingLaneIsRecognisedAsATestHost() {
        #expect(SpacesTestHost.isRunningUnderXCTest())
    }
}

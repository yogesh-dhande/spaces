import Foundation
import Testing

@testable import spacesterminalcore

/// Deliberately a Swift Testing suite, and registered in both the macOS and Linux lanes, because those
/// are the two lanes whose test-host detection has no margin and they rely on different signals: macOS
/// Swift Testing runs under `swiftpm-testing-helper` with no `.xctest` among its arguments, so only the
/// linked-in `XCTestCase` class marks it; Linux has no Objective-C runtime at all, so only `argv[0]`
/// ending in `.xctest` marks it. Either signal disappearing drops profile resolution's refusal for that
/// whole lane. An XCTest case cannot cover this — it satisfies the other checks anyway.
@Suite struct SpacesTestHostDetectionTests {
    @Test func testHostIsRecognisedInThisLane() { #expect(SpacesTestHost.isRunningUnderXCTest()) }

    /// The Linux signal, spelled exactly as measured in the container: SwiftPM execs the test binary
    /// directly and passes the testing library after it.
    @Test func testBundleExecutableIsRecognised() {
        #expect(
            SpacesTestHost.executableIsTestBundle(arguments: [
                "/root/src/apps/macos/.build/x86_64-unknown-linux-gnu/debug/spacesPackageTests.xctest", "--testing-library", "swift-testing",
            ]))
    }

    /// A `.xctest` path among the ARGUMENTS is data the process was asked to act on, not what the process
    /// is. Running or tailing a test bundle from a Spaces terminal is ordinary, and it must not make the
    /// CLI classify itself as a test host — which would have profile resolution refuse the user's own live
    /// profile and fail a command that did nothing wrong.
    @Test func testBundleNamedInArgumentsIsNotTheExecutable() {
        #expect(!SpacesTestHost.executableIsTestBundle(arguments: ["/usr/local/bin/spaces", "terminal", "command", "xcrun xctest ./Foo.xctest"]))
        #expect(!SpacesTestHost.executableIsTestBundle(arguments: ["/usr/local/bin/spaces", "terminal", "tail", "some/path/Foo.xctest"]))
    }

    /// A process with no arguments answers `false` rather than trapping.
    @Test func emptyArgumentsAreNotATestBundle() { #expect(!SpacesTestHost.executableIsTestBundle(arguments: [])) }
}

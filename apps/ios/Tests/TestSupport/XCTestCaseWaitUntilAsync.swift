#if canImport(UIKit)
    import XCTest

    @MainActor extension XCTestCase {
        /// Polls a condition that has to be read off an actor instead of awaiting it directly, so a
        /// regression that strands a waiter fails the test itself rather than hanging until XCTest's own
        /// timeout kills the whole run.
        func waitUntilAsync(_ description: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async {
            let deadline = ContinuousClock().now + timeout
            while ContinuousClock().now < deadline {
                if await condition() { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Timed out waiting for \(description).")
        }
    }
#endif

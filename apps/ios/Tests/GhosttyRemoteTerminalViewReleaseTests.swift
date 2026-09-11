#if canImport(UIKit)
    import UIKit
    import XCTest
    @testable import spacesterminalmobileghostty

    /// A `@MainActor` class whose last reference is dropped by a background thread runs its `deinit` there,
    /// and `MainActor.assumeIsolated` in a `deinit` traps when that happens. These tests pin that a
    /// terminal host view tears down the same way whichever thread performs its last release.
    ///
    /// Deallocation is the assertion rather than the display link the `deinit` invalidates: a live momentum
    /// link retains this view (it is the link's target), so a view that reaches `deinit` never has one (see
    /// the comment at the `deinit`). A trap would take the whole test process with it, and a view that
    /// never deallocates fails the same check.
    @MainActor final class GhosttyRemoteTerminalViewReleaseTests: XCTestCase {
        override func setUp() {
            super.setUp()
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = false
        }

        override func tearDown() {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            super.tearDown()
        }

        func testLastReleaseOffMainDeallocatesTheView() async {
            let box = TerminalHostViewBox()
            let weakReference = WeakTerminalHostViewReference()
            // Building the view leaves autoreleased references to it on the enclosing pool, so that pool has
            // to drain before `box` genuinely holds the last one.
            autoreleasepool {
                box.view = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
                weakReference.view = box.view
            }

            let releaseFinished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                autoreleasepool { box.view = nil }
                releaseFinished.signal()
            }
            _ = releaseFinished.wait(timeout: .now() + 5)
            await drainMainQueue()

            XCTAssertNil(weakReference.view, "a terminal host view released off the main thread did not tear down")
        }

        /// The control: the same view released on the main thread.
        func testLastReleaseOnMainDeallocatesTheView() async {
            let box = TerminalHostViewBox()
            let weakReference = WeakTerminalHostViewReference()
            autoreleasepool {
                box.view = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
                weakReference.view = box.view
            }

            autoreleasepool { box.view = nil }
            await drainMainQueue()

            XCTAssertNil(weakReference.view, "a terminal host view released on the main thread did not tear down")
        }

        /// Lets anything the release handed to the main queue run before the assertion reads the result.
        private func drainMainQueue() async { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
    }

    /// Carries the view across to the thread that performs its last release. `@unchecked Sendable` because
    /// the view is `@MainActor` and not `Sendable`: each box is written once by the test and once by the
    /// releasing thread, never concurrently.
    private final class TerminalHostViewBox: @unchecked Sendable { var view: GhosttyRemoteTerminalHostView? }

    /// Watches the view without keeping it alive, from whichever thread asks.
    private final class WeakTerminalHostViewReference: @unchecked Sendable { weak var view: GhosttyRemoteTerminalHostView? }
#endif

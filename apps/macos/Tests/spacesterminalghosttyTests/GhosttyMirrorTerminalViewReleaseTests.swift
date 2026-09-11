import AppKit
import Foundation
import GhosttyKit
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// A mirrored pane owns two process-wide resources: a C mirror (`ghostty_mirror_free`) and an entry in
/// `GhosttyMirrorAppService`'s surface-keyed action-handler table. Both are released by the pane's
/// `deinit`, which runs on whichever thread dropped the pane's last reference — a background thread when an
/// async caller holds the final reference to the pane's owner. Abandoning either one leaves a live mirror
/// and a stale handler keyed on a surface address Ghostty will hand out again.
///
/// AppKit defers an `NSView`'s deallocation to the main thread even when the final release lands off it, so
/// the off-main test below cannot reach a `deinit` that runs off the main thread the way the plain
/// `@MainActor` classes in `RemoteGhosttySessionHostTests` and the device state model's suite do. What it
/// pins is the contract that does not depend on that framework behavior: a pane dropped from a background
/// thread releases both resources.
@MainActor final class GhosttyMirrorTerminalViewReleaseTests: XCTestCase {
    private var window: NSWindow?
    private var mainQueueDrained = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        try useIsolatedSpacesProfile()
        GhosttyMirrorSurfaceMRU.shared.resetForTesting()
        window = Self.makeVisibleWindow()
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        GhosttyMirrorSurfaceMRU.shared.resetForTesting()
        super.tearDown()
    }

    /// The regression: a background thread performs the pane's final release, so its `deinit` and every
    /// stored-property destruction run there.
    func testLastReleaseOffMainFreesTheMirrorAndUnregistersItsActionHandler() throws {
        let box = MirrorViewBox()
        let weakReference = WeakMirrorViewReference()
        var surfaceKey: UInt = 0
        // Building the pane leaves autoreleased references to it on the enclosing pool, so that pool has to
        // drain before `box` genuinely holds the last one — otherwise the release below is not the last
        // release and the pane's `deinit` runs later, on the main thread, proving nothing.
        try autoreleasepool {
            surfaceKey = try makeDisplayedPaneReadyForRelease(label: "off-main-release", into: box)
            weakReference.view = box.view
        }

        let releaseFinished = DispatchSemaphore(value: 0)
        let deallocatedOnReleasingThread = ReleasingThreadOutcome()
        Thread.detachNewThread {
            autoreleasepool { box.view = nil }
            // Read from the releasing thread itself: a pane that is gone by the time this line runs was
            // deallocated by that thread's release, which is the scenario under test. A pane still alive
            // here outlived the release (an autorelease elsewhere held it) and would be torn down on the
            // main thread instead, where nothing about this deinit is at risk.
            deallocatedOnReleasingThread.value = weakReference.view == nil
            releaseFinished.signal()
        }
        waitForCondition("the releasing thread finishes") { releaseFinished.wait(timeout: .now()) == .success }
        settle()

        XCTAssertTrue(deallocatedOnReleasingThread.value, "the background thread did not perform the pane's last release")
        XCTAssertNil(weakReference.view, "the pane was still referenced, so its deinit never ran")
        XCTAssertFalse(
            GhosttyMirrorAppService.shared.debugHasActionHandler(forSurfaceKey: surfaceKey),
            "a pane released off the main thread left its action handler registered on a freed surface's address")
    }

    /// The control: the same pane released on the main thread, where the cleanup runs inline.
    func testLastReleaseOnMainFreesTheMirrorAndUnregistersItsActionHandler() throws {
        let box = MirrorViewBox()
        let weakReference = WeakMirrorViewReference()
        var surfaceKey: UInt = 0
        try autoreleasepool {
            surfaceKey = try makeDisplayedPaneReadyForRelease(label: "main-release", into: box)
            weakReference.view = box.view
        }

        autoreleasepool { box.view = nil }
        settle()

        XCTAssertNil(weakReference.view, "the pane was still referenced, so its deinit never ran")
        XCTAssertFalse(
            GhosttyMirrorAppService.shared.debugHasActionHandler(forSurfaceKey: surfaceKey),
            "a pane released on the main thread left its action handler registered on a freed surface's address")
    }

    // MARK: - Harness

    /// Builds a pane, displays it until it holds a live mirror, then detaches it from the view hierarchy so
    /// `box` holds its only strong reference. Returns the surface key its action handler is registered
    /// under, having asserted that the registration and the mirror are both live at the moment the
    /// reference is about to be dropped — otherwise a pane whose surface was already freed (an MRU
    /// eviction, say) would let either test pass with nothing left for `deinit` to release.
    private func makeDisplayedPaneReadyForRelease(label: String, into box: MirrorViewBox) throws -> UInt {
        let view = GhosttyMirrorTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: label, backend: .ghosttyEmbedded, title: label, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        view.update(snapshot: Self.snapshot(text: label), renderStateKey: "state")
        window?.contentView?.addSubview(container)
        window?.contentView?.layoutSubtreeIfNeeded()
        settle()

        XCTAssertTrue(view.debugHasLiveMirrorSurface, "the pane did not build a surface when displayed")
        let surfaceKey = try XCTUnwrap(view.debugMirrorSurfaceKey, "the pane's mirror reported no surface")
        XCTAssertTrue(
            GhosttyMirrorAppService.shared.debugHasActionHandler(forSurfaceKey: surfaceKey),
            "the pane did not register an action handler for its surface")

        // Detached without `releaseSurface()`: that teardown is what these tests must NOT rely on, since
        // the pane is deliberately dropped with a live mirror still attached to it.
        view.removeFromSuperview()
        container.removeFromSuperview()
        box.view = view
        return surfaceKey
    }

    private func settle() {
        mainQueueDrained = false
        Task { @MainActor [weak self] in self?.mainQueueDrained = true }
        waitForCondition("main queue drain") { self.mainQueueDrained }
    }

    private func waitForCondition(_ label: String, timeout: TimeInterval = 10, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    private nonisolated static func makeVisibleWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private static func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = rows.map(\.count).max() ?? 0
        let paddedRows = rows.map { row in row.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedRows.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: paddedRows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells)
    }
}

/// Carries the pane across to the thread that performs its last release. `@unchecked Sendable` because the
/// pane is `@MainActor` and not `Sendable`: the box is written once by the test and once by the releasing
/// thread, never concurrently.
private final class MirrorViewBox: @unchecked Sendable { var view: GhosttyMirrorTerminalView? }

/// Watches the pane without keeping it alive, from whichever thread asks. A plain `weak var` local cannot
/// be captured by the releasing thread's closure, and reading it from that thread is the only way to tell
/// a release that deallocated the pane from one that merely dropped a reference.
private final class WeakMirrorViewReference: @unchecked Sendable { weak var view: GhosttyMirrorTerminalView? }

/// Carries the releasing thread's verdict back to the test.
private final class ReleasingThreadOutcome: @unchecked Sendable { var value = false }

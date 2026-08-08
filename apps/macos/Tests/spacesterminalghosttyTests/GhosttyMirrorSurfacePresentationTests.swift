import AppKit
import Foundation
import GhosttyKit
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// A mirrored pane is driven entirely from the outside: frames arrive from the session, the pane applies
/// them to its Ghostty surface, and the pane decides when that surface paints. These tests cover the two
/// ways that chain can stop while the session behind it stays alive — the surface being told it is
/// occluded and never told otherwise, and a frame the surface refused that nothing ever re-offers.
@MainActor final class GhosttyMirrorSurfacePresentationTests: XCTestCase {
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

    /// A window's occlusion moves with no geometry, hierarchy, or visibility event: it is covered,
    /// uncovered, or has its state corrected by AppKit a beat after being ordered in. The pane samples
    /// occlusion on its geometry pass, so a surface that was built during one of those beats would keep
    /// whatever it was told then — and an occluded Ghostty surface stops rebuilding cells, freezing the
    /// pane at a stale picture while frames go on applying underneath it.
    func testWindowOcclusionChangeRestatesOcclusionAtTheSurface() throws {
        let pane = makePane(label: "occlusion-restate")
        // A pane still holding a live mirror when the test ends would keep its IOSurface buffers for the
        // life of the test process; this is the teardown the app performs when it releases a renderer.
        defer { pane.view.releaseSurface() }
        show(pane)
        XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "the pane did not build a surface when displayed")
        let pushesBefore = pane.view.debugSurfaceOcclusionPushCount

        let window = try XCTUnwrap(self.window)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)

        XCTAssertEqual(
            pane.view.debugSurfaceOcclusionPushCount, pushesBefore + 1,
            "the pane did not re-state occlusion at its surface when its window's occlusion changed")
        XCTAssertEqual(
            pane.view.debugLastPushedSurfaceOcclusion, window.occlusionState.contains(.visible),
            "the pane pushed something other than its window's current occlusion state")
    }

    /// The pane's own presentation is the only thing that paints an applied frame, and it runs off the
    /// frame path. A pane coming back on screen holds a frame it has already applied and its session may
    /// stay idle for minutes, so the transition itself has to paint or the pane shows whatever was on the
    /// surface when it left.
    func testPaneComingBackOnScreenPresentsWithoutANewFrame() {
        let pane = makePane(label: "redisplay-present")
        // A pane still holding a live mirror when the test ends would keep its IOSurface buffers for the
        // life of the test process; this is the teardown the app performs when it releases a renderer.
        defer { pane.view.releaseSurface() }
        show(pane)
        waitForCondition("initial present") { pane.view.debugSurfacePresentationCount > 0 }

        // Off screen the way the pane controller does it — the container above the mirror view is hidden
        // inside a window that stays visible — and back again, with no frame arriving in between.
        pane.container.isHidden = true
        settle()
        let presentsBefore = pane.view.debugSurfacePresentationCount
        pane.container.isHidden = false
        settle()

        waitForCondition("present when the pane comes back") { pane.view.debugSurfacePresentationCount > presentsBefore }
    }

    /// Same rule across a surface rebuild, which is what a pane row being re-keyed under a live session
    /// produces: the view and its frame survive, the surface does not.
    func testRebuiltSurfacePresentsTheRetainedFrameWithoutANewFrame() {
        let pane = makePane(label: "rebuild-present")
        // A pane still holding a live mirror when the test ends would keep its IOSurface buffers for the
        // life of the test process; this is the teardown the app performs when it releases a renderer.
        defer { pane.view.releaseSurface() }
        show(pane)
        waitForCondition("initial present") { pane.view.debugSurfacePresentationCount > 0 }

        pane.view.evictMirrorSurface()
        XCTAssertFalse(pane.view.debugHasLiveMirrorSurface, "the pane kept its surface")
        let presentsBefore = pane.view.debugSurfacePresentationCount

        pane.container.isHidden = true
        settle()
        pane.container.isHidden = false
        settle()

        XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "the pane did not rebuild its surface")
        waitForCondition("present after the rebuild") { pane.view.debugSurfacePresentationCount > presentsBefore }
        XCTAssertNotNil(pane.view.debugLastPushedSurfaceOcclusion, "the rebuilt surface was never told its occlusion state")
    }

    /// A refused frame records no applied identity, so later frames are deduped against the last one that
    /// *did* apply and an idle session sends no later frame at all. Without a retry the pane sits at the
    /// last picture that applied while its session runs on underneath.
    func testFrameTheSurfaceRefusesIsRetriedUntilItLands() {
        let pane = makePane(label: "apply-retry")
        // A pane still holding a live mirror when the test ends would keep its IOSurface buffers for the
        // life of the test process; this is the teardown the app performs when it releases a renderer.
        defer { pane.view.releaseSurface() }
        let surface = RefusingSurface(refusalsLeft: 2)
        pane.view.debugRenderFrameApplyHandler = { _, _ in surface.offer() }

        pane.view.update(snapshot: Self.snapshot(text: "refused"), renderStateKey: "state")

        XCTAssertEqual(surface.offers, 1, "the frame was not offered to the surface")
        XCTAssertEqual(pane.view.debugRenderFrameApplyCount, 0, "a refused frame counted as applied")
        waitForCondition("the refused frame lands") { pane.view.debugRenderFrameApplyCount == 1 }
    }

    /// The other half of the rule: not every refusal is transient. A frame the surface can never take
    /// must stop being re-offered rather than wake the pane once per display interval forever.
    func testFrameTheSurfaceNeverAcceptsStopsBeingRetried() {
        let pane = makePane(label: "apply-retry-bound")
        // A pane still holding a live mirror when the test ends would keep its IOSurface buffers for the
        // life of the test process; this is the teardown the app performs when it releases a renderer.
        defer { pane.view.releaseSurface() }
        let surface = RefusingSurface(refusalsLeft: Int.max)
        pane.view.debugRenderFrameApplyHandler = { _, _ in surface.offer() }

        pane.view.update(snapshot: Self.snapshot(text: "never-applies"), renderStateKey: "state")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let offersAfterTheBudget = surface.offers
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        XCTAssertGreaterThan(offersAfterTheBudget, 1, "a refused frame was never retried")
        XCTAssertEqual(surface.offers, offersAfterTheBudget, "a frame the surface never accepts was retried forever")
    }

    /// The retry budget belongs to the frame, not to the pane: a session that recovers after sending
    /// something the surface could not take must not find the pane refusing to apply anything again.
    func testFrameArrivingAfterAnExhaustedRetryBudgetStillApplies() {
        let pane = makePane(label: "apply-retry-budget-per-frame")
        // A pane still holding a live mirror when the test ends would keep its IOSurface buffers for the
        // life of the test process; this is the teardown the app performs when it releases a renderer.
        defer { pane.view.releaseSurface() }
        let surface = RefusingSurface(refusalsLeft: Int.max)
        pane.view.debugRenderFrameApplyHandler = { _, _ in surface.offer() }

        pane.view.update(snapshot: Self.snapshot(text: "never-applies"), renderStateKey: "state")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(pane.view.debugRenderFrameApplyCount, 0, "a refused frame counted as applied")

        surface.refusalsLeft = 0
        pane.view.update(snapshot: Self.snapshot(text: "later-output"), renderStateKey: "state")

        XCTAssertEqual(pane.view.debugRenderFrameApplyCount, 1, "a later frame was not applied after an earlier one exhausted its retries")
    }

    // MARK: - Harness

    /// Stands in for a mirror surface that refuses the frames handed to it, counting how many times one
    /// was offered. A reference type so the pane's apply handler and the test read the same counts.
    @MainActor private final class RefusingSurface {
        var refusalsLeft: Int
        private(set) var offers = 0

        init(refusalsLeft: Int) { self.refusalsLeft = refusalsLeft }

        func offer() -> Bool {
            offers += 1
            guard refusalsLeft > 0 else { return true }
            refusalsLeft -= 1
            return false
        }
    }

    private struct Pane {
        let view: GhosttyMirrorTerminalView
        let container: NSView
    }

    private func makePane(label: String) -> Pane {
        let view = GhosttyMirrorTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: label, backend: .ghosttyEmbedded, title: label, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        view.update(snapshot: Self.snapshot(text: label), renderStateKey: "state")
        return Pane(view: view, container: container)
    }

    private func show(_ pane: Pane) {
        window?.contentView?.addSubview(pane.container)
        window?.contentView?.layoutSubtreeIfNeeded()
        settle()
    }

    private func settle() {
        mainQueueDrained = false
        Task { @MainActor [weak self] in self?.mainQueueDrained = true }
        waitForCondition("main queue drain") { self.mainQueueDrained }
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

    private func waitForCondition(_ label: String, timeout: TimeInterval = 10, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

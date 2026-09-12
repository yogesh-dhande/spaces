import AppKit
import Foundation
import GhosttyKit
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// The floating jump-to-bottom control is the only way a mirrored pane offers to leave scrollback
/// without a manual scroll. These tests cover its own show/hide/activate behavior in isolation, and the
/// contract `GhosttyMirrorTerminalView` owes it: visibility tracks each frame's own scrollbar state, and
/// the control is offered only while the pane can actually move the viewport it claims to control.
@MainActor final class TerminalJumpToBottomControlTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try useIsolatedSpacesProfile()
    }

    // MARK: - TerminalJumpToBottomControl

    func testControlIsHiddenUntilToldTheViewportScrolledBack() {
        let control = TerminalJumpToBottomControl()
        XCTAssertFalse(control.debugIsVisible, "a freshly created control must not invite a jump before any scroll position is known")
    }

    func testControlShowsWhenScrolledBackAndHidesAgainAtTheLiveBottom() {
        let control = TerminalJumpToBottomControl()

        control.setScrolledIntoScrollback(true)
        XCTAssertTrue(control.debugIsVisible, "the control did not appear when told the viewport scrolled into scrollback")

        control.setScrolledIntoScrollback(false)
        XCTAssertFalse(control.debugIsVisible, "the control stayed on screen after being told the viewport returned to the live bottom")
    }

    func testActivatingTheControlCallsItsHandlerExactlyOnce() {
        let control = TerminalJumpToBottomControl()
        var activationCount = 0
        control.onActivate = { activationCount += 1 }

        control.debugActivate()

        XCTAssertEqual(
            activationCount, 1, "one click on the jump-to-bottom control must send exactly one scroll-to-bottom request, not zero or several")
    }

    // MARK: - GhosttyMirrorTerminalView wiring

    /// The mirror view owns the control and is the one thing that knows where a frame's viewport sits;
    /// this covers it driving visibility from that frame's own scrollbar state rather than leaving the
    /// control to guess.
    func testMirrorViewShowsJumpToBottomControlOnlyWhileScrolledBack() {
        let view = makeView()
        defer { view.releaseSurface() }
        view.acceptsTerminalInput = true

        view.update(snapshot: Self.snapshot(scrolledBack: true), renderStateKey: "state")
        XCTAssertTrue(
            view.debugJumpToBottomControlIsVisible,
            "a frame whose viewport sits above the live bottom must surface the jump-to-bottom control on an owner pane")

        view.update(snapshot: Self.snapshot(scrolledBack: false), renderStateKey: "state")
        XCTAssertFalse(view.debugJumpToBottomControlIsVisible, "a frame back at the live bottom must hide the jump-to-bottom control again")
    }

    /// A viewer pane (or an ended session's read-only replay) cannot move the shared viewport at all, so
    /// offering the control there would be a dead button. This is the same gate
    /// `RemoteGhosttySessionHost.sendRemoteScroll` enforces before forwarding a scroll.
    func testMirrorViewHidesTheControlWhenItCannotMoveTheViewportEvenWhileScrolledBack() {
        let view = makeView()
        defer { view.releaseSurface() }

        view.update(snapshot: Self.snapshot(scrolledBack: true), renderStateKey: "state")
        XCTAssertFalse(
            view.debugJumpToBottomControlIsVisible,
            "a pane that cannot forward a scroll must not offer a jump-to-bottom control that would do nothing when clicked")

        view.acceptsTerminalInput = true
        XCTAssertTrue(
            view.debugJumpToBottomControlIsVisible,
            "promoting an already-scrolled-back pane to owner must surface the control immediately, not wait for the next frame")
    }

    // MARK: - Helpers

    private func makeView() -> GhosttyMirrorTerminalView {
        GhosttyMirrorTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "jump-to-bottom", backend: .ghosttyEmbedded, title: "jump-to-bottom", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
    }

    /// Twenty total rows behind a four-row viewport: an offset of 10 leaves six rows below the viewport
    /// (scrolled back), an offset of 16 leaves none (the live bottom). The mapping from these fields to
    /// `isScrolledIntoScrollback` belongs to `TerminalScrollbackPosition`; these values only need to land
    /// on either side of it.
    private static func snapshot(scrolledBack: Bool) -> GhosttyTerminalSnapshot {
        GhosttyTerminalSnapshot(
            columns: 4, rows: 4, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF, defaultBackgroundRGB: 0,
            cells: [], scrollbarTotal: 20, scrollbarOffset: scrolledBack ? 10 : 16)
    }
}

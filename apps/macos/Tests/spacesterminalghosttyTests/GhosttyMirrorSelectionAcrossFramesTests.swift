import AppKit
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// Selecting text in a pane whose program keeps printing. A coding agent's spinner, a build log, or
/// a test runner writes another line while the user is dragging out a selection or reading one they
/// already made, and the highlight has to stay on the words they picked: what they copy afterwards
/// is what they saw highlighted, not a range the new output moved or erased.
///
/// The guarantee is split between the daemon and the mirror: a completed drag commits the selection
/// to the daemon, which keeps it anchored and echoes it inside every later frame, while a drag still
/// in progress is local to the mirror and rides the stream's scroll-rect carry. The harness below
/// stands in for the daemon on both sides of that split.
@MainActor final class GhosttyMirrorSelectionAcrossFramesTests: XCTestCase {
    /// One row of distinct characters, so any two ranges of it differ in text. The frame that arrives
    /// mid-selection changes only the far-right end of the row, well right of every cell the drags
    /// touch, which makes the selected text itself identical before and after the frame.
    private static let row = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWX"
    private static let changedSuffix = "!!!!!!"
    private static let topRowY: CGFloat = 392

    private var window: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try useIsolatedSpacesProfile()
    }

    override func setUp() {
        super.setUp()
        GhosttyMirrorSurfaceMRU.shared.resetForTesting()
        window = Self.makeVisibleWindow()
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        GhosttyMirrorSurfaceMRU.shared.resetForTesting()
        super.tearDown()
    }

    /// The user finishes a selection and the program prints again. Releasing the drag commits the
    /// selection to the daemon, whose next frame carries both the new output and the selection it
    /// keeps anchored, so the highlight stays where they put it, over the same text, ready to be
    /// copied.
    func testCompletedSelectionSurvivesLaterOutput() throws {
        let view = makeAttachedView(sessionID: "sel-frames-1")
        defer { view.removeFromSuperview() }
        var committed: GhosttyTerminalSelectionRange?
        view.onSetSelection = { startColumn, startRow, endColumn, endRow, isRectangle in
            // The grid is one screen row with no scrollback, so the absolute rows the commit reports
            // are already this viewport's rows and the daemon's projection is the identity.
            committed = GhosttyTerminalSelectionRange(
                startColumn: startColumn, startRow: UInt16(startRow), endColumn: endColumn, endRow: UInt16(endRow), isRectangle: isRectangle,
                extendsAbove: false, extendsBelow: false)
        }
        try applyOriginalFrame(to: view, renderStateKey: "sel-frames-1")

        send(.leftMouseDown, x: 60, to: view)
        send(.leftMouseDragged, x: 100, to: view)
        send(.leftMouseDragged, x: 160, to: view)
        send(.leftMouseUp, x: 160, to: view)

        XCTAssertTrue(view.debugHasSurfaceSelection, "the drag did not select anything to begin with")
        let selected = try XCTUnwrap(view.debugSurfaceSelectionText, "the drag did not select anything to begin with")
        XCTAssertFalse(selected.isEmpty, "the drag did not select anything to begin with")
        let echoed = try XCTUnwrap(committed, "releasing the drag did not commit the selection to the daemon")

        try applyChangedFrame(to: view, renderStateKey: "sel-frames-1", selection: echoed)

        XCTAssertTrue(view.debugHasSurfaceSelection, "output printed after the selection cleared it")
        XCTAssertEqual(view.debugSurfaceSelectionText, selected, "output printed after the selection moved it off the selected text")
    }

    /// The user is still dragging when the program prints. The selection keeps growing from where the
    /// drag started, so releasing the button ends up with the same text as a drag nothing interrupted.
    func testDragInProgressKeepsItsStartAcrossLaterOutput() throws {
        let control = makeAttachedView(sessionID: "sel-frames-2a")
        try applyOriginalFrame(to: control, renderStateKey: "sel-frames-2a")
        send(.leftMouseDown, x: 60, to: control)
        send(.leftMouseDragged, x: 120, to: control)
        send(.leftMouseDragged, x: 160, to: control)
        send(.leftMouseUp, x: 160, to: control)
        let expected = try XCTUnwrap(control.debugSurfaceSelectionText, "the uninterrupted drag selected nothing")
        XCTAssertFalse(expected.isEmpty, "the uninterrupted drag selected nothing")
        control.removeFromSuperview()

        let view = makeAttachedView(sessionID: "sel-frames-2b")
        defer { view.removeFromSuperview() }
        try applyOriginalFrame(to: view, renderStateKey: "sel-frames-2b")
        send(.leftMouseDown, x: 60, to: view)
        send(.leftMouseDragged, x: 120, to: view)
        try applyChangedFrame(to: view, renderStateKey: "sel-frames-2b")
        send(.leftMouseDragged, x: 160, to: view)
        send(.leftMouseUp, x: 160, to: view)

        XCTAssertEqual(view.debugSurfaceSelectionText, expected, "output printed mid-drag moved where the selection started")
    }

    /// The program shrinks its grid to fewer columns than the drag started on, so the cell the drag
    /// grows from no longer exists. The drag cancels outright: continuing it would regrow the
    /// selection from the top-left corner, which is the symptom this suite exists to prevent.
    func testShrinkingFrameMidDragCancelsTheDrag() throws {
        let view = makeAttachedView(sessionID: "sel-frames-3")
        defer { view.removeFromSuperview() }
        try applyOriginalFrame(to: view, renderStateKey: "sel-frames-3")

        send(.leftMouseDown, x: 160, to: view)
        send(.leftMouseDragged, x: 120, to: view)
        try applyNarrowFrame(to: view, renderStateKey: "sel-frames-3")
        send(.leftMouseDragged, x: 60, to: view)
        send(.leftMouseUp, x: 60, to: view)

        XCTAssertNil(view.debugSurfaceSelectionText, "a drag whose start the shrink removed kept selecting")
    }

    // MARK: - Harness

    /// Frames are built at the pane's own grid, the way the daemon streams them: the mirror reports
    /// its viewport and the daemon sizes the session to it, so a streamed frame's grid matches the
    /// surface's. A frame at any other size reads as a resize landing between applies, which cancels
    /// an in-progress drag by design (the shrink test exercises exactly that).
    private func applyOriginalFrame(to view: GhosttyMirrorTerminalView, renderStateKey: String) throws {
        let grid = try paneGrid(of: view)
        let snapshot = Self.snapshot(text: Self.row, columns: grid.columns, rows: grid.rows)
        view.update(snapshot: snapshot, renderStateKey: renderStateKey)
        try waitFor("the pane to paint the row") { view.debugMirrorSurfaceText?.contains("abcdefghij") ?? false }
    }

    /// The pane's surface grid, which only exists once the view has built its mirror surface.
    private func paneGrid(of view: GhosttyMirrorTerminalView) throws -> (columns: Int, rows: Int) {
        try XCTUnwrap(view.surfaceCellSize(), "the pane never produced a surface grid")
    }

    /// The frame the session sends while the user is selecting: the same row with only its far-right
    /// end rewritten, which is how a test tells an applied frame from a pending one without touching
    /// any cell either drag covers. Delivered the way the daemon streams it: a delta continuation
    /// whose scroll rects say nothing moved (empty and not overflowed), carrying whatever selection
    /// the daemon holds. A default-initialized frame would instead claim an untrustworthy carry,
    /// which cancels an in-progress drag by design.
    private func applyChangedFrame(
        to view: GhosttyMirrorTerminalView, renderStateKey: String, selection: GhosttyTerminalSelectionRange? = nil
    ) throws {
        let grid = try paneGrid(of: view)
        let changed = String(Self.row.dropLast(Self.changedSuffix.count)) + Self.changedSuffix
        let frame = GhosttyRenderFrame(
            sessionRevision: nil, ownerEpoch: 0,
            snapshot: Self.snapshot(text: changed, columns: grid.columns, rows: grid.rows, selection: selection), scrollRects: [],
            scrollRectsOverflowed: false)
        view.update(frame: frame, renderStateKey: renderStateKey)
        try waitFor("the pane to paint the later output") { view.debugMirrorSurfaceText?.contains(Self.changedSuffix) ?? false }
    }

    /// A frame with fewer columns than the column the drag started on, the shape a TUI resize
    /// sends while the user is selecting.
    private func applyNarrowFrame(to view: GhosttyMirrorTerminalView, renderStateKey: String) throws {
        let narrow = String(Self.row.prefix(10))
        view.update(snapshot: Self.snapshot(text: narrow, columns: narrow.count, rows: 1), renderStateKey: renderStateKey)
        try waitFor("the pane to paint the narrower grid") {
            guard let painted = view.debugMirrorSurfaceSnapshot else { return false }
            return painted.columns == narrow.count
        }
    }

    /// Delivers one left-button event to the pane the way AppKit would, then lets the surface act on
    /// it before the next one arrives.
    private func send(_ type: NSEvent.EventType, x: CGFloat, to view: GhosttyMirrorTerminalView) {
        let event = mouseEvent(type: type, x: x)
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: XCTFail("unsupported mouse event type")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// Every event lands on the top row of a 640x400 pane, at an x well left of the row's rewritten
    /// tail. Columns are never asserted: the tests compare selected text, not grid coordinates.
    private func mouseEvent(type: NSEvent.EventType, x: CGFloat) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: Self.topRowY), modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func makeAttachedView(sessionID: String) -> GhosttyMirrorTerminalView {
        let view = GhosttyMirrorTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: sessionID, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-07-26T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window?.contentView?.addSubview(container)
        window?.contentView?.layoutSubtreeIfNeeded()
        return view
    }

    /// A frame whose top row holds `text` (space-padded to `columns`) over otherwise blank rows, the
    /// shape that keeps the whole test on one line of text. Nothing is tracking the mouse: the
    /// program the user is selecting from is printing, not reading clicks.
    private static func snapshot(
        text: String, columns: Int, rows: Int, selection: GhosttyTerminalSelectionRange? = nil
    ) -> GhosttyTerminalSnapshot {
        let padded = text.padding(toLength: columns, withPad: " ", startingAt: 0)
        let topRow = padded.unicodeScalars.map { scalar in
            GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        }
        let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0x20, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        let cells = topRow + Array(repeating: blank, count: columns * (rows - 1))
        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells, mouseReportingActive: false, selection: selection)
    }

    // 30 seconds matches the embedded-surface waits across this target. Note this suite runs in its
    // own coverage.sh invocation, never the shared parallel run: it starts a real MIRROR-owned
    // ghostty app, and a worker process that ran any daemon-core suite first cannot host one
    // (GhosttyProcessAppRuntime's one-live-app-per-process contract).
    private func waitFor(_ label: String, timeout: TimeInterval = 30, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for \(label)")
        throw SurfaceSnapshotTimeout()
    }

    private struct SurfaceSnapshotTimeout: Error {}

    /// The pane only takes a click once its window is key, and a real mirror surface only exists in a
    /// window that is on screen.
    private final class KeyTestWindow: NSWindow { override var isKeyWindow: Bool { true } }

    private nonisolated static func makeVisibleWindow() -> NSWindow {
        let window = KeyTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

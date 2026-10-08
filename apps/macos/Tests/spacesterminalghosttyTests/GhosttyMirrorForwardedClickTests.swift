import AppKit
import Foundation
import GhosttyKit
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// What a Mac pane puts on the wire when it forwards a click to the session that can deliver it.
///
/// A forwarded button names one cell as that cell's center in the session's grid
/// (`TerminalControlMouseButtonPayload`), so the pane has to quantize the click against the geometry its
/// own mirror surface rendered: a real surface, because the padding Ghostty leaves around the grid and the
/// cell size it chose are what decide which cell a point is in, and neither is derivable from the pane's
/// bounds alone.
@MainActor final class GhosttyMirrorForwardedClickTests: XCTestCase {
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

    /// Two clicks a fraction of a point apart on either side of a cell boundary reach the session as the
    /// cells on either side of it, in both axes. A position proportional to the pane's pixels would not:
    /// the session surface has its own scale, so its padding, its cell size and the pixels left over past
    /// its last cell all differ from this pane's.
    func testMirrorForwardsTheClickedCellAcrossACellBoundary() throws {
        let view = makeAttachedView(sessionID: "forwarded-click-boundary")
        defer { view.removeFromSuperview() }
        let snapshot = Self.snapshot(columns: 20, rows: 4, mouseTrackingLevel: .clicks)
        view.update(snapshot: snapshot, renderStateKey: "click|20x4")
        _ = try waitForSurfaceGeometry(view)

        let geometry = try XCTUnwrap(view.debugMirrorSurfaceCellGeometry)
        var forwarded: [TerminalScrollPointerPosition?] = []
        view.onSendMouseButton = { _, _, pointer in forwarded.append(pointer) }

        let scale = Double(window?.backingScaleFactor ?? 2)
        let padding = GhosttySurfaceGridPadding.perSidePixels(scale: scale) / scale
        let cellWidth = Double(geometry.cellWidthPx) / scale
        let cellHeight = Double(geometry.cellHeightPx) / scale
        let boundaryX = padding + cellWidth * 4
        let boundaryY = padding + cellHeight * 2

        func clickedCell(atX x: Double, yFromTop y: Double) throws -> (column: Int, row: Int) {
            forwarded.removeAll()
            let event = mouseEvent(type: .leftMouseDown, at: NSPoint(x: x, y: Self.paneHeight - y))
            view.mouseDown(with: event)
            let position = try XCTUnwrap(XCTUnwrap(forwarded.first), "the click must carry the cell it landed on")
            view.mouseUp(with: mouseEvent(type: .leftMouseUp, at: NSPoint(x: x, y: Self.paneHeight - y)))
            return TerminalPointerGrid.cell(x: position.x, y: position.y, columns: geometry.columns, rows: geometry.rows)
        }

        let beforeBoundary = try clickedCell(atX: boundaryX - 0.1, yFromTop: boundaryY + 0.1)
        XCTAssertEqual(beforeBoundary.column, 3, "a click just short of the column boundary belongs to the column before it")
        XCTAssertEqual(beforeBoundary.row, 2, "a click just past the row boundary belongs to the next row")

        let afterBoundary = try clickedCell(atX: boundaryX + 0.1, yFromTop: boundaryY - 0.1)
        XCTAssertEqual(afterBoundary.column, 4, "a click just past the column boundary belongs to the next column")
        XCTAssertEqual(afterBoundary.row, 1, "a click just short of the row boundary belongs to the row before it")
    }

    // MARK: - Motion

    /// What the pane forwarded: the cells its motions named, and its button presses and releases, in order.
    private final class MotionRecorder {
        var cells: [(column: Int, row: Int)] = []
        var buttons: [(button: UInt8, pressed: Bool)] = []
    }

    private func makeMotionView(sessionID: String, level: TerminalMouseTrackingLevel, recorder: MotionRecorder) throws -> (
        view: GhosttyMirrorTerminalView, columns: Int, rows: Int
    ) {
        let view = makeAttachedView(sessionID: sessionID)
        view.update(snapshot: Self.snapshot(columns: 20, rows: 6, mouseTrackingLevel: level), renderStateKey: "motion|20x6")
        let geometry = try waitForSurfaceGeometry(view)
        view.onSendMouseMotion = { pointer in
            recorder.cells.append(TerminalPointerGrid.cell(x: pointer.x, y: pointer.y, columns: geometry.columns, rows: geometry.rows))
        }
        view.onSendMouseButton = { button, pressed, _ in recorder.buttons.append((button, pressed)) }
        return (view, geometry.columns, geometry.rows)
    }

    private func point(_ view: GhosttyMirrorTerminalView, column: Int, row: Int) throws -> NSPoint {
        try XCTUnwrap(view.windowPointForTesting(column: column, row: row))
    }

    /// Any-event tracking wants the hover: one motion per cell change, none for movement inside a cell.
    func testMirrorForwardsHoverMotionOncePerCellUnderAnyEventTracking() throws {
        let recorder = MotionRecorder()
        let (view, _, _) = try makeMotionView(sessionID: "motion-any", level: .anyMotion, recorder: recorder)
        defer { view.removeFromSuperview() }

        let first = try point(view, column: 3, row: 2)
        view.mouseMoved(with: mouseEvent(type: .mouseMoved, at: first))
        view.mouseMoved(with: mouseEvent(type: .mouseMoved, at: NSPoint(x: first.x + 1, y: first.y)))
        view.mouseMoved(with: mouseEvent(type: .mouseMoved, at: try point(view, column: 4, row: 2)))

        XCTAssertEqual(recorder.cells.map { [$0.column, $0.row] }, [[3, 2], [4, 2]], "one report per cell change, never per pixel")
    }

    /// Button-event tracking wants the drag: motion is forwarded only while a forwarded button is held.
    func testMirrorForwardsDragMotionOnlyWhileAForwardedButtonIsHeldUnderButtonEventTracking() throws {
        let recorder = MotionRecorder()
        let (view, _, _) = try makeMotionView(sessionID: "motion-button", level: .buttonMotion, recorder: recorder)
        defer { view.removeFromSuperview() }

        view.mouseMoved(with: mouseEvent(type: .mouseMoved, at: try point(view, column: 1, row: 1)))
        XCTAssertTrue(recorder.cells.isEmpty, "a hover is not wanted under button-event tracking")

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: try point(view, column: 1, row: 1)))
        XCTAssertEqual(recorder.buttons.map(\.pressed), [true])
        view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: try point(view, column: 1, row: 1)))
        XCTAssertTrue(recorder.cells.isEmpty, "a drag inside the press's own cell has not changed cell")
        view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: try point(view, column: 5, row: 1)))
        XCTAssertEqual(recorder.cells.map { [$0.column, $0.row] }, [[5, 1]])

        view.mouseUp(with: mouseEvent(type: .leftMouseUp, at: try point(view, column: 5, row: 1)))
        view.mouseMoved(with: mouseEvent(type: .mouseMoved, at: try point(view, column: 7, row: 1)))
        XCTAssertEqual(recorder.cells.count, 1, "motion after the release is not forwarded")
    }

    func testMirrorForwardsNoMotionUnderClicksOnlyTrackingOrWithoutTracking() throws {
        for level in [TerminalMouseTrackingLevel.none, .clicks] {
            let recorder = MotionRecorder()
            let (view, _, _) = try makeMotionView(sessionID: "motion-\(level.rawValue)", level: level, recorder: recorder)
            defer { view.removeFromSuperview() }

            view.mouseMoved(with: mouseEvent(type: .mouseMoved, at: try point(view, column: 2, row: 2)))
            view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: try point(view, column: 6, row: 2)))
            XCTAssertTrue(recorder.cells.isEmpty, "level \(level) wants no motion")
        }
    }

    /// Shift hands the pointer to local selection, so it does not reach the program, and a session that
    /// no longer permits mouse capture (an exited process) keeps nothing for it either.
    func testMirrorForwardsNoMotionWhenShiftOrAnEndedSessionOwnsThePointer() throws {
        let recorder = MotionRecorder()
        let (view, _, _) = try makeMotionView(sessionID: "motion-shift", level: .anyMotion, recorder: recorder)
        defer { view.removeFromSuperview() }

        view.mouseMoved(with: mouseEvent(type: .mouseMoved, at: try point(view, column: 2, row: 2), modifierFlags: [.shift]))
        XCTAssertTrue(recorder.cells.isEmpty, "a Shift move belongs to selection")

        view.sessionPermitsMouseCapture = false
        view.mouseMoved(with: mouseEvent(type: .mouseMoved, at: try point(view, column: 4, row: 2)))
        XCTAssertTrue(recorder.cells.isEmpty, "a session that does not permit mouse capture receives no motion")
    }

    /// A press forwarded to the program must be released on the session even when Shift is down by the
    /// time the button comes up: the session host would otherwise keep the button held and report later
    /// hover as a drag.
    func testMirrorForwardsTheReleaseOfAForwardedPressWhenShiftIsDownAtRelease() throws {
        let recorder = MotionRecorder()
        let (view, _, _) = try makeMotionView(sessionID: "release-shift", level: .buttonMotion, recorder: recorder)
        defer { view.removeFromSuperview() }

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: try point(view, column: 2, row: 2)))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, at: try point(view, column: 2, row: 2), modifierFlags: [.shift]))
        XCTAssertEqual(recorder.buttons.map(\.pressed), [true, false], "the Shift release of a forwarded press still reaches the session")

        view.mouseMoved(with: mouseEvent(type: .mouseMoved, at: try point(view, column: 6, row: 2)))
        XCTAssertTrue(recorder.cells.isEmpty, "with the button released, button-event tracking wants no hover")
    }

    /// A Shift release whose press was not forwarded (Shift selected from the start) stays local.
    func testMirrorKeepsAShiftReleaseLocalWhenItsPressWasNotForwarded() throws {
        let recorder = MotionRecorder()
        let (view, _, _) = try makeMotionView(sessionID: "release-shift-local", level: .buttonMotion, recorder: recorder)
        defer { view.removeFromSuperview() }

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: try point(view, column: 2, row: 2), modifierFlags: [.shift]))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, at: try point(view, column: 2, row: 2), modifierFlags: [.shift]))
        XCTAssertTrue(recorder.buttons.isEmpty)
    }

    // MARK: - Harness

    private nonisolated static let paneWidth = 640.0
    private nonisolated static let paneHeight = 400.0

    private func makeAttachedView(sessionID: String) -> GhosttyMirrorTerminalView {
        let view = GhosttyMirrorTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: sessionID, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-07-26T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.paneWidth, height: Self.paneHeight))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        view.acceptsTerminalInput = true
        container.addSubview(view)
        window?.contentView?.addSubview(container)
        window?.contentView?.layoutSubtreeIfNeeded()
        return view
    }

    private static func snapshot(columns: Int, rows: Int, mouseTrackingLevel: TerminalMouseTrackingLevel) -> GhosttyTerminalSnapshot {
        let cells = (0..<(columns * rows)).map { index in
            GhosttyTerminalSnapshot.Cell(
                codepoint: UnicodeScalar("a").value + UInt32(index % 26), foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells, mouseTrackingLevel: mouseTrackingLevel)
    }

    private func mouseEvent(type: NSEvent.EventType, at location: NSPoint, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifierFlags, timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
    }

    /// 30 seconds matches the embedded-surface waits across this target. Like the other mirror-surface
    /// suites this one drives a real mirror-owned ghostty app, so it runs in its own coverage process.
    private func waitForSurfaceGeometry(_ view: GhosttyMirrorTerminalView, timeout: TimeInterval = 30) throws -> (
        columns: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let geometry = view.debugMirrorSurfaceCellGeometry { return geometry }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("the mirror surface never reported the grid it laid out")
        throw SurfaceGeometryTimeout()
    }

    private struct SurfaceGeometryTimeout: Error {}

    /// The pane only takes a click once its window is key, and a real mirror surface only exists in a
    /// window that is on screen.
    private final class KeyTestWindow: NSWindow { override var isKeyWindow: Bool { true } }

    private nonisolated static func makeVisibleWindow() -> NSWindow {
        let window = KeyTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: paneHeight), styleMask: [.titled, .miniaturizable], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: paneHeight))
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

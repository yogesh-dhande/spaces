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
        let snapshot = Self.snapshot(columns: 20, rows: 4, mouseReportingActive: true)
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

    private static func snapshot(columns: Int, rows: Int, mouseReportingActive: Bool) -> GhosttyTerminalSnapshot {
        let cells = (0..<(columns * rows)).map { index in
            GhosttyTerminalSnapshot.Cell(
                codepoint: UnicodeScalar("a").value + UInt32(index % 26), foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells, mouseReportingActive: mouseReportingActive)
    }

    private func mouseEvent(type: NSEvent.EventType, at location: NSPoint) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
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

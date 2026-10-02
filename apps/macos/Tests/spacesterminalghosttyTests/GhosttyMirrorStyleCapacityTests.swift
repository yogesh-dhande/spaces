import AppKit
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// A mirrored pane must paint frames from TUIs that use many colors at once (gradient logos,
/// syntax-highlighted diffs). A fresh terminal page holds only 128 distinct styles, so a frame with
/// more distinct colors than that has to grow the page rather than be dropped whole, which would leave
/// the pane showing a stale frame.
@MainActor final class GhosttyMirrorStyleCapacityTests: XCTestCase {
    private static let columns = 80
    private static let rows = 24
    private static let styledCellCount = 300

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

    func testMirrorSurfaceAppliesAFrameWithMoreDistinctStylesThanAPageHolds() throws {
        let view = makeAttachedView()
        view.update(snapshot: Self.snapshot(), renderStateKey: "many-styles")

        let captured = try waitForSnapshot(view) { snapshot in
            snapshot.columns == Self.columns && snapshot.rows == Self.rows && snapshot.cells.count >= Self.columns * Self.rows
                && snapshot.cells[0].codepoint == Self.codepoint(0)
        }
        for index in 0..<Self.styledCellCount {
            let cell = captured.cells[index]
            XCTAssertEqual(cell.foregroundRGB, Self.foreground(index), "cell \(index) lost its foreground color")
            XCTAssertEqual(cell.backgroundRGB, Self.background(index), "cell \(index) lost its background color")
        }
    }

    // MARK: - Harness

    /// Each styled cell gets its own foreground; every third also gets a distinct background. None
    /// equals the frame's default colors (white on black).
    private static func foreground(_ index: Int) -> UInt32 { 0x10_0000 + UInt32(index) * 0x00_0301 }
    private static func background(_ index: Int) -> UInt32 { index % 3 == 0 ? 0x00_0001 + UInt32(index) * 0x00_0100 : 0 }
    private static func codepoint(_ index: Int) -> UInt32 { 0x41 + UInt32(index % 26) }

    private static func snapshot() -> GhosttyTerminalSnapshot {
        var cells: [GhosttyTerminalSnapshot.Cell] = []
        for index in 0..<(columns * rows) {
            if index < styledCellCount {
                cells.append(
                    GhosttyTerminalSnapshot.Cell(
                        codepoint: codepoint(index), foregroundRGB: foreground(index), backgroundRGB: background(index), flags: 0))
            } else {
                cells.append(GhosttyTerminalSnapshot.Cell(codepoint: 0x20, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0))
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells, clusters: [:])
    }

    private func makeAttachedView() -> GhosttyMirrorTerminalView {
        let view = GhosttyMirrorTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "style-capacity-mirror", backend: .ghosttyEmbedded, title: "style-capacity-mirror", workingDirectory: "/tmp/work",
                shell: "/bin/zsh", command: "cat", createdAt: "2026-07-26T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window?.contentView?.addSubview(container)
        window?.contentView?.layoutSubtreeIfNeeded()
        return view
    }

    // This suite runs in its own invocation for the same reason as the grapheme suite: it hosts a real
    // MIRROR-owned ghostty app (one live app per process).
    private func waitForSnapshot(_ view: GhosttyMirrorTerminalView, timeout: TimeInterval = 30, until condition: (GhosttyTerminalSnapshot) -> Bool)
        throws -> GhosttyTerminalSnapshot
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = view.debugMirrorSurfaceSnapshot, condition(snapshot) { return snapshot }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("the mirror surface never exported the applied frame")
        throw SurfaceSnapshotTimeout()
    }

    private struct SurfaceSnapshotTimeout: Error {}

    private nonisolated static func makeVisibleWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

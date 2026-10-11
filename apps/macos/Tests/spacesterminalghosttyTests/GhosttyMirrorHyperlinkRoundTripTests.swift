import AppKit
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// OSC 8 hyperlinks through a real macOS Ghostty mirror surface. A pane mirroring another device's
/// terminal hands the frame's link table to a Ghostty surface, which must hold each link as a page
/// hyperlink: that is what its own hover, underline and Cmd-click resolve against. Reading the surface
/// back through the export path shows the links survived the trip.
@MainActor final class GhosttyMirrorHyperlinkRoundTripTests: XCTestCase {
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

    /// A label that is not its target ("Docs" linked to a URL) keeps its target, and the cells around it
    /// stay unlinked.
    func testMirrorSurfaceRoundTripsALabelAndItsTarget() throws {
        let docs = "https://example.com/docs"
        let other = "https://example.com/other"
        let view = makeAttachedView()
        view.update(
            snapshot: Self.snapshot(text: "Docs  More", links: [0: docs, 1: docs, 2: docs, 3: docs, 6: other, 7: other, 8: other, 9: other]),
            renderStateKey: "links")

        let captured = try waitForSnapshot(view) { $0.columns == 10 && $0.linkURLs[0] != nil }
        XCTAssertEqual(captured.linkURLs[0], docs)
        XCTAssertEqual(captured.linkURLs[3], docs)
        XCTAssertNil(captured.linkURLs[4], "the gap between the labels is not part of either link")
        XCTAssertEqual(captured.linkURLs[6], other)
        XCTAssertEqual(captured.linkURLs[9], other)
    }

    /// Every 8 cells of a full grid carry their own long target. The page a mirror writes into starts with
    /// room for a few links, so this forces its string and hyperlink capacity to grow, which relocates the
    /// page and invalidates every pointer the write holds. Getting that wrong is memory corruption, so
    /// this pins that a frame far past the initial capacity applies and reads back whole.
    func testMirrorSurfaceAppliesAFullGridOfDistinctLinks() throws {
        let columns = 80
        let rows = 24
        let cellCount = columns * rows
        let view = makeAttachedView()
        let padding = String(repeating: "x", count: 100)
        var links: [Int: String] = [:]
        for index in 0..<cellCount { links[index] = "https://example.com/\(index / 8)/\(padding)" }
        view.update(
            snapshot: Self.snapshot(text: String(repeating: "a", count: cellCount), columns: columns, links: links), renderStateKey: "link-grid")

        let captured = try waitForSnapshot(view) { $0.columns == columns && $0.rows == rows && $0.linkURLs[0] != nil }
        let intact = (0..<cellCount).allSatisfy { captured.linkURLs[$0] == links[$0] }
        XCTAssertTrue(intact, "a full grid of links did not read back intact")
    }

    /// A later frame replaces the links of the one before it: a cell that lost its link reads back
    /// unlinked, and a cell whose link changed reads back the new target, never the earlier frame's.
    func testAFrameAppliedAgainReplacesThePreviousFramesLinks() throws {
        let first = "https://example.com/first"
        let second = "https://example.com/second"
        let view = makeAttachedView()
        view.update(snapshot: Self.snapshot(text: "abcd", links: [0: first, 1: first, 2: first, 3: first]), renderStateKey: "links-1")
        _ = try waitForSnapshot(view) { $0.columns == 4 && $0.linkURLs[0] == first }

        view.update(snapshot: Self.snapshot(text: "abcd", links: [2: second, 3: second]), renderStateKey: "links-2")

        let captured = try waitForSnapshot(view) { $0.columns == 4 && $0.linkURLs[2] == second }
        XCTAssertNil(captured.linkURLs[0], "a cell the new frame does not link keeps no link from the old frame")
        XCTAssertNil(captured.linkURLs[1])
        XCTAssertEqual(captured.linkURLs[3], second)
    }

    /// A wide character in a link label occupies two cells: the character and an empty spacer with no
    /// codepoint and a default style. Both halves carry the link, because hover and Cmd-click resolve the
    /// exact cell under the pointer.
    func testMirrorSurfaceKeepsTheLinkOnAWideCharactersSpacerCell() throws {
        let target = "https://example.com/wide"
        let view = makeAttachedView()
        let wide = GhosttyTerminalSnapshot.Cell(codepoint: 0x4E2D, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        let spacer = GhosttyTerminalSnapshot.Cell(
            codepoint: 0, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: GhosttyTerminalSnapshotGrid.spacerFlag)
        let plain = GhosttyTerminalSnapshot.Cell(codepoint: 0x61, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        view.update(
            snapshot: GhosttyTerminalSnapshot(
                columns: 3, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF, defaultBackgroundRGB: 0,
                cells: [wide, spacer, plain], linkURLs: [0: target, 1: target]), renderStateKey: "wide-link")

        let captured = try waitForSnapshot(view) { $0.columns == 3 && $0.linkURLs[0] != nil }
        XCTAssertEqual(captured.linkURLs[0], target)
        XCTAssertEqual(captured.linkURLs[1], target, "the spacer half of a wide character keeps its link")
        XCTAssertNil(captured.linkURLs[2])
    }

    // MARK: - Harness

    private func makeAttachedView() -> GhosttyMirrorTerminalView {
        let view = GhosttyMirrorTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "hyperlink-mirror", backend: .ghosttyEmbedded, title: "hyperlink-mirror", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-07-26T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window?.contentView?.addSubview(container)
        window?.contentView?.layoutSubtreeIfNeeded()
        return view
    }

    /// `text` laid out `columns` wide (one row of `text.count` cells when `columns` is nil), with each
    /// cell's link target in `links`.
    private static func snapshot(text: String, columns: Int? = nil, links: [Int: String]) -> GhosttyTerminalSnapshot {
        let cells = text.unicodeScalars.map { scalar in
            GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        }
        let width = columns ?? cells.count
        return GhosttyTerminalSnapshot(
            columns: width, rows: cells.count / width, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells, linkURLs: links)
    }

    // 30 seconds matches the embedded-surface waits across this target. Note this suite runs in its
    // own coverage.sh invocation, never the shared parallel run: it starts a real MIRROR-owned
    // ghostty app, and a worker process that ran any daemon-core suite first cannot host one
    // (GhosttyProcessAppRuntime's one-live-app-per-process contract).
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

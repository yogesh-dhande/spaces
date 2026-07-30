import AppKit
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// Grapheme fidelity through a real macOS Ghostty mirror surface. A pane mirroring another device's
/// terminal gets its cells over the render wire and hands them to a Ghostty surface; what that
/// surface holds afterwards has to be the cell's whole cluster — the emoji a coding agent, package
/// manager, or test runner emits — not just its base scalar. Reading it back also covers the export
/// direction, which is the path `captureFromSurface` runs.
@MainActor final class GhosttyMirrorGraphemeClusterTests: XCTestCase {
    /// Clusters a terminal keeps in a single cell under grapheme clustering: a variation selector, a
    /// skin-tone modifier, a four-member ZWJ family, a regional-indicator flag, and a combining mark.
    private static let sequences = ["\u{2764}\u{FE0F}", "👋🏽", "👨‍👩‍👧‍👦", "🇯🇵", "e\u{0301}"]
    private static let family = "👨‍👩‍👧‍👦"

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

    /// A frame carrying clusters must survive the trip through the C snapshot and the mirror's real
    /// terminal state: what the surface exports back is what a client would read for copy,
    /// accessibility, and previews, and what its renderer draws.
    func testMirrorSurfaceRoundTripsGraphemeClusters() throws {
        let view = makeAttachedView()
        view.update(snapshot: Self.snapshot(clusters: [Self.sequences]), renderStateKey: "clusters")

        let captured = try waitForSnapshot(view) { snapshot in
            snapshot.columns == Self.sequences.count && snapshot.cells.count >= Self.sequences.count && snapshot.clusters[0] != nil
        }
        for (column, sequence) in Self.sequences.enumerated() {
            XCTAssertEqual(
                GhosttyTerminalSnapshotCellText.displayText(for: captured.cells[column], cluster: captured.clusters[column]), sequence,
                "column \(column) lost part of a \(sequence.unicodeScalars.count)-scalar cluster")
        }
    }

    /// Every cell of a full grid holding a six-codepoint cluster. The page a mirror writes into starts
    /// with room for a few clusters, so this is the case that forces its grapheme capacity to grow —
    /// which relocates the page and invalidates every cell pointer the write is holding. Getting that
    /// wrong is memory corruption, so this pins that a frame far past the initial capacity applies and
    /// reads back whole.
    func testMirrorSurfaceAppliesAFullGridOfClusters() throws {
        let columns = 80
        let rows = 24
        let view = makeAttachedView()
        view.update(
            snapshot: Self.snapshot(clusters: Array(repeating: Array(repeating: Self.family, count: columns), count: rows)),
            renderStateKey: "cluster-grid")

        let captured = try waitForSnapshot(view) { snapshot in
            snapshot.columns == columns && snapshot.rows == rows && snapshot.cells.count >= columns * rows && snapshot.clusters[0] != nil
        }
        let intact = (0..<(columns * rows)).allSatisfy {
            GhosttyTerminalSnapshotCellText.displayText(for: captured.cells[$0], cluster: captured.clusters[$0]) == Self.family
        }
        XCTAssertTrue(intact, "a full grid of clusters did not read back intact")
    }

    // MARK: - Harness

    private func makeAttachedView() -> GhosttyMirrorTerminalView {
        let view = GhosttyMirrorTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "grapheme-mirror", backend: .ghosttyEmbedded, title: "grapheme-mirror", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                command: "cat", createdAt: "2026-07-26T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window?.contentView?.addSubview(container)
        window?.contentView?.layoutSubtreeIfNeeded()
        return view
    }

    /// A grid whose cells each hold one cluster, shaped the way a producer builds a frame: the cluster
    /// travels whole and the base codepoint stays populated for a consumer that renders one scalar.
    private static func snapshot(clusters: [[String]]) -> GhosttyTerminalSnapshot {
        let columns = clusters.map(\.count).max() ?? 0
        var cells: [GhosttyTerminalSnapshot.Cell] = []
        var clusterTable: [Int: String] = [:]
        for row in clusters {
            for column in 0..<columns {
                let cluster = column < row.count ? row[column] : " "
                if cluster.unicodeScalars.count > 1 { clusterTable[cells.count] = cluster }
                cells.append(
                    GhosttyTerminalSnapshot.Cell(
                        codepoint: cluster.unicodeScalars.first?.value ?? 0x20, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0))
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: clusters.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells, clusters: clusterTable)
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

import AppKit
import Foundation
import GhosttyKit
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// Link activation through a real Ghostty mirror surface. A pane mirrors another device's terminal,
/// and the link under a click is found by that local surface, never by the session on the other end.
/// Which modifiers reach the link depends on whether the mirrored terminal is tracking the mouse:
/// under a tracking application Ghostty refreshes link hover state only for a shift-held pointer,
/// which is why a Mac pane needs cmd+shift and why the iOS tap probe adds shift to its synthesized
/// click. That coupling lives in Ghostty, so it is pinned here against a real surface rather than
/// re-derived from the fork's source.
@MainActor final class GhosttyMirrorLinkActivationTests: XCTestCase {
    private static let url = "https://example.com"

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

    /// Nothing is tracking the mouse: cmd alone activates the link, and adding shift does not, because
    /// shift is then just another modifier the link's own requirement does not match.
    func testIdleTerminalActivatesLinkOnCommandClickOnly() throws {
        XCTAssertEqual(try openedLinks(mouseReportingActive: false, modifierFlags: [.command]), [Self.url])
        XCTAssertEqual(try openedLinks(mouseReportingActive: false, modifierFlags: [.command, .shift]), [])
    }

    /// An application is tracking the mouse: cmd alone finds no link because Ghostty suppresses link
    /// hover under a tracking terminal, and cmd+shift releases the pointer from the application long
    /// enough for the link to resolve.
    func testTrackingTerminalActivatesLinkOnlyWhenShiftReleasesThePointer() throws {
        XCTAssertEqual(try openedLinks(mouseReportingActive: true, modifierFlags: [.command]), [])
        XCTAssertEqual(try openedLinks(mouseReportingActive: true, modifierFlags: [.command, .shift]), [Self.url])
    }

    // MARK: - Harness

    /// Renders a single-line frame holding a URL into a real mirror surface, clicks the URL with the
    /// given modifiers, and returns what the pane was asked to open.
    private func openedLinks(mouseReportingActive: Bool, modifierFlags: NSEvent.ModifierFlags) throws -> [String] {
        let view = makeAttachedView(sessionID: "link-\(mouseReportingActive)-\(modifierFlags.rawValue)")
        defer { view.removeFromSuperview() }
        view.update(
            snapshot: Self.snapshot(text: Self.url, mouseReportingActive: mouseReportingActive),
            renderStateKey: "link|\(mouseReportingActive)|\(modifierFlags.rawValue)")
        _ = try waitForSnapshot(view) { $0.columns >= Self.url.count }

        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }

        let windowNumber = window?.windowNumber ?? 0
        view.mouseMoved(with: mouseEvent(type: .mouseMoved, windowNumber: windowNumber, modifierFlags: modifierFlags))
        view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: windowNumber, modifierFlags: modifierFlags))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: windowNumber, modifierFlags: modifierFlags))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return opened
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

    private static func snapshot(text: String, mouseReportingActive: Bool) -> GhosttyTerminalSnapshot {
        let cells = text.unicodeScalars.map { scalar in
            GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        }
        return GhosttyTerminalSnapshot(
            columns: cells.count, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells, mouseReportingActive: mouseReportingActive)
    }

    /// The click lands a few characters into the URL on the top row of a 640x400 pane.
    private func mouseEvent(type: NSEvent.EventType, windowNumber: Int, modifierFlags: NSEvent.ModifierFlags) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 20, y: 392), modifierFlags: modifierFlags, timestamp: 0, windowNumber: windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
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

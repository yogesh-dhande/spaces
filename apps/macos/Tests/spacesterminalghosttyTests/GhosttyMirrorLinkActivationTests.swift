import AppKit
import Foundation
import GhosttyKit
import XCTest
import ghosttyvtshim
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
        try assertOpenedLinks([Self.url], mouseReportingActive: false, modifierFlags: [.command])
        try assertOpenedLinks([], mouseReportingActive: false, modifierFlags: [.command, .shift])
    }

    /// An application is tracking the mouse: cmd alone finds no link because Ghostty suppresses link
    /// hover under a tracking terminal, and cmd+shift releases the pointer from the application long
    /// enough for the link to resolve.
    func testTrackingTerminalActivatesLinkOnlyWhenShiftReleasesThePointer() throws {
        try assertOpenedLinks([], mouseReportingActive: true, modifierFlags: [.command])
        try assertOpenedLinks([Self.url], mouseReportingActive: true, modifierFlags: [.command, .shift])
    }

    /// The Linux daemon and ended-session replay both export this frame through libghostty-vt. The
    /// mirror must retain its row metadata through the render-update codec so Ghostty's local link
    /// detector joins the visual rows before opening the URL.
    func testSoftWrappedLinkFromVTSnapshotActivatesAsCompleteURL() throws {
        try assertOpenedLinks([Self.url], snapshot: Self.softWrappedVTSnapshot(), modifierFlags: [.command])
    }

    /// A hyperlink whose label is not its target: the link table carries the target, and the click
    /// finds it on the surface because the frame's links were written onto its pages. The same rules
    /// as a URL in the text decide which modifiers activate it.
    func testIdleTerminalActivatesOSC8LabelOnCommandClickOnly() throws {
        let snapshot = Self.osc8Snapshot(mouseReportingActive: false)
        try assertOpenedLinks([Self.osc8Target], snapshot: snapshot, modifierFlags: [.command])
        try assertOpenedLinks([], snapshot: snapshot, modifierFlags: [], "a plain click on a link label opens nothing")
        try assertOpenedLinks([], snapshot: snapshot, modifierFlags: [.command, .shift])
    }

    func testTrackingTerminalActivatesOSC8LabelOnlyWhenShiftReleasesThePointer() throws {
        let snapshot = Self.osc8Snapshot(mouseReportingActive: true)
        try assertOpenedLinks([], snapshot: snapshot, modifierFlags: [.command])
        try assertOpenedLinks([Self.osc8Target], snapshot: snapshot, modifierFlags: [.command, .shift])
    }

    /// The click arrives tagged as an OSC 8 open, which is what puts the target under the untrusted-link
    /// policy rather than the open-anything rule a link detected in the text gets.
    func testOSC8ClickReportsItsKind() throws {
        let view = try attachedView(snapshot: Self.osc8Snapshot(mouseReportingActive: false), modifierFlags: [.command])
        defer { view.removeFromSuperview() }
        var kinds: [GhosttyActionEvent.OpenURLKind] = []
        view.onOpenLink = { _, kind in kinds.append(kind) }
        click(view, modifierFlags: [.command])
        waitUntil("the click's open-link action") { !kinds.isEmpty }
        XCTAssertEqual(kinds, [.osc8])
    }

    /// Cmd held over the label shows the target (sanitized as the standalone Ghostty banner shows it).
    func testHoveringAnOSC8LabelWithCommandHeldReportsItsTarget() throws {
        let view = try attachedView(snapshot: Self.osc8Snapshot(mouseReportingActive: false), modifierFlags: [.command])
        defer { view.removeFromSuperview() }
        XCTAssertNil(view.debugLinkTooltip)

        view.mouseMoved(with: mouseEvent(type: .mouseMoved, windowNumber: window?.windowNumber ?? 0, modifierFlags: [.command]))
        waitUntil("the hover to report the label's target") { view.hoveredLinkDisplayString == Self.osc8Target }

        XCTAssertEqual(view.hoveredLinkDisplayString, Self.osc8Target)
        XCTAssertEqual(view.debugLinkTooltip?.text, Self.osc8Target)
    }

    /// Pressing Cmd over a link highlights it without the pointer moving, and releasing it clears the
    /// highlight. The modifier event is delivered through the application, as the system does, while the
    /// pane is not the first responder: the pane under the pointer is not necessarily the focused one.
    func testPressingAndReleasingCommandOverALabelTogglesTheHoverWithoutMovingThePointer() throws {
        let snapshot = Self.osc8Snapshot(mouseReportingActive: false)
        let view = try attachedView(snapshot: snapshot, modifierFlags: [])
        defer { view.removeFromSuperview() }
        let windowNumber = window?.windowNumber ?? 0
        XCTAssertTrue(window?.firstResponder !== view, "the hovered pane is not focused")

        view.mouseMoved(with: mouseEvent(type: .mouseMoved, windowNumber: windowNumber, modifierFlags: []))
        settleForAbsence()
        XCTAssertNil(view.hoveredLinkDisplayString, "without Cmd the label is plain text")

        NSApplication.shared.sendEvent(flagsChangedEvent(windowNumber: windowNumber, modifierFlags: [.command]))
        waitUntil("Cmd to highlight the label") { view.hoveredLinkDisplayString == Self.osc8Target }
        XCTAssertEqual(view.hoveredLinkDisplayString, Self.osc8Target)
        XCTAssertEqual(view.debugLinkTooltip?.text, Self.osc8Target)

        NSApplication.shared.sendEvent(flagsChangedEvent(windowNumber: windowNumber, modifierFlags: []))
        waitUntil("releasing Cmd to clear the highlight") { view.hoveredLinkDisplayString == nil }
        XCTAssertNil(view.hoveredLinkDisplayString)
        XCTAssertNil(view.debugLinkTooltip, "the tooltip goes as soon as the hover clears")
    }

    /// Once the pointer has left the pane, Cmd changes no longer reach it.
    func testCommandPressedAfterThePointerLeavesDoesNotHighlightTheLabel() throws {
        let view = try attachedView(snapshot: Self.osc8Snapshot(mouseReportingActive: false), modifierFlags: [])
        defer { view.removeFromSuperview() }
        let windowNumber = window?.windowNumber ?? 0

        view.mouseMoved(with: mouseEvent(type: .mouseMoved, windowNumber: windowNumber, modifierFlags: []))
        view.mouseExited(
            with: try XCTUnwrap(
                NSEvent.enterExitEvent(
                    with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: windowNumber, context: nil, eventNumber: 2,
                    trackingNumber: 0, userData: nil)))
        NSApplication.shared.sendEvent(flagsChangedEvent(windowNumber: windowNumber, modifierFlags: [.command]))
        settleForAbsence()

        XCTAssertNil(view.hoveredLinkDisplayString)
    }

    /// A path the program wrapped itself, with no soft-wrap flag on either row: a click on either row
    /// offers the rejoined path first, then the text Ghostty matched on that row.
    func testClickOnEitherRowOfAHardWrappedPathOffersTheJoinedPathFirst() throws {
        let wrapped = Self.hardWrappedPath
        try assertOpenedLinks(
            [wrapped.joined, wrapped.firstRow], snapshot: wrapped.snapshot, modifierFlags: [.command], clickedCell: (column: 5, row: 0))
        try assertOpenedLinks(
            [wrapped.joined, wrapped.secondRow], snapshot: wrapped.snapshot, modifierFlags: [.command], clickedCell: (column: 5, row: 1))
    }

    /// A hyperlink carries its whole target, so a wrapped one is never rejoined from the text.
    func testClickOnAnOSC8LinkOffersASingleCandidate() throws {
        try assertOpenedLinks([Self.osc8Target], snapshot: Self.osc8Snapshot(mouseReportingActive: false), modifierFlags: [.command])
    }

    // MARK: - Harness

    private static let hardWrappedPath: (joined: String, firstRow: String, secondRow: String, snapshot: GhosttyTerminalSnapshot) = {
        let columns = 40
        let joined = "/Users/dev/projects/spaces/apps/macos/Sources/File.swift"
        let firstRow = String(joined.prefix(columns))
        let secondRow = String(joined.dropFirst(columns))
        let rows = [firstRow, "  " + secondRow]
        let cells = (0..<(columns * rows.count)).map { index -> GhosttyTerminalSnapshot.Cell in
            let scalars = Array(rows[index / columns].unicodeScalars)
            let scalar = index % columns < scalars.count ? scalars[index % columns].value : 0x20
            return GhosttyTerminalSnapshot.Cell(codepoint: scalar, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        }
        let snapshot = GhosttyTerminalSnapshot(
            columns: columns, rows: rows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells)
        return (joined, firstRow, secondRow, snapshot)
    }()

    private static let osc8Target = "https://example.com/docs"

    /// A label that is not its target, linked to `osc8Target` across all of its cells.
    private static func osc8Snapshot(mouseReportingActive: Bool) -> GhosttyTerminalSnapshot {
        let label = "Documentation"
        let cells = label.unicodeScalars.map { scalar in
            GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
        }
        var linkURLs: [Int: String] = [:]
        for index in 0..<cells.count { linkURLs[index] = osc8Target }
        return GhosttyTerminalSnapshot(
            columns: cells.count, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells, linkURLs: linkURLs, mouseTrackingLevel: mouseReportingActive ? .clicks : .none)
    }

    /// A view that has applied `snapshot`; the caller removes it.
    private func attachedView(snapshot: GhosttyTerminalSnapshot, modifierFlags: NSEvent.ModifierFlags) throws -> GhosttyMirrorTerminalView {
        let view = makeAttachedView(sessionID: "link-\(snapshot.columns)x\(snapshot.rows)-\(modifierFlags.rawValue)")
        view.update(snapshot: snapshot, renderStateKey: "link|\(snapshot.columns)x\(snapshot.rows)|\(modifierFlags.rawValue)")
        _ = try waitForSnapshot(view) { $0.columns == snapshot.columns && $0.rows == snapshot.rows }
        return view
    }

    private func click(_ view: GhosttyMirrorTerminalView, modifierFlags: NSEvent.ModifierFlags, at point: NSPoint? = nil) {
        let windowNumber = window?.windowNumber ?? 0
        view.mouseMoved(with: mouseEvent(type: .mouseMoved, windowNumber: windowNumber, modifierFlags: modifierFlags, at: point))
        view.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: windowNumber, modifierFlags: modifierFlags, at: point))
        view.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: windowNumber, modifierFlags: modifierFlags, at: point))
    }

    /// Link hover and link opens reach the view as Ghostty actions, which `GhosttyMirrorAppService`
    /// hops onto the main actor in two steps after the event that raised them, so a test reads the
    /// outcome only once it has arrived. The wait is on the outcome itself; the timeout only bounds a
    /// failing run.
    private func waitUntil(_ outcome: String, timeout: TimeInterval = 30, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line)
    {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(outcome)", file: file, line: line) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// For an assertion that nothing happened: an event that never fires cannot be awaited, so this
    /// gives one a generous window to arrive. A late delivery can only hide a regression here, never
    /// fail a correct run.
    private func settleForAbsence() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    private func flagsChangedEvent(windowNumber: Int, modifierFlags: NSEvent.ModifierFlags) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: modifierFlags, timestamp: 0, windowNumber: windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
    }

    private func assertOpenedLinks(
        _ expected: [String], mouseReportingActive: Bool, modifierFlags: NSEvent.ModifierFlags, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try assertOpenedLinks(
            expected, snapshot: Self.snapshot(text: Self.url, mouseReportingActive: mouseReportingActive), modifierFlags: modifierFlags, message,
            file: file, line: line)
    }

    private func assertOpenedLinks(
        _ expected: [String], snapshot: GhosttyTerminalSnapshot, modifierFlags: NSEvent.ModifierFlags, clickedCell: (column: Int, row: Int)? = nil,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let opened = try openedLinks(expecting: expected.count, snapshot: snapshot, modifierFlags: modifierFlags, clickedCell: clickedCell)
        XCTAssertEqual(opened, expected, message, file: file, line: line)
    }

    /// The links a click opened. A click expected to open `count` links is read once that many have
    /// arrived; one expected to open none is read after `settleForAbsence`.
    private func openedLinks(
        expecting count: Int, snapshot: GhosttyTerminalSnapshot, modifierFlags: NSEvent.ModifierFlags, clickedCell: (column: Int, row: Int)? = nil
    ) throws -> [String] {
        let view = makeAttachedView(sessionID: "link-\(snapshot.columns)x\(snapshot.rows)-\(modifierFlags.rawValue)")
        defer { view.removeFromSuperview() }
        view.update(snapshot: snapshot, renderStateKey: "link|\(snapshot.columns)x\(snapshot.rows)|\(modifierFlags.rawValue)")
        _ = try waitForSnapshot(view) { $0.columns == snapshot.columns && $0.rows == snapshot.rows }

        var opened: [String] = []
        view.onOpenLink = { candidates, _ in opened.append(contentsOf: candidates) }
        let point = try clickedCell.map { try XCTUnwrap(view.windowPointForTesting(column: $0.column, row: $0.row)) }
        click(view, modifierFlags: modifierFlags, at: point)
        if count > 0 { waitUntil("the click to open \(count) link(s)") { opened.count >= count } } else { settleForAbsence() }
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
            defaultBackgroundRGB: 0, cells: cells, mouseTrackingLevel: mouseReportingActive ? .clicks : .none)
    }

    /// Build the frame from the real vt exporter, then pass it through the same delta codec and
    /// applier a remote mirror receives. Do not synthesize row flags here: their absence is the
    /// original regression this test protects against.
    private static func softWrappedVTSnapshot() throws -> GhosttyTerminalSnapshot {
        let columns: UInt16 = 8
        let rows: UInt16 = 3
        let session = try XCTUnwrap(spaces_ghostty_vt_session_new(columns, rows, 0, nil))
        defer { spaces_ghostty_vt_session_free(session) }

        let output = Data(Self.url.utf8)
        XCTAssertTrue(output.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })

        var rawSnapshot = SpacesGhosttyVtSnapshot()
        XCTAssertTrue(spaces_ghostty_vt_session_copy_snapshot(session, &rawSnapshot))
        defer { spaces_ghostty_vt_snapshot_free(&rawSnapshot) }
        let exported = GhosttyVtSessionBridge.snapshot(from: rawSnapshot, mouseTrackingLevel: .none, alternateScreenActive: false)

        let blank = GhosttyTerminalSnapshot(
            columns: Int(columns), rows: Int(rows), cursorColumn: 0, cursorRow: 0, cursorVisible: false,
            defaultForegroundRGB: exported.defaultForegroundRGB, defaultBackgroundRGB: exported.defaultBackgroundRGB,
            cells: Array(
                repeating: .init(codepoint: 0, foregroundRGB: exported.defaultForegroundRGB, backgroundRGB: exported.defaultBackgroundRGB, flags: 0),
                count: Int(columns) * Int(rows)))
        let baseline = GhosttyRenderUpdateBaseline(snapshot: blank, sessionRevision: 1, ownerEpoch: 1)
        let update = GhosttyRenderUpdateFactory.makeUpdate(
            target: GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: exported), baseline: baseline)
        let decoded = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update))
        return try GhosttyRenderUpdateApplier.apply(decoded, to: baseline).snapshot
    }

    /// Without a `point` the click lands a few characters into the URL on the top row of a 640x400 pane.
    private func mouseEvent(type: NSEvent.EventType, windowNumber: Int, modifierFlags: NSEvent.ModifierFlags, at point: NSPoint? = nil) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point ?? NSPoint(x: 20, y: 392), modifierFlags: modifierFlags, timestamp: 0, windowNumber: windowNumber, context: nil,
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

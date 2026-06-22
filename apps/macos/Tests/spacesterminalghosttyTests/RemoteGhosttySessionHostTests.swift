import AppKit
import Carbon
import Foundation
import GhosttyKit
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class RemoteGhosttySessionHostTests: XCTestCase {
    private var originalDatabasePath: String?
    private var databaseRoot: URL?
    private final class RuntimeNotificationProbe: @unchecked Sendable { var count = 0 }
    private final class DirectTerminalServiceRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [GhosttyRemoteSessionStatePayload]
        private var recordedRequests: [TerminalServiceRequest] = []

        init(payload: GhosttyRemoteSessionStatePayload) { payloads = [payload] }

        init(payloads: [GhosttyRemoteSessionStatePayload]) { self.payloads = payloads }

        func send(_ request: TerminalServiceRequest) throws -> TerminalServiceResponse {
            lock.lock()
            recordedRequests.append(request)
            let currentPayload: GhosttyRemoteSessionStatePayload?
            if case .state = request.command, payloads.count > 1 { currentPayload = payloads.removeFirst() } else { currentPayload = payloads.first }
            lock.unlock()

            switch request.command {
            case .state: return TerminalServiceResponse(ok: true, message: "state", sessionState: currentPayload)
            case .control:
                return TerminalServiceResponse(
                    ok: true, message: "controlled", controlResponse: TerminalControlResponse(ok: true, message: "controlled"))
            default: return TerminalServiceResponse(ok: false, message: "Unexpected command '\(request.commandName)'.")
            }
        }

        func setPayload(_ payload: GhosttyRemoteSessionStatePayload) {
            lock.lock()
            payloads = [payload]
            lock.unlock()
        }

        func requests() -> [TerminalServiceRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let databaseRoot { try? FileManager.default.removeItem(at: databaseRoot) }
        databaseRoot = nil
        originalDatabasePath = nil
        try super.tearDownWithError()
    }

    @MainActor private final class FocusableView: NSView { override var acceptsFirstResponder: Bool { true } }
    @MainActor private final class KeyTestWindow: NSWindow { override var isKeyWindow: Bool { true } }
    @MainActor private final class ActivatingTestWindow: NSWindow {
        var keyWindowState = false
        override var isKeyWindow: Bool { keyWindowState }
        override func makeKeyAndOrderFront(_ sender: Any?) { keyWindowState = true }
    }

    @MainActor private func searchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField, searchField.accessibilityIdentifier() == "terminal-search-field" { return searchField }
        for subview in view.subviews { if let searchField = searchField(in: subview) { return searchField } }
        return nil
    }

    @MainActor func testRemoteMirrorForwardsModifiedBackspaceSpecs() throws {
        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: keyEvent(keyCode: UInt16(kVK_Delete))), "backspace")
        XCTAssertEqual(
            GhosttyMirrorTerminalView.remoteKeySpecifier(for: keyEvent(keyCode: UInt16(kVK_Delete), modifierFlags: .option)), "opt+backspace")
        XCTAssertEqual(
            GhosttyMirrorTerminalView.remoteKeySpecifier(for: keyEvent(keyCode: UInt16(kVK_Delete), modifierFlags: .command)), "cmd+backspace")
        XCTAssertEqual(
            GhosttyMirrorTerminalView.remoteKeySpecifier(
                for: keyEvent(keyCode: UInt16(kVK_Delete), modifierFlags: [.command, .numericPad, .function])), "cmd+backspace")
    }

    @MainActor func testRemoteMirrorMapsCommandKToClearScreenControl() throws {
        XCTAssertEqual(GhosttyMirrorTerminalView.remoteKeySpecifier(for: keyEvent(keyCode: UInt16(kVK_ANSI_K), modifierFlags: .command)), "cmd+k")
    }

    @MainActor func testRemoteMirrorEncodesPreciseScrollMods() {
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .changed), 0b0000_0111)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .ended), 0b0000_1001)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .cancelled), 0b0000_1011)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: .mayBegin), 0b0000_1101)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: true, phase: []), 0b0000_0001)
        XCTAssertEqual(GhosttyMirrorTerminalView.makeScrollMods(hasPreciseDeltas: false, phase: []), 0)
    }

    @MainActor func testRemoteMirrorMapsMouseModifiersButtonsAndCoordinatesLikeGhosttyAppKitSurface() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let mods = GhosttyMirrorTerminalView.ghosttyMouseModifiers(for: flags).rawValue

        XCTAssertNotEqual(mods & GHOSTTY_MODS_SHIFT.rawValue, 0)
        XCTAssertNotEqual(mods & GHOSTTY_MODS_CTRL.rawValue, 0)
        XCTAssertNotEqual(mods & GHOSTTY_MODS_ALT.rawValue, 0)
        XCTAssertNotEqual(mods & GHOSTTY_MODS_SUPER.rawValue, 0)
        XCTAssertEqual(GhosttyMirrorTerminalView.ghosttyMouseButton(for: 0), GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(GhosttyMirrorTerminalView.ghosttyMouseButton(for: 1), GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(GhosttyMirrorTerminalView.ghosttyMouseButton(for: 2), GHOSTTY_MOUSE_MIDDLE)
        XCTAssertEqual(GhosttyMirrorTerminalView.ghosttyMouseButton(for: 3), GHOSTTY_MOUSE_EIGHT)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let view = NSView(frame: NSRect(x: 10, y: 20, width: 200, height: 100))
        container.addSubview(view)

        let position = GhosttyMirrorTerminalView.ghosttyMousePosition(for: NSPoint(x: 60, y: 70), in: view)

        XCTAssertEqual(position.x, 50, accuracy: 0.01)
        XCTAssertEqual(position.y, 50, accuracy: 0.01)
    }

    @MainActor func testRemoteMirrorSuppressesFocusOnlyMouseClickBeforeForwarding() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-focus-only-mouse", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = ActivatingTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.addSubview(mirrorView)
        mirrorView.frame = container.bounds
        mirrorView.acceptsTerminalInput = true
        mirrorView.debugMouseEventHandler = { _ in true }
        defer { window.close() }

        XCTAssertFalse(window.isKeyWindow)

        mirrorView.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: window.windowNumber))
        mirrorView.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: window.windowNumber))

        XCTAssertTrue(window.isKeyWindow)
        XCTAssertEqual(mirrorView.debugRecordedMouseEvents, [])

        mirrorView.mouseDown(with: mouseEvent(type: .leftMouseDown, windowNumber: window.windowNumber))
        mirrorView.mouseUp(with: mouseEvent(type: .leftMouseUp, windowNumber: window.windowNumber))

        XCTAssertEqual(mirrorView.debugRecordedMouseEvents.count, 4)
        XCTAssertEqual(mirrorView.debugRecordedMouseEvents.first, "position")
        XCTAssertTrue(mirrorView.debugRecordedMouseEvents.contains("button:press:\(GHOSTTY_MOUSE_LEFT.rawValue)"))
        XCTAssertTrue(mirrorView.debugRecordedMouseEvents.contains("button:release:\(GHOSTTY_MOUSE_LEFT.rawValue)"))
    }

    @MainActor func testRemoteMirrorDoesNotReapplyIdenticalRevisionedRenderFrame() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-idempotent-frame", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-06T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugRenderFrameApplyHandler = { _, _ in true }
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let nextFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 0, snapshot: snapshot(text: "beta"))

        mirrorView.update(frame: firstFrame, renderStateKey: "runtime=5x1|frame=5x1|ownerEpoch=0")
        mirrorView.update(frame: firstFrame, renderStateKey: "runtime=5x1|frame=5x1|ownerEpoch=0")
        mirrorView.update(frame: nextFrame, renderStateKey: "runtime=5x1|frame=5x1|ownerEpoch=0")
        mirrorView.update(frame: nextFrame, renderStateKey: "runtime=4x1|frame=4x1|ownerEpoch=0")

        XCTAssertEqual(mirrorView.debugRenderFrameApplyCount, 3)
    }

    @MainActor func testRemoteMirrorReappliesSameRevisionFrameWhenSnapshotChanges() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-same-revision-changed-frame", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-09T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugRenderFrameApplyHandler = { _, _ in true }
        let staleFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let correctedFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha\n% "))

        mirrorView.update(frame: staleFrame, renderStateKey: "runtime=5x2|frame=5x2|ownerEpoch=0")
        mirrorView.update(frame: correctedFrame, renderStateKey: "runtime=5x2|frame=5x2|ownerEpoch=0")

        XCTAssertEqual(mirrorView.debugRenderFrameApplyCount, 2)
    }

    @MainActor func testRemoteMirrorReappliesSnapshotFrameWhenContentChangesWithoutRevision() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-idempotent-snapshot", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-06T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugRenderFrameApplyHandler = { _, _ in true }
        let firstFrame = GhosttyRenderFrame(sessionRevision: nil, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let changedFrame = GhosttyRenderFrame(sessionRevision: nil, ownerEpoch: 0, snapshot: snapshot(text: "bravo"))

        mirrorView.update(frame: firstFrame, renderStateKey: "snapshot=5x1")
        mirrorView.update(frame: firstFrame, renderStateKey: "snapshot=5x1")
        mirrorView.update(frame: changedFrame, renderStateKey: "snapshot=5x1")

        XCTAssertEqual(mirrorView.debugRenderFrameApplyCount, 2)
    }

    @MainActor func testRemoteMirrorSearchActionEventsUpdateOverlayState() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-actions", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-02T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)

        mirrorView.applyActionEvent(.startSearch("needle"))
        mirrorView.applyActionEvent(.searchTotal(3))
        mirrorView.applyActionEvent(.searchSelected(1))

        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "needle")
        XCTAssertEqual(mirrorView.debugSearchState.total, 3)
        XCTAssertEqual(mirrorView.debugSearchState.selected, 1)

        mirrorView.applyActionEvent(.startSearch(nil))

        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "needle")

        mirrorView.applyActionEvent(.endSearch)

        XCTAssertFalse(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "")
    }

    @MainActor func testRemoteMirrorStartSearchWithNeedleSubmitsSeededQuery() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-selection", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugBindingActionHandler = { _ in true }

        mirrorView.applyActionEvent(.startSearch("selected-token"))

        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "selected-token")
        XCTAssertNil(mirrorView.debugSearchState.total)
        XCTAssertNil(mirrorView.debugSearchState.selected)
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:selected-token"])

        mirrorView.applyActionEvent(.startSearch(nil))

        XCTAssertEqual(mirrorView.debugSearchState.query, "selected-token")
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:selected-token"])
    }

    @MainActor func testRemoteMirrorIgnoresStaleSearchResultsAfterClose() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-stale-results", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugBindingActionHandler = { _ in true }

        mirrorView.applyActionEvent(.startSearch("needle"))
        mirrorView.applyActionEvent(.searchTotal(3))
        mirrorView.applyActionEvent(.searchSelected(1))
        XCTAssertEqual(mirrorView.debugSearchState.total, 3)
        XCTAssertEqual(mirrorView.debugSearchState.selected, 1)

        mirrorView.applyActionEvent(.endSearch)
        mirrorView.applyActionEvent(.searchTotal(9))
        mirrorView.applyActionEvent(.searchSelected(4))

        XCTAssertFalse(mirrorView.debugSearchState.isVisible)
        XCTAssertNil(mirrorView.debugSearchState.total)
        XCTAssertNil(mirrorView.debugSearchState.selected)

        mirrorView.applyActionEvent(.startSearch(nil))
        mirrorView.applyActionEvent(.searchTotal(9))
        mirrorView.applyActionEvent(.searchSelected(4))

        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "")
        XCTAssertNil(mirrorView.debugSearchState.total)
        XCTAssertNil(mirrorView.debugSearchState.selected)
    }

    @MainActor func testRemoteMirrorSearchFieldEditSubmitsQueryOnce() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-single-edit", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugBindingActionHandler = { _ in true }
        mirrorView.applyActionEvent(.startSearch(nil))
        let field = try XCTUnwrap(searchField(in: mirrorView))

        field.stringValue = "needle"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.sendAction(field.action, to: field.target)

        XCTAssertEqual(mirrorView.debugSearchState.query, "needle")
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:needle"])
    }

    @MainActor func testRemoteMirrorSearchFieldEditDebouncesShortQueries() async throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-short-debounce", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.debugBindingActionHandler = { _ in true }
        mirrorView.applyActionEvent(.startSearch(nil))
        let field = try XCTUnwrap(searchField(in: mirrorView))

        field.stringValue = "n"
        field.sendAction(field.action, to: field.target)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(mirrorView.debugSearchState.query, "n")
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, [])

        field.stringValue = "ne"
        field.sendAction(field.action, to: field.target)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, [])

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:ne"])

        field.stringValue = "nee"
        field.sendAction(field.action, to: field.target)

        XCTAssertEqual(mirrorView.debugRecordedBindingActions, ["search:ne", "search:nee"])
    }

    @MainActor func testRemoteMirrorReleaseSurfaceResetsSearchOverlay() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-release", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)

        mirrorView.applyActionEvent(.startSearch("needle"))
        mirrorView.applyActionEvent(.searchTotal(2))
        mirrorView.applyActionEvent(.searchSelected(0))
        XCTAssertTrue(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "needle")

        mirrorView.releaseSurface()

        XCTAssertFalse(mirrorView.debugSearchState.isVisible)
        XCTAssertEqual(mirrorView.debugSearchState.query, "")
        XCTAssertNil(mirrorView.debugSearchState.total)
        XCTAssertNil(mirrorView.debugSearchState.selected)
    }

    @MainActor func testRemoteMirrorInstallsMouseMoveTrackingArea() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-mouse-tracking", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        mirrorView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)

        mirrorView.updateTrackingAreas()

        let trackingArea = mirrorView.trackingAreas.first { $0.owner === mirrorView }
        XCTAssertNotNil(trackingArea)
        XCTAssertEqual(trackingArea?.options.contains(.mouseMoved), true)
        XCTAssertEqual(trackingArea?.options.contains(.mouseEnteredAndExited), true)
        XCTAssertEqual(trackingArea?.options.contains(.activeAlways), true)
        XCTAssertEqual(trackingArea?.options.contains(.inVisibleRect), true)
    }

    @MainActor func testRemoteMirrorSearchOverlayDoesNotReserveBlankStatusOrLoseFocus() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-search-focus", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-05T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.addSubview(mirrorView)
        mirrorView.frame = container.bounds
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        mirrorView.acceptsTerminalInput = true
        XCTAssertTrue(window.firstResponder === mirrorView)

        mirrorView.applyActionEvent(.startSearch(nil))
        XCTAssertTrue(mirrorView.debugSearchFieldHasFocus)
        XCTAssertFalse(mirrorView.debugSearchStatusVisible)
        XCTAssertEqual(mirrorView.debugSearchUpBindingAction, "navigate_search:next")
        XCTAssertEqual(mirrorView.debugSearchDownBindingAction, "navigate_search:previous")

        mirrorView.focusWindow(window)

        XCTAssertTrue(mirrorView.debugSearchFieldHasFocus)

        mirrorView.acceptsTerminalInput = false
        mirrorView.acceptsTerminalInput = true

        XCTAssertTrue(mirrorView.debugSearchFieldHasFocus)

        mirrorView.applyActionEvent(.startSearch("missing"))
        mirrorView.applyActionEvent(.searchTotal(0))

        XCTAssertTrue(mirrorView.debugSearchStatusVisible)
    }

    func testGhosttyActionEventParserParsesSearchEvents() {
        var start = ghostty_action_s()
        start.tag = GHOSTTY_ACTION_START_SEARCH
        "needle".withCString { pointer in
            start.action.start_search.needle = pointer
            XCTAssertEqual(GhosttyActionEventParser.parse(start), .startSearch("needle"))
        }

        var end = ghostty_action_s()
        end.tag = GHOSTTY_ACTION_END_SEARCH
        XCTAssertEqual(GhosttyActionEventParser.parse(end), .endSearch)

        var total = ghostty_action_s()
        total.tag = GHOSTTY_ACTION_SEARCH_TOTAL
        total.action.search_total = ghostty_action_search_total_s(total: 4)
        XCTAssertEqual(GhosttyActionEventParser.parse(total), .searchTotal(4))
        total.action.search_total = ghostty_action_search_total_s(total: -1)
        XCTAssertEqual(GhosttyActionEventParser.parse(total), .searchTotal(nil))

        var selected = ghostty_action_s()
        selected.tag = GHOSTTY_ACTION_SEARCH_SELECTED
        selected.action.search_selected = ghostty_action_search_selected_s(selected: 2)
        XCTAssertEqual(GhosttyActionEventParser.parse(selected), .searchSelected(2))
        selected.action.search_selected = ghostty_action_search_selected_s(selected: -1)
        XCTAssertEqual(GhosttyActionEventParser.parse(selected), .searchSelected(nil))
    }

    func testGhosttyActionEventParserParsesOpenURLAndMouseOverLinkEvents() {
        var open = ghostty_action_s()
        open.tag = GHOSTTY_ACTION_OPEN_URL
        "https://example.com/image.png".withCString { pointer in
            open.action.open_url = ghostty_action_open_url_s(
                kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, url: pointer, len: UInt("https://example.com/image.png".utf8.count))
            XCTAssertEqual(GhosttyActionEventParser.parse(open), .openURL(kind: .text, value: "https://example.com/image.png"))
        }

        var hover = ghostty_action_s()
        hover.tag = GHOSTTY_ACTION_MOUSE_OVER_LINK
        "/tmp/screenshot.png".withCString { pointer in
            hover.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: pointer, len: "/tmp/screenshot.png".utf8.count)
            XCTAssertEqual(GhosttyActionEventParser.parse(hover), .mouseOverLink("/tmp/screenshot.png"))
        }

        hover.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: nil, len: 0)
        XCTAssertEqual(GhosttyActionEventParser.parse(hover), .mouseOverLink(nil))
    }

    @MainActor func testMirrorTerminalViewOpensSupportedLinksAndTracksHover() {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-open-link", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-08T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        var openedURLs: [URL] = []
        mirrorView.debugOpenURLHandler = { url in
            openedURLs.append(url)
            return true
        }
        let macRecordingPath = "/Users/yogesh/Desktop/Screen Recording 2026-05-07 at 10.11.01\u{202F}AM.mov"

        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "/tmp/screenshot.png"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "file:///tmp/movie.mp4"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "file://localhost/tmp/local-report.png"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: macRecordingPath))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "file://build-host/tmp/remote-report.png"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "https://example.com/report"))
        mirrorView.applyActionEvent(.openURL(kind: .unknown, value: "relative/path.png"))

        let openedLinkRepresentations = openedURLs.map { url in url.isFileURL ? url.path : url.absoluteString }
        XCTAssertEqual(openedURLs.count, 5)
        XCTAssertEqual(
            openedLinkRepresentations,
            ["/tmp/screenshot.png", "/tmp/movie.mp4", "/tmp/local-report.png", macRecordingPath, "https://example.com/report"])

        mirrorView.applyActionEvent(.mouseOverLink("https://example.com/report"))
        XCTAssertEqual(mirrorView.debugHoveredLink, "https://example.com/report")
        mirrorView.applyActionEvent(.mouseOverLink(nil))
        XCTAssertNil(mirrorView.debugHoveredLink)
    }

    @MainActor func testRemoteMirrorWindowKeyHandoffRestoresFirstResponderAndSendsEnter() throws {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "remote-key-handoff", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil,
            createdAt: "2026-06-02T00:00:00Z")
        let mirrorView = GhosttyMirrorTerminalView(launchConfiguration: launchConfiguration)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.addSubview(mirrorView)
        mirrorView.frame = container.bounds
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let dummyResponder = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(dummyResponder)
        var sentKeys: [String] = []
        mirrorView.acceptsTerminalInput = true
        mirrorView.onSendKey = { sentKeys.append($0) }
        XCTAssertTrue(window.makeFirstResponder(dummyResponder))
        XCTAssertTrue(window.firstResponder === dummyResponder)

        XCTAssertTrue(mirrorView.handleTerminalKeyEvent(keyEvent(keyCode: UInt16(kVK_Return)), requireFirstResponder: false))

        XCTAssertEqual(sentKeys, ["enter"])
        XCTAssertTrue(window.firstResponder === mirrorView)
    }

    func testSnapshotTextCaptureReadsVisibleViewport() {
        let selection = GhosttyTerminalSnapshotCapture.visibleViewportSelection(columns: 80, rows: 24)

        XCTAssertEqual(selection.top_left.tag, GHOSTTY_POINT_VIEWPORT)
        XCTAssertEqual(selection.top_left.coord, GHOSTTY_POINT_COORD_TOP_LEFT)
        XCTAssertEqual(selection.bottom_right.tag, GHOSTTY_POINT_VIEWPORT)
        XCTAssertEqual(selection.bottom_right.coord, GHOSTTY_POINT_COORD_BOTTOM_RIGHT)
    }

    func testRemoteHostSendsResizeWhenRuntimeStillHasPreviousOwnerSize() {
        XCTAssertTrue(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: (columns: 120, rows: 40), pendingSize: nil,
                runtimeSize: (columns: 60, rows: 20), force: false))
        XCTAssertFalse(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: (columns: 120, rows: 40), pendingSize: nil,
                runtimeSize: (columns: 120, rows: 40), force: false))
        XCTAssertFalse(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: nil, pendingSize: (columns: 120, rows: 40),
                runtimeSize: (columns: 60, rows: 20), force: false))
        XCTAssertTrue(
            RemoteGhosttySessionHost.shouldSendViewportResize(
                requestedSize: (columns: 120, rows: 40), lastRequestedSize: nil, pendingSize: (columns: 120, rows: 40),
                runtimeSize: (columns: 60, rows: 20), force: true))
    }

    @MainActor func testStateStreamClientPreservesOutputBeforeInputOutputResync() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-state-stream-preserve-events")
        let initialPayload = remoteStatePayload(sessionID: "stream-preserve-events", reason: TerminalRemoteSessionStateReason.initial)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(socketPath: paths.subscriptionSocketPath) { payload in receivedPayloads.append(payload) }
        try client.start()
        defer { client.stop() }

        waitForCondition("initial stream payload") { receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        receivedPayloads.removeAll()

        server.broadcast(
            remoteStatePayload(
                sessionID: "stream-preserve-events", reason: TerminalRemoteSessionStateReason.output, outputByteCount: 11, outputEndByteOffset: 42))
        server.broadcast(remoteStatePayload(sessionID: "stream-preserve-events", reason: TerminalRemoteSessionStateReason.inputOutput))

        waitForCondition("output before input-output resync") {
            receivedPayloads.count >= 2 && receivedPayloads[0].reason == TerminalRemoteSessionStateReason.output
                && receivedPayloads[1].reason == TerminalRemoteSessionStateReason.inputOutput
        }
        XCTAssertEqual(receivedPayloads[0].outputByteCount, 11)
        XCTAssertEqual(receivedPayloads[0].outputEndByteOffset, 42)
    }

    @MainActor func testEndedRemoteHostDoesNotReloadFinalStateFromNotificationRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-final-reentry"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-04T00:00:00Z")
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-04T00:00:01Z",
            exitedAt: "2026-06-04T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 5, rows: 1)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        try TerminalSessionPersistence.writeRemoteSessionState(
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-04T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "done", sessionRevision: 1)), paths: paths)

        let probe = RuntimeNotificationProbe()
        let observer = NotificationCenter.default.addObserver(forName: .spacesTerminalRuntimeStateDidChange, object: nil, queue: nil) {
            notification in
            guard notification.userInfo?["sessionID"] as? String == sessionID else { return }
            MainActor.assumeIsolated {
                probe.count += 1
                if probe.count == 1 { _ = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths).effectiveTitle }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths)
        XCTAssertEqual(host.effectiveTitle, "final-title")
        XCTAssertEqual(host.snapshotText(), "done")
        XCTAssertEqual(probe.count, 0)
    }

    @MainActor func testEndedRemoteHostPermitsReadOnlyBindingsForFinalRenderViewer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-final-read-only-bindings"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z")
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-05T00:00:01Z",
            exitedAt: "2026-06-05T00:00:01Z", title: "final-title", workingDirectory: "/tmp/final", columns: 4, rows: 1)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        try TerminalSessionPersistence.writeRemoteSessionState(
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-05T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-title", workingDirectory: "/tmp/final", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "done", sessionRevision: 1)), paths: paths)

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths)
        host.debugSetBindingActionHandler { _ in true }
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        XCTAssertEqual(host.snapshotText(), "done")
        XCTAssertTrue(host.performBindingAction("select_all"))
        XCTAssertTrue(host.performBindingAction("copy_to_clipboard"))
        XCTAssertTrue(host.performBindingAction("end_search"))
        XCTAssertFalse(host.performBindingAction("start_search"))
        XCTAssertFalse(host.performBindingAction("search:done"))
        XCTAssertFalse(host.performBindingAction("clear_screen"))
        XCTAssertEqual(host.debugRecordedBindingActions, ["select_all", "copy_to_clipboard", "end_search"])
    }

    @MainActor func testRunningRemoteHostRejectsViewerBindingActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-running-viewer-bindings"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "live", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-05T00:00:00Z")
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-06-05T00:00:01Z",
                title: "live", workingDirectory: "/tmp/work", columns: 4, rows: 1), paths: paths)

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths)
        host.debugSetBindingActionHandler { _ in true }
        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-05T00:00:02Z"),
            mode: .viewer, into: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)))

        XCTAssertFalse(host.performBindingAction("select_all"))
        XCTAssertFalse(host.performBindingAction("copy_to_clipboard"))
        XCTAssertFalse(host.performBindingAction("end_search"))
        XCTAssertEqual(host.debugRecordedBindingActions, [])
    }

    @MainActor func testRemoteHostIgnoresStaleFinalStateWhenRuntimeIsRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-stale-final-live"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "fallback", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
            createdAt: "2026-06-04T00:00:00Z")
        let runningState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-06-04T00:00:02Z",
            title: "live-title", workingDirectory: "/tmp/live", columns: 4, rows: 1)
        let staleExitedState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-06-04T00:00:01Z",
            exitedAt: "2026-06-04T00:00:01Z", title: "stale-title", workingDirectory: "/tmp/stale", columns: 5, rows: 1)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runningState, paths: paths)
        try TerminalSessionPersistence.writeRemoteSessionState(
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-04T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: staleExitedState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "stale-title", workingDirectory: "/tmp/stale", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "stale", sessionRevision: 1)), paths: paths)

        let liveRenderUpdate = try renderUpdate(text: "live", sessionRevision: 2)
        let server = GhosttyRemoteSessionStateStreamServer(
            socketPath: paths.subscriptionSocketPath, queue: DispatchQueue(label: "spaces.remote-device.stale-final-live-test")
        ) {
            GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-06-04T00:00:02Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runningState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "live-title", workingDirectory: "/tmp/live", outputByteCount: nil, renderUpdate: liveRenderUpdate)
        }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths)

        waitForCondition("live stream supersedes stale final state") { host.snapshotText() == "live" }
        XCTAssertEqual(host.effectiveTitle, "live-title")
    }

    @MainActor func testStateStreamClientReceivesRenderUpdatePayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "stream-render-update", reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-06-03T00:00:00Z",
            sessionStateRevision: 1, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "live",
            workingDirectory: "/tmp/live", outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
        let server = GhosttyRemoteSessionStateStreamServer(
            socketPath: paths.subscriptionSocketPath, queue: DispatchQueue(label: "spaces.remote-state-stream-render-update-only")
        ) { initialPayload }
        try server.start()
        defer { server.stop() }

        var receivedPayloads: [GhosttyRemoteSessionStatePayload] = []
        let client = GhosttyRemoteSessionStateStreamClient(
            socketPath: paths.subscriptionSocketPath, onEvent: { payload in receivedPayloads.append(payload) })
        try client.start()
        defer { client.stop() }

        waitForCondition("render-update stream payload") { receivedPayloads.contains { $0.reason == TerminalRemoteSessionStateReason.initial } }
        let payload = try XCTUnwrap(receivedPayloads.first { $0.reason == TerminalRemoteSessionStateReason.initial })
        XCTAssertNotNil(payload.renderUpdate)
        let snapshot = try XCTUnwrap(payload.renderSnapshot)
        XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: snapshot), "alpha")
    }

    func testStateStreamClientDoesNotCoalesceDeltaRenderUpdatePayloads() throws {
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let secondFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 0, snapshot: snapshot(text: "bravo"))
        let thirdFrame = GhosttyRenderFrame(sessionRevision: 3, ownerEpoch: 0, snapshot: snapshot(text: "charl"))
        let firstBaseline = GhosttyRenderUpdateBaseline(frame: firstFrame)
        let firstDelta = GhosttyRenderUpdateFactory.makeUpdate(target: secondFrame, baseline: firstBaseline)
        let secondBaseline = try GhosttyRenderUpdateApplier.apply(firstDelta, to: firstBaseline)
        let secondDelta = GhosttyRenderUpdateFactory.makeUpdate(target: thirdFrame, baseline: secondBaseline)
        XCTAssertEqual(firstDelta.kind, .delta)
        XCTAssertEqual(secondDelta.kind, .delta)

        func payload(_ update: GhosttyRenderUpdate, revision: UInt64) throws -> GhosttyRemoteSessionStatePayload {
            GhosttyRemoteSessionStatePayload(
                sessionID: "stream-delta-coalescing", reason: TerminalRemoteSessionStateReason.stateChange,
                emittedAt: "2026-06-03T00:00:0\(revision)Z", sessionStateRevision: revision, sessionStateFlags: 1, screenStateRevision: revision,
                runtimeState: nil, attachmentSnapshot: nil, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(update))
        }

        let pendingDeltaPayload = try payload(firstDelta, revision: 2)
        let incomingDeltaPayload = try payload(secondDelta, revision: 3)
        let incomingFullPayload = try payload(.full(thirdFrame), revision: 3)
        let pendingMetadataPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "stream-delta-coalescing", reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-06-03T00:00:01Z",
            sessionStateRevision: 2, sessionStateFlags: 1, screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "live",
            workingDirectory: "/tmp/live", outputByteCount: nil)

        XCTAssertFalse(GhosttyRemoteSessionStateStreamClient.canCoalescePendingEvent(pendingDeltaPayload, with: incomingDeltaPayload))
        XCTAssertFalse(GhosttyRemoteSessionStateStreamClient.canCoalescePendingEvent(pendingDeltaPayload, with: incomingFullPayload))
        XCTAssertFalse(GhosttyRemoteSessionStateStreamClient.canCoalescePendingEvent(pendingMetadataPayload, with: incomingDeltaPayload))
        XCTAssertTrue(GhosttyRemoteSessionStateStreamClient.canCoalescePendingEvent(pendingMetadataPayload, with: pendingMetadataPayload))
    }

    @MainActor func testRemoteHostPrefersRenderFrameSnapshotWhenAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.stream-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-live", reason: "initial", emittedAt: "2026-05-18T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-live", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-18T00:00:00Z",
                title: "live", workingDirectory: "/tmp/live", columns: 5, rows: 1), attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "live", workingDirectory: "/tmp/live", outputByteCount: nil, renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-live", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-18T00:00:00Z"), paths: paths)

        waitForCondition("initial live snapshot") { host.snapshotText() == "alpha" }
        XCTAssertEqual(host.effectiveTitle, "live")
        XCTAssertEqual(host.effectiveWorkingDirectory, "/tmp/live")

        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-live", reason: "output", emittedAt: "2026-05-18T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1,
                screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-live", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-18T00:00:01Z", title: "live", workingDirectory: "/tmp/live", columns: 4, rows: 2),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: 9,
                renderUpdate: try renderUpdate(text: "beta\ngamm", sessionRevision: 2)))

        waitForCondition("updated live snapshot") { host.snapshotText() == "beta\ngamm" }
        XCTAssertEqual(host.snapshot()?.rows, 2)

        let ownerClient = TerminalClient(
            id: "owner-client", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPad"), connectedAt: "2026-05-18T00:00:02Z")
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [ownerClient],
            attachments: [TerminalAttachment(sessionID: "remote-live", clientID: ownerClient.id, mode: .owner, attachedAt: "2026-05-18T00:00:02Z")])
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-live", reason: "attachment_state", emittedAt: "2026-05-18T00:00:02Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: attachmentSnapshot, title: "live",
                workingDirectory: "/tmp/live", outputByteCount: nil))

        waitForCondition("owner update without snapshot") { host.activeOwnerClientID() == ownerClient.id }
        XCTAssertEqual(host.snapshotText(), "beta\ngamm")
        XCTAssertNil(host.snapshot())
    }

    @MainActor func testRemoteHostDoesNotUseOutputLogWhenSnapshotSizeIsStale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-stale-size", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-22T00:00:00Z", columns: 12, rows: 2), paths: paths)
        try "from-log\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-stale-size", reason: "resize", emittedAt: "2026-05-22T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-stale-size", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-22T00:00:00Z", title: "live", workingDirectory: "/tmp/live", columns: 12, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "tiny", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(
            socketPath: paths.subscriptionSocketPath, queue: DispatchQueue(label: "spaces.remote-device.stale-size-test")
        ) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-stale-size", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-22T00:00:00Z"), paths: paths)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse((host.snapshotText() ?? "").contains("from-log"))
        XCTAssertFalse(host.snapshotText()?.contains("tiny") == true)
    }

    @MainActor func testRemoteHostDoesNotBuildTerminalRenderFromOutputLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-render", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-05-17T00:00:00Z",
                columns: 4, rows: 2), paths: paths)
        let transcript = "\u{001B}[31mAB\u{001B}[0mCD\u{001B}[2;1HEF"
        try transcript.write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-render", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-17T00:00:00Z"), paths: paths)

        XCTAssertNil(host.snapshot())
        XCTAssertNil(host.snapshotText())
    }

    @MainActor func testRemoteHostIgnoresOutputLogChangesWithoutRenderFrameSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-truncate", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-17T00:00:00Z", columns: 8, rows: 2), paths: paths)
        try "hello world".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-truncate", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-17T00:00:00Z"), paths: paths)

        XCTAssertNil(host.snapshotText())

        try "reset".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        XCTAssertNil(host.snapshotText())
    }

    @MainActor func testRemoteHostExposesViewerSnapshotWhenLiveStateIsAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.renderable-viewer-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-renderable", reason: "initial", emittedAt: "2026-05-19T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-renderable", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-19T00:00:00Z", title: "renderable", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "renderable", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-renderable", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-19T00:00:00Z"), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-19T00:00:00Z"),
            mode: .viewer, into: container)

        waitForCondition("rendered viewer text") { (host.snapshotText() ?? "").contains("alpha") }

        XCTAssertTrue((host.snapshotText() ?? "").contains("beta"))
        if host.hasRenderableSurface() { XCTAssertTrue(normalize(host.debugVisibleSurfaceText()).contains("alpha")) }
    }

    @MainActor func testRemoteOwnerFrameUpdateRestoresMirrorFirstResponder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.owner-focus-render-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-owner-focus", reason: "initial", emittedAt: "2026-06-02T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-owner-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-06-02T00:00:00Z", title: "owner", workingDirectory: "/tmp/live", columns: 8, rows: 1),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "owner", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-owner-focus", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-06-02T00:00:00Z"), paths: paths)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = KeyTestWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(
                id: "owner-client", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-02T00:00:00Z"),
            mode: .owner, into: container)
        waitForCondition("initial owner first responder") { window.firstResponder is GhosttyMirrorTerminalView }

        let dummyResponder = FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(dummyResponder)
        XCTAssertTrue(window.makeFirstResponder(dummyResponder))
        XCTAssertTrue(window.firstResponder === dummyResponder)

        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-owner-focus", reason: "state_change", emittedAt: "2026-06-02T00:00:01Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-owner-focus", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-06-02T00:00:01Z", title: "owner", workingDirectory: "/tmp/live", columns: 8, rows: 1),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "owner", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "beta", sessionRevision: 2)))

        waitForCondition("owner first responder restored") { window.firstResponder is GhosttyMirrorTerminalView }
    }

    @MainActor func testRemoteRenderableViewerPreservesSnapshotAcrossAttachmentStateChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.attachment-state-render-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-attachment-state", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-attachment-state", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-20T00:00:00Z", title: "renderable", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "renderable", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-attachment-state", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-20T00:00:00Z"), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-20T00:00:00Z"),
            mode: .viewer, into: container)

        waitForCondition("initial rendered viewer text") { self.normalize(self.visibleText(for: host)).contains("alpha") }

        let ownerClient = TerminalClient(
            id: "ipad-owner", kind: .remoteViewer, identity: TerminalClientIdentity(label: "iPad"), connectedAt: "2026-05-20T00:00:01Z")
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [ownerClient],
            attachments: [
                TerminalAttachment(sessionID: "remote-attachment-state", clientID: ownerClient.id, mode: .owner, attachedAt: "2026-05-20T00:00:01Z")
            ])
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-attachment-state", reason: "attachment_state", emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: attachmentSnapshot, title: "renderable",
                workingDirectory: "/tmp/live", outputByteCount: nil))

        waitForCondition("attachment state owner update") { host.activeOwnerClientID() == ownerClient.id }
        waitForCondition("viewer retains rendered text after attachment state") {
            self.normalize(self.visibleText(for: host)).contains("alpha") && self.normalize(self.visibleText(for: host)).contains("beta")
        }

        XCTAssertEqual(normalize(visibleText(for: host)), normalize("alpha\nbeta "))
    }

    @MainActor func testRemoteRenderableViewerPrefersSnapshotWhenFreshUpdateAlsoIncludesIncrementalOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let queue = DispatchQueue(label: "spaces.remote-device.snapshot-precedence-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-snapshot-precedence", reason: "initial", emittedAt: "2026-05-21T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: nil,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-snapshot-precedence", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-21T00:00:00Z", title: "renderable", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "renderable", workingDirectory: "/tmp/live", outputByteCount: nil)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-snapshot-precedence", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-21T00:00:00Z"), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-21T00:00:00Z"),
            mode: .viewer, into: container)

        try "WRONG\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-snapshot-precedence", reason: "output", emittedAt: "2026-05-21T00:00:01Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 1,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-snapshot-precedence", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-21T00:00:01Z", title: "renderable", workingDirectory: "/tmp/live", columns: 8, rows: 2),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "renderable", workingDirectory: "/tmp/live", outputByteCount: 5,
                renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 2)))

        waitForCondition("viewer renders snapshot instead of output history") {
            self.normalize(self.visibleText(for: host)).contains("alpha") && self.normalize(self.visibleText(for: host)).contains("beta")
        }

        XCTAssertFalse(normalize(visibleText(for: host)).contains("WRONG"))
        XCTAssertFalse(normalize(host.snapshotText()).contains("WRONG"))
        XCTAssertEqual(normalize(visibleText(for: host)), normalize("alpha\nbeta "))
    }

    @MainActor func testRemoteRenderableOwnerPrefersHandoffSnapshotOverOutputLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-handoff-snapshot", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-29T00:00:00Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2), paths: paths)
        let queue = DispatchQueue(label: "spaces.remote-device.handoff-snapshot-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-handoff-snapshot", reason: "initial", emittedAt: "2026-05-29T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: nil,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-handoff-snapshot", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-29T00:00:00Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live", workingDirectory: "/tmp/live", outputByteCount: nil)
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-handoff-snapshot", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-29T00:00:00Z"), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-29T00:00:00Z")
        try host.attach(client: client, mode: .owner, into: container)

        try "WRONG\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [client],
            attachments: [
                TerminalAttachment(sessionID: "remote-handoff-snapshot", clientID: client.id, mode: .owner, attachedAt: "2026-05-29T00:00:01Z")
            ])
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-handoff-snapshot", reason: "attachment_state", emittedAt: "2026-05-29T00:00:01Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-handoff-snapshot", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-29T00:00:01Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2),
                attachmentSnapshot: attachmentSnapshot, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 2)))

        waitForCondition("owner handoff snapshot") {
            self.normalize(self.visibleText(for: host)).contains("alpha") && self.normalize(self.visibleText(for: host)).contains("beta")
        }

        XCTAssertFalse(normalize(visibleText(for: host)).contains("WRONG"))
        XCTAssertEqual(normalize(visibleText(for: host)), normalize("alpha\nbeta "))
    }

    @MainActor func testRemoteMirrorRecreatesNativeSurfaceAfterRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-30T00:00:00Z")
        let attachmentSnapshot = TerminalSessionAttachmentSnapshot(
            clients: [client],
            attachments: [
                TerminalAttachment(sessionID: "remote-recreate-surface", clientID: client.id, mode: .owner, attachedAt: "2026-05-30T00:00:00Z")
            ])
        let queue = DispatchQueue(label: "spaces.remote-device.recreate-surface-test")
        let initialPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "remote-recreate-surface", reason: "initial", emittedAt: "2026-05-30T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "remote-recreate-surface", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-30T00:00:00Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2),
            attachmentSnapshot: attachmentSnapshot, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
            renderUpdate: try renderUpdate(text: "alpha\nbeta ", sessionRevision: 1))
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: paths.subscriptionSocketPath, queue: queue) { initialPayload }
        try server.start()
        defer { server.stop() }

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-recreate-surface", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-30T00:00:00Z"), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(client: client, mode: .owner, into: container)
        waitForCondition("initial native mirror") { host.hasRenderableSurface() && self.normalize(self.visibleText(for: host)).contains("alpha") }

        host.releaseRendererSurface()
        XCTAssertFalse(host.hasRenderableSurface())

        try host.attach(client: client, mode: .owner, into: container)
        server.broadcast(
            GhosttyRemoteSessionStatePayload(
                sessionID: "remote-recreate-surface", reason: "output", emittedAt: "2026-05-30T00:00:01Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: "remote-recreate-surface", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                    updatedAt: "2026-05-30T00:00:01Z", title: "live", workingDirectory: "/tmp/live", columns: 8, rows: 2),
                attachmentSnapshot: attachmentSnapshot, title: "live", workingDirectory: "/tmp/live", outputByteCount: nil,
                renderUpdate: try renderUpdate(text: "gamma\ndelta", sessionRevision: 2)))

        waitForCondition("recreated native mirror") { host.hasRenderableSurface() && self.normalize(self.visibleText(for: host)).contains("gamma") }
        XCTAssertEqual(normalize(visibleText(for: host)), normalize("gamma\ndelta"))
    }

    @MainActor func testRemoteHostDoesNotRefreshRenderFromOutputHistoryWhenHistoryAdvances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-history-refresh", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-22T00:00:00Z", columns: 24, rows: 4), paths: paths)
        try "first\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-history-refresh", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-22T00:00:00Z"), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-22T00:00:00Z"),
            mode: .owner, into: container)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(normalize(visibleText(for: host)).contains("first"))

        try "first\nsecond\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(normalize(visibleText(for: host)).contains("second"))
    }

    @MainActor func testRemoteMirrorViewDoesNotRenderOutputLogQueryResponses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: "remote-query-responses", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running,
                updatedAt: "2026-05-28T00:00:00Z", columns: 80, rows: 8), paths: paths)
        let transcript = "before\r\n\u{1B}[6n\u{1B}]10;?\u{7}after\r\n"
        try transcript.write(toFile: paths.outputPath, atomically: true, encoding: .utf8)

        let host = RemoteGhosttySessionHost(
            launchConfiguration: .init(
                sessionID: "remote-query-responses", title: "remote", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-05-28T00:00:00Z"), paths: paths)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try host.attach(
            client: TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-05-28T00:00:00Z"),
            mode: .owner, into: container)

        let renderedText = normalize(visibleText(for: host))
        XCTAssertFalse(renderedText.contains("before"))
        XCTAssertFalse(renderedText.contains("after"))
        XCTAssertFalse(renderedText.contains("^["))
        XCTAssertFalse(renderedText.contains("^]"))
        XCTAssertFalse(renderedText.contains("rgb:"))
        XCTAssertFalse(renderedText.contains(";R"))
    }

    @MainActor func testRemoteHostFetchesStateAndSendsDirectDaemonControls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-direct-daemon"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "remote", workingDirectory: "/tmp/work", shell: "/bin/bash", command: "cat",
            createdAt: "2026-06-10T00:00:00Z")
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-06-10T00:00:00Z",
            title: "remote", workingDirectory: "/tmp/work", columns: 5, rows: 1)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-06-10T00:00:01Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil, renderUpdate: try renderUpdate(text: "alpha", sessionRevision: 1))
        let recorder = DirectTerminalServiceRecorder(payload: payload)

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send)

        waitForCondition("direct daemon state render") { host.snapshotText() == "alpha" }
        XCTAssertEqual(try TerminalSessionPersistence.readRemoteSessionState(paths: paths).sessionID, sessionID)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-06-10T00:00:02Z")
        try host.attach(client: client, mode: .owner, into: container)

        XCTAssertTrue(host.clearScreenAndScrollback())
        waitForCondition("direct daemon control") {
            recorder.requests().contains {
                if case .control(let payload) = $0.command {
                    return payload.sessionID == sessionID && payload.controlRequest.command == "clearScreen"
                        && payload.controlRequest.clientID == client.id
                }
                return false
            }
        }
        XCTAssertTrue(
            recorder.requests().contains { request in
                if case .state(let payload) = request.command { return payload.sessionID == sessionID }
                return false
            })
    }

    @MainActor func testRemoteHostRequestsDirectStateResyncAfterMissingDeltaBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "remote-direct-resync"
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "remote", workingDirectory: "/tmp/work", shell: "/bin/bash", command: "cat",
            createdAt: "2026-06-10T00:00:00Z")
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-06-10T00:00:00Z",
            title: "remote", workingDirectory: "/tmp/work", columns: 5, rows: 1)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot(text: "alpha"))
        let secondFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 0, snapshot: snapshot(text: "bravo"))
        let missingBaselineDelta = GhosttyRenderUpdateFactory.makeUpdate(
            target: secondFrame, baseline: GhosttyRenderUpdateBaseline(frame: firstFrame))
        XCTAssertEqual(missingBaselineDelta.kind, .delta)
        let deltaPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-06-10T00:00:01Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
            renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(missingBaselineDelta))
        let fullPayload = GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: "2026-06-10T00:00:02Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            title: "remote", workingDirectory: "/tmp/work", outputByteCount: nil,
            renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(secondFrame)))
        let recorder = DirectTerminalServiceRecorder(payloads: [deltaPayload, fullPayload])

        let host = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: recorder.send)

        waitForCondition("direct state resync request") {
            recorder.requests().filter { request in
                if case .state = request.command { return true }
                return false
            }.count >= 2 && host.snapshotText() == "bravo"
        }
    }

    @MainActor private func waitForCondition(_ label: String, timeout: TimeInterval = 2, condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    private func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = rows.map(\.count).max() ?? 0
        let paddedRows = rows.map { row in row.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedRows.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: paddedRows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000, cells: cells)
    }

    private func renderUpdate(text: String, sessionRevision: UInt64? = nil, ownerEpoch: UInt64 = 0) throws -> Data {
        let frame = GhosttyRenderFrame(sessionRevision: sessionRevision, ownerEpoch: ownerEpoch, snapshot: snapshot(text: text))
        return try GhosttyRenderUpdateBinaryCodec.encode(.full(frame))
    }

    private func remoteStatePayload(sessionID: String, reason: String, outputByteCount: Int? = nil, outputEndByteOffset: Int? = nil)
        -> GhosttyRemoteSessionStatePayload
    {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: reason, emittedAt: "2026-06-03T00:00:00Z", sessionStateRevision: nil, sessionStateFlags: nil,
            screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: "live", workingDirectory: "/tmp/live",
            outputByteCount: outputByteCount, outputEndByteOffset: outputEndByteOffset)
    }

    private func normalize(_ text: String?) -> String {
        (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private func visibleText(for host: RemoteGhosttySessionHost) -> String? { host.debugVisibleSurfaceText() ?? host.snapshotText() }

    @MainActor private func keyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifierFlags, timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: keyCode))
    }

    @MainActor private func mouseEvent(type: NSEvent.EventType, windowNumber: Int) -> NSEvent {
        try! XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 20, y: 30), modifierFlags: [], timestamp: 0, windowNumber: windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

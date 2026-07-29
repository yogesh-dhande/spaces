import AppKit
import Foundation
import GhosttyKit
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// Terminal panes keep their Ghostty mirror surface — tens of megabytes of IOSurface buffers each —
/// only while they are among the most recently displayed panes. These tests drive that lifecycle the
/// way the app does: a pane is displayed by putting its container in a window and hidden by taking
/// the container out again.
@MainActor final class GhosttyMirrorSurfaceMRUTests: XCTestCase {
    private var window: NSWindow?
    private var secondaryWindow: NSWindow?
    private var mainQueueDrained = false

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
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.orderOut(nil)
        window = nil
        secondaryWindow?.orderOut(nil)
        secondaryWindow = nil
        GhosttyMirrorSurfaceMRU.shared.resetForTesting()
        super.tearDown()
    }

    func testHiddenPaneSurfaceIsFreedOnceNewerPanesFillTheWarmLimit() throws {
        let limit = GhosttyMirrorSurfaceMRU.warmSurfaceLimit
        let panes = (0...limit).map { makePane(index: $0) }

        for pane in panes.prefix(limit) {
            show(pane)
            XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "\(pane.label) did not build a surface when displayed")
            hide(pane)
        }
        for pane in panes.prefix(limit) { XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "\(pane.label) was freed while within the warm limit") }

        show(panes[limit])

        XCTAssertFalse(panes[0].view.debugHasLiveMirrorSurface, "the least recently displayed pane kept its surface past the warm limit")
        for pane in panes.dropFirst() { XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "\(pane.label) was freed while within the warm limit") }
    }

    func testMostRecentlyDisplayedPaneKeepsItsSurfaceHoweverManyPanesFollowIt() throws {
        let limit = GhosttyMirrorSurfaceMRU.warmSurfaceLimit
        let first = makePane(index: 0)
        show(first)
        hide(first)

        for index in 1...(limit * 2) {
            let pane = makePane(index: index)
            show(pane)
            hide(pane)
            // Every later pane displaces the one before it, but the pane displayed most recently is
            // never a candidate: it is the one the user is looking at.
            XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "\(pane.label) was freed while it was the most recently displayed pane")
        }

        XCTAssertFalse(first.view.debugHasLiveMirrorSurface, "a pane hidden long ago kept its surface")
        XCTAssertTrue(first.view.hasRenderedContent, "a freed pane stopped reporting that it has terminal content to show")
    }

    func testFreedPaneRebuildsAndRepaintsItsSurfaceWhenDisplayedAgain() throws {
        let limit = GhosttyMirrorSurfaceMRU.warmSurfaceLimit
        let pane = makePane(index: 0)
        show(pane)
        waitForCondition("initial paint") { self.normalize(pane.view.debugMirrorSurfaceText).contains(pane.label) }
        hide(pane)

        for index in 1...limit {
            let filler = makePane(index: index)
            show(filler)
            hide(filler)
        }
        XCTAssertFalse(pane.view.debugHasLiveMirrorSurface, "the pane under test was not freed")
        XCTAssertNil(pane.view.debugMirrorSurfaceText, "a freed pane still read text back from a live surface")

        show(pane)

        XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "a re-displayed pane did not rebuild its surface")
        waitForCondition("repaint after redisplay") { self.normalize(pane.view.debugMirrorSurfaceText).contains(pane.label) }
    }

    func testPaneShowingNewOutputWhileFreedRepaintsThatOutputWhenDisplayedAgain() throws {
        let limit = GhosttyMirrorSurfaceMRU.warmSurfaceLimit
        let pane = makePane(index: 0)
        show(pane)
        waitForCondition("initial paint") { self.normalize(pane.view.debugMirrorSurfaceText).contains(pane.label) }
        hide(pane)
        for index in 1...limit {
            let filler = makePane(index: index)
            show(filler)
            hide(filler)
        }
        XCTAssertFalse(pane.view.debugHasLiveMirrorSurface)

        // The session keeps streaming frames into a hidden pane; the newest one must be what the pane
        // shows when it comes back, not the frame it last painted.
        pane.view.update(snapshot: Self.snapshot(text: "later-output"), renderStateKey: "state")
        show(pane)

        waitForCondition("repaint of the newest frame") { self.normalize(pane.view.debugMirrorSurfaceText).contains("later-output") }
        XCTAssertFalse(normalize(pane.view.debugMirrorSurfaceText).contains(pane.label))
    }

    func testDisplayedPanesKeepTheirSurfacesEvenPastTheWarmLimit() throws {
        // A split shows several panes at once. Freeing an on-screen pane's surface would blank it with
        // nothing left to trigger a rebuild, so the limit never applies to a displayed pane.
        let panes = (0...GhosttyMirrorSurfaceMRU.warmSurfaceLimit).map { makePane(index: $0) }
        for pane in panes { show(pane) }

        for pane in panes { XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "\(pane.label) was freed while it was on screen") }
    }

    func testRerenderingATabsPaneTreeKeepsEveryPaneWarmAndIntact() throws {
        // A tab holding more panes than the warm limit — a split.
        let panes = (0...GhosttyMirrorSurfaceMRU.warmSurfaceLimit).map { makePane(index: $0) }
        let tabHost = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window?.contentView?.addSubview(tabHost)
        renderTab(panes: panes, into: tabHost)
        settle()
        for pane in panes {
            XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "\(pane.label) did not build a surface when displayed")
            waitForCondition("\(pane.label) paints") { self.normalize(pane.view.debugMirrorSurfaceText).contains(pane.label) }
            // Search matches and selection live in the surface and cannot outlive it, so they show
            // whether a pane kept its surface or had it freed and rebuilt underneath it.
            pane.view.applyActionEvent(.startSearch(pane.label))
            XCTAssertTrue(pane.view.performBindingAction("select_all"), "\(pane.label) could not select its content")
            XCTAssertTrue(pane.view.debugHasSurfaceSelection, "\(pane.label) did not hold a selection before the rerender")
        }

        // Any layout change — a divider drag, a split or close elsewhere — rerenders the whole tree.
        renderTab(panes: panes, into: tabHost)
        settle()

        for pane in panes {
            XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "\(pane.label) was freed by a rerender that left it on screen")
            XCTAssertTrue(pane.view.debugSearchState.isVisible, "\(pane.label) lost its search overlay to a rerender")
            XCTAssertEqual(pane.view.debugSearchState.query, pane.label)
            XCTAssertTrue(pane.view.debugHasSurfaceSelection, "\(pane.label) lost its selection to a rerender")
        }
    }

    func testDisplayedPanesClaimTheWarmBudgetBeforeHiddenOnes() throws {
        let limit = GhosttyMirrorSurfaceMRU.warmSurfaceLimit
        let displayed = (0..<limit).map { makePane(index: $0) }
        for pane in displayed { show(pane) }
        let hidden = makePane(index: limit)
        show(hidden)
        hide(hidden)

        // The hidden pane is the most recently displayed of all of them, but `limit` panes on screen
        // have already exhausted the budget: the live total is max(limit, displayed panes), so a
        // hidden pane is kept warm only out of what the displayed ones leave behind.
        XCTAssertFalse(hidden.view.debugHasLiveMirrorSurface, "a hidden pane held a warm slot the displayed panes had already filled")
        for pane in displayed { XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "\(pane.label) was freed while it was on screen") }
    }

    func testPaneInAMiniaturizedWindowIsFreedAndRebuildsWhenTheWindowReturns() throws {
        let pane = makePane(index: 0)
        show(pane)
        waitForCondition("initial paint") { self.normalize(pane.view.debugMirrorSurfaceText).contains(pane.label) }

        window?.miniaturize(nil)
        waitForCondition("window leaves the screen") { self.window?.isVisible == false }
        settle()
        let secondaryWindow = Self.makeVisibleWindow()
        self.secondaryWindow = secondaryWindow
        let visiblePanes = (1...GhosttyMirrorSurfaceMRU.warmSurfaceLimit).map { makePane(index: $0) }
        for visiblePane in visiblePanes { show(visiblePane, in: secondaryWindow) }

        // A miniaturized window leaves its views' `window` set, so without a visibility signal this
        // pane would stay exempt from the cap for as long as the window stayed in the Dock.
        XCTAssertFalse(pane.view.debugHasLiveMirrorSurface, "a pane in a miniaturized window kept its surface past the warm limit")
        for visiblePane in visiblePanes {
            XCTAssertTrue(visiblePane.view.debugHasLiveMirrorSurface, "\(visiblePane.label) was freed while on screen")
        }

        window?.deminiaturize(nil)
        waitForCondition("window returns to the screen") { self.window?.isVisible == true }
        settle()

        XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "a pane did not rebuild its surface when its window came back")
        waitForCondition("repaint after the window returns") { self.normalize(pane.view.debugMirrorSurfaceText).contains(pane.label) }
    }

    func testPaneHiddenBehindTheStatusRendererIsFreedOnceNewerPanesFillTheWarmLimit() throws {
        let limit = GhosttyMirrorSurfaceMRU.warmSurfaceLimit
        let pane = makePane(index: 0)
        show(pane)
        XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "\(pane.label) did not build a surface when displayed")
        hideBehindStatusRenderer(pane)

        for index in 1...limit {
            let filler = makePane(index: index)
            show(filler)
            hide(filler)
        }

        // The window stays visible and the view stays attached to it, so without looking at the hidden
        // ancestor this pane would hold a warm slot forever — and, counted as displayed, would push the
        // panes the user actually switched to out of theirs.
        XCTAssertFalse(pane.view.debugHasLiveMirrorSurface, "a pane hidden behind the status renderer kept its surface past the warm limit")
    }

    func testPaneHiddenBehindTheStatusRendererRebuildsAndRepaintsWhenTheTerminalReturns() throws {
        let limit = GhosttyMirrorSurfaceMRU.warmSurfaceLimit
        let pane = makePane(index: 0)
        show(pane)
        waitForCondition("initial paint") { self.normalize(pane.view.debugMirrorSurfaceText).contains(pane.label) }
        hideBehindStatusRenderer(pane)
        for index in 1...limit {
            let filler = makePane(index: index)
            show(filler)
            hide(filler)
        }
        XCTAssertFalse(pane.view.debugHasLiveMirrorSurface, "the pane under test was not freed")
        XCTAssertTrue(pane.view.hasRenderedContent, "a freed pane stopped reporting that it has terminal content to show")

        showTerminalRendererAgain(pane)

        XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "a pane did not rebuild its surface when its terminal renderer came back")
        waitForCondition("repaint after the terminal renderer returns") { self.normalize(pane.view.debugMirrorSurfaceText).contains(pane.label) }
    }

    func testPaneAttachedBehindTheStatusRendererBuildsNoSurfaceUntilItIsShown() throws {
        // A viewer pane's terminal container is hidden from the moment the pane attaches: the product
        // shows that client a takeover prompt and never live content, so a surface for it is pure cost.
        let pane = makePane(index: 0)
        pane.container.isHidden = true
        show(pane)

        XCTAssertFalse(pane.view.debugHasLiveMirrorSurface, "a pane that was never on screen built a surface")
        // The pane controller unhides the terminal container only for a pane that reports content, and
        // the pane builds its surface only once that container is unhidden, so a pane holding a frame
        // must report content before it has a surface or it could never be shown at all.
        XCTAssertTrue(pane.view.hasRenderedContent, "a pane holding a frame reported nothing to render before it was shown")

        showTerminalRendererAgain(pane)

        XCTAssertTrue(pane.view.debugHasLiveMirrorSurface, "a pane did not build its surface when it was shown")
        waitForCondition("paint once shown") { self.normalize(pane.view.debugMirrorSurfaceText).contains(pane.label) }
    }

    func testFreedPaneDoesNotResizeItsSessionWhileHidden() throws {
        let session = try makeOwnerSession(sessionID: "mru-hidden-resize")
        defer { session.cleanUp() }
        let host = session.host
        let recorder = session.recorder

        window?.contentView?.addSubview(session.container)
        try host.attach(client: session.client, mode: .owner, into: session.container)
        waitForCondition("owner pane paints") { host.hasRenderableSurface() }
        // A displayed owner pane does report its grid: the session is resized to the surface Ghostty
        // actually rendered. Waiting for it also keeps that resize out of the count taken below.
        waitForCondition("displayed pane resizes its session") { recorder.resizeCount > 0 }

        session.container.removeFromSuperview()
        for index in 1...GhosttyMirrorSurfaceMRU.warmSurfaceLimit {
            let filler = makePane(index: index)
            show(filler)
            hide(filler)
        }

        // The pane's grid is unchanged while it is hidden, and its freed surface can no longer report
        // one. A pane that fell back to measuring its own bounds would resize the session to a grid
        // Ghostty never rendered — the session's rows and columns must stay untouched until the pane
        // comes back on screen.
        let resizesBeforeRefresh = recorder.resizeCount
        host.requestSurfaceRefresh()
        _ = host.synchronizeSurfaceGeometry()
        waitForCondition("state refresh lands") { recorder.stateCount > 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(recorder.resizeCount, resizesBeforeRefresh, "a hidden pane resized its session after its surface was freed")
    }

    /// Switching back to a workspace joins the pane to the window before the panel's edge constraints
    /// settle it, so the pane is momentarily laid out at a fraction of its real size and reports that
    /// grid — with its evicted surface rebuilt from inside that same pass. Sending it would cost the
    /// shell two SIGWINCHes (whose prompt redraw eats a line of scrollback) and a remote session a full
    /// reflow to the tiny grid, every single switch. Coming back to a pane the user left at the same
    /// size must not resize its session at all.
    func testSwitchingBackToAPaneAtUnchangedSizeDoesNotResizeItsSession() throws {
        let session = try makeOwnerSession(sessionID: "mru-switch-back-resize")
        defer { session.cleanUp() }
        let host = session.host
        let recorder = session.recorder
        let settledFrame = session.container.frame

        window?.contentView?.addSubview(session.container)
        try host.attach(client: session.client, mode: .owner, into: session.container)
        waitForCondition("owner pane paints") { host.hasRenderableSurface() }
        waitForCondition("displayed pane resizes its session") { recorder.resizeCount > 0 }
        waitForQuiescentResizes(recorder)

        // Switch away: the pane leaves the screen and later panes take its warm surface slot.
        session.container.removeFromSuperview()
        for index in 1...GhosttyMirrorSurfaceMRU.warmSurfaceLimit {
            let filler = makePane(index: index)
            show(filler)
            hide(filler)
        }

        // Switch back, the way the workspace detail does it: the pane joins the window before its real
        // frame is applied, rebuilding its surface against the unsettled size, and the settled frame
        // lands later in the same pass.
        let resizesBeforeSwitchBack = recorder.resizeCount
        session.container.frame = NSRect(x: 0, y: 0, width: 48, height: 32)
        window?.contentView?.addSubview(session.container)
        session.container.frame = settledFrame
        session.container.layoutSubtreeIfNeeded()
        settle()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(recorder.resizeCount, resizesBeforeSwitchBack, "switching back to a pane at its unchanged size resized the session anyway")
    }

    /// A size measured while the pane still had a surface must not be sent once that surface is gone.
    /// The surface sweep frees a pane's mirror on the view itself, so the session host is never told;
    /// with the send a turn behind the measurement, the two can interleave. The sequence below is the
    /// order that interleaves them: the pane leaves the screen (queueing the sweep), its frame settles
    /// while its mirror is still warm (queueing the send behind the sweep), and the sweep then frees the
    /// surface the queued size was measured on.
    func testSizeMeasuredBeforeAPaneLosesItsSurfaceIsNotSentAfterwards() throws {
        let session = try makeOwnerSession(sessionID: "mru-freed-before-send")
        defer { session.cleanUp() }
        let host = session.host
        let recorder = session.recorder

        window?.contentView?.addSubview(session.container)
        try host.attach(client: session.client, mode: .owner, into: session.container)
        waitForCondition("owner pane paints") { host.hasRenderableSurface() }
        waitForCondition("displayed pane resizes its session") { recorder.resizeCount > 0 }
        waitForQuiescentResizes(recorder)

        // Another pane holds the only warm slot, so this one is evictable the moment it goes hidden.
        // It stays on screen for the rest of the test, so it also has to give its surface back by hand:
        // an on-screen pane is exactly the one the registry never evicts.
        let occupant = makePane(index: 1)
        defer { occupant.view.releaseSurface() }
        show(occupant)
        let resizesBeforeHiding = recorder.resizeCount

        // Off the screen first, which queues the surface sweep; then the frame settles while the mirror
        // is still warm, queueing the send behind that sweep. Draining the main queue runs them in that
        // order: the surface is freed, and the size measured off it comes up for sending afterwards.
        session.container.removeFromSuperview()
        session.container.frame = NSRect(x: 0, y: 0, width: 220, height: 130)
        session.container.layoutSubtreeIfNeeded()
        settle()

        // Show the pane again at a size of its own. That resize is issued after the one above and must
        // land, so waiting for it — rather than for a stretch of wall clock — is what proves the earlier
        // send either happened or never will.
        session.container.frame = NSRect(x: 0, y: 0, width: 240, height: 150)
        window?.contentView?.addSubview(session.container)
        settle()
        waitForCondition("the re-shown pane resizes its session") { recorder.resizeCount > resizesBeforeHiding }
        waitForQuiescentResizes(recorder)

        XCTAssertEqual(recorder.resizeCount, resizesBeforeHiding + 1, "a pane resized its session to a grid measured on a surface it no longer holds")
    }

    /// The other half of the same rule: a size the pane genuinely settles at is still sent. A window
    /// drag or a divider move passes through intermediate sizes exactly like the switch above does, so
    /// suppressing them must not cost the session the size it ended on.
    func testPaneResizedThroughAnIntermediateSizeResizesItsSessionOnlyToTheSettledGrid() throws {
        let session = try makeOwnerSession(sessionID: "mru-settled-resize")
        defer { session.cleanUp() }
        let host = session.host
        let recorder = session.recorder

        window?.contentView?.addSubview(session.container)
        try host.attach(client: session.client, mode: .owner, into: session.container)
        waitForCondition("owner pane paints") { host.hasRenderableSurface() }
        waitForCondition("displayed pane resizes its session") { recorder.resizeCount > 0 }
        waitForQuiescentResizes(recorder)
        let startingGrid = try XCTUnwrap(recorder.lastResizeSize)
        let resizesBeforeDrag = recorder.resizeCount

        // Grow well past the starting size, then settle smaller than it — so the grid the session is
        // told about says on its own which of the two the pane sent.
        session.container.frame = NSRect(x: 0, y: 0, width: 620, height: 360)
        session.container.layoutSubtreeIfNeeded()
        session.container.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        session.container.layoutSubtreeIfNeeded()
        settle()
        waitForCondition("the settled size reaches the session") { recorder.resizeCount > resizesBeforeDrag }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(recorder.resizeCount, resizesBeforeDrag + 1, "a resize passing through an intermediate size sent more than the settled grid")
        let settledGrid = try XCTUnwrap(recorder.lastResizeSize)
        XCTAssertLessThan(settledGrid.columns, startingGrid.columns, "the session was resized to the intermediate grid rather than the settled one")
        XCTAssertLessThan(settledGrid.rows, startingGrid.rows, "the session was resized to the intermediate grid rather than the settled one")
    }

    // MARK: - Harness

    /// Waits until the pane and its session agree on a grid — the initial exchange resizes the session
    /// to the surface Ghostty rendered and then reads that size back — so a later count is a count of
    /// resizes this test caused.
    private func waitForQuiescentResizes(_ recorder: ControlRequestRecorder) {
        var previousCount = -1
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let count = recorder.resizeCount
            if count > 0, count == previousCount { return }
            previousCount = count
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Timed out waiting for the pane and its session to agree on a grid")
    }

    /// An owner pane wired to a stand-in daemon, with the session's own directories on disk.
    private struct OwnerSession {
        let host: RemoteGhosttySessionHost
        let recorder: ControlRequestRecorder
        let container: NSView
        let client: TerminalClient
        /// Tears the pane's surface down and removes its session directory. The suite's `tearDown`
        /// clears the surface registry without freeing anything, so a pane still holding a live mirror
        /// when its test ends keeps those IOSurface buffers for the life of the test process — this
        /// gives the pane the same teardown the app performs when it releases a renderer.
        let cleanUp: @MainActor () -> Void
    }

    private func makeOwnerSession(sessionID: String) throws -> OwnerSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()

        let client = TerminalClient(kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces window"), connectedAt: "2026-07-24T00:00:00Z")
        let renderUpdate = try GhosttyRenderUpdateBinaryCodec.encode(
            .full(GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: Self.snapshot(text: "alpha"))))
        let recorder = ControlRequestRecorder { columns, rows in
            Self.statePayload(sessionID: sessionID, client: client, renderUpdate: renderUpdate, columns: columns, rows: rows)
        }
        let host = RemoteGhosttySessionHost(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, title: "live", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths,
            terminalServiceRequestSender: recorder.send)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        return OwnerSession(
            host: host, recorder: recorder, container: container, client: client,
            cleanUp: {
                host.releaseRendererSurface()
                container.removeFromSuperview()
                try? FileManager.default.removeItem(at: root)
            })
    }

    private nonisolated static func statePayload(sessionID: String, client: TerminalClient, renderUpdate: Data, columns: Int, rows: Int)
        -> GhosttyRemoteSessionStatePayload
    {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: "initial", emittedAt: "2026-07-24T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .running, updatedAt: "2026-07-24T00:00:00Z",
                title: "live", workingDirectory: "/tmp/live", columns: columns, rows: rows),
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                clients: [client],
                attachments: [TerminalAttachment(sessionID: sessionID, clientID: client.id, mode: .owner, attachedAt: "2026-07-24T00:00:00Z")]),
            title: "live", workingDirectory: "/tmp/live", outputByteCount: nil, renderUpdate: renderUpdate)
    }

    /// Stands in for the session's daemon: it counts the control requests the host sends and, like a
    /// real session, adopts the grid it is resized to and reports it back as its runtime size.
    private final class ControlRequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let payloadForSize: @Sendable (Int, Int) -> GhosttyRemoteSessionStatePayload
        private var states = 0
        private var resizes = 0
        private var size = (columns: 8, rows: 5)

        init(payloadForSize: @escaping @Sendable (Int, Int) -> GhosttyRemoteSessionStatePayload) { self.payloadForSize = payloadForSize }

        var stateCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return states
        }

        var resizeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return resizes
        }

        /// The grid the session was last resized to; nil until the first resize lands.
        var lastResizeSize: (columns: Int, rows: Int)? {
            lock.lock()
            defer { lock.unlock() }
            return resizes > 0 ? size : nil
        }

        func send(_ request: TerminalServiceRequest) throws -> TerminalServiceResponse {
            switch request.command {
            case .state:
                lock.lock()
                states += 1
                let payload = payloadForSize(size.columns, size.rows)
                lock.unlock()
                return TerminalServiceResponse(ok: true, message: "state", sessionState: payload)
            case .control(let control):
                if control.controlRequest.command == "resize" {
                    lock.lock()
                    resizes += 1
                    if let columns = control.controlRequest.columns, let rows = control.controlRequest.rows { size = (columns, rows) }
                    lock.unlock()
                }
                return TerminalServiceResponse(ok: true, message: "ok", controlResponse: TerminalControlResponse(ok: true, message: "ok"))
            default: return TerminalServiceResponse(ok: false, message: "Unexpected command '\(request.commandName)'.")
            }
        }
    }

    private struct Pane {
        let view: GhosttyMirrorTerminalView
        let container: NSView
        let label: String
    }

    /// Builds a pane holding one frame of its own text. The container stands in for the pane's view
    /// tree: the app hides a tab by detaching an ancestor, not the mirror view itself.
    private func makePane(index: Int) -> Pane {
        let label = "pane-\(index)"
        let view = GhosttyMirrorTerminalView(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: label, backend: .ghosttyEmbedded, title: label, workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                createdAt: "2026-07-24T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        view.update(snapshot: Self.snapshot(text: label), renderStateKey: "state")
        return Pane(view: view, container: container, label: label)
    }

    private func show(_ pane: Pane, in host: NSWindow? = nil) {
        let host = host ?? window
        host?.contentView?.addSubview(pane.container)
        host?.contentView?.layoutSubtreeIfNeeded()
        settle()
    }

    private func hide(_ pane: Pane) {
        pane.container.removeFromSuperview()
        settle()
    }

    /// Takes a pane off screen the way the pane controller does when it switches to the status or text
    /// renderer: the terminal container above the mirror view is hidden while the view stays attached
    /// to a window that is still perfectly visible.
    private func hideBehindStatusRenderer(_ pane: Pane) {
        pane.container.isHidden = true
        settle()
    }

    private func showTerminalRendererAgain(_ pane: Pane) {
        pane.container.isHidden = false
        settle()
    }

    /// Runs the main queue until the work already scheduled on it has drained. Surfaces are freed on
    /// the turn after a pane appears or disappears, never in the middle of one, so a test reads an
    /// eviction decision only once the pass that triggered it has settled — exactly as the app does.
    private func settle() {
        mainQueueDrained = false
        Task { @MainActor [weak self] in self?.mainQueueDrained = true }
        waitForCondition("main queue drain") { self.mainQueueDrained }
    }

    private nonisolated static func makeVisibleWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Replays `PaneTreeView.render`: the split root is detached, every cached pane view is rebuilt
    /// into a fresh split-view skeleton, and the new root is attached — all in one synchronous pass,
    /// during which every pane in the tab has no window.
    private func renderTab(panes: [Pane], into host: NSView) {
        for view in host.subviews { view.removeFromSuperview() }
        let splitRoot = NSView(frame: host.bounds)
        splitRoot.autoresizingMask = [.width, .height]
        for pane in panes {
            pane.container.removeFromSuperview()
            splitRoot.addSubview(pane.container)
        }
        host.addSubview(splitRoot)
    }

    private static func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = rows.map(\.count).max() ?? 0
        let paddedRows = rows.map { row in row.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedRows.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFF_FFFF, backgroundRGB: 0, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: paddedRows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFF_FFFF,
            defaultBackgroundRGB: 0, cells: cells)
    }

    private func normalize(_ text: String?) -> String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    private func waitForCondition(_ label: String, timeout: TimeInterval = 10, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

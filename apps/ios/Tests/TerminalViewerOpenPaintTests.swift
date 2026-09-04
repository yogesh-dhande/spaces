#if canImport(UIKit)
    import Foundation
    import UIKit
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// Opening a terminal paints once, at the phone's grid.
    ///
    /// A session runs at whatever grid its daemon last set, so the frames that arrive while a viewer opens
    /// describe that screen. The viewer holds its screen updates until a frame at the grid its surface last
    /// reported has arrived, and releases the hold as soon as no such frame can come: an ended session, a
    /// session another client owns, or a bounded wait that expires.
    @MainActor final class TerminalViewerOpenPaintTests: XCTestCase {
        // MARK: - The hold

        func testOpenHoldsTheSessionsGridAndPaintsOnceTheViewportGridArrives() async throws {
            let model = makeModel()
            defer { model.stop() }
            model.start()
            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting, "start must hold the open burst")
            model.updateViewportSize(columns: 40, rows: 30)

            await model.applyLatestState(
                try Self.framedState(
                    columns: 80, rows: 24, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)

            XCTAssertTrue(model.isOwner, "this client owns the session")
            XCTAssertNil(model.ownerRenderEpoch, "the session's pre-resize grid must not paint")
            XCTAssertEqual(model.renderMode, "ownerBootstrapping")
            XCTAssertEqual(model.visibleText, "Preparing terminal…", "the viewer shows its loading state while it holds")

            await model.applyLatestState(
                try Self.framedState(columns: 40, rows: 30, revision: 2, emittedAt: "2026-06-04T14:23:32Z", owner: model.remoteClientForTesting),
                isOutOfBand: false)

            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 40, "the first paint is at the reported viewport")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.rows, 30)
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting, "the matching frame ends the hold")
        }

        /// The surface reports its grid only after this client owns the session, so a session already
        /// running at that grid delivered the frame the hold waits for before there was anything to match
        /// it against, and nothing later produces another one on a quiet session. Reporting the viewport is
        /// therefore itself a release, and it has to paint what that frame left behind: a barrier's payload
        /// applies even while the pipeline holds, so its frame was consumed by the apply the first-paint
        /// gate refused to paint from and is queued nowhere for the release to drain.
        func testViewportReportReleasesTheHoldAndPaintsTheFrameTheGateSuppressed() async throws {
            let model = makeModel()
            defer { model.stop() }
            model.start()

            await model.applyLatestState(
                try Self.framedState(
                    columns: 40, rows: 30, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)
            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting, "no viewport has been reported yet, so nothing can match")
            XCTAssertNil(model.ownerRenderEpoch)

            model.updateViewportSize(columns: 40, rows: 30)

            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting)
            await waitUntil("the held screen to paint") { model.ownerRenderEpoch != nil }
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 40, "the one paint is at the reported grid")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.rows, 30)

            // `updateViewportSize`'s own `isOwner && !isBusy` branch also scheduled an ownership sync. By
            // the time its debounce elapses the runtime already matches the viewport, so that run takes
            // the resize-skip branch (`ownership_resize_skip_matching_runtime`) and finds no further frame
            // to wait for: a quiet already-sized session, settling with nothing left to test. Regression
            // coverage that this still legitimately calls `releaseOpenScreenHoldIfTheHandshakeProducedNoFrame`
            // (a no-op here, since the hold already released above) rather than being excluded from it, and
            // that doing so does not re-arm the hold or repaint.
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting, "a quiet already-sized session must stay released")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 40, "still the one paint from the release above")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.rows, 30)
        }

        /// The surface reports its grid more than once as a detail opens. Only the latest of those is the
        /// grid the viewer wants, so a frame matching an earlier one neither releases the hold nor paints:
        /// painting it would reflow to the newer grid a moment later, which is the replay one step on.
        func testOnlyAFrameAtTheLatestReportedGridReleasesTheHold() async throws {
            let model = makeModel()
            defer { model.stop() }
            model.start()
            model.updateViewportSize(columns: 50, rows: 40)
            model.updateViewportSize(columns: 45, rows: 35)

            await model.applyLatestState(
                try Self.framedState(
                    columns: 50, rows: 40, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)

            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting, "that frame is at the grid the surface already moved past")
            XCTAssertNil(model.ownerRenderEpoch, "and it must not paint either")

            await model.applyLatestState(
                try Self.framedState(
                    columns: 45, rows: 35, revision: 2, emittedAt: "2026-06-04T14:23:32Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)

            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting, "the latest grid's frame ends the hold")
            XCTAssertNotNil(model.ownerRenderEpoch, "the matching frame's own apply completes the release, so the paint is synchronous with it")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 45, "the one paint is at the grid the surface last reported")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.rows, 35)
        }

        /// A retained detail's model survives `stop()`/`start()` (`fullScreenCover`/`sheet` fires
        /// `.onDisappear { model.stop() }` then `.task { model.start() }` on the same instance when the
        /// cover dismisses and reopens). `beginStop` bumps the lifecycle and clears screen state only for
        /// owners; a non-owner viewer's `latestState` keeps its last render snapshot across the restart, so
        /// the retained view still has something to draw while stopped. If the restarted hold matched that
        /// leftover snapshot against the freshly reported grid, it would release before the new lifecycle's
        /// own subscription produced anything — painting whatever grid the session happens to be at when
        /// this viewer reattaches, which can be a size another client resized it to while this detail was
        /// covered. That is the reflow the open hold exists to remove, reintroduced across a restart.
        /// Regression test for `latestStateLifecycle`, which scopes the match to the lifecycle whose own
        /// payload produced the stored state.
        func testRestartedLifecycleDoesNotReleaseTheHoldOnAPreviousLifecyclesStaleFrame() async throws {
            let model = makeModel()
            defer { model.stop() }
            let otherOwner = TerminalClient(
                id: "mac-owner", kind: .localWindow, identity: TerminalClientIdentity(label: "mac"), connectedAt: "2026-06-04T14:23:31Z")

            // First lifecycle: this viewer never takes ownership, but `latestState` still gets a frame at
            // grid G (40x30) — attachment_state is a barrier, so it applies even while the open hold is on.
            model.start()
            await model.applyLatestState(
                try Self.framedState(
                    columns: 40, rows: 30, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: otherOwner,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)
            XCTAssertFalse(model.isOwner, "this lifecycle never takes ownership")

            // The detail is covered and reopened: `stop()` bumps the lifecycle without clearing
            // `latestState`, and `start()` re-arms the hold for the new lifecycle.
            model.stop()
            model.start()
            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting, "the restarted lifecycle re-arms the hold")

            // The surface reports grid G again before this lifecycle's own subscription has delivered
            // anything at all. Only the leftover frame from the first lifecycle matches it.
            model.updateViewportSize(columns: 40, rows: 30)
            XCTAssertTrue(
                model.isHoldingOpenScreenUpdatesForTesting,
                "a frame stored by a previous lifecycle must not release this lifecycle's hold just because its grid matches")

            // The restarted subscription then delivers its own frame at G, this time making the viewer the
            // owner: the hold releases on this frame, and it paints exactly once.
            await model.applyLatestState(
                try Self.framedState(
                    columns: 40, rows: 30, revision: 2, emittedAt: "2026-06-04T14:23:35Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)

            XCTAssertTrue(model.isOwner)
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting, "the new lifecycle's own matching frame releases the hold")
            XCTAssertNotNil(model.ownerRenderEpoch, "the matching frame's own apply completes the release, so the paint is synchronous with it")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 40, "the one paint is at the reported grid")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.rows, 30)
        }

        /// A frameless payload (e.g. a bare `attachment_state`/`runtime_state` transition, which carries no
        /// render update) reduces to a `storedPayload` that merges the previous payload's render snapshot
        /// forward untouched — `reduction.frameToApply` is nil because nothing decoded. If applying such a
        /// payload after a restart stamped `latestStateLifecycle` to the current lifecycle anyway, the
        /// stale snapshot inherited from the *previous* lifecycle would read as though the *current*
        /// lifecycle produced it, and `updateViewportSize`'s stored-frame match (gated on
        /// `latestStateLifecycle == viewerAttachmentLifecycle`) would release the open hold on a grid this
        /// restarted subscription never delivered. Regression test for stamping the lifecycle only when a
        /// reduce actually contributes a frame.
        func testFramelessPayloadAfterRestartDoesNotRefreshTheStampOnAPreviousLifecyclesStaleFrame() async throws {
            let model = makeModel()
            defer { model.stop() }
            let otherOwner = TerminalClient(
                id: "mac-owner", kind: .localWindow, identity: TerminalClientIdentity(label: "mac"), connectedAt: "2026-06-04T14:23:31Z")

            // First lifecycle: this viewer never takes ownership, but `latestState` still gets a frame at
            // grid G (40x30) — attachment_state is a barrier, so it applies even while the open hold is on.
            model.start()
            await model.applyLatestState(
                try Self.framedState(
                    columns: 40, rows: 30, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: otherOwner,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)
            XCTAssertFalse(model.isOwner, "this lifecycle never takes ownership")

            // The detail is covered and reopened: `stop()` bumps the lifecycle without clearing
            // `latestState`, and `start()` re-arms the hold for the new lifecycle.
            model.stop()
            model.start()
            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting, "the restarted lifecycle re-arms the hold")

            // The restarted subscription's first delivery is frameless: same owner, no render update at
            // all. It reduces (barrier reasons apply even while the hold is on), but it contributes no
            // frame of its own — `storedPayload` just carries the first lifecycle's frame forward.
            await model.applyLatestState(Self.otherOwnerState(emittedAt: "2026-06-04T14:23:36Z", state: .running), isOutOfBand: false)
            XCTAssertFalse(model.isOwner, "the frameless payload names the same non-owning attachment")

            // The surface reports grid G. Before the fix this frameless apply had already stamped the
            // restarted lifecycle onto the leftover frame from the first lifecycle, so this match would
            // wrongly release the hold on a grid the restarted subscription never delivered.
            model.updateViewportSize(columns: 40, rows: 30)
            XCTAssertTrue(
                model.isHoldingOpenScreenUpdatesForTesting, "a frameless reduce must not refresh the stamp on a previous lifecycle's stale frame")

            // The restarted subscription then delivers its own frame at G, this time making the viewer the
            // owner: the hold releases on this frame, and it paints exactly once.
            await model.applyLatestState(
                try Self.framedState(
                    columns: 40, rows: 30, revision: 2, emittedAt: "2026-06-04T14:23:37Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)

            XCTAssertTrue(model.isOwner)
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting, "the new lifecycle's own matching frame releases the hold")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 40, "the one paint is at the reported grid")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.rows, 30)
        }

        // MARK: - Releases that cannot wait

        func testEndedSessionReleasesTheHoldImmediately() async throws {
            let model = makeModel()
            defer { model.stop() }
            model.start()
            model.updateViewportSize(columns: 40, rows: 30)

            await model.applyLatestState(
                try Self.framedState(
                    columns: 80, rows: 24, revision: 1, emittedAt: "2026-06-04T14:23:31Z", state: .exited,
                    reason: TerminalRemoteSessionStateReason.runtimeState.rawValue), isOutOfBand: false)

            XCTAssertEqual(model.renderMode, "ended")
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting, "an ended session never resizes, so nothing is left to wait for")
            XCTAssertNotNil(model.endedRender, "the final transcript paints at whatever grid it was captured on")
        }

        /// A session this viewer does not own and will not take over (it is not running, so automatic
        /// takeover is not eligible) exports its owner's grid and answers no resize from here.
        func testSessionOwnedElsewhereReleasesTheHoldImmediately() async throws {
            let model = makeModel(state: .starting)
            defer { model.stop() }
            model.start()
            model.updateViewportSize(columns: 40, rows: 30)

            await model.applyLatestState(Self.otherOwnerState(emittedAt: "2026-06-04T14:23:31Z", state: .starting), isOutOfBand: false)

            XCTAssertFalse(model.isOwner)
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting)
        }

        func testHoldReleasesWhenItsBoundedWaitExpires() async throws {
            let model = makeModel()
            defer { model.stop() }
            model.openScreenHoldTimeoutForTesting = .milliseconds(50)
            model.start()
            model.updateViewportSize(columns: 40, rows: 30)

            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting)
            await waitUntil("the bounded wait to expire") { !model.isHoldingOpenScreenUpdatesForTesting }

            await model.applyLatestState(
                try Self.framedState(columns: 80, rows: 24, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: model.remoteClientForTesting),
                isOutOfBand: false)
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 80, "past the wait, whatever is newest paints")
        }

        // MARK: - A handshake that tested nothing must not release

        /// The debounced ownership sync can run and settle before the surface has ever reported a grid:
        /// its own bounded wait for one (`awaitViewportSizeIfNeeded`, 8 x 50ms) can time out with nothing
        /// reported yet, on top of the sync's own debounce (120ms). That run tested nothing — no grid to
        /// resize to, so no resize was sent — and the report, the sync it triggers, and the frame that
        /// would match it are all still coming. Releasing here is exactly the replay this hold exists to
        /// close: the daemon's pre-resize grid paints, then the viewport reports, then the real resize
        /// repaints. Regression test for `runOwnershipSynchronization`'s defer, which used to release
        /// unconditionally whenever a run ended without a frame at the viewer's own grid.
        func testSyncWithNoViewportReportedYetDoesNotReleaseTheHold() async throws {
            let model = makeModel()
            defer { model.stop() }
            model.start()
            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting, "start must hold the open burst")

            await model.applyLatestState(
                try Self.framedState(
                    columns: 80, rows: 24, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)
            XCTAssertTrue(model.isOwner, "the attach payload makes this client the owner and schedules the sync")

            // No viewport is ever reported in this window, so the sync's viewport wait (400ms) plus its
            // debounce (120ms) must both run out before this assertion, with the hold still holding.
            try await Task.sleep(for: .milliseconds(900))
            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting, "a sync with no viewport to test must not release the hold")
            XCTAssertNil(model.ownerRenderEpoch, "nothing must paint while the hold is on")

            // The surface measures itself and the matching frame lands: the hold releases and paints once,
            // at the reported grid, exactly as an ordinary open does.
            model.updateViewportSize(columns: 49, rows: 37)
            await model.applyLatestState(
                try Self.framedState(columns: 49, rows: 37, revision: 2, emittedAt: "2026-06-04T14:23:33Z", owner: model.remoteClientForTesting),
                isOutOfBand: false)

            await waitUntil("the paint at the reported viewport") { model.ownerRenderEpoch != nil }
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 49, "the one paint is at the reported viewport")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.rows, 37)
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting)
        }

        /// A resize the sync sends can succeed before its own bounded wait for the resulting frame
        /// (`awaitOwnerStateFromStream`, 6 x 50ms) sees it: the daemon can take longer than that to flush
        /// the resized frame back down the stream. That frame is still en route when the wait times out,
        /// so the run must not release the hold either — releasing paints the pre-resize grid the resize
        /// was sent to replace. This test never delays the frame directly (no seam does that
        /// deterministically); instead it withholds it past the wait's fixed bound and lets the wait time
        /// out on its own, which is the same condition the fix classifies as `.resizedAwaitingFrame`.
        func testResizeSucceedsButItsFrameArrivesAfterTheStreamWaitDoesNotReleaseTheHold() async throws {
            let model = makeModel()
            defer { model.stop() }
            model.start()
            model.updateViewportSize(columns: 49, rows: 37)

            // The owner attaches already running, but at a mismatched runtime (80x24), so the sync's
            // resize targets 49x37; the fake backend answers it immediately. No frame at 49x37 is sent for
            // the rest of this test, so the sync's post-resize stream wait has nothing to find.
            await model.applyLatestState(
                try Self.framedState(
                    columns: 80, rows: 24, revision: 1, emittedAt: "2026-06-04T14:23:31Z", owner: model.remoteClientForTesting,
                    reason: TerminalRemoteSessionStateReason.attachmentState.rawValue), isOutOfBand: false)
            XCTAssertTrue(model.isOwner)
            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting)

            // The sync's debounce (120ms) plus its post-resize stream wait (300ms) must both run out with
            // the hold still holding: the resize succeeded, so this run is `.resizedAwaitingFrame`, not a
            // settled handshake that tested nothing.
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertTrue(model.isHoldingOpenScreenUpdatesForTesting, "a resize awaiting its frame must not release the hold")
            XCTAssertNil(model.ownerRenderEpoch)

            // The resized frame lands late: it must still paint, and paint only once, at the resized grid.
            await model.applyLatestState(
                try Self.framedState(columns: 49, rows: 37, revision: 2, emittedAt: "2026-06-04T14:23:34Z", owner: model.remoteClientForTesting),
                isOutOfBand: false)

            await waitUntil("the late frame to paint") { model.ownerRenderEpoch != nil }
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.columns, 49, "the one paint is at the resized grid")
            XCTAssertEqual(model.ownerRenderEpoch?.bootstrapSnapshot?.rows, 37)
            XCTAssertFalse(model.isHoldingOpenScreenUpdatesForTesting)
        }

        // MARK: - One command connection per open

        /// Every request the open path makes rides this viewer's own command channel, so a cold open costs
        /// one pinned-TLS dial for commands (plus the session stream's own) instead of one per call.
        func testOpenPathRequestsShareOneCommandTransport() async throws {
            let backend = TransportCountingBackend()
            let model = makeModel(backend: backend)
            defer { model.stop() }

            model.prepareForBackgrounding()
            model.resumeAfterBackgrounding()
            await waitUntil("the foreground heartbeat to run") { backend.sentCommands.contains("terminal:heartbeat") }
            await waitUntil("the foreground state read to run") { backend.sentCommands.contains("state") }
            await model.takeOver()

            XCTAssertTrue(backend.sentCommands.contains("terminal:takeover"))
            XCTAssertEqual(backend.transportCount, 1, "the viewer's requests must not each dial their own connection")
        }

        // MARK: - Release ordering: reduce marks, submit confirms

        /// `TerminalViewerOpenScreenHold.noteReducedFrame` runs inside the pipeline's `shouldUseFrame`,
        /// which fires *during* reduction, before that frame's own output reaches the apply mailbox. It
        /// must therefore only mark the release pending, not run it: running it there could flip
        /// `setHoldsScreenUpdates(false)` while the mailbox still holds an older, stale-grid frame and
        /// this frame's own output is not even queued yet, letting the mailbox drain that older frame
        /// first. `releasePendingAfterSubmit` is what the pipeline's `didSubmit` hook calls once the
        /// matching frame's output is actually queued, and that is the only thing allowed to run the
        /// release.
        func testNoteReducedFrameDefersReleaseUntilSubmitIsConfirmed() {
            let hold = TerminalViewerOpenScreenHold()
            let releases = ReleaseCounter()
            hold.begin(viewport: (columns: 80, rows: 24)) { releases.increment() }

            hold.noteReducedFrame(Self.gridFrame(columns: 80, rows: 24))
            XCTAssertEqual(releases.count, 0, "a matching frame must mark the release pending, not run it")

            hold.releasePendingAfterSubmit()
            XCTAssertEqual(releases.count, 1, "confirming the submit must run the release that was marked pending")

            hold.releasePendingAfterSubmit()
            XCTAssertEqual(releases.count, 1, "nothing is pending after the first confirmation, so a second one is a no-op")
        }

        /// `end()` can win the race against `releasePendingAfterSubmit` when something else (the surface
        /// settling, the bounded wait) ends the hold before the pipeline confirms the matching frame's
        /// submit. The pending mark must not resurrect a hold `end()` already closed.
        func testEndAfterAPendingMarkTakesTheReleaseAndTheLaterConfirmationIsANoOp() {
            let hold = TerminalViewerOpenScreenHold()
            let releases = ReleaseCounter()
            hold.begin(viewport: (columns: 80, rows: 24)) { releases.increment() }

            hold.noteReducedFrame(Self.gridFrame(columns: 80, rows: 24))
            hold.end()
            XCTAssertEqual(releases.count, 1, "end() takes the release directly, even with a submit confirmation still pending")

            hold.releasePendingAfterSubmit()
            XCTAssertEqual(releases.count, 1, "a pending mark from before end() must not run the release a second time")
        }

        /// `setViewport` reporting a newer grid must clear a release `noteReducedFrame` already marked
        /// pending for the old grid: the frame that matched the old grid says nothing about the new one.
        /// Without this, a `releasePendingAfterSubmit()` that runs after the target moved releases the
        /// hold with no frame that ever matched the new grid, painting it stale.
        func testSetViewportClearsAPendingMarkFromTheOldGridSoAStaleSubmitCannotRelease() {
            let hold = TerminalViewerOpenScreenHold()
            let releases = ReleaseCounter()
            hold.begin(viewport: (columns: 80, rows: 24)) { releases.increment() }

            hold.noteReducedFrame(Self.gridFrame(columns: 80, rows: 24))
            let releasedByViewportChange = hold.setViewport(columns: 40, rows: 30, matchesLatestFrame: false)
            XCTAssertFalse(releasedByViewportChange, "the new grid has no frame yet, so this call must not release on its own")

            hold.releasePendingAfterSubmit()
            XCTAssertEqual(releases.count, 0, "the pending mark was for the old grid; it must not release the hold at the new one")

            hold.noteReducedFrame(Self.gridFrame(columns: 40, rows: 30))
            XCTAssertEqual(releases.count, 0, "the matching frame at the new grid only marks the release pending")
            hold.releasePendingAfterSubmit()
            XCTAssertEqual(releases.count, 1, "confirming the submit of the frame that actually matches the new grid must release")
        }

        /// Integration coverage through the real pipeline, wired exactly like `TerminalViewerModel`:
        /// `shouldUseFrame` marks the hold, `didSubmit` confirms it once that frame's own output is
        /// queued, and the hold's release closure flips `setHoldsScreenUpdates(false)`. With the mailbox
        /// holding, an older frame submitted ahead of the matching one must never apply on its own: the
        /// fix's ordering only lets the release run after the matching frame's output has already reached
        /// the mailbox, where it collapses onto the older held one before the resulting drain can apply
        /// anything, so the drain the release triggers finds one merged entry at the viewport grid. Before
        /// the fix, marking-and-releasing from `shouldUseFrame` could flip the hold off while the older
        /// frame was still the only thing queued, letting it drain and apply on its own ahead of the
        /// matching frame. Looped because that race depends on how the reduce loop's synchronous
        /// continuation interleaves with the asynchronous main-actor drain it schedules, which does not
        /// reproduce on every run.
        func testHoldOrderingNeverAppliesAnOlderFrameAheadOfTheMatchingOneAcrossManyOpens() async throws {
            for iteration in 0..<50 {
                let hold = TerminalViewerOpenScreenHold()
                let collector = HoldOrderingApplyCollector()
                let pipeline = TerminalRemoteStateReductionPipeline(
                    shouldUseFrame: { [hold] frame, _ in
                        hold.noteReducedFrame(frame)
                        return true
                    }, apply: { output in collector.record(output) }, didSubmit: { [hold] in hold.releasePendingAfterSubmit() })
                hold.begin(viewport: (columns: 40, rows: 30)) { [weak pipeline] in pipeline?.setHoldsScreenUpdates(false) }
                pipeline.setHoldsScreenUpdates(true)

                pipeline.submit(try Self.framedState(columns: 80, rows: 24, revision: 1, emittedAt: "2026-06-04T14:23:31Z"))
                pipeline.submit(try Self.framedState(columns: 40, rows: 30, revision: 2, emittedAt: "2026-06-04T14:23:32Z"))

                await waitUntil("iteration \(iteration) to apply") { collector.recorded.count >= 1 }
                XCTAssertEqual(collector.recorded.count, 1, "iteration \(iteration): the held frame must apply exactly once")
                XCTAssertEqual(collector.recorded.first?.columns, 40, "iteration \(iteration): the one apply must be at the viewport grid")
                XCTAssertEqual(collector.recorded.first?.rows, 30, "iteration \(iteration): the one apply must be at the viewport grid")
            }
        }

        // MARK: - Fixtures

        private func makeModel(state: TerminalSessionState = .running, backend: (any SpacesDeviceAPIBackend)? = nil) -> TerminalViewerModel {
            let bridgeClient: SpacesDeviceAPIClient
            if let backend {
                bridgeClient = SpacesDeviceAPIClient(settings: Self.settings, backend: backend)
            } else {
                bridgeClient = SpacesDeviceAPIClient(settings: Self.settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            }
            return TerminalViewerModel(
                session: Self.session(state: state), settings: Self.settings, onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in },
                bridgeClient: bridgeClient)
        }

        /// A payload carrying a full frame at `columns`x`rows`, the shape a session exports whenever it
        /// includes screen state. `reason` decides whether it is a barrier: a screen-content reason waits
        /// out the open hold in the mailbox, while a transition (`attachment_state`, `runtime_state`)
        /// applies as it arrives even while the hold is on, which is what makes it the payload the
        /// first-paint gate has to answer for.
        /// `owner`, when given, is named as the session's owner-mode attachment, which is how a payload from
        /// the daemon hands this viewer ownership. Without it the payload names no attachments and the
        /// ownership the reduction chain already carries rides forward untouched.
        private nonisolated static func framedState(
            columns: Int, rows: Int, revision: UInt64, emittedAt: String, state: TerminalSessionState = .running, owner: TerminalClient? = nil,
            reason: String = TerminalRemoteSessionStateReason.stateChange.rawValue
        ) throws -> GhosttyRemoteSessionStatePayload {
            let frame = GhosttyRenderFrame(sessionRevision: revision, ownerEpoch: 1, snapshot: gridSnapshot(columns: columns, rows: rows))
            return GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: reason, emittedAt: emittedAt, sessionStateRevision: revision, sessionStateFlags: 1,
                screenStateRevision: revision,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, servicePID: 100, childPID: 200, state: state, updatedAt: emittedAt, columns: columns, rows: rows),
                attachmentSnapshot: owner.map { client in
                    TerminalSessionAttachmentSnapshot(
                        clients: [client],
                        attachments: [TerminalAttachment(sessionID: sessionID, clientID: client.id, mode: .owner, attachedAt: emittedAt)])
                }, title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
        }

        private nonisolated static func otherOwnerState(emittedAt: String, state: TerminalSessionState) -> GhosttyRemoteSessionStatePayload {
            let ownerClient = TerminalClient(
                id: "mac-owner", kind: .localWindow, identity: TerminalClientIdentity(label: "mac"), connectedAt: emittedAt)
            return GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, emittedAt: emittedAt,
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(sessionID: sessionID, servicePID: 100, childPID: 200, state: state, updatedAt: emittedAt),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                    clients: [ownerClient],
                    attachments: [TerminalAttachment(sessionID: sessionID, clientID: ownerClient.id, mode: .owner, attachedAt: emittedAt)]),
                title: "terminal", workingDirectory: "/tmp/work", outputByteCount: 0)
        }

        /// A bare frame at `columns`x`rows`, for exercising `TerminalViewerOpenScreenHold` directly
        /// without going through a payload or the pipeline.
        private nonisolated static func gridFrame(columns: Int, rows: Int) -> GhosttyRenderFrame {
            GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 1, snapshot: gridSnapshot(columns: columns, rows: rows))
        }

        private nonisolated static func gridSnapshot(columns: Int, rows: Int) -> GhosttyTerminalSnapshot {
            let cells = (0..<(columns * rows)).map { index in
                GhosttyTerminalSnapshot.Cell(
                    codepoint: index == 0 ? UInt32(UnicodeScalar("x").value) : 32, foregroundRGB: 0xFFFFFF, backgroundRGB: 0, flags: 0)
            }
            return GhosttyTerminalSnapshot(
                columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
                defaultBackgroundRGB: 0, cells: cells)
        }

        private static let sessionID = "terminal-session"

        private static var settings: SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = 12_345
            settings.authToken = "token"
            settings.certificateFingerprint = "SHA256:test"
            return settings
        }

        private static func session(state: TerminalSessionState) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: sessionID, title: "terminal", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, state: state,
                backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: 200, workspaceID: "workspace-1",
                workspaceTitle: nil, projectID: nil, projectName: nil, createdAt: "2026-06-04T14:23:10Z", updatedAt: "2026-06-04T14:23:23Z",
                isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .process,
                rowSourceID: "process-row", hasFinalRender: false)
        }

        private func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
            let deadline = ContinuousClock().now + timeout
            while ContinuousClock().now < deadline {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Timed out waiting for \(description).")
        }

        /// Answers every request in memory while counting how many request transports the client asked it
        /// for. One transport is one pinned-TLS command connection in production, so the count is the dial
        /// count the open path would pay on a device.
        private final class TransportCountingBackend: SpacesDeviceAPIBackend, @unchecked Sendable {
            private let lock = NSLock()
            private var transports = 0
            private var commands: [String] = []

            var transportCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return transports
            }

            var sentCommands: [String] {
                lock.lock()
                defer { lock.unlock() }
                return commands
            }

            func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport {
                lock.lock()
                transports += 1
                lock.unlock()
                return CountingTransport(backend: self)
            }

            func openSessionStream(
                request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
                onDisconnect: @escaping @MainActor (SpacesDeviceAPIStreamDisconnect) -> Void
            ) async throws -> SpacesDeviceAPIStreamHandle { throw SpacesDeviceAPIClientError.invalidEndpoint }

            fileprivate func record(_ request: SpacesDeviceAPIRequest) {
                lock.lock()
                commands.append(Self.token(request))
                lock.unlock()
            }

            private static func token(_ request: SpacesDeviceAPIRequest) -> String {
                switch request.command {
                case .terminalControl(let payload): return "terminal:\(payload.action.rawValue)"
                case .state: return "state"
                default: return "other"
                }
            }

            private struct CountingTransport: SpacesDeviceAPIRequestTransport {
                let backend: TransportCountingBackend

                func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse {
                    backend.record(request)
                    return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }

                func close() async {}
            }
        }

        /// Counts how many times a `TerminalViewerOpenScreenHold` release closure has run, from whichever
        /// path claims it.
        private final class ReleaseCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var runCount = 0

            func increment() {
                lock.lock()
                runCount += 1
                lock.unlock()
            }

            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return runCount
            }
        }

        /// Records the grid of every frame a pipeline apply carries, in apply order. Used by the
        /// held-mailbox ordering test, which cares only about how many times the drain applied something
        /// and what grid the surviving frame was at, not the rest of the output.
        private final class HoldOrderingApplyCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var applies: [(columns: Int, rows: Int)] = []

            func record(_ output: TerminalRemoteStateReductionOutput) {
                guard let frame = output.reduction?.frameToApply else { return }
                lock.lock()
                applies.append((frame.columns, frame.rows))
                lock.unlock()
            }

            var recorded: [(columns: Int, rows: Int)] {
                lock.lock()
                defer { lock.unlock() }
                return applies
            }
        }
    }
#endif

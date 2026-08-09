import Foundation
import XCTest
import spacesterminalcore

final class GhosttyRemoteSessionStateTests: XCTestCase {
    func testMergedPayloadCarriesOutputPositionWithoutRawBytes() throws {
        let initial = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha", outputByteCount: nil,
            renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))

        let outputUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "output", emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha", outputByteCount: 2,
            outputEndByteOffset: 42)

        let merged = initial.merged(with: outputUpdate)
        XCTAssertEqual(merged.renderText, "alpha")
        XCTAssertEqual(merged.renderSnapshot?.columns, initial.renderSnapshot?.columns)
        XCTAssertEqual(merged.renderOwnerEpoch, 4)
        XCTAssertEqual(merged.outputByteCount, 2)
        XCTAssertEqual(merged.outputEndByteOffset, 42)
        let decodedOutputUpdate = try GhosttyRemoteSessionStateCodec.decodeLine(try GhosttyRemoteSessionStateCodec.encodeLine(outputUpdate))
        XCTAssertEqual(decodedOutputUpdate.outputEndByteOffset, 42)

        let metadataUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "attachment_state", emittedAt: "2026-05-20T00:00:02Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "alpha",
            workingDirectory: "/tmp/alpha", outputByteCount: nil)

        let metadataMerged = merged.merged(with: metadataUpdate)
        XCTAssertNil(metadataMerged.outputEndByteOffset)
        XCTAssertEqual(metadataMerged.renderText, "alpha")
    }

    func testMergedPayloadClearsScreenStateWhenOwnerChangesWithoutFreshSnapshot() throws {
        let initial = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: attachmentSnapshot(ownerID: "mac-window"), title: "alpha",
            workingDirectory: "/tmp/alpha", outputByteCount: nil,
            renderUpdate: try renderUpdateData(text: "stale suggestion", sessionRevision: 1, ownerEpoch: 9))

        let ownerUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "attachment_state", emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: attachmentSnapshot(ownerID: "ios-viewer"), title: "alpha",
            workingDirectory: "/tmp/alpha", outputByteCount: nil)

        let merged = initial.merged(with: ownerUpdate)
        XCTAssertNil(merged.renderSnapshot)
        XCTAssertNil(merged.renderText)
    }

    func testReducerDoesNotApplyPreservedFrameForMetadataOnlyUpdate() throws {
        var reducer = TerminalRemoteStateReducer()
        let initial = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha", outputByteCount: nil,
            renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))

        let initialReduction = reducer.reduce(incomingPayload: initial, previousPayload: nil)
        XCTAssertEqual(initialReduction.frameToApply?.snapshot, initial.renderSnapshot)

        let inputAck = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.input, emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: 5)

        let inputReduction = reducer.reduce(incomingPayload: inputAck, previousPayload: initialReduction.storedPayload)

        XCTAssertNil(inputReduction.frameToApply)
        XCTAssertEqual(inputReduction.storedPayload.renderText, "alpha")
        XCTAssertEqual(inputReduction.storedPayload.outputByteCount, 5)
    }

    func testReducerYieldsFullFrameWithoutDrop() throws {
        var reducer = TerminalRemoteStateReducer()
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))

        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil)

        XCTAssertEqual(reduction.frameToApply?.snapshot, snapshot(text: "alpha"))
        XCTAssertEqual(reduction.frameToApply?.ownerEpoch, 4)
        XCTAssertNil(reduction.dropReason)
        XCTAssertFalse(reduction.didRequestResync)
        XCTAssertEqual(reduction.storedPayload.renderText, "alpha")
        XCTAssertEqual(reduction.storedPayload.renderOwnerEpoch, 4)
    }

    func testReducerAppliesDeltaOntoEstablishedBaseline() throws {
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha"))
        let secondFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "bravo"))
        let delta = GhosttyRenderUpdateFactory.makeUpdate(target: secondFrame, baseline: GhosttyRenderUpdateBaseline(frame: firstFrame))
        XCTAssertEqual(delta.kind, .delta)

        var reducer = TerminalRemoteStateReducer()
        let full = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(firstFrame)))
        _ = reducer.reduce(incomingPayload: full, previousPayload: nil)

        let deltaPayload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(delta))
        let reduction = reducer.reduce(incomingPayload: deltaPayload, previousPayload: full)

        XCTAssertEqual(reduction.frameToApply?.snapshot, snapshot(text: "bravo"))
        XCTAssertNil(reduction.dropReason)
        XCTAssertFalse(reduction.didRequestResync)
        XCTAssertEqual(reduction.storedPayload.renderText, "bravo")
    }

    func testReducerDropsFrameRejectedByShouldUseFrame() throws {
        var reducer = TerminalRemoteStateReducer()
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.resize, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))

        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil, shouldUseFrame: { _, _ in false })

        XCTAssertNil(reduction.frameToApply)
        XCTAssertEqual(reduction.dropReason, "stale_resize_grid")
        XCTAssertNil(reduction.storedPayload.renderSnapshot)
    }

    /// A frame the caller refuses (its grid disagrees with the runtime state a resize is still settling
    /// into) leaves the client with no frame to draw, exactly like a frame that failed to apply — and
    /// unlike an apply failure it also leaves the stored payload carrying no render update for a later
    /// attach to repaint from. So it has to ask the session for a fresh full frame too; without the
    /// request nothing else on the client ever asks, and the pane keeps whatever partial picture it had
    /// until the session happens to send another full frame.
    func testReducerRequestsResyncWhenTheResizeGridVetoDropsTheFrame() throws {
        var reducer = TerminalRemoteStateReducer()
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.resize, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))

        let reduction = reducer.reduce(
            incomingPayload: payload, previousPayload: nil, shouldUseFrame: { _, _ in false }, requestResyncOnApplyFailure: true)

        XCTAssertNil(reduction.frameToApply)
        XCTAssertEqual(reduction.dropReason, "stale_resize_grid")
        XCTAssertTrue(reduction.didRequestResync)
    }

    /// A direct `.state` response re-enters the reducer beside a stream that never stopped, so it has to
    /// prove at the head of the queue that the session has not already moved past it. Same epoch, revision
    /// not newer means the client is already there — equal revisions describe identical content — so the
    /// response is refused rather than allowed to walk the chain backwards.
    func testReducerDropsAnOutOfBandFrameThatIsNotNewerThanTheBaseline() throws {
        for responseRevision in [UInt64(1), UInt64(2)] {
            var reducer = TerminalRemoteStateReducer()
            let streamed = try payload(text: "bravo", sessionRevision: 2, ownerEpoch: 4, emittedAt: "2026-08-09T00:00:02Z")
            let streamedReduction = reducer.reduce(incomingPayload: streamed, previousPayload: nil)
            XCTAssertEqual(streamedReduction.frameToApply?.snapshot, snapshot(text: "bravo"))

            let response = try payload(text: "alpha", sessionRevision: responseRevision, ownerEpoch: 4, emittedAt: "2026-08-09T00:00:01Z")
            let reduction = reducer.reduce(
                incomingPayload: response, previousPayload: streamedReduction.storedPayload, requestResyncOnApplyFailure: true, isOutOfBand: true)

            XCTAssertNil(reduction.frameToApply, "revision \(responseRevision) is not newer than the baseline's 2")
            XCTAssertEqual(reduction.dropReason, "stale_out_of_band_state")
            XCTAssertEqual(reduction.storedPayload.renderText, "bravo", "the stored state must keep the newer screen")
            XCTAssertFalse(reduction.didRequestResync, "the baseline is intact and newer, so nothing is owed")
        }
    }

    /// The other side: exporting state flushes the session's pending output into its surface without
    /// broadcasting, so a response can be the only carrier of a strictly newer screen and must land.
    func testReducerAppliesAnOutOfBandFrameNewerThanTheBaseline() throws {
        var reducer = TerminalRemoteStateReducer()
        let streamed = try payload(text: "bravo", sessionRevision: 2, ownerEpoch: 4, emittedAt: "2026-08-09T00:00:02Z")
        let streamedReduction = reducer.reduce(incomingPayload: streamed, previousPayload: nil)

        let response = try payload(text: "charl", sessionRevision: 3, ownerEpoch: 4, emittedAt: "2026-08-09T00:00:01Z")
        let reduction = reducer.reduce(
            incomingPayload: response, previousPayload: streamedReduction.storedPayload, requestResyncOnApplyFailure: true, isOutOfBand: true)

        XCTAssertEqual(reduction.frameToApply?.snapshot, snapshot(text: "charl"))
        XCTAssertNil(reduction.dropReason)
    }

    /// Owner epochs only advance, so a response stamped with an older one describes a session generation
    /// that has already been handed off; letting its frame through would replace the newer baseline and
    /// leave every epoch-gated control request quoting a dead epoch.
    func testReducerOrdersOutOfBandFramesByOwnerEpochBeforeRevision() throws {
        var reducer = TerminalRemoteStateReducer()
        let streamed = try payload(text: "bravo", sessionRevision: 2, ownerEpoch: 4, emittedAt: "2026-08-09T00:00:02Z")
        let streamedReduction = reducer.reduce(incomingPayload: streamed, previousPayload: nil)

        // Older epoch, and a revision that would have passed on its own.
        let staleEpochResponse = try payload(text: "alpha", sessionRevision: 9, ownerEpoch: 3, emittedAt: "2026-08-09T00:00:03Z")
        let staleReduction = reducer.reduce(
            incomingPayload: staleEpochResponse, previousPayload: streamedReduction.storedPayload, requestResyncOnApplyFailure: true,
            isOutOfBand: true)
        XCTAssertNil(staleReduction.frameToApply)
        XCTAssertEqual(staleReduction.dropReason, "stale_out_of_band_state")
        XCTAssertFalse(staleReduction.didRequestResync)

        // Newer epoch, and a revision that would have been refused within one epoch.
        let handoffResponse = try payload(text: "charl", sessionRevision: 1, ownerEpoch: 5, emittedAt: "2026-08-09T00:00:04Z")
        let handoffReduction = reducer.reduce(
            incomingPayload: handoffResponse, previousPayload: staleReduction.storedPayload, requestResyncOnApplyFailure: true, isOutOfBand: true)
        XCTAssertEqual(handoffReduction.frameToApply?.snapshot, snapshot(text: "charl"), "a handoff's own epoch machinery owns this case")
    }

    /// A frameless response still carries runtime state, ownership, title and working directory, and
    /// merging a stale one reverts metadata that streamed while the read was in flight.
    func testReducerDropsAFramelessOutOfBandPayloadThatIsNotNewer() throws {
        var reducer = TerminalRemoteStateReducer()
        let streamed = try payload(text: "bravo", sessionRevision: 2, ownerEpoch: 4, emittedAt: "2026-08-09T00:00:02Z", title: "current")
        let streamedReduction = reducer.reduce(incomingPayload: streamed, previousPayload: nil)

        let response = metadataPayload(emittedAt: "2026-08-09T00:00:01Z", title: "stale")
        let reduction = reducer.reduce(
            incomingPayload: response, previousPayload: streamedReduction.storedPayload, requestResyncOnApplyFailure: true, isOutOfBand: true)

        XCTAssertEqual(reduction.dropReason, "stale_out_of_band_state")
        XCTAssertEqual(reduction.storedPayload.title, "current")
        XCTAssertEqual(reduction.storedPayload.renderText, "bravo", "refusing the metadata must not disturb the screen either")
        XCTAssertFalse(reduction.didRequestResync)
    }

    func testReducerMergesAFramelessOutOfBandPayloadThatIsNewer() throws {
        var reducer = TerminalRemoteStateReducer()
        let streamed = try payload(text: "bravo", sessionRevision: 2, ownerEpoch: 4, emittedAt: "2026-08-09T00:00:02Z", title: "current")
        let streamedReduction = reducer.reduce(incomingPayload: streamed, previousPayload: nil)

        let response = metadataPayload(emittedAt: "2026-08-09T00:00:03Z", title: "fresh")
        let reduction = reducer.reduce(
            incomingPayload: response, previousPayload: streamedReduction.storedPayload, requestResyncOnApplyFailure: true, isOutOfBand: true)

        XCTAssertNil(reduction.dropReason)
        XCTAssertEqual(reduction.storedPayload.title, "fresh")
        XCTAssertEqual(reduction.storedPayload.renderText, "bravo", "a metadata-only merge carries the stored screen forward")
    }

    /// `emittedAt` is millisecond-resolution, so a tie says the session answered in the same instant it
    /// broadcast — not that the response repeats it. Ties are kept, matching the ordering guard the device
    /// state model applies to the same field.
    func testReducerKeepsAFramelessOutOfBandPayloadStampedInTheSameInstant() throws {
        var reducer = TerminalRemoteStateReducer()
        let streamed = try payload(text: "bravo", sessionRevision: 2, ownerEpoch: 4, emittedAt: "2026-08-09T00:00:02Z", title: "current")
        let streamedReduction = reducer.reduce(incomingPayload: streamed, previousPayload: nil)

        let response = metadataPayload(emittedAt: "2026-08-09T00:00:02Z", title: "same instant")
        let reduction = reducer.reduce(
            incomingPayload: response, previousPayload: streamedReduction.storedPayload, requestResyncOnApplyFailure: true, isOutOfBand: true)

        XCTAssertNil(reduction.dropReason)
        XCTAssertEqual(reduction.storedPayload.title, "same instant")
    }

    /// A response reporting the session ended is the session's final word, not one screen update among
    /// many. Ordering it away would leave the pane believing a dead session is live, so it lands even when
    /// every ordering field says it is behind.
    func testReducerNeverRefusesAnOutOfBandPayloadReportingTheSessionEnded() throws {
        var reducer = TerminalRemoteStateReducer()
        let streamed = try payload(text: "bravo", sessionRevision: 5, ownerEpoch: 4, emittedAt: "2026-08-09T00:00:05Z")
        let streamedReduction = reducer.reduce(incomingPayload: streamed, previousPayload: nil)

        let exited = TerminalSessionRuntimeState(
            sessionID: "session-1", backend: .ghosttyEmbedded, servicePID: 1, childPID: 2, state: .exited, updatedAt: "2026-08-09T00:00:01Z",
            exitedAt: "2026-08-09T00:00:01Z")
        let finalFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "final"))
        let response = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-08-09T00:00:01Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: exited, attachmentSnapshot: nil, title: "t", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(finalFrame)))

        let reduction = reducer.reduce(
            incomingPayload: response, previousPayload: streamedReduction.storedPayload, requestResyncOnApplyFailure: true, isOutOfBand: true)

        XCTAssertEqual(reduction.frameToApply?.snapshot, snapshot(text: "final"))
        XCTAssertNil(reduction.dropReason)
    }

    private func payload(text: String, sessionRevision: UInt64, ownerEpoch: UInt64, emittedAt: String, title: String = "t") throws
        -> GhosttyRemoteSessionStatePayload
    {
        let frame = GhosttyRenderFrame(sessionRevision: sessionRevision, ownerEpoch: ownerEpoch, snapshot: snapshot(text: text))
        return GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.initial, emittedAt: emittedAt, sessionStateRevision: sessionRevision,
            sessionStateFlags: 1, screenStateRevision: sessionRevision, runtimeState: nil, attachmentSnapshot: nil, title: title,
            workingDirectory: "/tmp/alpha", outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
    }

    private func metadataPayload(emittedAt: String, title: String) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.initial, emittedAt: emittedAt, sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: title,
            workingDirectory: "/tmp/alpha", outputByteCount: nil)
    }

    func testReducerReportsDecodeFailureForCorruptRenderUpdate() {
        var reducer = TerminalRemoteStateReducer()
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: Data([0x00, 0x01, 0x02, 0x03]))

        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil, requestResyncOnApplyFailure: true)

        XCTAssertNil(reduction.frameToApply)
        XCTAssertEqual(reduction.dropReason, "render_update_decode_failed")
        XCTAssertTrue(reduction.didRequestResync)
        XCTAssertNil(reduction.storedPayload.renderSnapshot)
    }

    func testDecodedRenderUpdateReturnsEqualValueAcrossRepeatedAccess() throws {
        let data = try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4)
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: data)

        XCTAssertEqual(payload.decodedRenderUpdate, payload.decodedRenderUpdate)
        XCTAssertEqual(payload.decodedRenderUpdate?.fullFrame?.snapshot, snapshot(text: "alpha"))

        // A materialized full frame stored back into a payload resolves to that frame.
        var reducer = TerminalRemoteStateReducer()
        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil)
        let stored = reduction.storedPayload
        XCTAssertEqual(stored.decodedRenderUpdate, stored.decodedRenderUpdate)
        XCTAssertEqual(stored.decodedRenderUpdate?.fullFrame?.snapshot, snapshot(text: "alpha"))
    }

    /// A reduced payload carries the materialized frame rather than a re-encoded blob, and every read a
    /// client makes of it agrees with the blob it still produces on demand.
    func testReducedPayloadYieldsTheSameBytesItReportsAsState() throws {
        let data = try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4)
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: data)

        var reducer = TerminalRemoteStateReducer()
        let stored = reducer.reduce(incomingPayload: payload, previousPayload: nil).storedPayload

        XCTAssertTrue(stored.hasRenderUpdate)
        let bytes = try XCTUnwrap(stored.renderUpdate)
        XCTAssertEqual(
            bytes, try GhosttyRenderUpdateBinaryCodec.encode(.full(.init(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha")))))
        XCTAssertEqual(try GhosttyRenderUpdateBinaryCodec.decode(bytes), stored.decodedRenderUpdate)
        XCTAssertEqual(stored.renderUpdate, bytes, "encoding a materialized update twice must produce the same blob")
        XCTAssertEqual(stored.renderSnapshot, snapshot(text: "alpha"))
        XCTAssertEqual(stored.renderText, "alpha")
        XCTAssertEqual(stored.renderOwnerEpoch, 4)
    }

    /// A metadata-only update inherits the stored screen state, and inherits it as the same render
    /// update: the merge carries the body, so the bytes a subscriber would be handed do not change.
    func testMergedPayloadCarriesTheMaterializedRenderUpdateUnchanged() throws {
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: attachmentSnapshot(ownerID: "mac-window"),
            title: "alpha", workingDirectory: "/tmp/alpha", outputByteCount: nil,
            renderUpdate: try renderUpdateData(text: "alpha", sessionRevision: 1, ownerEpoch: 4))
        var reducer = TerminalRemoteStateReducer()
        let stored = reducer.reduce(incomingPayload: payload, previousPayload: nil).storedPayload

        let metadataOnly = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.input, emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: 5)
        let merged = stored.merged(with: metadataOnly)
        XCTAssertEqual(merged.renderUpdate, stored.renderUpdate)
        XCTAssertEqual(merged.decodedRenderUpdate, stored.decodedRenderUpdate)
        XCTAssertTrue(merged.hasRenderUpdate)

        // An owner change with no fresh screen state drops it, materialized or not.
        let ownerChange = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.attachmentState, emittedAt: "2026-05-20T00:00:02Z",
            sessionStateRevision: 3, sessionStateFlags: 1, screenStateRevision: 1, runtimeState: nil,
            attachmentSnapshot: attachmentSnapshot(ownerID: "ios-viewer"), title: "alpha", workingDirectory: "/tmp/alpha", outputByteCount: nil)
        let afterOwnerChange = stored.merged(with: ownerChange)
        XCTAssertFalse(afterOwnerChange.hasRenderUpdate)
        XCTAssertNil(afterOwnerChange.renderUpdate)
        XCTAssertNil(afterOwnerChange.renderSnapshot)
    }

    func testReducerRequestsResyncForDeltaWithoutBaseline() throws {
        let firstFrame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 4, snapshot: snapshot(text: "alpha"))
        let secondFrame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 4, snapshot: snapshot(text: "bravo"))
        let delta = GhosttyRenderUpdateFactory.makeUpdate(target: secondFrame, baseline: GhosttyRenderUpdateBaseline(frame: firstFrame))
        XCTAssertEqual(delta.kind, .delta)
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: TerminalRemoteSessionStateReason.output, emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 2,
            sessionStateFlags: 1, screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(delta))
        var reducer = TerminalRemoteStateReducer()

        let reduction = reducer.reduce(incomingPayload: payload, previousPayload: nil, requestResyncOnApplyFailure: true)

        XCTAssertNil(reduction.frameToApply)
        XCTAssertNil(reduction.storedPayload.renderSnapshot)
        XCTAssertEqual(reduction.dropReason, "missing_baseline")
        XCTAssertTrue(reduction.didRequestResync)
    }

    func testRenderFrameRoundTripsOwnerEpochAndGrid() throws {
        let snapshot = snapshot(text: "frame")
        let data = try GhosttyRenderFrame.encode(.init(sessionRevision: 12, ownerEpoch: 34, snapshot: snapshot))
        let decoded = try GhosttyRenderFrame.decode(data)

        XCTAssertEqual(decoded.version, GhosttyRenderFrame.currentVersion)
        XCTAssertEqual(decoded.sessionRevision, 12)
        XCTAssertEqual(decoded.ownerEpoch, 34)
        XCTAssertEqual(decoded.columns, snapshot.columns)
        XCTAssertEqual(decoded.rows, snapshot.rows)
        XCTAssertEqual(decoded.snapshot, snapshot)
    }

    func testRenderFrameMetricAttributesIncludePayloadAndGridFields() throws {
        let snapshot = snapshot(text: "frame")
        let frame = GhosttyRenderFrame(sessionRevision: 12, ownerEpoch: 34, snapshot: snapshot)
        let attributes = GhosttyRenderFrameMetrics.attributes(
            reason: "output", frame: frame, frameByteCount: 256, frameEncodeMS: 3, decodeMS: 5, outputByteCount: 6, screenStateRevision: 7,
            dropped: false, renderMode: "ghostty-mirror")

        XCTAssertEqual(attributes["reason"], "output")
        XCTAssertEqual(attributes["render_frame"], "1")
        XCTAssertEqual(attributes["frame_bytes"], "256")
        XCTAssertEqual(attributes["frame_encode_ms"], "3")
        XCTAssertEqual(attributes["decode_ms"], "5")
        XCTAssertEqual(attributes["output_bytes"], "6")
        XCTAssertEqual(attributes["screen_revision"], "7")
        XCTAssertEqual(attributes["frame_kind"], "full")
        XCTAssertEqual(attributes["base_revision"], "nil")
        XCTAssertEqual(attributes["target_revision"], "7")
        XCTAssertEqual(attributes["applied_revision"], "nil")
        XCTAssertEqual(attributes["frame_columns"], String(snapshot.columns))
        XCTAssertEqual(attributes["frame_rows"], String(snapshot.rows))
        XCTAssertEqual(attributes["owner_epoch"], "34")
        XCTAssertEqual(attributes["session_revision"], "12")
        XCTAssertEqual(attributes["dropped"], "0")
        XCTAssertEqual(attributes["drop_reason"], "none")
        XCTAssertEqual(attributes["render_mode"], "ghostty-mirror")
        XCTAssertTrue(GhosttyRenderFrameMetrics.detailString(attributes).contains("frame_bytes=256"))
    }

    func testRenderFrameMetricAttributesMarkMissingRenderUpdateAsNone() {
        let attributes = GhosttyRenderFrameMetrics.attributes(reason: "input", frame: nil, frameByteCount: nil, screenStateRevision: 7)

        XCTAssertEqual(attributes["render_frame"], "0")
        XCTAssertEqual(attributes["frame_kind"], "none")
        XCTAssertEqual(attributes["frame_bytes"], "0")
        XCTAssertEqual(attributes["screen_revision"], "7")
    }

    // MARK: - Clipboard writes are one-shots

    /// The clipboard write must not be carried onto the payload the merge produces. Both directions
    /// matter: a stored clipboard write leaking forward would re-paste on every later output turn, and
    /// nothing in the state stream ever re-announces a write, so the field only ever means "this
    /// payload announced a copy".
    func testMergedPayloadDropsTheClipboardWrite() {
        let clipboardPayload = payload(
            reason: TerminalRemoteSessionStateReason.clipboardWrite, clipboardWrite: .init(targetClientID: "mac-window", text: "copied"))
        let laterOutput = payload(reason: TerminalRemoteSessionStateReason.output)

        XCTAssertNil(clipboardPayload.merged(with: laterOutput).clipboardWrite)
        XCTAssertNil(laterOutput.merged(with: clipboardPayload).clipboardWrite)
    }

    /// `replacingRenderUpdate` rebuilds a payload around re-exported screen state, which a clipboard
    /// write is not part of.
    func testReplacingRenderUpdateDropsTheClipboardWrite() {
        let clipboardPayload = payload(
            reason: TerminalRemoteSessionStateReason.clipboardWrite, clipboardWrite: .init(targetClientID: "mac-window", text: "copied"))
        XCTAssertNil(clipboardPayload.replacingRenderUpdate(nil).clipboardWrite)
    }

    /// The reducer hands the incoming payload's clipboard write to the client (so it can be applied
    /// once) while the payload it stores as the session's state carries none.
    func testReducerAppliesTheClipboardWriteOnceAndStoresNone() {
        var reducer = TerminalRemoteStateReducer()
        let clipboardPayload = payload(
            reason: TerminalRemoteSessionStateReason.clipboardWrite, clipboardWrite: .init(targetClientID: "mac-window", text: "copied"))

        let reduction = reducer.reduce(incomingPayload: clipboardPayload, previousPayload: payload(reason: "initial"))

        XCTAssertEqual(reduction.payload.clipboardWrite?.text, "copied")
        XCTAssertNil(reduction.storedPayload.clipboardWrite)
    }

    /// Clipboard bytes are a live one-shot for the attached owner and must never reach disk: the
    /// terminated payload the daemon persists at session exit is rebuilt without one, and a subscriber
    /// that reconnects afterwards would otherwise be handed a stale copy to paste.
    func testClipboardWriteSurvivesTheWireButNotAMerge() throws {
        let clipboardPayload = payload(
            reason: TerminalRemoteSessionStateReason.clipboardWrite, clipboardWrite: .init(targetClientID: "mac-window", text: "copied"))
        let decoded = try GhosttyRemoteSessionStateCodec.decodeLine(try GhosttyRemoteSessionStateCodec.encodeLine(clipboardPayload))
        XCTAssertEqual(decoded.clipboardWrite, TerminalClipboardWritePayload(targetClientID: "mac-window", text: "copied"))

        let terminated = payload(reason: TerminalRemoteSessionStateReason.terminated)
        XCTAssertNil(decoded.merged(with: terminated).clipboardWrite)
    }

    private func payload(reason: String, clipboardWrite: TerminalClipboardWritePayload? = nil) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: reason, emittedAt: "2026-07-28T00:00:00Z", sessionStateRevision: nil, sessionStateFlags: nil,
            screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: attachmentSnapshot(ownerID: "mac-window"), title: "alpha",
            workingDirectory: "/tmp/alpha", outputByteCount: nil, clipboardWrite: clipboardWrite)
    }

    private func renderUpdateData(text: String, sessionRevision: UInt64, ownerEpoch: UInt64) throws -> Data {
        let frame = GhosttyRenderFrame(sessionRevision: sessionRevision, ownerEpoch: ownerEpoch, snapshot: snapshot(text: text))
        return try GhosttyRenderUpdateBinaryCodec.encode(.full(frame))
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

    private func attachmentSnapshot(ownerID: String) -> TerminalSessionAttachmentSnapshot {
        let client = TerminalClient(
            id: ownerID, kind: ownerID.hasPrefix("mac") ? .localWindow : .remoteViewer, identity: .init(label: ownerID),
            connectedAt: "2026-05-20T00:00:00Z")
        return TerminalSessionAttachmentSnapshot(
            clients: [client],
            attachments: [TerminalAttachment(sessionID: "session-1", clientID: ownerID, mode: .owner, attachedAt: "2026-05-20T00:00:00Z")])
    }
}

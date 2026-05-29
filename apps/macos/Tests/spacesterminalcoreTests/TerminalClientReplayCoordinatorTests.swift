import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalClientReplayCoordinatorTests: XCTestCase {
    func testAppliesInitialHistorySeedAndSkipsStableSurfaceRefreshes() {
        XCTAssertTrue(
            TerminalClientReplayCoordinator.shouldApplyHistorySeed(
                lastAppliedHistorySeedID: nil, nextHistorySeedID: "history|100", hasHistorySeedData: true, hasSurface: true,
                replayStateChanged: false, hasReplaySurfaceContent: true))
        XCTAssertFalse(
            TerminalClientReplayCoordinator.shouldApplyHistorySeed(
                lastAppliedHistorySeedID: "history|100", nextHistorySeedID: "history|200", hasHistorySeedData: true, hasSurface: true,
                replayStateChanged: false, hasReplaySurfaceContent: true))
        XCTAssertTrue(
            TerminalClientReplayCoordinator.shouldApplyHistorySeed(
                lastAppliedHistorySeedID: "history|100", nextHistorySeedID: "history|200", hasHistorySeedData: true, hasSurface: true,
                replayStateChanged: true, hasReplaySurfaceContent: true))
        XCTAssertTrue(
            TerminalClientReplayCoordinator.shouldApplyHistorySeed(
                lastAppliedHistorySeedID: "history|100", nextHistorySeedID: "history|200", hasHistorySeedData: true, hasSurface: true,
                replayStateChanged: false, hasReplaySurfaceContent: false))
        XCTAssertFalse(
            TerminalClientReplayCoordinator.shouldApplyHistorySeed(
                lastAppliedHistorySeedID: "history|200", nextHistorySeedID: "history|200", hasHistorySeedData: true, hasSurface: true))
        XCTAssertFalse(
            TerminalClientReplayCoordinator.shouldApplyHistorySeed(
                lastAppliedHistorySeedID: nil, nextHistorySeedID: "history|200", hasHistorySeedData: false, hasSurface: true))
        XCTAssertFalse(
            TerminalClientReplayCoordinator.shouldApplyHistorySeed(
                lastAppliedHistorySeedID: nil, nextHistorySeedID: "history|200", hasHistorySeedData: true, hasSurface: false))
    }

    func testPreservesRenderedHistoryOnlyForSameOwnerEpochAndSnapshotWithoutReplayData() {
        let snapshot = Self.snapshot(text: "prompt")

        XCTAssertTrue(
            TerminalClientReplayCoordinator.shouldPreserveRenderedHistoryForOwnerBootstrap(
                previousOwnerEpochID: "owner|1", currentOwnerEpochID: "owner|1", previousBootstrapSnapshot: snapshot,
                currentBootstrapSnapshot: snapshot, hasPendingOutputs: false, hasHistorySeed: false, hasAppliedOwnerEpoch: true))
        XCTAssertFalse(
            TerminalClientReplayCoordinator.shouldPreserveRenderedHistoryForOwnerBootstrap(
                previousOwnerEpochID: "owner|1", currentOwnerEpochID: "owner|2", previousBootstrapSnapshot: snapshot,
                currentBootstrapSnapshot: snapshot, hasPendingOutputs: false, hasHistorySeed: false, hasAppliedOwnerEpoch: true))
        XCTAssertFalse(
            TerminalClientReplayCoordinator.shouldPreserveRenderedHistoryForOwnerBootstrap(
                previousOwnerEpochID: "owner|1", currentOwnerEpochID: "owner|1", previousBootstrapSnapshot: snapshot,
                currentBootstrapSnapshot: snapshot, hasPendingOutputs: true, hasHistorySeed: false, hasAppliedOwnerEpoch: true))
        XCTAssertFalse(
            TerminalClientReplayCoordinator.shouldPreserveRenderedHistoryForOwnerBootstrap(
                previousOwnerEpochID: "owner|1", currentOwnerEpochID: "owner|1", previousBootstrapSnapshot: snapshot,
                currentBootstrapSnapshot: snapshot, hasPendingOutputs: false, hasHistorySeed: true, hasAppliedOwnerEpoch: true))
    }

    func testOutputReconciliationDropsBytesAtOrBeforeHistorySeedEnd() {
        let pendingOutputs = [
            TerminalClientReplayCoordinator.OutputBatch(id: "before-tail", data: Data("old".utf8), outputEndByteOffset: 80),
            TerminalClientReplayCoordinator.OutputBatch(id: "inside-tail", data: Data("tail".utf8), outputEndByteOffset: 98),
            TerminalClientReplayCoordinator.OutputBatch(id: "after-tail", data: Data("new".utf8), outputEndByteOffset: 103),
        ]

        let reconciled = TerminalClientReplayCoordinator.outputBatchesNotCovered(byHistorySeedEndOffset: 100, pendingOutputs: pendingOutputs)

        XCTAssertEqual(reconciled, [pendingOutputs[2]])
    }

    func testOutputReconciliationKeepsOnlySuffixAfterHistorySeedEnd() {
        let pendingOutput = TerminalClientReplayCoordinator.OutputBatch(id: "straddles-end", data: Data("abcXYZ".utf8), outputEndByteOffset: 103)

        let reconciled = TerminalClientReplayCoordinator.outputBatchesNotCovered(byHistorySeedEndOffset: 100, pendingOutputs: [pendingOutput])

        XCTAssertEqual(
            reconciled, [TerminalClientReplayCoordinator.OutputBatch(id: "straddles-end|after|100", data: Data("XYZ".utf8), outputEndByteOffset: 103)]
        )
    }

    private static func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let cells = text.unicodeScalars.map {
            GhosttyTerminalSnapshot.Cell(codepoint: $0.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
        }
        return GhosttyTerminalSnapshot(
            columns: max(text.count, 1), rows: 1, cursorColumn: max(text.count - 1, 0), cursorRow: 0, cursorVisible: true,
            defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0x000000, cells: cells)
    }
}

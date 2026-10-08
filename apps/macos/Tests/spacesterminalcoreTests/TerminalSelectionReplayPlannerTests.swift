import Foundation
import Testing

@testable import spacesterminalcore

/// Which read a copy or select-all needs next, given the replay a client holds, the live frame the
/// request started at, and the reads the request has already run.
@Suite struct TerminalSelectionReplayPlannerTests {
    private let columns = 20
    private let rows = 6
    private let identity: UInt64 = 7

    private var theme: GhosttyThemeExport {
        GhosttyThemeExport(
            background: ThemeColor(0, 0, 0), foreground: ThemeColor(255, 255, 255), cursorColor: ThemeColor(200, 200, 200),
            cursorText: ThemeColor(0, 0, 0), selectionBackground: ThemeColor(50, 50, 50), selectionForeground: ThemeColor(255, 255, 255),
            palette: (0..<16).map { ThemeColor($0 * 8, $0 * 8, $0 * 8) })
    }

    /// A replay of lines 1...`lines`. `startByteOffset` above zero stands for a suffix read, which leaves
    /// deeper history unread; `requestedByteCount` is what the read asked the daemon for.
    private func makeModel(lines: Int = 40, startByteOffset: UInt64 = 0, requestedByteCount: Int = 1000, fileIdentity: UInt64? = 7) throws
        -> TerminalLocalScrollbackModel
    {
        let transcript = HostTranscript.lines(1...lines)
        return try #require(
            TerminalLocalScrollbackModel(
                columns: columns, rows: rows, theme: theme, appearance: .dark, transcript: transcript, transcriptStartByteOffset: startByteOffset,
                transcriptEndByteOffset: startByteOffset + UInt64(transcript.count), requestedByteCount: requestedByteCount,
                transcriptFileIdentity: fileIdentity, runIdentity: nil))
    }

    private func stamp(offset: UInt64, fileIdentity: UInt64 = 7) -> TerminalLiveFrameStamp {
        TerminalLiveFrameStamp(
            transcriptByteOffset: offset, transcriptFileIdentity: fileIdentity, historyEpoch: 1, activeTopRow: 0, columns: 20, rows: 6)
    }

    private func selection(_ startRow: Int64, _ endRow: Int64, epoch: UInt64) -> TerminalAbsoluteSelection {
        TerminalAbsoluteSelection(
            from: TerminalAbsoluteCell(column: 0, row: startRow), to: TerminalAbsoluteCell(column: 9, row: endRow), isRectangle: false,
            historyEpoch: epoch)
    }

    private func next(
        _ model: TerminalLocalScrollbackModel?, _ need: TerminalSelectionReplayNeed, stamp: TerminalLiveFrameStamp? = nil,
        performed: [TerminalSelectionReplayStep] = [], unavailable: Bool = false
    ) -> TerminalSelectionReplayStep {
        TerminalSelectionReplayPlanner.nextStep(model: model, need: need, targetStamp: stamp, performed: performed, replayIsUnavailable: unavailable)
    }

    @Test func withoutAReplayCopyReadsTheFirstPageAndSelectAllReadsTheWholeBudget() throws {
        #expect(next(nil, .copy(selection(0, 1, epoch: 1))) == .readFirstPage)
        #expect(next(nil, .selectAll) == .readWholeBudget)
    }

    @Test func aFailedFirstReadOrAnUnavailableReplayEndsTheRequestWithoutFormatting() throws {
        let need = TerminalSelectionReplayNeed.copy(selection(0, 1, epoch: 1))
        #expect(next(nil, need, performed: [.readFirstPage]) == .abandon)
        #expect(next(nil, .selectAll, performed: [.readWholeBudget]) == .abandon)
        #expect(next(nil, need, unavailable: true) == .abandon)
    }

    @Test func aReplayThatHoldsTheWholeTranscriptNeedsNoDeeperRead() throws {
        let model = try makeModel()
        let selection = selection(-5, 3, epoch: model.historyEpoch)
        #expect(next(model, .copy(selection)) == .format)
        #expect(next(model, .selectAll) == .format)
    }

    @Test func aReplayEndingBeforeTheTargetStampReadsAContinuationFirst() throws {
        let model = try makeModel()
        let end = model.transcriptEndByteOffset
        let selection = selection(0, 1, epoch: model.historyEpoch)
        #expect(next(model, .copy(selection), stamp: stamp(offset: end + 1)) == .readContinuation)
        #expect(next(model, .selectAll, stamp: stamp(offset: end + 1)) == .readContinuation)
    }

    @Test func aReplayCaughtUpToOrAheadOfTheTargetStampIsReady() throws {
        let model = try makeModel()
        let end = model.transcriptEndByteOffset
        let selection = selection(0, 1, epoch: model.historyEpoch)
        #expect(next(model, .copy(selection), stamp: stamp(offset: end)) == .format)
        #expect(next(model, .copy(selection), stamp: stamp(offset: end - 1)) == .format)
    }

    @Test func aStampFromAnotherTranscriptFileReadsAContinuationSoTheDaemonCanRebuild() throws {
        let model = try makeModel()
        let selection = selection(0, 1, epoch: model.historyEpoch)
        #expect(next(model, .copy(selection), stamp: stamp(offset: 10, fileIdentity: 99)) == .readContinuation)
    }

    /// Streaming output keeps the newest stamp ahead of any replay, and the host stamps a buffered chunk
    /// the file has not received yet. The target is the stamp at the press, and one continuation is as
    /// caught up as the file allows, so the request formats instead of asking again.
    @Test func aContinuationThatStopsShortOfTheTargetStampStillFormats() throws {
        let model = try makeModel()
        let beyondTheFile = stamp(offset: model.transcriptEndByteOffset + 500)
        let selection = selection(0, 1, epoch: model.historyEpoch)
        #expect(next(model, .copy(selection), stamp: beyondTheFile, performed: [.readContinuation]) == .format)
        #expect(next(model, .selectAll, stamp: beyondTheFile, performed: [.readContinuation]) == .format)
    }

    @Test func aWholeBudgetReadCountsAsCaughtUp() throws {
        let model = try makeModel()
        let beyondTheFile = stamp(offset: model.transcriptEndByteOffset + 500)
        let selection = selection(0, 1, epoch: model.historyEpoch)
        #expect(next(model, .copy(selection), stamp: beyondTheFile, performed: [.readWholeBudget]) == .format)
    }

    @Test func aStepAlreadyPerformedIsNeverReturnedAgain() throws {
        let model = try makeModel(startByteOffset: 5000, requestedByteCount: 100)
        let above = selection(model.oldestAbsoluteRow - 1, model.oldestAbsoluteRow + 2, epoch: model.historyEpoch)
        let ahead = stamp(offset: model.transcriptEndByteOffset + 1)
        #expect(next(model, .copy(above), stamp: ahead) == .readContinuation)
        #expect(next(model, .copy(above), stamp: ahead, performed: [.readContinuation]) == .readWholeBudget)
        // The budget read left deeper history unread (the file is longer than the budget): format anyway.
        #expect(model.hasDeeperHistory)
        #expect(next(model, .copy(above), stamp: ahead, performed: [.readContinuation, .readWholeBudget]) == .format)
        #expect(next(model, .selectAll, stamp: ahead, performed: [.readContinuation, .readWholeBudget]) == .format)
    }

    @Test func aSelectionAboveTheReplaysOldestRowReadsTheWholeBudgetWhileDeeperHistoryExists() throws {
        let model = try makeModel(startByteOffset: 5000, requestedByteCount: 100)
        #expect(model.hasDeeperHistory)
        let above = selection(model.oldestAbsoluteRow - 1, model.oldestAbsoluteRow + 2, epoch: model.historyEpoch)
        let inside = selection(model.oldestAbsoluteRow, model.oldestAbsoluteRow + 2, epoch: model.historyEpoch)
        #expect(next(model, .copy(above)) == .readWholeBudget)
        #expect(next(model, .copy(inside)) == .format)
    }

    @Test func aSelectionAboveAReplayThatAlreadyAskedForTheWholeBudgetIsReady() throws {
        let model = try makeModel(startByteOffset: 5000, requestedByteCount: TerminalScrollbackBudget.defaultMaxBytes)
        #expect(!model.hasDeeperHistory)
        let above = selection(model.oldestAbsoluteRow - 1, model.oldestAbsoluteRow + 2, epoch: model.historyEpoch)
        #expect(next(model, .copy(above)) == .format)
    }

    @Test func aSelectionOfAnotherCoordinateSystemNeverPagesDeeper() throws {
        let model = try makeModel(startByteOffset: 5000, requestedByteCount: 100)
        let foreign = selection(model.oldestAbsoluteRow - 1, model.oldestAbsoluteRow + 2, epoch: model.historyEpoch &+ 1)
        #expect(next(model, .copy(foreign)) == .format)
        #expect(TerminalSelectionReplayPlanner.copyText(for: foreign, in: model) == nil)
    }

    /// A suffix replay built before any stamp lined it up reports its own epoch, so a selection in the
    /// host's epoch looks foreign and would format. Once a stamp at the replay's end arrives and the
    /// caller aligns the replay, the same selection reaches above the suffix and the planner pages deeper.
    @Test func aSelectionAboveAReplayThatAlignedAfterItWasBuiltReadsTheWholeBudget() throws {
        let model = try makeModel(startByteOffset: 5000, requestedByteCount: 100)
        let unalignedEpoch = model.historyEpoch
        let hostStamp = stamp(offset: model.transcriptEndByteOffset)
        let hostEpoch = hostStamp.historyEpoch
        #expect(unalignedEpoch != hostEpoch)

        model.align(with: [hostStamp])

        #expect(model.historyEpoch == hostEpoch)
        let above = selection(model.oldestAbsoluteRow - 1, model.oldestAbsoluteRow + 2, epoch: hostEpoch)
        #expect(next(model, .copy(above)) == .readWholeBudget)
    }

    @Test func selectAllReadsTheWholeBudgetOfAReplayThatCouldHoldMore() throws {
        let model = try makeModel(startByteOffset: 5000, requestedByteCount: 100)
        #expect(next(model, .selectAll) == .readWholeBudget)
    }

    @Test func copyTextAndSelectAllReadTheReplaysRows() throws {
        let model = try makeModel()
        let selection = try #require(TerminalSelectionReplayPlanner.selectAllSelection(in: model))
        #expect(selection.start == TerminalAbsoluteCell(column: 0, row: 0))
        let text = try #require(TerminalSelectionReplayPlanner.copyText(for: selection, in: model))
        #expect(text.hasPrefix(HostTranscript.line(1) + "\n" + HostTranscript.line(2)))
        #expect(text.hasSuffix(HostTranscript.line(40)))
    }
}

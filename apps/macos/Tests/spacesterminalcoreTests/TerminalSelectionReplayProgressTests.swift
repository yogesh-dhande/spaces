import Foundation
import Testing

@testable import spacesterminalcore

/// A request's walk through the planner: the steps it performed are recorded so none repeats.
@Suite struct TerminalSelectionReplayProgressTests {
    private func stamp(offset: UInt64) -> TerminalLiveFrameStamp {
        TerminalLiveFrameStamp(transcriptByteOffset: offset, transcriptFileIdentity: 7, historyEpoch: 1, activeTopRow: 0, columns: 20, rows: 6)
    }

    private func ring(_ offsets: [UInt64]) -> TerminalLiveFrameStampRing {
        var ring = TerminalLiveFrameStampRing()
        for offset in offsets { ring.record(stamp(offset: offset)) }
        return ring
    }

    @Test func theRequestStartsAtTheNewestLiveStamp() {
        let progress = TerminalSelectionReplayProgress(need: .selectAll, liveStamps: ring([10, 20]))

        #expect(progress.targetStamp == stamp(offset: 20))
        #expect(progress.performedSteps.isEmpty)
    }

    @Test func withoutAReplayASelectAllReadsOnceAndThenGivesUp() {
        var progress = TerminalSelectionReplayProgress(need: .selectAll, liveStamps: ring([]))

        #expect(progress.nextStep(model: nil, liveStamps: ring([]), replayIsUnavailable: false) == .readWholeBudget)
        #expect(progress.performedSteps == [.readWholeBudget])
        #expect(progress.nextStep(model: nil, liveStamps: ring([]), replayIsUnavailable: false) == .abandon)
        #expect(progress.performedSteps == [.readWholeBudget])
    }

    @Test func aLatchedUnavailableReplayAbandonsTheRequestWithoutARead() {
        var progress = TerminalSelectionReplayProgress(need: .selectAll, liveStamps: ring([]))

        #expect(progress.nextStep(model: nil, liveStamps: ring([]), replayIsUnavailable: true) == .abandon)
        #expect(progress.performedSteps.isEmpty)
    }
}

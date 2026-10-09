import Foundation

/// One copy or select-all request walking `TerminalSelectionReplayPlanner`'s steps, so every client (the
/// Mac pane and the iPhone) keeps the same bookkeeping and only performs the reads.
///
/// The request records the newest live frame stamp when it starts, and the replay must reach that
/// stamp's offset, not whatever streaming output stamps later. It also records the reads already spent,
/// which is what lets the planner never return one twice.
public struct TerminalSelectionReplayProgress: Sendable {
    public let need: TerminalSelectionReplayNeed
    public let targetStamp: TerminalLiveFrameStamp?
    public private(set) var performedSteps: [TerminalSelectionReplayStep] = []

    public init(need: TerminalSelectionReplayNeed, liveStamps: TerminalLiveFrameStampRing) {
        self.need = need
        targetStamp = liveStamps.stamps.last
    }

    /// The next step for this request. The replay is lined up with the newest stamps first, because the
    /// planner compares the selection's epoch with the replay's. A read step is recorded as performed
    /// here, so the caller only starts it.
    public mutating func nextStep(model: TerminalLocalScrollbackModel?, liveStamps: TerminalLiveFrameStampRing, replayIsUnavailable: Bool)
        -> TerminalSelectionReplayStep
    {
        model?.align(with: liveStamps.stamps)
        let step = TerminalSelectionReplayPlanner.nextStep(
            model: model, need: need, targetStamp: targetStamp, performed: performedSteps, replayIsUnavailable: replayIsUnavailable)
        switch step {
        case .readFirstPage, .readContinuation, .readWholeBudget: performedSteps.append(step)
        case .format, .abandon: break
        }
        return step
    }
}

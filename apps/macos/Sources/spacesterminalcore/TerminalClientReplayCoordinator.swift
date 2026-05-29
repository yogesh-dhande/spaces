import Foundation

public enum TerminalClientReplayCoordinator {
    public struct OutputBatch: Equatable, Sendable {
        public let id: String
        public let data: Data
        public let outputEndByteOffset: Int?

        public init(id: String, data: Data, outputEndByteOffset: Int? = nil) {
            self.id = id
            self.data = data
            self.outputEndByteOffset = outputEndByteOffset
        }
    }

    public static func shouldApplyHistorySeed(
        lastAppliedHistorySeedID: String?, nextHistorySeedID: String?, hasHistorySeedData: Bool, hasSurface: Bool, replayStateChanged: Bool = true,
        hasReplaySurfaceContent: Bool = false
    ) -> Bool {
        guard hasSurface, hasHistorySeedData, let nextHistorySeedID else { return false }
        guard lastAppliedHistorySeedID != nextHistorySeedID else { return false }
        return lastAppliedHistorySeedID == nil || replayStateChanged || !hasReplaySurfaceContent
    }

    public static func shouldPreserveRenderedHistoryForOwnerBootstrap(
        previousOwnerEpochID: String?, currentOwnerEpochID: String, previousBootstrapSnapshot: GhosttyTerminalSnapshot?,
        currentBootstrapSnapshot: GhosttyTerminalSnapshot?, hasPendingOutputs: Bool, hasHistorySeed: Bool, hasAppliedOwnerEpoch: Bool
    ) -> Bool {
        !hasPendingOutputs && !hasHistorySeed && currentBootstrapSnapshot != nil && hasAppliedOwnerEpoch
            && previousOwnerEpochID == currentOwnerEpochID && previousBootstrapSnapshot == currentBootstrapSnapshot
    }

    public static func outputBatchesNotCovered(byHistorySeedEndOffset historySeedEndOffset: Int?, pendingOutputs: [OutputBatch]) -> [OutputBatch] {
        guard let historySeedEndOffset, !pendingOutputs.isEmpty else { return pendingOutputs }
        return pendingOutputs.compactMap { pendingOutput in
            guard let outputEndByteOffset = pendingOutput.outputEndByteOffset else { return pendingOutput }
            guard outputEndByteOffset > historySeedEndOffset else { return nil }

            let outputStartByteOffset = max(0, outputEndByteOffset - pendingOutput.data.count)
            guard outputStartByteOffset < historySeedEndOffset else { return pendingOutput }

            let coveredByteCount = historySeedEndOffset - outputStartByteOffset
            guard coveredByteCount < pendingOutput.data.count else { return nil }
            return OutputBatch(
                id: "\(pendingOutput.id)|after|\(historySeedEndOffset)", data: Data(pendingOutput.data.dropFirst(coveredByteCount)),
                outputEndByteOffset: outputEndByteOffset)
        }
    }

    public static func appendingOutputBatchNotCovered(
        _ pendingOutput: OutputBatch, to pendingOutputs: [OutputBatch], byHistorySeedEndOffset historySeedEndOffset: Int?
    ) -> [OutputBatch] { pendingOutputs + outputBatchesNotCovered(byHistorySeedEndOffset: historySeedEndOffset, pendingOutputs: [pendingOutput]) }
}

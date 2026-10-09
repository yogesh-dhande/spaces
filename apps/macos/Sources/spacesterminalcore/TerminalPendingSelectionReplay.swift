import Foundation

/// What the user asked of the replay. A copy carries the pasteboard's change count at the press: the
/// text is written only if nothing else has written the pasteboard while the replay caught up.
public enum TerminalSelectionReplayRequest: Equatable, Sendable {
    case copy(TerminalAbsoluteSelection, pasteboardChangeCount: Int)
    case selectAll

    public var need: TerminalSelectionReplayNeed {
        switch self {
        case .copy(let selection, _): .copy(selection)
        case .selectAll: .selectAll
        }
    }
}

/// A request and its walk through the planner's steps (`TerminalSelectionReplayProgress`): the one copy
/// or select-all a client has waiting on its replay.
public struct TerminalPendingSelectionReplay: Sendable {
    public let request: TerminalSelectionReplayRequest
    public var progress: TerminalSelectionReplayProgress
    /// Set when a copy was pressed while this select-all was pending: the pasteboard's change count at
    /// that press, and the copy runs on the selection the select-all produces.
    public var copyPasteboardChangeCount: Int?

    public init(request: TerminalSelectionReplayRequest, liveStamps: TerminalLiveFrameStampRing) {
        self.request = request
        progress = TerminalSelectionReplayProgress(need: request.need, liveStamps: liveStamps)
    }
}

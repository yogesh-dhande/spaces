import Foundation

public enum TerminalRemoteSessionStateReason {
    public static let initial = "initial"
    public static let attachmentState = "attachment_state"
    public static let input = "input"
    public static let inputOutput = "input_output"
    public static let output = "output"
    public static let scroll = "scroll"
    public static let runtimeState = "runtime_state"
    public static let resize = "resize"
    public static let terminated = "terminated"
}

public enum TerminalRemoteSessionStatePolicy {
    public static func shouldIncludeScreenState(reason: String, ownerKind: TerminalClientKind? = nil) -> Bool {
        switch reason {
        case TerminalRemoteSessionStateReason.initial, TerminalRemoteSessionStateReason.attachmentState:
            return ownerKind == .localWindow || ownerKind == .remoteViewer
        case TerminalRemoteSessionStateReason.resize: return ownerKind == .localWindow || ownerKind == .remoteViewer
        case TerminalRemoteSessionStateReason.output: return ownerKind == .localWindow || ownerKind == .remoteViewer
        case TerminalRemoteSessionStateReason.scroll: return true
        case TerminalRemoteSessionStateReason.terminated: return true
        case TerminalRemoteSessionStateReason.input: return false
        case TerminalRemoteSessionStateReason.inputOutput: return ownerKind == .localWindow
        default: return false
        }
    }

    public static func hasVisibleScreenContent(snapshot: GhosttyTerminalSnapshot?, snapshotText: String?) -> Bool {
        if let snapshot { if GhosttyTerminalSnapshotGrid.containsVisibleContent(snapshot) { return true } }
        guard let snapshotText else { return false }
        return snapshotText.contains(where: { !$0.isWhitespace && !$0.isNewline })
    }

    public static func hasUsableOwnerBootstrapState(
        _ payload: GhosttyRemoteSessionStatePayload?, viewportColumns: Int? = nil, viewportRows: Int? = nil
    ) -> Bool {
        guard let snapshot = payload?.renderFrameSnapshot else { return false }
        if let viewportColumns, snapshot.columns != viewportColumns { return false }
        if let viewportRows, snapshot.rows != viewportRows { return false }
        return true
    }
}

import Foundation

public enum TerminalRemoteSessionStateReason {
    public static let initial = "initial"
    public static let attachmentState = "attachment_state"
    public static let input = "input"
    public static let inputOutput = "input_output"
    public static let runtimeState = "runtime_state"
    public static let resize = "resize"
    public static let terminated = "terminated"
}

public enum TerminalRemoteSessionStatePolicy {
    public static func shouldIncludeScreenState(reason: String, ownerKind: TerminalClientKind? = nil) -> Bool {
        switch reason {
        case TerminalRemoteSessionStateReason.initial, TerminalRemoteSessionStateReason.attachmentState:
            return ownerKind == .localWindow || ownerKind == .remoteViewer
        case TerminalRemoteSessionStateReason.terminated: return true
        case TerminalRemoteSessionStateReason.input, TerminalRemoteSessionStateReason.inputOutput: return ownerKind != .remoteViewer
        default: return false
        }
    }

    public static func shouldUseCachedSessionSnapshot(reason: String, ownerKind: TerminalClientKind? = nil) -> Bool {
        guard ownerKind == .remoteViewer else { return false }
        return reason == TerminalRemoteSessionStateReason.initial || reason == TerminalRemoteSessionStateReason.attachmentState
    }

    public static func hasVisibleScreenContent(snapshot: GhosttyTerminalSnapshot?, snapshotText: String?) -> Bool {
        if let snapshot {
            let text = GhosttyTerminalSnapshotLayout.plainText(for: snapshot)
            if text.contains(where: { !$0.isWhitespace && !$0.isNewline }) { return true }
        }
        guard let snapshotText else { return false }
        return snapshotText.contains(where: { !$0.isWhitespace && !$0.isNewline })
    }

    public static func hasUsableOwnerBootstrapState(_ payload: GhosttyRemoteSessionStatePayload?) -> Bool { payload?.snapshot != nil }
}

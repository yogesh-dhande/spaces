import Foundation

extension Notification.Name {
    public static let spacesTerminalAttachmentStateDidChange = Notification.Name("spaces.terminal.attachment-state-did-change")
    public static let spacesTerminalSessionMetadataDidChange = Notification.Name("spaces.terminal.session-metadata-did-change")
    public static let spacesTerminalRuntimeStateDidChange = Notification.Name("spaces.terminal.runtime-state-did-change")
    public static let spacesTerminalOutputDidChange = Notification.Name("spaces.terminal.output-did-change")
}

/// Typed helpers for posting and reading the terminal session notifications above.
///
/// Every post carries a `sessionID` string in `userInfo`. Output-change posts
/// additionally carry a `byteCount` int; that key is retained for wire-compatibility
/// of the `userInfo` shape and currently has no readers.
public enum TerminalSessionNotification {
    private static let sessionIDKey = "sessionID"
    private static let byteCountKey = "byteCount"

    /// Posts `name` on `NotificationCenter.default` with the byte-identical
    /// `userInfo` shape the terminal session hosts have always used.
    public static func post(_ name: Notification.Name, sessionID: String, outputByteCount: Int? = nil) {
        var userInfo: [String: Any] = [sessionIDKey: sessionID]
        if let outputByteCount { userInfo[byteCountKey] = outputByteCount }
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    /// Defensively reads the `sessionID` string from a session notification.
    public static func sessionID(from notification: Notification) -> String? {
        notification.userInfo?[sessionIDKey] as? String
    }
}

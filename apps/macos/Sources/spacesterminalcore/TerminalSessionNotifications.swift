import Foundation

extension Notification.Name {
    public static let spacesTerminalAttachmentStateDidChange = Notification.Name("spaces.terminal.attachment-state-did-change")
    public static let spacesTerminalSessionMetadataDidChange = Notification.Name("spaces.terminal.session-metadata-did-change")
    public static let spacesTerminalRuntimeStateDidChange = Notification.Name("spaces.terminal.runtime-state-did-change")
    public static let spacesTerminalOutputDidChange = Notification.Name("spaces.terminal.output-did-change")
}

/// Typed helpers for posting and reading the terminal session notifications above.
///
/// Every post carries a `sessionID` string in `userInfo`.
public enum TerminalSessionNotification {
    private static let sessionIDKey = "sessionID"

    /// Posts `name` on `NotificationCenter.default` with the `userInfo` shape
    /// the terminal session hosts have always used.
    public static func post(_ name: Notification.Name, sessionID: String) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: [sessionIDKey: sessionID])
    }

    /// Defensively reads the `sessionID` string from a session notification.
    public static func sessionID(from notification: Notification) -> String? {
        notification.userInfo?[sessionIDKey] as? String
    }
}

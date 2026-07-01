import Foundation

/// Announces that a terminal session's overview-affecting state changed (exit,
/// title, or runtime/agent state).
///
/// Terminal runtime state is persisted outside the SQLite database, so these
/// changes do not raise `databaseDidChange`, the signal that otherwise drives
/// device-overview pushes. Without this signal a remote terminal exit or
/// title/state change would not reach overview subscribers until an unrelated
/// database write happened to occur. The device-overview stream server observes
/// this to rebroadcast a fresh overview.
public enum TerminalOverviewSignal {
    public static let name = Notification.Name("spaces.terminal.overview-state-did-change")

    /// Posts in-process for a same-process overview server (and for Linux, where
    /// `DistributedNotificationCenter` is unavailable) and, on macOS, profile-scoped
    /// across processes so a daemon-hosted overview server hears changes made by a
    /// terminal session hosted in another process.
    public static func post(profile: SpacesProfile? = nil) {
        NotificationCenter.default.post(name: name, object: nil)
        #if os(macOS)
            guard let object = (try? (profile ?? SpacesProfile.current()))?.ipcNotificationObject else { return }
            DistributedNotificationCenter.default().postNotificationName(
                name, object: object, userInfo: nil, options: [.deliverImmediately])
        #endif
    }
}

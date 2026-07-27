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
    ///
    /// The cross-process half resolves the profile itself when the caller passes none, and every
    /// production call site does — this fires on every terminal runtime-state change from a detached
    /// engine-actor task, with no natural place to surface an error and no test to attribute one to. It
    /// uses `currentOrNilLoggingRefusal()` rather than `try?`, so a test-host refusal reached from this
    /// hot path is reported (see that function's doc comment for why it is reported instead of trapped)
    /// instead of looking identical to the ordinary "no profile" case that already skips this half.
    public static func post(profile: SpacesProfile? = nil) {
        NotificationCenter.default.post(name: name, object: nil)
        #if os(macOS)
            guard let object = (profile ?? SpacesProfile.currentOrNilLoggingRefusal())?.ipcNotificationObject else { return }
            DistributedNotificationCenter.default().postNotificationName(name, object: object, userInfo: nil, options: [.deliverImmediately])
        #endif
    }
}

import Foundation

extension Notification.Name {
    public static let spacesTerminalAttachmentStateDidChange = Notification.Name("spaces.terminal.attachment-state-did-change")
    public static let spacesTerminalSessionMetadataDidChange = Notification.Name("spaces.terminal.session-metadata-did-change")
    public static let spacesTerminalRuntimeStateDidChange = Notification.Name("spaces.terminal.runtime-state-did-change")
    public static let spacesTerminalOutputDidChange = Notification.Name("spaces.terminal.output-did-change")
    /// Posted when a session's state provider gains or loses its live subscription to the owning
    /// device. It carries no payload beyond the session id: observers re-read
    /// `TerminalSessionStateProviding.isStateStreamDisconnected`.
    public static let spacesTerminalStateStreamConnectionDidChange = Notification.Name("spaces.terminal.state-stream-connection-did-change")
}

/// The identity object one session's notifications are posted against. Carries the session id so a
/// scope is readable in a debugger; routing uses the instance itself, never this string.
private final class TerminalSessionNotificationScope: NSObject, @unchecked Sendable {
    let sessionID: String

    init(sessionID: String) { self.sessionID = sessionID }
}

/// Interns one canonical scope object per session id.
///
/// `NotificationCenter` indexes registrations by the (name, object) pair and compares `object` by
/// pointer identity, never `isEqual:`. A session id bridged to `NSString` yields a fresh object on
/// every call and would therefore match nothing, so the poster and the session's observers have to
/// share one instance: that instance is what this registry hands out.
///
/// Scopes are held weakly. The only strong reference to one is the capture inside the observer block
/// registered through `TerminalSessionNotification.addObserver(forName:sessionID:queue:using:)`, so a
/// scope lives exactly as long as its session has an observer and the table never accumulates entries
/// for sessions that have gone. Posting for a session nobody observes interns a scope that dies with
/// the call, which changes nothing: such a post has only `nil`-object observers to reach.
private final class TerminalSessionNotificationScopeRegistry: @unchecked Sendable {
    static let shared = TerminalSessionNotificationScopeRegistry()

    /// A weak slot for one session's scope. A plain dictionary of these rather than `NSMapTable`:
    /// this file is in the Linux daemon's build graph, and swift-corelibs Foundation has no `NSMapTable`.
    private struct WeakScope { weak var scope: TerminalSessionNotificationScope? }

    private let lock = NSLock()
    private var scopesBySessionID: [String: WeakScope] = [:]

    func scope(for sessionID: String) -> TerminalSessionNotificationScope {
        lock.lock()
        defer { lock.unlock() }
        if let existing = scopesBySessionID[sessionID]?.scope { return existing }
        // Slots whose scope has been released stay behind until something looks them up, so interning a
        // new one is the moment to drop them: it keeps the table bounded by live sessions without a timer.
        scopesBySessionID = scopesBySessionID.filter { $0.value.scope != nil }
        let scope = TerminalSessionNotificationScope(sessionID: sessionID)
        scopesBySessionID[sessionID] = WeakScope(scope: scope)
        return scope
    }
}

/// Typed helpers for posting and observing the terminal session notifications above.
///
/// Every post is scoped to its session's canonical identity object and carries a `sessionID` string in
/// `userInfo`. The scope is what makes `NotificationCenter` route: an observer registered for one
/// session runs only for that session's posts, and an observer registered with a `nil` object still
/// receives every session's posts (the daemon's reconcilers, which react to any session's change).
public enum TerminalSessionNotification {
    private static let sessionIDKey = "sessionID"

    /// Posts `name` for one session, scoped so only that session's observers and the all-sessions
    /// (`nil`-object) observers are called out to.
    public static func post(_ name: Notification.Name, sessionID: String) {
        NotificationCenter.default.post(
            name: name, object: TerminalSessionNotificationScopeRegistry.shared.scope(for: sessionID), userInfo: [sessionIDKey: sessionID])
    }

    /// Registers an observer of `name` for one session. `block` runs only for posts about `sessionID`,
    /// so it needs no session check of its own.
    ///
    /// Register through this rather than `NotificationCenter` directly: it is what pairs the observer
    /// with the same scope object `post` uses, and its returned observer is what keeps that scope
    /// alive. Remove it with `NotificationCenter.default.removeObserver(_:)` as usual.
    public static func addObserver(
        forName name: Notification.Name, sessionID: String, queue: OperationQueue?, using block: @escaping @Sendable () -> Void
    ) -> any NSObjectProtocol {
        let scope = TerminalSessionNotificationScopeRegistry.shared.scope(for: sessionID)
        return NotificationCenter.default.addObserver(forName: name, object: scope, queue: queue) { _ in
            // The registry holds scopes weakly, so this capture is what keeps this session's scope
            // alive, and with it the identity `post` interns, for as long as the observer is registered.
            withExtendedLifetime(scope) { block() }
        }
    }

    /// Reads the `sessionID` string from a session notification, for observers registered with a `nil`
    /// object: they receive every session's posts and this is how they tell which session moved.
    public static func sessionID(from notification: Notification) -> String? { notification.userInfo?[sessionIDKey] as? String }
}

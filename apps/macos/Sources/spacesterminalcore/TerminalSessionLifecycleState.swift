import Foundation

/// What a session's persisted rows say about where it stands in its life: when its launch was recorded,
/// and its runtime state if a runtime row has been written for it.
///
/// This is what a caller classifying many sessions at once reads
/// (`TerminalSessionPersistence.sessionLifecycleStates(sessionIDs:)`), in place of a launch-configuration
/// and a runtime-state read per session.
public struct TerminalSessionLifecycleState: Sendable, Equatable {
    /// The launch configuration's `created_at`, in `TerminalSessionTimestamp` form.
    public let createdAt: String
    /// Nil when the session's launch row is committed but no runtime state has been written for it yet.
    public let runtimeState: TerminalSessionState?

    public init(createdAt: String, runtimeState: TerminalSessionState?) {
        self.createdAt = createdAt
        self.runtimeState = runtimeState
    }
}

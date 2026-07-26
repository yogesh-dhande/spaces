import Foundation
import spacesterminalcore

/// The persistent notice a pane's banner carries: a fact about the pane itself that stays up until
/// the pane replaces or clears it, unlike the transient banners a pane's link activity raises.
public struct TerminalPaneBannerNotice: Equatable, Sendable {
    /// How the notice is drawn. The two kinds report different things and are weighted differently:
    /// a stopped session is a failure the pane wants the eye on, while a dropped connection is an
    /// informational state the app is already working through.
    public enum Kind: Equatable, Sendable {
        /// The session's process is gone — it exited or failed.
        case stopped
        /// The client has lost its state subscription to the owning device and is retrying.
        case disconnected
    }

    public let message: String
    public let kind: Kind

    public init(message: String, kind: Kind) {
        self.message = message
        self.kind = kind
    }
}

extension TerminalPaneBannerNotice {
    static let sessionEnded = TerminalPaneBannerNotice(message: "Session ended. This pane is read-only.", kind: .stopped)
    static let sessionFailed = TerminalPaneBannerNotice(message: "Session failed. The process stopped unexpectedly.", kind: .stopped)
    /// Deliberately says nothing about the session: the process keeps running on the device through an
    /// outage, and the pane's frozen render is a viewing problem, not a death.
    static let disconnected = TerminalPaneBannerNotice(message: "Connection lost. Reconnecting…", kind: .disconnected)

    /// Resolves the pane's persistent notice from the two independent facts it knows: what the device
    /// last reported this session's process is doing, and whether the client can currently see that
    /// device. Pure, so the precedence between them is directly testable.
    ///
    /// A stopped session wins over a dropped connection. The device reported the process gone before
    /// the link dropped, and no reconnect can change that; the drop itself is expected for a session
    /// that ended, because the daemon streams live sessions only and refuses to subscribe to one that
    /// did not. Reporting the drop would replace the notice that explains why the pane is read-only
    /// with one that implies it might come back.
    ///
    /// A dropped connection is reported for every other case, including an unknown runtime state: not
    /// yet knowing what the session is doing is exactly what an unreachable device looks like.
    static func resolve(runtimeState: TerminalSessionState?, isStateStreamDisconnected: Bool) -> TerminalPaneBannerNotice? {
        switch runtimeState {
        case .exited: return .sessionEnded
        case .failed: return .sessionFailed
        case .starting, .running, .none: return isStateStreamDisconnected ? .disconnected : nil
        }
    }
}

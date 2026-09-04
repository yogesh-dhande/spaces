import Foundation
import spacesterminalcore

/// The persistent notice a pane's banner carries: a fact about the pane itself that stays up until
/// the pane replaces or clears it, unlike the transient banners a pane's link activity raises.
public struct TerminalPaneBannerNotice: Equatable, Sendable {
    /// How the notice is drawn. The kinds report different things and are weighted differently: a
    /// stopped session or an unreachable device are failures the pane wants the eye on, while a
    /// dropped-but-still-retrying connection is an informational state the app is already working
    /// through.
    public enum Kind: Equatable, Sendable {
        /// The session's process is gone — it exited or failed.
        case stopped
        /// The client has lost its state subscription to the owning device and is retrying: stage 1
        /// of `TerminalConnectionStage`.
        case disconnected
        /// Every one of the device's candidate addresses has refused to dial: stage 2 of
        /// `TerminalConnectionStage`. Automatic retries keep coming on a slower cadence, and the pane
        /// offers a Retry action to redial immediately.
        case unreachable
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
    static let disconnected = TerminalPaneBannerNotice(message: TerminalConnectionNotice.reconnectingText, kind: .disconnected)
    /// Stage 2: every candidate address has refused to dial. Still says nothing about the session
    /// itself, for the same reason `disconnected` does not.
    static let unreachable = TerminalPaneBannerNotice(message: TerminalConnectionNotice.unreachableText, kind: .unreachable)

    /// True for the message of either connection notice (`disconnected` or `unreachable`): the two
    /// messages the input-status row clears itself against once the connection recovers, without caring
    /// which stage it was in. See `TerminalSessionPaneViewController+Keyboard`.
    static func isConnectionNoticeMessage(_ message: String) -> Bool {
        message == TerminalPaneBannerNotice.disconnected.message || message == TerminalPaneBannerNotice.unreachable.message
    }

    /// Resolves the pane's persistent notice from the facts it knows: what the device last reported
    /// this session's process is doing, and, while that process is still running as far as the device
    /// last said, the connection stage and whether its banner has cleared its grace. Pure, so the
    /// precedence between them is directly testable.
    ///
    /// A stopped session wins over a dropped connection. The device reported the process gone before
    /// the link dropped, and no reconnect can change that; the drop itself is expected for a session
    /// that ended, because the daemon streams live sessions only and refuses to subscribe to one that
    /// did not. Reporting the drop would replace the notice that explains why the pane is read-only
    /// with one that implies it might come back.
    ///
    /// For every other runtime state, including an unknown one (not yet knowing what the session is
    /// doing is exactly what an unreachable device looks like), the connection stage decides: nothing
    /// while connected or still inside the grace, "Reconnecting…" for stage 1 once the banner is
    /// visible, "Device unreachable" for stage 2.
    static func resolve(runtimeState: TerminalSessionState?, connectionStage: TerminalConnectionStage, isBannerVisible: Bool) -> TerminalPaneBannerNotice? {
        switch runtimeState {
        case .exited: return .sessionEnded
        case .failed: return .sessionFailed
        case .starting, .running, .none:
            guard isBannerVisible else { return nil }
            switch connectionStage {
            case .connected: return nil
            case .reconnecting: return .disconnected
            case .unreachable: return .unreachable
            }
        }
    }
}

import Foundation

/// The verbatim copy and timing constants for the terminal connection banner, shared by both clients so
/// their wording and grace period never drift apart.
///
/// Both clients render one compact banner over the terminal frame keyed off `TerminalConnectionStage`:
/// stage 1 shows `reconnectingText`, stage 2 shows `unreachableText` plus a `retryActionTitle` button.
/// The strings live here rather than in each client's UI layer so a copy change is made once.
public enum TerminalConnectionNotice {
    /// Stage 1 banner text. Uses the Unicode ellipsis character (U+2026), not three periods.
    public static let reconnectingText = "Reconnecting…"

    /// Stage 2 banner text.
    public static let unreachableText = "Device unreachable"

    /// Stage 2 banner action title.
    public static let retryActionTitle = "Retry"

    /// How long a client waits after losing the stream before it shows the stage 1 banner.
    ///
    /// Most redials succeed on their first attempt well inside a second, and flashing a banner for those
    /// would make ordinary blips look like incidents. The grace only ever hides stage 1; a redial that
    /// comes back with hard evidence of unreachability (stage 2) skips the grace entirely, because that
    /// state is worth surfacing immediately regardless of how quickly it was reached.
    public static let bannerGraceSeconds: TimeInterval = 1
}

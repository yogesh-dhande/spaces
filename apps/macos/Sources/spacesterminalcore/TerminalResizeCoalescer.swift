import Foundation

/// Decides which of a burst of resize requests a session actually reflows to.
///
/// A reflow is lossy for an inline TUI: shrinking the rows pushes the cursor's row into scrollback, the
/// cursor resets to the top, and growing back adds blank rows instead of pulling the scrollback home, so
/// the screen the program drew survives only as its footer rows (#468). A client that measures a
/// transient tiny grid and restores the real one a moment later must therefore never make the session
/// reflow to the tiny grid at all. The macOS host gets this from Ghostty's termio, which applies only the
/// last resize that arrived within `window`; the headless Linux core has no termio, so it uses this type.
///
/// Like termio's, the window opens on the first request of a burst and is not extended by later ones, so
/// a continuous drag still reflows every `window`. The type owns no timer: the caller arms one for
/// `window` when `request` answers `.armTimer` and calls `settle` when it fires, which keeps the policy
/// deterministic to test.
public struct TerminalResizeCoalescer: Sendable {
    public static let window: Duration = .milliseconds(25)

    public struct Size: Equatable, Sendable {
        public let columns: Int
        public let rows: Int

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing is waiting and the session already has this grid.
        case alreadyCurrent
        /// This request opened a window: the caller arms a timer for `window` and calls `settle` when it fires.
        case armTimer
        /// A window is already open; the size replaces the one waiting and the open window's timer applies it.
        case coalesced
    }

    private var pending: Size?
    private var windowIsOpen = false

    public init() {}

    /// Whether a window is open, so a caller can drop its timer on teardown.
    public var hasOpenWindow: Bool { windowIsOpen }

    public mutating func request(_ size: Size, current: Size) -> Outcome {
        if windowIsOpen {
            pending = size
            return .coalesced
        }
        guard size != current else { return .alreadyCurrent }
        pending = size
        windowIsOpen = true
        return .armTimer
    }

    /// Closes the window without applying anything, for a caller whose pending size is no longer wanted.
    public mutating func discardPending() {
        pending = nil
        windowIsOpen = false
    }

    /// Closes the window and returns the grid to reflow to, or nil when the burst ended back at `current`.
    public mutating func settle(current: Size) -> Size? {
        let settled = pending
        pending = nil
        windowIsOpen = false
        guard let settled, settled != current else { return nil }
        return settled
    }
}

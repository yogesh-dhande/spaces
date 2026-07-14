import Foundation

enum GhosttyTerminalTranscriptMutation {
    /// Replays the user-visible clear operation through both GhosttyKit and
    /// libghostty-vt: home the cursor, erase the display, then erase scrollback.
    static let clearScreenAndScrollback = Data("\u{001B}[H\u{001B}[2J\u{001B}[3J".utf8)
}

import Foundation

/// Whether opening a terminal session's pane is allowed to move focus.
///
/// Carried alongside `TerminalAttachmentMode` on the open-pane request: attachment decides how the
/// client attaches to the session, this decides what the open does to the window. The two are
/// independent, so a non-focusing open still reclaims owner attachment.
public enum TerminalOpenFocusIntent: String, Codable, Sendable, CaseIterable {
    /// Bring the session's panel forward, select its tab, and put the caret in it. What a user
    /// asking for a terminal (`spaces terminal show`, a `spaces://` link, an in-app action) wants.
    case focus
    /// Install the pane, or leave the one it already has exactly where it is: no tab selection, no
    /// panel brought forward, no first-responder change. What a programmatically triggered launch
    /// wants, so that starting a workspace from a script never steals the window the user is in.
    case withoutFocus = "without_focus"
}

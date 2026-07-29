import Foundation

/// The single rule that names a terminal session. It lives apart from the catalog entry because
/// clients resolve the same name from pieces they hold separately — an open pane knows the live
/// title first-hand while the rename reaches it through the device overview — and both sides must
/// agree on which one wins.
public enum TerminalSessionTitle {
    /// A manual rename (`userTitle`) pins the name: it wins over the runtime title, which Ghostty
    /// set_title events keep rewriting; the launch-time title is the fallback before either exists.
    /// A blank title at any level is treated as unset — a program that clears its title should hand
    /// the name back to the level below rather than leave the session nameless.
    public static func effective(userTitle: String?, runtimeTitle: String?, launchTitle: String) -> String {
        [userTitle, runtimeTitle, launchTitle].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? launchTitle
    }
}

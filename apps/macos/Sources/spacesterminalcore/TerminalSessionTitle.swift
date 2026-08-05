import Foundation

/// The two things a terminal session is called: the name that identifies it and the title the program
/// inside it reports. They resolve here rather than at each surface because the daemon publishes both
/// to every client as separate values, and a surface that mixed them would let a program rename the row
/// the user named.
public enum TerminalSessionTitle {
    /// The session's stable name: the user's rename when one is stored, else the launch-generated name
    /// (`shell-1`). A blank stored rename counts as none, which is what clearing a rename writes.
    public static func name(userTitle: String?, launchTitle: String) -> String {
        guard let userTitle, !userTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return launchTitle }
        return userTitle
    }

    /// The title the running program last set (OSC 0/2), or nil when it has set none. A blank title is a
    /// cleared one: a program that clears its title stops describing itself rather than describing
    /// itself as nothing.
    public static func liveTitle(_ runtimeTitle: String?) -> String? {
        guard let runtimeTitle, !runtimeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return runtimeTitle
    }
}

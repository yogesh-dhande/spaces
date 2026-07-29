import Foundation

/// Renders a terminal session's working directory as row-sized secondary text. Every client
/// shows the same abbreviation, so the rule lives here rather than in each surface.
public enum TerminalWorkingDirectoryDisplay {
    /// The fish-shell `prompt_pwd` abbreviation: the home prefix collapses to `~`, every
    /// component but the last collapses to its first character (hidden components keep the
    /// dot, so `.config` reads as `.c`), and the last component stays whole —
    /// `/Users/ada/projects/spaces` reads as `~/p/spaces`.
    public static func abbreviated(_ path: String, homeDirectory: String) -> String {
        let components = self.components(of: path)
        guard !components.isEmpty else { return "/" }

        let homeComponents = self.components(of: homeDirectory)
        let isUnderHome = !homeComponents.isEmpty && components.starts(with: homeComponents)
        let tail = isUnderHome ? Array(components.dropFirst(homeComponents.count)) : components
        // An empty leading element joins into the leading "/" an absolute path needs.
        let prefix = isUnderHome ? "~" : ""
        guard let last = tail.last else { return "~" }
        return ([prefix] + tail.dropLast().map(shortened(_:)) + [last]).joined(separator: "/")
    }

    /// The secondary text for an ad hoc shell row, or `nil` when there is nothing worth showing:
    /// a shell sitting at its workspace root adds no information the row's workspace does not
    /// already carry.
    public static func rowDetail(workingDirectory: String, workspaceDirectory: String, homeDirectory: String) -> String? {
        // Missing is an empty STRING; the filesystem root is a present directory whose component
        // list is empty, and a shell sitting at `/` deserves its detail.
        guard !workingDirectory.isEmpty else { return nil }
        guard self.components(of: workingDirectory) != self.components(of: workspaceDirectory) else { return nil }
        return abbreviated(workingDirectory, homeDirectory: homeDirectory)
    }

    /// A component collapses to its first character; a hidden component keeps the leading dot
    /// so `.config` and `config` stay distinguishable.
    private static func shortened(_ component: String) -> String { String(component.prefix(component.hasPrefix(".") ? 2 : 1)) }

    private static func components(of path: String) -> [String] { path.split(separator: "/").map(String.init) }
}

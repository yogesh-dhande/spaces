import Foundation

/// How Spaces runs the Codex CLI on its host: always the executable the installer resolved, always
/// against the Codex home Spaces manages.
enum AgentHookCodexCLI {
    /// The environment for one Codex command: the daemon's own, with `CODEX_HOME` naming the managed
    /// home and the executable's directory leading `PATH`.
    ///
    /// Version-manager launchers commonly use `#!/usr/bin/env node`; resolving the launcher by absolute
    /// path is not enough unless its sibling runtime also leads PATH.
    static func environment(executablePath: String, codexHome: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        let currentPathDirectories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = ([executableDirectory] + currentPathDirectories.filter { $0 != executableDirectory }).joined(separator: ":")
        return environment
    }
}

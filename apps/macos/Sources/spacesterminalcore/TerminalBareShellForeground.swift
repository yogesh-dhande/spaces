import Foundation

/// Decides whether a terminal session's foreground process is the session's own shell sitting at a bare
/// prompt, as opposed to a purposeful program the user started in it.
///
/// Two decisions share this rule so they can never disagree about what "back at a prompt" means: the
/// conditional stop that ends an ad hoc terminal the user closed, and the agent-row demotion that sheds a
/// detected coding-agent classification once the agent process is gone.
///
/// Matching the executable name against the session's own launch shell is what makes the answer
/// unambiguous: a foreground sample that has not landed yet, or a running program nothing classified,
/// both report a name that is not the shell and are therefore not bare. The argv rule then separates a
/// shell waiting for input from a shell that IS the user's program: `zsh build.sh` and `zsh -c '...'` are
/// running work under the same executable name, so only flag arguments (and no `-c`) count as bare.
public enum TerminalBareShellForeground {
    /// - Parameters:
    ///   - executableName: the foreground process's executable basename, as sampled from the OS. A nil or
    ///     empty name is not bare: it means no foreground sample, which says nothing about what is running.
    ///   - argv: the foreground process's arguments. `argv[0]` is process identity and is ignored; a
    ///     missing or empty argv alongside a matching executable name is bare.
    ///   - launchShell: the shell path the session was launched with.
    public static func isBareShell(executableName: String?, argv: [String]?, launchShell: String) -> Bool {
        guard let executableName = executableName?.trimmingCharacters(in: .whitespacesAndNewlines), !executableName.isEmpty else { return false }
        let shellBasename = TerminalForegroundProcessInspector.lastPathComponent(of: launchShell.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !shellBasename.isEmpty else { return false }
        // A login shell is exec'd with a leading dash on its name (`-zsh`), which is the same shell.
        guard executableName == shellBasename || executableName == "-\(shellBasename)" else { return false }
        guard let argv, argv.count > 1 else { return true }
        return argv.dropFirst().allSatisfy { $0.hasPrefix("-") && $0 != "-c" }
    }
}

import Foundation

/// How a terminal's shell is started so the wrapper directory ends up first on PATH.
///
/// Two launch shapes exist. A bare shell (`exec <shell> -l`) is interactive, so its user startup files and
/// prompt hooks run: each supported shell is pointed at a generated startup file that sources the user's
/// own files and then installs a prompt hook. A command (`exec <shell> -l -i -c '<cmd>'`) never reaches a
/// prompt, so the command text itself re-prepends the wrapper directory after the rc files have run.
/// Shells other than zsh, bash and fish get only the launch-time PATH entry.
///
/// Statements are evaluated by the launching shell, which is the same shell that is then exec'd, and are
/// written to keep the pane's command summary clean: zsh and bash statements are plain `export` forms.
extension SpacesShellIntegration {
    public enum LaunchShell: Equatable, Sendable {
        case zsh, bash, fish, other

        init(shellPath: String) {
            switch URL(fileURLWithPath: shellPath).lastPathComponent {
            case "zsh": self = .zsh
            case "bash": self = .bash
            case "fish": self = .fish
            default: self = .other
            }
        }
    }

    /// Whether bash can be started with `--posix` and `ENV` pointing at the generated script.
    ///
    /// Apple's patched `/bin/bash` 3.2 disables the `ENV` startup path, so injection cannot work there and
    /// that shell gets only the launch-time PATH entry (accepted limitation; same rule Ghostty applies).
    /// `/bin` is not writable on modern macOS, so the exact path identifies Apple's build.
    public static func bashSupportsStartupInjection(shellPath: String) -> Bool {
        #if canImport(Darwin)
            return shellPath != "/bin/bash"
        #else
            return true
        #endif
    }

    /// Statements to run before `exec <shell>` for a bare interactive shell, and the arguments that shell
    /// is started with.
    public func bareShellLaunch(shellPath: String) -> (statements: [String], shellArguments: [String]) {
        let pathStatement = Self.pathPrependStatement(for: LaunchShell(shellPath: shellPath), binDirectory: binDirectory)
        let quote = SpacesShellIntegrationScripts.quoted
        switch LaunchShell(shellPath: shellPath) {
        case .zsh:
            return (
                [
                    pathStatement, #"export SPACES_USER_ZDOTDIR="${ZDOTDIR-}""#, #"export SPACES_USER_ZDOTDIR_SET="${ZDOTDIR+1}""#,
                    "export ZDOTDIR=\(quote(zshDirectory))",
                ], ["-l"]
            )
        case .bash where Self.bashSupportsStartupInjection(shellPath: shellPath):
            return (
                [
                    pathStatement, #"export SPACES_USER_ENV="${ENV-}""#, #"export SPACES_USER_ENV_SET="${ENV+1}""#,
                    "export ENV=\(quote(bashScriptPath))",
                ], ["--posix", "-l"]
            )
        case .fish:
            let dirs = quote(fishDataDirectory)
            // When the variable is unset its default is spelled out, so distro vendor_conf.d files still load.
            let injection =
                "if set -q XDG_DATA_DIRS; set -gx SPACES_USER_XDG_DATA_DIRS \"$XDG_DATA_DIRS\"; set -gx XDG_DATA_DIRS \(dirs):\"$XDG_DATA_DIRS\"; "
                + "else; set -e SPACES_USER_XDG_DATA_DIRS; set -gx XDG_DATA_DIRS \(quote(fishDataDirectory + ":/usr/local/share:/usr/share")); end"
            return ([pathStatement, injection], ["-l"])
        case .bash, .other: return ([pathStatement], ["-l"])
        }
    }

    /// Statements to run before `exec <shell> -l -i -c ...`.
    public func commandLaunchStatements(shellPath: String) -> [String] {
        [Self.pathPrependStatement(for: LaunchShell(shellPath: shellPath), binDirectory: binDirectory)]
    }

    /// A statement for the front of the command text that puts the wrapper directory first again after the
    /// rc files an interactive `-c` shell reads. Nil for shells whose syntax is unknown here.
    public func commandPathPrelude(shellPath: String) -> String? {
        let shell = LaunchShell(shellPath: shellPath)
        return shell == .other ? nil : Self.pathPrependStatement(for: shell, binDirectory: binDirectory)
    }

    private static func pathPrependStatement(for shell: LaunchShell, binDirectory: String) -> String {
        let bin = SpacesShellIntegrationScripts.quoted(binDirectory)
        return shell == .fish ? "set -gx PATH \(bin) $PATH" : "export PATH=\(bin):\"$PATH\""
    }
}

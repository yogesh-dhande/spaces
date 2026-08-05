import Foundation
import spacesterminalcore

/// How a `spacese2e` invocation says it targets the installed profile (`~/.spaces`) instead of the profile
/// the binary resolves from where it sits.
///
/// There is exactly one way to say it: the `--installed-profile` selector on this process's own command line.
/// It is deliberately not an environment variable — an inherited binding is precisely what must never be able
/// to point one profile's tooling at another profile's state — and it is deliberately not a per-command
/// option, so it is settled before ArgumentParser runs and before any command has resolved a profile.
///
/// `spacese2e` never ships to users, which is why this exists here and not in the `spaces` CLI, where it would
/// be product API.
public enum SpacesE2EInstalledProfileSelection {
    public static let selector = "--installed-profile"

    /// What is left of a command line once the selector is consumed, and whether it was there.
    public struct Invocation: Equatable, Sendable {
        public let commandArguments: [String]
        public let targetsInstalledProfile: Bool

        public init(commandArguments: [String], targetsInstalledProfile: Bool) {
            self.commandArguments = commandArguments
            self.targetsInstalledProfile = targetsInstalledProfile
        }

        /// Refuses this invocation if any of its arguments names a path inside `profileRoot`.
        ///
        /// A `readOnly` classification is a claim about the PROFILE, not about the filesystem: several
        /// permitted commands take a destination they own outright — `record-screen` deletes and recreates
        /// both its `--output` and its `--ready-file`, and `dump-terminal-session-window-state` has the
        /// running app atomically overwrite its `--output-path`. Pointed at `~/.spaces/spaces.db` any of them
        /// destroys live state under a classification promising it cannot, so a bound invocation may name no
        /// path inside the profile it borrowed.
        ///
        /// Every argument is tested rather than the destination options of the commands that have them today.
        /// Recognising destinations by option name would mean a second argument parser beside ArgumentParser's,
        /// kept in step by hand, and a destination option added later would be unguarded until someone
        /// remembered it. Nothing a permitted command legitimately takes points inside the profile root — the
        /// paths it reads there it derives itself — so "no argument names a path in there" costs nothing and
        /// covers every command, including ones not written yet.
        ///
        /// A relative argument is resolved against `currentDirectoryPath`, which is what the command itself
        /// would do with it, so a destination is caught whether it was spelled absolutely or reached by
        /// running from inside the profile root. That does mean a bound invocation started with the profile
        /// root as its working directory is refused on almost any argument, since every relative one resolves
        /// in there — the right answer for a working directory nothing should be run from, arrived at by
        /// failing closed rather than by a rule of its own.
        public func refuseArgumentsInside(
            profileRoot: String, currentDirectoryPath: String = FileManager.default.currentDirectoryPath
        ) throws {
            guard targetsInstalledProfile else { return }
            let profileRootURL = URL(fileURLWithPath: profileRoot, isDirectory: true)
            for argument in commandArguments {
                for candidate in Self.pathCandidates(in: argument, currentDirectoryPath: currentDirectoryPath)
                where SpacesProfile.isPath(candidate, atOrUnder: profileRootURL) {
                    throw SpacesE2EInstalledProfileRefusal.argumentNamesPathInsideProfile(
                        argument: argument, path: candidate, profileRoot: profileRoot)
                }
            }
        }

        /// The absolute paths one argument could name. An option written `--output=<path>` carries its value
        /// in the same token, so the part after the first `=` is tested as well — that is reading the one
        /// spelling ArgumentParser also accepts, not interpreting which option it belongs to.
        private static func pathCandidates(in argument: String, currentDirectoryPath: String) -> [String] {
            var tokens = [argument]
            if argument.hasPrefix("-"), let separatorIndex = argument.firstIndex(of: "=") {
                tokens.append(String(argument[argument.index(after: separatorIndex)...]))
            }
            return tokens.compactMap { token in
                let expanded = (token as NSString).expandingTildeInPath
                guard !expanded.isEmpty else { return nil }
                if expanded.hasPrefix("/") { return expanded }
                return URL(fileURLWithPath: currentDirectoryPath, isDirectory: true).appendingPathComponent(expanded).path
            }
        }
    }

    /// Consumes the selector from `arguments` and decides whether this invocation may have it.
    ///
    /// Without the selector nothing is checked and the arguments pass through unchanged: the ordinary
    /// invocation resolves this checkout's development profile and is not this gate's business.
    ///
    /// With it, the named command's classification decides, and anything the classification does not permit —
    /// including a command with no classification at all, and a command line that names no command — is
    /// refused. The command is the first argument that is not an option, which is where ArgumentParser reads
    /// a subcommand from; only the top-level command is classified, so a group's own entry governs its
    /// subcommands.
    public static func parse(arguments: [String]) throws -> Invocation {
        guard arguments.contains(selector) else { return Invocation(commandArguments: arguments, targetsInstalledProfile: false) }
        let commandArguments = arguments.filter { $0 != selector }
        guard let commandName = commandArguments.first(where: { !$0.hasPrefix("-") }) else { throw SpacesE2EInstalledProfileRefusal.noCommandNamed }
        guard let access = SpacesE2EInstalledProfileAccess.byCommandName[commandName] else {
            throw SpacesE2EInstalledProfileRefusal.commandUnclassified(commandName: commandName)
        }
        switch access {
        case .readOnly, .reversible: return Invocation(commandArguments: commandArguments, targetsInstalledProfile: true)
        case .refused(let reason): throw SpacesE2EInstalledProfileRefusal.commandRefused(commandName: commandName, reason: reason)
        }
    }
}

/// Why an invocation may not target the installed profile. Every case is loud on purpose: the refused command
/// would otherwise act on the profile a user's own app, daemon, and CLI are serving.
public enum SpacesE2EInstalledProfileRefusal: Error, CustomStringConvertible {
    /// The command is classified as unsafe on a live profile. `reason` comes from that classification.
    case commandRefused(commandName: String, reason: String)

    /// The command has no installed-profile classification, so it is refused rather than assumed safe.
    case commandUnclassified(commandName: String)

    /// The selector was passed without a command to apply it to.
    case noCommandNamed

    /// An argument named a path inside the installed profile root. Permitted commands own the destinations
    /// they are given — they delete and overwrite them — so one pointed there destroys the live state the
    /// classification promises it cannot touch.
    case argumentNamesPathInsideProfile(argument: String, path: String, profileRoot: String)

    public var description: String {
        switch self {
        case .commandRefused(let commandName, let reason):
            return "spacese2e: `\(commandName)` is refused against the installed profile (~/.spaces) because \(reason). "
                + "Run it without \(SpacesE2EInstalledProfileSelection.selector) to act on this checkout's development profile instead."
        case .commandUnclassified(let commandName):
            return "spacese2e: `\(commandName)` has no installed-profile classification, so it is refused. Classify it in "
                + "`SpacesE2EInstalledProfileAccess.byCommandName` as .readOnly, .reversible, or .refused(reason:) once what it does to a live "
                + "profile is settled."
        case .noCommandNamed:
            return "spacese2e: \(SpacesE2EInstalledProfileSelection.selector) names no command. Pass it alongside a command that is classified "
                + "as safe on the installed profile."
        case .argumentNamesPathInsideProfile(let argument, let path, let profileRoot):
            return "spacese2e: the argument `\(argument)` names \(path), which is inside the installed profile root \(profileRoot). A command "
                + "that takes a destination deletes and overwrites it, so a path in there would destroy live profile state that this command's "
                + "classification promises it cannot touch. Point it somewhere outside \(profileRoot) — the system temporary directory — and "
                + "retry."
        }
    }
}

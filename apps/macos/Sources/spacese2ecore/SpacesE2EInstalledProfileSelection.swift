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
        }
    }
}

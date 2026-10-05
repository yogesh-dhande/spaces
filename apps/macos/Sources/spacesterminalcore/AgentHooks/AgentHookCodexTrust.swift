import Foundation

/// Codex's trust in this device's Spaces hooks, read and recorded through Codex itself
/// (`AgentHookCodexAppServer`).
///
/// **Which entries are Spaces'.** An entry Codex reads from the user hooks file (`source` `user`, and the
/// `sourcePath` of the `hooks.json` Spaces writes) whose command is exactly the one this device's Spaces
/// writes for that event: `AgentHookCommand.signalCommand` with the `spaces` path the installer resolves
/// on this device. The `spaces-agent-hook` marker alone is not enough. A trust is the user's consent to
/// run exactly the commands they were shown, so another tool's hook on the same event, a lookalike that
/// carries the marker around a different command, and a hook defined in `config.toml` are never trusted
/// and never decide what the row says.
///
/// **What the row says.** Every bound event needs such an entry. An event without one means the file does
/// not carry what this device would write (an entry aimed at another `spaces`, hand-edited text), which
/// rewriting fixes, so it reads `outdated`. Past that, an entry switched off in Codex reads
/// `disabledByAgent`, since Codex runs it whatever its trust says and Spaces never switches it back on;
/// any entry Codex has not trusted at its current text reads `awaitingTrust`, carrying those entries for
/// the confirmation the user sees before trusting them; and otherwise `current`.
enum AgentHookCodexTrust {
    /// The app-server session a status read may take. A healthy one answers in about a tenth of a second;
    /// the bound keeps a wedged Codex inside the status request's own deadline alongside the
    /// `codex features list` probe that runs before it.
    static let statusTimeoutSeconds: TimeInterval = 5
    /// The session a trust may take: two listings and a write.
    static let trustTimeoutSeconds: TimeInterval = 15

    struct Reading: Equatable {
        let installState: AgentHookInstallState
        /// The entries the user is asked to trust, in binding order. Empty unless `awaitingTrust`.
        let untrustedEntries: [AgentHookEntry]
    }

    enum TrustError: LocalizedError, Equatable {
        /// Some bound event has no entry with this device's exact Spaces command, so there is nothing
        /// Spaces can stand behind trusting until the hooks are rewritten.
        case entriesNotListed
        /// Codex accepted the write and still lists entries as untrusted.
        case notRecorded(count: Int)

        var errorDescription: String? {
            switch self {
            case .entriesNotListed: "Codex does not list the hooks Spaces installs on this device"
            case .notRecorded(let count): "Codex still lists \(count == 1 ? "1 hook" : "\(count) hooks") as untrusted after recording the trust"
            }
        }
    }

    /// Asks Codex how it treats this device's Spaces entries. Runs only once the hooks file and the
    /// `hooks` feature are already current, since nothing short of that is worth trusting.
    ///
    /// A Codex that cannot answer (too old for `hooks/list`, broken, or slower than the bound) reads as
    /// `awaitingTrust` over every entry this device writes. That is the state whose action, trusting,
    /// asks Codex again and shows the user Codex's own reason when it still cannot answer, which is where
    /// the user learns to update Codex. Claiming `current` instead would hide hooks Codex may be skipping.
    static func status(codexExecutablePath: String, codexHome: URL, spacesExecutablePath: String, launcher: AgentHookCodexAppServer.Launcher)
        -> Reading
    {
        let hooksFileURL = codexHome.appendingPathComponent("hooks.json")
        let answer = try? AgentHookCodexAppServer.withSession(
            executablePath: codexExecutablePath, codexHome: codexHome, timeoutSeconds: statusTimeoutSeconds, launcher: launcher
        ) { (hooks: try $0.listHooks(), mcpServer: try $0.readSpacesMCPServer()) }
        guard let answer else {
            let expected = CodingAgent.codex.jsonEventBindings.map {
                AgentHookEntry(
                    eventName: $0.eventName, command: AgentHookCommand.signalCommand(event: $0.event, spacesExecutablePath: spacesExecutablePath))
            }
            return Reading(installState: .awaitingTrust, untrustedEntries: expected)
        }
        // A missing or stale `spaces` MCP server entry is fixed by the same setup that rewrites the hooks,
        // and setup comes before trust, so it reads `outdated` ahead of any trust question.
        guard AgentHookCodexMCPEntry.isCurrent(answer.mcpServer, spacesExecutablePath: spacesExecutablePath) else {
            return Reading(installState: .outdated, untrustedEntries: [])
        }
        return reading(listed: answer.hooks, hooksFileURL: hooksFileURL, spacesExecutablePath: spacesExecutablePath)
    }

    /// The row's state for a `hooks/list` answer. See the type's documentation for the rules.
    static func reading(listed: [AgentHookCodexListedHook], hooksFileURL: URL, spacesExecutablePath: String) -> Reading {
        let matched = spacesEntries(listed: listed, hooksFileURL: hooksFileURL, spacesExecutablePath: spacesExecutablePath)
        guard matched.allSatisfy({ !$0.entries.isEmpty }) else { return Reading(installState: .outdated, untrustedEntries: []) }
        if matched.contains(where: { $0.entries.contains { !$0.enabled } }) { return Reading(installState: .disabledByAgent, untrustedEntries: []) }
        let untrusted = matched.flatMap { binding, entries in
            entries.filter { !$0.isTrusted }.map { AgentHookEntry(eventName: binding.eventName, command: $0.command ?? "") }
        }
        return Reading(installState: untrusted.isEmpty ? .current : .awaitingTrust, untrustedEntries: untrusted)
    }

    /// Records Codex's trust in every Spaces entry it has not trusted yet, then confirms with Codex that
    /// the trust took. Entries switched off in Codex are left alone: a trust never turns a hook back on.
    /// Throws Codex's own reason when it cannot be asked or will not record the trust.
    static func trust(codexExecutablePath: String, codexHome: URL, spacesExecutablePath: String, launcher: AgentHookCodexAppServer.Launcher) throws {
        let hooksFileURL = codexHome.appendingPathComponent("hooks.json")
        try AgentHookCodexAppServer.withSession(
            executablePath: codexExecutablePath, codexHome: codexHome, timeoutSeconds: trustTimeoutSeconds, launcher: launcher
        ) { session in
            let matched = spacesEntries(listed: try session.listHooks(), hooksFileURL: hooksFileURL, spacesExecutablePath: spacesExecutablePath)
            guard matched.allSatisfy({ !$0.entries.isEmpty }) else { throw TrustError.entriesNotListed }
            let candidates = matched.flatMap(\.entries).filter { $0.enabled && !$0.isTrusted }
            guard !candidates.isEmpty else { return }
            try session.recordTrust(candidates)
            let recorded = Set(candidates.map(\.key))
            let stillUntrusted = try session.listHooks().filter { recorded.contains($0.key) && !$0.isTrusted }
            guard stillUntrusted.isEmpty else { throw TrustError.notRecorded(count: stillUntrusted.count) }
        }
    }

    /// Codex's entries that are Spaces' on this device, grouped by the binding whose command they carry,
    /// in binding order.
    static func spacesEntries(listed: [AgentHookCodexListedHook], hooksFileURL: URL, spacesExecutablePath: String) -> [(
        binding: AgentHookJSONWriter.EventBinding, entries: [AgentHookCodexListedHook]
    )] {
        let userHooksFile = codexSourcePath(for: hooksFileURL)
        let userEntries = listed.filter { $0.source == "user" && $0.sourcePath == userHooksFile }
        return CodingAgent.codex.jsonEventBindings.map { binding in
            // The command has to be this device's own, `spaces` path included, because that exact match is
            // what keeps a lookalike entry from being trusted. Accepted cost: a dev build and the installed
            // app sharing one home write different paths, so each reads the other's entries as outdated.
            // Only a developer running both side by side meets it.
            let command = AgentHookCommand.signalCommand(event: binding.event, spacesExecutablePath: spacesExecutablePath)
            // Codex reports the event in camel case (`preToolUse`) where the hooks file has `PreToolUse`.
            let entries = userEntries.filter { $0.eventName.lowercased() == binding.eventName.lowercased() && $0.command == command }
            return (binding, entries)
        }
    }

    /// The `sourcePath` Codex reports for the entries of `hooksFileURL`: its home resolved through any
    /// symlinks, with the file's own name appended unresolved. Both halves were read off `hooks/list`,
    /// against a codex home reached through a symlink and against a home holding a `hooks.json` symlinked
    /// into a dotfiles repository, which Spaces writes through and Codex reads and names in place.
    ///
    /// The home resolves through `FilesystemPaths.realPath`, which is what Codex's own canonicalization
    /// produces. Foundation's `resolvingSymlinksInPath` is not: it strips the leading `/private` back off
    /// the canonical path it just resolved, so a home under `/tmp` or `/var` would be named one way here
    /// and the other way by Codex, and no entry would ever match.
    static func codexSourcePath(for hooksFileURL: URL) -> String {
        let home = FilesystemPaths.realPath(hooksFileURL.deletingLastPathComponent())
        return (home as NSString).appendingPathComponent(hooksFileURL.lastPathComponent)
    }
}

import Foundation

/// Idempotently merges Spaces lifecycle hooks into a JSON hooks file that uses the Claude Code hook
/// shape. Both Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) use this
/// exact structure:
///
/// ```
/// { "hooks": { "<Event>": [ { "matcher": "", "hooks": [ { "type": "command", "command": "…" } ] } ] } }
/// ```
///
/// The merge is "ensure desired state," never "append": on every run it strips all Spaces-owned
/// entries (identified by the command marker) from every event, then re-adds exactly one entry per
/// mapped event. Running twice yields byte-identical output and never duplicates a hook. The user's
/// unrelated keys and non-Spaces hooks are preserved; only key ordering is normalized (sorted) so
/// output is deterministic.
enum AgentHookJSONWriter {
    struct MalformedConfigError: LocalizedError {
        let path: String
        var errorDescription: String? { "\(path) is not valid JSON; refusing to overwrite it." }
    }

    /// A single event → Spaces command mapping to install.
    struct EventBinding {
        /// The hook event name key (e.g. "SessionStart").
        let eventName: String
        /// The lifecycle signal it reports.
        let event: AgentHookLifecycleEvent
    }

    /// Writes the merged hooks to `fileURL`. Creates parent directories and the file as needed.
    static func install(fileURL: URL, bindings: [EventBinding], spacesExecutablePath: String, fileManager: FileManager = .default) throws {
        var root = try loadRootObject(fileURL: fileURL, fileManager: fileManager)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        // Strip every Spaces-owned entry from all events first, so a reinstall with a changed event
        // set leaves no stale entries behind, then drop events that become empty as a result.
        for (eventName, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap(strippingSpacesOwnedEntries)
            if kept.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = kept
            }
        }

        // Re-add exactly one Spaces group per mapped event.
        for binding in bindings {
            var groups = (hooks[binding.eventName] as? [[String: Any]]) ?? []
            groups.append(spacesGroup(event: binding.event, spacesExecutablePath: spacesExecutablePath))
            hooks[binding.eventName] = groups
        }

        root["hooks"] = hooks
        try write(root: root, to: fileURL, fileManager: fileManager)
    }

    /// How completely `fileURL` carries the hooks `bindings` describe.
    ///
    /// A file with no Spaces-owned entry at all is `.notInstalled`. Anything partial — a bound event
    /// with no entry (this build added an event an older one did not write), or an entry carrying an
    /// older `AgentHookCommand.hookVersion` — is `.outdated`, because reinstalling is what fixes it.
    static func installState(fileURL: URL, bindings: [EventBinding], fileManager: FileManager = .default) -> AgentHookInstallState {
        guard !bindings.isEmpty, let root = try? loadRootObject(fileURL: fileURL, fileManager: fileManager),
            let hooks = root["hooks"] as? [String: Any]
        else { return .notInstalled }

        let ownedCommandsPerBinding = bindings.map { binding in
            ((hooks[binding.eventName] as? [[String: Any]]) ?? [])
                .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["command"] as? String }
                .filter(AgentHookCommand.isSpacesOwned)
        }
        guard ownedCommandsPerBinding.contains(where: { !$0.isEmpty }) else { return .notInstalled }
        let everyEventBound = ownedCommandsPerBinding.allSatisfy { !$0.isEmpty }
        let everyCommandCurrent = ownedCommandsPerBinding.allSatisfy { $0.allSatisfy(AgentHookCommand.isCurrent) }
        return everyEventBound && everyCommandCurrent ? .current : .outdated
    }

    // MARK: - Internals

    private static func loadRootObject(fileURL: URL, fileManager: FileManager) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
            throw MalformedConfigError(path: fileURL.path)
        }
        return dictionary
    }

    private static func spacesGroup(event: AgentHookLifecycleEvent, spacesExecutablePath: String) -> [String: Any] {
        [
            "matcher": "",
            "hooks": [["type": "command", "command": AgentHookCommand.signalCommand(event: event, spacesExecutablePath: spacesExecutablePath)]],
        ]
    }

    /// Drops Spaces-owned entries from `group`, whatever version wrote them. Matching on
    /// `isSpacesOwned` rather than the current version is what lets a reinstall replace an older
    /// build's entry instead of appending a second one beside it.
    private static func strippingSpacesOwnedEntries(from group: [String: Any]) -> [String: Any]? {
        guard let entries = group["hooks"] as? [[String: Any]] else { return group }
        let keptEntries = entries.filter { entry in
            guard let command = entry["command"] as? String else { return true }
            return !AgentHookCommand.isSpacesOwned(command)
        }
        guard keptEntries.count != entries.count else { return group }
        guard !keptEntries.isEmpty else { return nil }
        var updated = group
        updated["hooks"] = keptEntries
        return updated
    }

    private static func write(root: [String: Any], to fileURL: URL, fileManager: FileManager) throws {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)  // trailing newline
        try AgentHookConfigFile.write(data, to: fileURL, fileManager: fileManager)
    }
}

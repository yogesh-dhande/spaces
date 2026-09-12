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
/// mapped event, in the position the previous install left it. Running twice yields byte-identical
/// output and never duplicates a hook. The user's unrelated keys and non-Spaces hooks are preserved,
/// and so is their position, because Codex names a hook by the index of its group inside the event AND
/// the index of the hook inside that group: the strip leaves a placeholder at each coordinate a Spaces
/// entry held, at whichever of the two levels it held it, and the re-add writes the replacement back
/// into that placeholder. A Spaces entry sharing a group with hooks of the user's own therefore keeps
/// its hook index instead of moving to the end of the event and renumbering the entries that followed
/// it, which would leave the user's trust records describing the wrong hooks. Only key ordering is
/// normalized (sorted) so output is deterministic.
enum AgentHookJSONWriter {
    struct MalformedConfigError: LocalizedError {
        let path: String
        var errorDescription: String? { "\(path) is not valid JSON; refusing to overwrite it." }
    }

    struct UnsupportedConfigShapeError: LocalizedError {
        let path: String
        let location: String
        var errorDescription: String? { "\(path) has an unsupported JSON value at \(location); refusing to overwrite it." }
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
        var hooks: [String: Any]
        if let existingHooks = root["hooks"] {
            guard let existingHooks = existingHooks as? [String: Any] else {
                throw UnsupportedConfigShapeError(path: fileURL.path, location: "hooks")
            }
            hooks = existingHooks
        } else {
            hooks = [:]
        }

        // A mapped event is the one part of an existing hooks object this install must extend. If its
        // value is not the array shape the agent defines, replacing it would destroy valid user JSON.
        for binding in bindings {
            guard let existingEvent = hooks[binding.eventName] else { continue }
            guard existingEvent is [[String: Any]] else {
                throw UnsupportedConfigShapeError(path: fileURL.path, location: "hooks.\(binding.eventName)")
            }
        }

        // Strip every Spaces-owned entry from all events first, so a reinstall with a changed event set
        // leaves no stale entries behind. Each one leaves a placeholder at the coordinate it held rather
        // than closing the array up: Codex identifies a hook by its group index and its index inside
        // that group (`AgentHookCodexTrustState`), so putting the replacement back at both is what keeps
        // the rewrite from renumbering the user's own hooks and sending them back through review.
        var strippedEvents: [String: [StrippedGroup]] = [:]
        for (eventName, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            strippedEvents[eventName] = groups.map(strippingSpacesOwnedEntries)
        }

        // Re-add exactly one Spaces entry per mapped event, in the slot the last install left. Only an
        // event that has never carried one appends, and it appends a group of its own at the end so it
        // claims a coordinate no hook of the user's own holds.
        for binding in bindings {
            var groups = strippedEvents[binding.eventName] ?? []
            let entry = spacesEntry(event: binding.event, spacesExecutablePath: spacesExecutablePath)
            if let groupIndex = groups.firstIndex(where: { $0.openSlot != nil }), let slot = groups[groupIndex].openSlot {
                groups[groupIndex].entries[slot] = entry
            } else {
                groups.append(StrippedGroup(group: spacesGroup(entry: entry), entries: [entry]))
            }
            strippedEvents[binding.eventName] = groups
        }

        // Close up the placeholders no binding claimed, and drop an event left with no group at all.
        for (eventName, groups) in strippedEvents {
            let kept = groups.compactMap { $0.rebuilt() }
            if kept.isEmpty { hooks.removeValue(forKey: eventName) } else { hooks[eventName] = kept }
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
            ((hooks[binding.eventName] as? [[String: Any]]) ?? []).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap {
                $0["command"] as? String
            }.filter(AgentHookCommand.isSpacesOwned)
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

    /// One group of an event with its Spaces-owned entries lifted out, a nil left in each hook slot one
    /// held, so the re-add writes the replacement back at the same index.
    private struct StrippedGroup {
        /// The group as the file carries it. Its `hooks` value is the pre-strip one and is rewritten
        /// only when the group is rebuilt, which is also what tells a group with no hooks array apart
        /// from one whose entries all went.
        let group: [String: Any]
        var entries: [[String: Any]?]

        /// The first slot a Spaces entry gave up, and so the one this event's entry belongs back in.
        var openSlot: Int? { entries.firstIndex(where: { $0 == nil }) }

        /// The group to write, or nil when nothing of it is left to write.
        func rebuilt() -> [String: Any]? {
            guard group["hooks"] is [[String: Any]] else { return group }
            let kept = entries.compactMap { $0 }
            guard !kept.isEmpty else { return nil }
            var updated = group
            updated["hooks"] = kept
            return updated
        }
    }

    private static func spacesEntry(event: AgentHookLifecycleEvent, spacesExecutablePath: String) -> [String: Any] {
        ["type": "command", "command": AgentHookCommand.signalCommand(event: event, spacesExecutablePath: spacesExecutablePath)]
    }

    private static func spacesGroup(entry: [String: Any]) -> [String: Any] { ["matcher": "", "hooks": [entry]] }

    /// Lifts Spaces-owned entries out of `group`, whatever version wrote them. Matching on
    /// `isSpacesOwned` rather than the current version is what lets a reinstall replace an older
    /// build's entry instead of appending a second one beside it.
    private static func strippingSpacesOwnedEntries(from group: [String: Any]) -> StrippedGroup {
        guard let entries = group["hooks"] as? [[String: Any]] else { return StrippedGroup(group: group, entries: []) }
        return StrippedGroup(
            group: group,
            entries: entries.map { entry in
                guard let command = entry["command"] as? String, AgentHookCommand.isSpacesOwned(command) else { return entry }
                return nil
            })
    }

    private static func write(root: [String: Any], to fileURL: URL, fileManager: FileManager) throws {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)  // trailing newline
        try AgentHookConfigFile.write(data, to: fileURL, fileManager: fileManager)
    }
}

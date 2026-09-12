import Foundation

/// Reads Codex's own record of which Spaces hook entries the user has reviewed and trusted.
///
/// Codex does not run a hook it has not been told to trust. A `hooks.json` it has not seen before is
/// announced in its interface as "<N> hooks need review before they can run", and until the user
/// approves them there none of those hooks fire, `codex exec` included. The decision is Codex's to
/// record, and it records it in `~/.codex/config.toml` as one table per hook entry:
///
/// ```
/// [hooks.state."/Users/me/.codex/hooks.json:post_tool_use:1:0"]
/// enabled = true
/// trusted_hash = "sha256:3840b627…"
/// ```
///
/// The table name is the hook's identity: the absolute path of the hooks file, the event in
/// snake_case, the index of the group inside that event's array, and the index of the hook inside
/// that group. Both indices are positional, so where a Spaces entry sits among the user's own entries
/// for the same event decides its identity; the coordinates are read back out of the hooks file
/// rather than assumed. (Established against codex-cli 0.153.4 by reading the tables it writes and
/// cross-checking every one of them against the `key`, `enabled`, and `trustStatus` its app-server
/// `hooks/list` reports for the same entry.)
///
/// The path in that name is Codex's own resolution of its home, not the path Spaces used to get
/// there: it resolves `CODEX_HOME` through symlinks and names the file under the directory that comes
/// back, while leaving a symlinked `hooks.json` inside that directory unresolved. Both halves were
/// read off `hooks/list`, against a codex home reached through a symlink and against a real home
/// holding a `hooks.json` symlinked into a separate directory. A home reached through a link is a
/// supported setup, so the key is built the same way, or every hook in it reads as unreviewed forever
/// and its records are never cleared.
///
/// Reading the file is what keeps this check dependency-free: it costs no subprocess, it works the
/// same for a Linux daemon reading its own home, and it asks Codex for nothing beyond the record
/// Codex already keeps.
///
/// `trusted_hash` is Codex's hash of the exact hook text it trusted, computed by a scheme Spaces does
/// not reproduce, so the test is the table's presence plus `enabled`. The two ways it comes back short
/// are different situations and are reported apart: an entry with no table of its own has never been
/// through the review, while one carrying `enabled = false` was reviewed and then switched off in
/// Codex's hooks browser. Codex asks for a review of the first and not of the second, so treating them
/// alike would send the user looking for a prompt that never appears.
///
/// Codex keeps the table of a hook whose text has since changed rather than dropping it, and re-asks
/// for review by comparing the stored hash against the hook it now reads. A presence test alone would
/// therefore call a rewritten hook trusted on the strength of a record that no longer describes it,
/// which is exactly the state every `hookVersion` bump creates. `clearTrustRecords` closes that by
/// deleting the Spaces entries' own tables as part of the rewrite, so the record and the file it
/// describes are never out of step and presence means what it says.
enum AgentHookCodexTrustState {
    /// What Codex's record says about the Spaces-owned entries of a hooks file.
    enum Verdict: Equatable {
        /// Every entry is approved and switched on, so Codex runs them.
        case trusted
        /// At least one entry is switched off in Codex. Reported ahead of `awaitingReview` because it
        /// is the more specific answer: an entry the user turned off is one Codex never asks about
        /// again, so it has to be put back before an outstanding review is worth raising.
        case switchedOff
        /// At least one entry has no approval on record, and none is switched off.
        case awaitingReview
    }

    /// Codex's verdict on the Spaces-owned entries in `hooksFileURL`. A hooks file carrying no Spaces
    /// entry at all reads as `awaitingReview`, since there is then nothing Codex could have approved.
    ///
    /// Accepted window: because the key is positional, a hand edit that removes or reorders one of the
    /// user's own groups ahead of the Spaces group moves the Spaces entry onto a coordinate whose table
    /// records a different hook's `trusted_hash`, and presence then reads as trusted while Codex
    /// refuses the entry. It takes that hand edit under an existing record, and it heals itself: Codex
    /// compares the stored hash against the text it reads, re-asks for the review on its next start,
    /// and rewrites the table once the user approves, which is the same review the awaiting state
    /// already sends them to. Catching it instead means reproducing a hash scheme Codex does not
    /// publish, or a `codex` subprocess on every status probe, which is the cost reading the file
    /// exists to avoid, so the transient `current` in that window is accepted.
    static func verdict(hooksFileURL: URL, configURL: URL) -> Verdict {
        let keys = spacesEntryKeys(hooksFileURL: hooksFileURL)
        guard !keys.isEmpty else { return .awaitingReview }
        let states = hookStates(configURL: configURL)
        if keys.contains(where: { states[$0]?.enabled == false }) { return .switchedOff }
        return keys.allSatisfy { states[$0]?.isTrusted == true } ? .trusted : .awaitingReview
    }

    /// The `hooks.state` table names Codex would use for the Spaces-owned entries in `hooksFileURL`.
    static func spacesEntryKeys(hooksFileURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: hooksFileURL), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else { return [] }

        var keys: [String] = []
        for (eventName, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for (groupIndex, group) in groups.enumerated() {
                for (hookIndex, entry) in (((group["hooks"] as? [[String: Any]]) ?? [])).enumerated() {
                    guard let command = entry["command"] as? String, AgentHookCommand.isSpacesOwned(command) else { continue }
                    keys.append("\(codexKeyPath(for: hooksFileURL)):\(snakeCasedEventName(eventName)):\(groupIndex):\(hookIndex)")
                }
            }
        }
        return keys
    }

    /// The hooks-file path as Codex writes it into a state table name: its home resolved through any
    /// symlinks, with the file's own name appended unresolved. Resolving the whole path instead would
    /// disagree with Codex for a `hooks.json` symlinked into a dotfiles repository, which Spaces writes
    /// through and Codex still reads and names in place.
    ///
    /// The home resolves through `FilesystemPaths.realPath`, which is what Codex's own canonicalization
    /// produces. Foundation's `resolvingSymlinksInPath` is not: it strips the leading `/private` back
    /// off the canonical path it just resolved, so a home under `/tmp` or `/var` (`~/.codex` linked into
    /// a temporary directory, and every test fixture, since `NSTemporaryDirectory` is under
    /// `/var/folders`) would be named one way here and the other way by Codex, leaving every entry
    /// reading as unreviewed and its records never cleared.
    static func codexKeyPath(for hooksFileURL: URL) -> String {
        let home = FilesystemPaths.realPath(hooksFileURL.deletingLastPathComponent())
        return (home as NSString).appendingPathComponent(hooksFileURL.lastPathComponent)
    }

    /// Codex names hook events in camel case in `hooks.json` and in snake case in the state table
    /// names, so `SessionEnd` in the file is `session_end` in the key.
    static func snakeCasedEventName(_ eventName: String) -> String {
        var result = ""
        for character in eventName {
            if character.isUppercase, !result.isEmpty { result.append("_") }
            result.append(contentsOf: character.lowercased())
        }
        return result
    }

    /// Drops the `hooks.state` tables naming the Spaces entries of `hooksFileURL` from `configURL`, so
    /// hooks Spaces has just rewritten carry no trust record describing the text they used to hold.
    ///
    /// This runs as the last step of a Codex install, after Codex's own `features enable` has had its
    /// turn at rewriting the file. It costs Codex nothing: a rewritten hook no longer matches its
    /// stored hash, so Codex was going to demand the review again either way, and the record it keeps
    /// in the meantime describes text that is gone. Deleting it is what makes the file-only check
    /// exact instead of optimistic.
    ///
    /// Only tables naming this hooks file at a coordinate the rewritten file gives to a Spaces entry
    /// are removed; every other line is carried through byte for byte. The writer puts the Spaces group
    /// back at the index it already held and appends only on a first install, so the coordinates read
    /// out of the rewritten file are the ones the Spaces entries held before it, no hook of the user's
    /// own is renumbered by the rewrite, and no trust they gave their own hooks is discarded.
    static func clearTrustRecords(hooksFileURL: URL, configURL: URL, fileManager: FileManager) throws {
        let keys = Set(spacesEntryKeys(hooksFileURL: hooksFileURL))
        guard !keys.isEmpty, let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var isInsideRemovedTable = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                // A table runs to the next header, so the header decides what happens to the lines
                // under it: its fields, and the blank line Codex writes between tables.
                isInsideRemovedTable = hookStateKey(inTableHeader: trimmed).map(keys.contains) ?? false
            }
            if !isInsideRemovedTable { kept.append(line) }
        }
        guard kept.count != lines.count else { return }  // nothing to drop: leave the file untouched
        // Read, filter, write loses a Codex write to the same file that lands between the read and the
        // write. That outcome is accepted: the write itself is atomic (temp file plus rename), it runs
        // only while the user is clicking Install in Spaces, and it costs anything only if Codex saves
        // its own config in that same instant. Codex exposes no command and no lock for removing
        // `hooks.state` tables, so the alternative is a coordination layer built against an
        // undocumented file lock, which is a larger risk than one lost setting write in that window.
        try AgentHookConfigFile.write(kept.joined(separator: "\n"), to: configURL, fileManager: fileManager)
    }

    // MARK: - Internals

    private struct HookState {
        var enabled: Bool?
        var trustedHash: String?

        /// Codex omits `enabled` for an entry it has never been asked to switch off, so only an
        /// explicit `false` disables one. The hash is the record of the review itself.
        var isTrusted: Bool { enabled != false && !(trustedHash ?? "").isEmpty }
    }

    /// Reads the `[hooks.state."…"]` tables out of `configURL`.
    ///
    /// This reads the two fields it needs off a known table shape rather than parsing TOML: Codex
    /// stays the sole parser and writer of its own configuration, exactly as it stays the sole owner
    /// of the `features.hooks` flag, and a partial reader cannot damage a file it never writes. An
    /// entry Spaces cannot find here is reported as awaiting review, which is the safe direction: it
    /// asks the user to look at Codex rather than claiming a hook fires.
    private static func hookStates(configURL: URL) -> [String: HookState] {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }

        var states: [String: HookState] = [:]
        var currentKey: String?
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                currentKey = hookStateKey(inTableHeader: line)  // any other table ends the current one
                continue
            }
            guard let currentKey, let separator = line.firstIndex(of: "=") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "enabled": states[currentKey, default: HookState()].enabled = value.split(separator: " ").first == "true"
            case "trusted_hash": states[currentKey, default: HookState()].trustedHash = quotedValue(value)
            default: continue
            }
        }
        return states
    }

    private static func hookStateKey(inTableHeader line: String) -> String? {
        let prefix = "[hooks.state."
        guard line.hasPrefix(prefix), line.hasSuffix("]") else { return nil }
        return quotedValue(String(line.dropFirst(prefix.count).dropLast()))
    }

    /// The contents of a leading TOML basic string, or nil when `text` does not start with one.
    private static func quotedValue(_ text: String) -> String? {
        guard text.hasPrefix("\"") else { return nil }
        var result = ""
        var isEscaped = false
        for character in text.dropFirst() {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" { return result }
            result.append(character)
        }
        return nil
    }
}

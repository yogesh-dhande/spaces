import Foundation

/// Ensures Codex's `features.hooks = true` flag is set in `~/.codex/config.toml`, which Codex
/// requires before it runs any `~/.codex/hooks.json` hooks.
///
/// This is a narrow, table-aware line edit rather than a full TOML rewrite (Swift has no TOML
/// serializer, and rewriting would drop comments and reorder the user's config): it only touches the
/// `hooks` key inside the `[features]` table, a top-level `features = { ... }` inline table, or
/// top-level `features.*` dotted keys, appending the table when absent. Idempotent — once
/// `hooks = true` is present the file is left byte-identical.
///
/// Table headers and keys are matched by *name*, not by literal text: TOML allows whitespace inside
/// the brackets and quoted names, so `[features]`, `[ features ]`, and `["features"]` all name the
/// same table. Getting that wrong is not a missed edit but a corrupted config — an unrecognized
/// header sends the edit down the "append a `[features]` table" path, and the resulting duplicate
/// table definition makes Codex fail to parse `config.toml` at all.
enum AgentHookCodexFeatureToggle {
    private static let sectionName = "features"
    private static let hooksKey = "hooks"

    /// `features` (or `features.hooks`) is already defined in a shape this line editor cannot safely
    /// edit. Appending a `[features]` table beside it would produce a duplicate key or a table-type
    /// conflict, and rewriting a non-boolean `hooks` value would destroy user config — either way
    /// Codex would fail to parse `config.toml`. So refuse and leave the file untouched.
    struct ConflictingFeaturesDefinitionError: LocalizedError, Equatable {
        /// Names what is already there, e.g. "`features` as an array of tables (`[[features]]`)".
        let existingDefinition: String

        var errorDescription: String? {
            "Cannot enable Codex hooks: config.toml already defines \(existingDefinition). "
                + "Set `features.hooks = true` in that config yourself, then reinstall hooks."
        }
    }

    /// A `hooks = <value>` assignment, classified by whether this editor may rewrite it. Only a bool
    /// literal is rewritten: `hooks` is a boolean feature flag, so any other value means the config is
    /// shaped in a way we do not understand, and silently replacing it would lose the user's data.
    private enum HooksAssignment {
        case alreadyTrue
        /// `hooks = false`, with the line rewritten to `true` (indentation and trailing comment kept).
        case flippable(updatedLine: String)
        case nonBoolean
    }

    /// A top-level `features = { … }` inline table, classified the same way.
    private enum InlineFeaturesTable {
        case hooksAlreadyTrue
        case updated(line: String)
        case nonBooleanHooks
    }

    static func ensureEnabled(fileURL: URL, fileManager: FileManager = .default) throws {
        let original = try existingContents(fileURL: fileURL)
        guard let updated = try updatedContents(original) else { return }  // already enabled: leave the file untouched
        try AgentHookConfigFile.write(updated, to: fileURL, fileManager: fileManager)
    }

    static func isEnabled(fileURL: URL) -> Bool {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return featuresSectionHasHooksTrue(contents)
    }

    // MARK: - Internals

    private static func existingContents(fileURL: URL) throws -> String {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError { return "" }
            throw error
        }
    }

    /// Returns the edited contents, or nil when no change is needed.
    static func updatedContents(_ original: String) throws -> String? {
        if featuresSectionHasHooksTrue(original) { return nil }

        var lines = splitLines(original)
        let newline = lineTerminator(of: original)
        if let sectionIndex = lines.firstIndex(where: isFeaturesSectionHeader) {
            // Find the extent of the [features] table (up to the next table header or EOF).
            let sectionEnd = lines[(sectionIndex + 1)...].firstIndex(where: isAnySectionHeader) ?? lines.count
            if let hooksIndex = lines[(sectionIndex + 1)..<sectionEnd].firstIndex(where: { hooksAssignment(for: $0) != nil }) {
                lines[hooksIndex] = try flippedHooksLine(lines[hooksIndex])
            } else {
                lines.insert("\(hooksKey) = true", at: sectionIndex + 1)
            }
            return lines.joined(separator: newline)
        }

        let topLevelEnd = lines.firstIndex(where: isAnySectionHeader) ?? lines.count
        if let inlineIndex = lines[..<topLevelEnd].firstIndex(where: { inlineFeaturesTable(for: $0) != nil }) {
            switch inlineFeaturesTable(for: lines[inlineIndex]) {
            case .updated(let line):
                lines[inlineIndex] = line
                return lines.joined(separator: newline)
            case .nonBooleanHooks:
                throw ConflictingFeaturesDefinitionError(existingDefinition: nonBooleanHooksDefinition)
            case .hooksAlreadyTrue, .none:
                return nil  // unreachable: `featuresSectionHasHooksTrue` already returned above
            }
        }
        if let dottedHooksIndex = lines[..<topLevelEnd].firstIndex(where: { dottedFeaturesHooksAssignment(for: $0) != nil }) {
            lines[dottedHooksIndex] = try flippedDottedHooksLine(lines[dottedHooksIndex])
            return lines.joined(separator: newline)
        }
        if let dottedFeaturesIndex = lines[..<topLevelEnd].lastIndex(where: isDottedFeaturesAssignment) {
            lines.insert("\(sectionName).\(hooksKey) = true", at: dottedFeaturesIndex + 1)
            return lines.joined(separator: newline)
        }

        if let existingDefinition = conflictingFeaturesDefinition(lines) {
            throw ConflictingFeaturesDefinitionError(existingDefinition: existingDefinition)
        }

        // No [features] table in any spelling: append one. Keep exactly one blank separator line before it.
        // `removeLast()` drops a whole terminator: Swift reads "\r\n" as one Character.
        var prefix = original
        while prefix.hasSuffix(newline) { prefix.removeLast() }
        let separator = prefix.isEmpty ? "" : newline + newline
        return prefix + separator + "[\(sectionName)]" + newline + "\(hooksKey) = true" + newline
    }

    /// Text for the "`features.hooks` is not a boolean" conflict, shared by the section, inline-table,
    /// and dotted-key edit paths.
    private static let nonBooleanHooksDefinition = "`\(sectionName).\(hooksKey)` with a value that is not `true` or `false`"

    /// Rewrites a `hooks = false` line to `true`, or refuses when the value is not a bool literal.
    private static func flippedHooksLine(_ line: String) throws -> String {
        switch hooksAssignment(for: line) {
        case .flippable(let updatedLine): return updatedLine
        case .nonBoolean: throw ConflictingFeaturesDefinitionError(existingDefinition: nonBooleanHooksDefinition)
        case .alreadyTrue, .none: return line  // unreachable: `featuresSectionHasHooksTrue` already returned
        }
    }

    private static func flippedDottedHooksLine(_ line: String) throws -> String {
        switch dottedFeaturesHooksAssignment(for: line) {
        case .flippable(let updatedLine): return updatedLine
        case .nonBoolean: throw ConflictingFeaturesDefinitionError(existingDefinition: nonBooleanHooksDefinition)
        case .alreadyTrue, .none: return line  // unreachable: `featuresSectionHasHooksTrue` already returned
        }
    }

    private static func featuresSectionHasHooksTrue(_ contents: String) -> Bool {
        let lines = splitLines(contents)
        if let sectionIndex = lines.firstIndex(where: isFeaturesSectionHeader) {
            let sectionEnd = lines[(sectionIndex + 1)...].firstIndex(where: isAnySectionHeader) ?? lines.count
            if lines[(sectionIndex + 1)..<sectionEnd].contains(where: { isAlreadyTrue(hooksAssignment(for: $0)) }) { return true }
        }
        let topLevelEnd = lines.firstIndex(where: isAnySectionHeader) ?? lines.count
        return lines[..<topLevelEnd].contains { line in
            if case .hooksAlreadyTrue = inlineFeaturesTable(for: line) { return true }
            return isAlreadyTrue(dottedFeaturesHooksAssignment(for: line))
        }
    }

    private static func isAlreadyTrue(_ assignment: HooksAssignment?) -> Bool {
        if case .alreadyTrue = assignment { return true }
        return false
    }

    private static func commentStripped(_ line: String) -> String { splitTrailingComment(line).code }

    private static func splitTrailingComment(_ line: String) -> (code: String, comment: String) {
        var inSingleQuotedString = false
        var inDoubleQuotedString = false
        var isEscaped = false
        var result = ""
        for index in line.indices {
            let character = line[index]
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if inDoubleQuotedString && character == "\\" {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" && !inSingleQuotedString {
                inDoubleQuotedString.toggle()
            } else if character == "'" && !inDoubleQuotedString {
                inSingleQuotedString.toggle()
            } else if character == "#" && !inSingleQuotedString && !inDoubleQuotedString {
                return (result, String(line[index...]))
            }
            result.append(character)
        }
        return (result, "")
    }

    /// Splits TOML into lines on either newline TOML allows, `\n` or `\r\n`, leaving no terminator
    /// behind.
    ///
    /// Every parsing helper below reads a line as bare code, so a stray `\r` would defeat all of them
    /// at once: `[features]` would not end in `]` and so would not match a table header, and `true`
    /// would read as neither `true` nor `false`. A CRLF config — one synced from a Windows checkout,
    /// which Codex itself parses fine — would then have a second `[features]` table appended beside the
    /// one already there, producing a duplicate-table error the next time Codex read its own config.
    /// Normalizing here keeps that concern in one place instead of in every helper.
    private static func splitLines(_ contents: String) -> [String] {
        contents.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
    }

    /// The newline an edit rejoins with: the one the config already uses, so writing back does not
    /// convert the user's line endings or leave an LF-terminated stanza among CRLF lines.
    private static func lineTerminator(of contents: String) -> String { contents.contains("\r\n") ? "\r\n" : "\n" }

    private static func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }

    private static func trimmedHeader(_ line: String) -> String { trimmed(commentStripped(line)) }

    /// Strips one layer of TOML key quoting (`"features"` / `'features'` → `features`). Bare keys pass
    /// through unchanged.
    private static func unquotedKey(_ raw: String) -> String {
        let value = trimmed(raw)
        guard value.count >= 2 else { return value }
        let isQuoted = (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))
        return isQuoted ? String(value.dropFirst().dropLast()) : value
    }

    /// Any line that opens a new table, so table extents (`sectionEnd`, `topLevelEnd`) stop at it.
    /// Includes array-of-tables headers (`[[x]]`), which end the preceding table just as `[x]` does.
    private static func isAnySectionHeader(_ line: String) -> Bool {
        let value = trimmedHeader(line)
        return value.hasPrefix("[") && value.hasSuffix("]") && value.count >= 2
    }

    /// The table this header names (`[ "a" .b ]` → `a.b`), or nil when the line is not a plain table
    /// header. An array-of-tables header never names a plain table.
    private static func sectionHeaderName(_ line: String) -> String? {
        guard isAnySectionHeader(line) else { return nil }
        let inner = trimmed(String(trimmedHeader(line).dropFirst().dropLast()))
        guard !inner.hasPrefix("[") else { return nil }
        return dottedName(in: inner)
    }

    /// Normalizes a dotted TOML name (` "a" . b ` → `a.b`), or nil when it is empty.
    private static func dottedName(in raw: String) -> String? {
        let inner = trimmed(raw)
        guard !inner.isEmpty else { return nil }
        return inner.split(separator: ".", omittingEmptySubsequences: false).map { unquotedKey(String($0)) }.joined(separator: ".")
    }

    private static func isFeaturesSectionHeader(_ line: String) -> Bool { sectionHeaderName(line) == sectionName }

    /// The table this array-of-tables header names (`[[features]]` → `features`), or nil.
    private static func arrayOfTablesName(_ line: String) -> String? {
        let value = trimmedHeader(line)
        guard value.hasPrefix("[["), value.hasSuffix("]]"), value.count >= 5 else { return nil }
        return dottedName(in: String(value.dropFirst(2).dropLast(2)))
    }

    /// Describes a `features` definition that cannot be extended with a `hooks` key, or nil when
    /// appending a `[features]` table is safe. Reached only after every editable shape has been ruled
    /// out, so anything left that claims the `features` name — or the `features.hooks` name — collides.
    /// `[features.sub]` does not collide: TOML allows a super-table to be declared after its sub-table.
    private static func conflictingFeaturesDefinition(_ lines: [String]) -> String? {
        for line in lines {
            if arrayOfTablesName(line) == sectionName { return "`\(sectionName)` as an array of tables (`[[\(sectionName)]]`)" }
            if sectionHeaderName(line) == "\(sectionName).\(hooksKey)" { return "a `[\(sectionName).\(hooksKey)]` table" }
        }
        let topLevelEnd = lines.firstIndex(where: isAnySectionHeader) ?? lines.count
        for line in lines[..<topLevelEnd] {
            let code = commentStripped(line)
            guard let equalsIndex = code.firstIndex(of: "="), unquotedKey(String(code[..<equalsIndex])) == sectionName else { continue }
            return "`\(sectionName)` as a value that is not an inline table"
        }
        return nil
    }

    /// A `hooks = <value>` assignment (bare or quoted key), as it appears inside a `[features]` table
    /// or as an inline-table entry. Indentation and any trailing comment survive the flip to `true`.
    private static func hooksAssignment(for line: String) -> HooksAssignment? {
        let split = splitTrailingComment(line)
        let code = split.code
        guard let equalsIndex = code.firstIndex(of: "="), unquotedKey(String(code[..<equalsIndex])) == hooksKey else { return nil }
        return assignment(code: code, equalsIndex: equalsIndex, comment: split.comment)
    }

    private static func dottedFeaturesHooksAssignment(for line: String) -> HooksAssignment? {
        let split = splitTrailingComment(line)
        let code = split.code
        guard let equalsIndex = code.firstIndex(of: "="), dottedKeyParts(in: code[..<equalsIndex]) == [sectionName, hooksKey] else {
            return nil
        }
        return assignment(code: code, equalsIndex: equalsIndex, comment: split.comment)
    }

    /// Classifies the right-hand side of a `hooks` assignment whose key has already been matched.
    private static func assignment(code: String, equalsIndex: String.Index, comment: String) -> HooksAssignment {
        let value = trimmed(String(code[code.index(after: equalsIndex)...]))
        if value == "true" { return .alreadyTrue }
        guard value == "false" else { return .nonBoolean }
        let trailingComment = comment.isEmpty ? "" : " " + comment
        return .flippable(updatedLine: String(code[...equalsIndex]) + " true" + trailingComment)
    }

    private static func inlineFeaturesTable(for line: String) -> InlineFeaturesTable? {
        let split = splitTrailingComment(line)
        let code = split.code
        guard let equalsIndex = code.firstIndex(of: "="), unquotedKey(String(code[..<equalsIndex])) == sectionName else { return nil }

        let afterEqualsIndex = code.index(after: equalsIndex)
        guard let openBraceIndex = code[afterEqualsIndex...].firstIndex(of: "{"),
            let closeBraceIndex = matchingInlineTableCloseIndex(in: code, openBraceIndex: openBraceIndex)
        else { return nil }
        guard code[code.index(after: closeBraceIndex)...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let bodyRange = code.index(after: openBraceIndex)..<closeBraceIndex
        let body = String(code[bodyRange])
        var entries = splitInlineTableEntries(body).map { trimmed($0) }.filter { !$0.isEmpty }
        if entries.contains(where: { isAlreadyTrue(hooksAssignment(for: $0)) }) { return .hooksAlreadyTrue }
        if let hooksIndex = entries.firstIndex(where: { hooksAssignment(for: $0) != nil }) {
            switch hooksAssignment(for: entries[hooksIndex]) {
            case .flippable(let updatedEntry): entries[hooksIndex] = updatedEntry
            case .nonBoolean: return .nonBooleanHooks
            case .alreadyTrue, .none: return .hooksAlreadyTrue  // unreachable: handled by the check above
            }
        } else {
            entries.insert("\(hooksKey) = true", at: 0)
        }

        let updatedBody = entries.joined(separator: ", ")
        let beforeBody = String(code[..<bodyRange.lowerBound])
        let afterBody = String(code[bodyRange.upperBound...])
        let leadingSeparator = beforeBody.last.map { $0.isWhitespace ? "" : " " } ?? ""
        let trailingSeparator = afterBody.first.map { $0.isWhitespace ? "" : " " } ?? ""
        return .updated(line: beforeBody + leadingSeparator + updatedBody + trailingSeparator + afterBody + split.comment)
    }

    private static func isDottedFeaturesAssignment(_ line: String) -> Bool {
        let code = commentStripped(line)
        guard let equalsIndex = code.firstIndex(of: "="), let firstPart = dottedKeyParts(in: code[..<equalsIndex])?.first else { return false }
        return firstPart == sectionName
    }

    private static func dottedKeyParts(in key: Substring) -> [String]? {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map { unquotedKey(String($0)) }
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts
    }

    private static func matchingInlineTableCloseIndex(in value: String, openBraceIndex: String.Index) -> String.Index? {
        var inSingleQuotedString = false
        var inDoubleQuotedString = false
        var isEscaped = false
        var nestedBraceDepth = 0
        var index = value.index(after: openBraceIndex)
        while index < value.endIndex {
            let character = value[index]
            if isEscaped {
                isEscaped = false
            } else if inDoubleQuotedString && character == "\\" {
                isEscaped = true
            } else if character == "\"" && !inSingleQuotedString {
                inDoubleQuotedString.toggle()
            } else if character == "'" && !inDoubleQuotedString {
                inSingleQuotedString.toggle()
            } else if !inSingleQuotedString && !inDoubleQuotedString {
                if character == "{" {
                    nestedBraceDepth += 1
                } else if character == "}" {
                    if nestedBraceDepth == 0 { return index }
                    nestedBraceDepth -= 1
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func splitInlineTableEntries(_ body: String) -> [String] {
        var entries: [String] = []
        var inSingleQuotedString = false
        var inDoubleQuotedString = false
        var isEscaped = false
        var nestedBraceDepth = 0
        var nestedBracketDepth = 0
        var startIndex = body.startIndex
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if isEscaped {
                isEscaped = false
            } else if inDoubleQuotedString && character == "\\" {
                isEscaped = true
            } else if character == "\"" && !inSingleQuotedString {
                inDoubleQuotedString.toggle()
            } else if character == "'" && !inDoubleQuotedString {
                inSingleQuotedString.toggle()
            } else if !inSingleQuotedString && !inDoubleQuotedString {
                if character == "{" {
                    nestedBraceDepth += 1
                } else if character == "}" {
                    nestedBraceDepth -= 1
                } else if character == "[" {
                    nestedBracketDepth += 1
                } else if character == "]" {
                    nestedBracketDepth -= 1
                } else if character == "," && nestedBraceDepth == 0 && nestedBracketDepth == 0 {
                    entries.append(String(body[startIndex..<index]))
                    startIndex = body.index(after: index)
                }
            }
            index = body.index(after: index)
        }
        entries.append(String(body[startIndex...]))
        return entries
    }
}

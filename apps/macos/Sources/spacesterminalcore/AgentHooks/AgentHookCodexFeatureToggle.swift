import Foundation

/// Ensures Codex's `features.hooks = true` flag is set in `~/.codex/config.toml`, which Codex
/// requires before it runs any `~/.codex/hooks.json` hooks.
///
/// This is a narrow, table-aware line edit rather than a full TOML rewrite (Swift has no TOML
/// serializer, and rewriting would drop comments and reorder the user's config): it only touches the
/// `hooks` key inside the `[features]` table, a top-level `features = { ... }` inline table, or
/// top-level `features.*` dotted keys, appending the table when absent. Idempotent — once
/// `hooks = true` is present the file is left byte-identical.
enum AgentHookCodexFeatureToggle {
    private static let sectionHeader = "[features]"

    static func ensureEnabled(fileURL: URL, fileManager: FileManager = .default) throws {
        let original = try existingContents(fileURL: fileURL)
        guard let updated = updatedContents(original) else { return }  // already enabled: leave the file untouched
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
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
    static func updatedContents(_ original: String) -> String? {
        if featuresSectionHasHooksTrue(original) { return nil }

        var lines = original.components(separatedBy: "\n")
        if let sectionIndex = lines.firstIndex(where: { isSectionHeader($0, matching: sectionHeader) }) {
            // Find the extent of the [features] table (up to the next table header or EOF).
            let sectionEnd = lines[(sectionIndex + 1)...].firstIndex(where: { isAnySectionHeader($0) }) ?? lines.count
            if let hooksIndex = lines[(sectionIndex + 1)..<sectionEnd].firstIndex(where: { isHooksAssignment($0) }) {
                lines[hooksIndex] = "hooks = true"
            } else {
                lines.insert("hooks = true", at: sectionIndex + 1)
            }
            return lines.joined(separator: "\n")
        }

        let topLevelEnd = lines.firstIndex(where: { isAnySectionHeader($0) }) ?? lines.count
        if let inlineIndex = lines[..<topLevelEnd].firstIndex(where: { inlineFeaturesTableUpdate(for: $0) != nil }),
            let update = inlineFeaturesTableUpdate(for: lines[inlineIndex])
        {
            guard let updatedLine = update.updatedLine else { return nil }
            lines[inlineIndex] = updatedLine
            return lines.joined(separator: "\n")
        }
        if let dottedHooksIndex = lines[..<topLevelEnd].firstIndex(where: { dottedFeaturesHooksUpdate(for: $0) != nil }),
            let update = dottedFeaturesHooksUpdate(for: lines[dottedHooksIndex])
        {
            guard let updatedLine = update.updatedLine else { return nil }
            lines[dottedHooksIndex] = updatedLine
            return lines.joined(separator: "\n")
        }
        if let dottedFeaturesIndex = lines[..<topLevelEnd].lastIndex(where: isDottedFeaturesAssignment) {
            lines.insert("features.hooks = true", at: dottedFeaturesIndex + 1)
            return lines.joined(separator: "\n")
        }

        // No [features] table: append one. Keep exactly one blank separator line before it.
        var prefix = original
        while prefix.hasSuffix("\n") { prefix.removeLast() }
        let separator = prefix.isEmpty ? "" : "\n\n"
        return prefix + separator + "\(sectionHeader)\nhooks = true\n"
    }

    private static func featuresSectionHasHooksTrue(_ contents: String) -> Bool {
        let lines = contents.components(separatedBy: "\n")
        if let sectionIndex = lines.firstIndex(where: { isSectionHeader($0, matching: sectionHeader) }) {
            let sectionEnd = lines[(sectionIndex + 1)...].firstIndex(where: { isAnySectionHeader($0) }) ?? lines.count
            if lines[(sectionIndex + 1)..<sectionEnd].contains(where: isHooksTrueAssignment) { return true }
        }
        let topLevelEnd = lines.firstIndex(where: { isAnySectionHeader($0) }) ?? lines.count
        return lines[..<topLevelEnd].contains {
            inlineFeaturesTableUpdate(for: $0)?.hasHooksTrue == true || dottedFeaturesHooksUpdate(for: $0)?.hasHooksTrue == true
        }
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

    private static func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }

    private static func trimmedHeader(_ line: String) -> String { trimmed(commentStripped(line)) }

    private static func isSectionHeader(_ line: String, matching header: String) -> Bool { trimmedHeader(line) == header }

    private static func isAnySectionHeader(_ line: String) -> Bool {
        let value = trimmedHeader(line)
        return value.hasPrefix("[") && value.hasSuffix("]")
    }

    private static func isHooksAssignment(_ line: String) -> Bool {
        let value = trimmed(commentStripped(line))
        guard value.hasPrefix("hooks") else { return false }
        let afterKey = value.dropFirst("hooks".count).trimmingCharacters(in: .whitespaces)
        return afterKey.hasPrefix("=")
    }

    private static func isHooksTrueAssignment(_ line: String) -> Bool {
        let value = trimmed(commentStripped(line))
        guard isHooksAssignment(value), let equalsIndex = value.firstIndex(of: "=") else { return false }
        let rawValue = value[value.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
        return rawValue == "true"
    }

    private static func inlineFeaturesTableUpdate(for line: String) -> (hasHooksTrue: Bool, updatedLine: String?)? {
        let split = splitTrailingComment(line)
        let code = split.code
        guard let equalsIndex = code.firstIndex(of: "=") else { return nil }
        let key = code[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        guard key == "features" else { return nil }

        let afterEqualsIndex = code.index(after: equalsIndex)
        guard let openBraceIndex = code[afterEqualsIndex...].firstIndex(of: "{"),
            let closeBraceIndex = matchingInlineTableCloseIndex(in: code, openBraceIndex: openBraceIndex)
        else { return nil }
        guard code[code.index(after: closeBraceIndex)...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let bodyRange = code.index(after: openBraceIndex)..<closeBraceIndex
        let body = String(code[bodyRange])
        var entries = splitInlineTableEntries(body).map { trimmed($0) }.filter { !$0.isEmpty }
        if entries.contains(where: isHooksTrueAssignment) { return (true, nil) }
        if let hooksIndex = entries.firstIndex(where: isHooksAssignment) {
            entries[hooksIndex] = "hooks = true"
        } else {
            entries.insert("hooks = true", at: 0)
        }

        let updatedBody = entries.joined(separator: ", ")
        let beforeBody = String(code[..<bodyRange.lowerBound])
        let afterBody = String(code[bodyRange.upperBound...])
        let leadingSeparator = beforeBody.last.map { $0.isWhitespace ? "" : " " } ?? ""
        let trailingSeparator = afterBody.first.map { $0.isWhitespace ? "" : " " } ?? ""
        let updatedLine = beforeBody + leadingSeparator + updatedBody + trailingSeparator + afterBody + split.comment
        return (false, updatedLine)
    }

    private static func dottedFeaturesHooksUpdate(for line: String) -> (hasHooksTrue: Bool, updatedLine: String?)? {
        let split = splitTrailingComment(line)
        let code = split.code
        guard let equalsIndex = code.firstIndex(of: "="), dottedKeyParts(in: code[..<equalsIndex]) == ["features", "hooks"] else {
            return nil
        }

        let rawValue = code[code.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
        if rawValue == "true" { return (true, nil) }

        let prefix = String(code[...equalsIndex])
        let comment = split.comment.isEmpty ? "" : " " + split.comment
        return (false, prefix + " true" + comment)
    }

    private static func isDottedFeaturesAssignment(_ line: String) -> Bool {
        let code = commentStripped(line)
        guard let equalsIndex = code.firstIndex(of: "="), let firstPart = dottedKeyParts(in: code[..<equalsIndex])?.first else { return false }
        return firstPart == "features"
    }

    private static func dottedKeyParts(in key: Substring) -> [String]? {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map { trimmed(String($0)) }
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

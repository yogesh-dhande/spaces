import Foundation

/// The `const SPACES_CLI = "..."` line the script-file integrations (opencode's plugin, pi's extension)
/// bake the installed `spaces` path into, and the inverse that reads it back for install-state checks.
enum AgentHookEmbeddedCLIPath {
    private static let declarationPrefix = "const SPACES_CLI = \""

    /// The declaration line for `path`, a double-quoted JavaScript string literal.
    static func declaration(for path: String) -> String { "\(declarationPrefix.dropLast())\(javaScriptStringLiteral(path))" }

    /// Renders `value` as a double-quoted JavaScript string literal.
    static func javaScriptStringLiteral(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The `spaces` path baked into `contents`' `const SPACES_CLI = "..."` line, read back out of the
    /// double-quoted JavaScript string literal `javaScriptStringLiteral` writes: any character following
    /// a backslash is taken literally, and the first quote not preceded by one closes the string. Nil
    /// when the marker line, or its closing quote, is missing.
    static func path(in contents: String) -> String? {
        guard let markerRange = contents.range(of: declarationPrefix) else { return nil }
        var path = ""
        var index = markerRange.upperBound
        while index < contents.endIndex {
            let character = contents[index]
            if character == "\\" {
                let next = contents.index(after: index)
                guard next < contents.endIndex else { return nil }
                path.append(contents[next])
                index = contents.index(after: next)
                continue
            }
            if character == "\"" { return path }
            path.append(character)
            index = contents.index(after: index)
        }
        return nil  // no closing quote: not a well-formed string literal
    }
}

import Foundation

/// Which sessions a search is limited to, by the folder they ran in and by pinned conversation.
///
/// A session matches when its key is in `includedSessionKeys`, or when its key is not in
/// `excludedSessionKeys` and either its folder is under an included folder (any folder when
/// `includedFolders` is nil) and under no excluded folder, or it has no recorded folder and
/// `includesUnknownFolder` is set.
public struct AgentSessionFolderFilter: Sendable, Equatable {
    /// Nil means any folder.
    public var includedFolders: [String]?
    public var excludedFolders: [String]
    /// Sessions whose store records no folder.
    public var includesUnknownFolder: Bool
    public var includedSessionKeys: [String]
    public var excludedSessionKeys: [String]

    public init(
        includedFolders: [String]?, excludedFolders: [String] = [], includesUnknownFolder: Bool = false, includedSessionKeys: [String] = [],
        excludedSessionKeys: [String] = []
    ) {
        self.includedFolders = includedFolders
        self.excludedFolders = excludedFolders
        self.includesUnknownFolder = includesUnknownFolder
        self.includedSessionKeys = includedSessionKeys
        self.excludedSessionKeys = excludedSessionKeys
    }

    /// The filter as an SQL condition over the `cwd` and `session_key` columns of `sessions` (prefixed with
    /// `alias.` when given), using numbered parameters from `firstParameter`, and the text to bind to each in
    /// order.
    ///
    /// "Under a folder" is the folder itself or a path in the range between `folder/` and `folder0` ('0' is the
    /// byte after '/'), so `/a/foo` does not contain `/a/foobar`. A range compare is used where LIKE would be
    /// the obvious choice because paths can contain `%` and `_`.
    func sqlCondition(alias: String? = nil, firstParameter: Int) -> (sql: String, bindings: [String]) {
        let prefix = alias.map { "\($0)." } ?? ""
        let cwd = "\(prefix)cwd"
        let key = "\(prefix)session_key"
        var bindings: [String] = []

        func parameter(_ value: String) -> String {
            bindings.append(value)
            return "?\(firstParameter + bindings.count - 1)"
        }
        func under(_ folder: String) -> String {
            let placeholder = parameter(Self.withoutTrailingSlash(folder))
            return "(\(cwd) = \(placeholder) OR (\(cwd) >= \(placeholder) || '/' AND \(cwd) < \(placeholder) || '0'))"
        }
        func anyUnder(_ folders: [String]) -> String { folders.isEmpty ? "0" : "(" + folders.map(under).joined(separator: " OR ") + ")" }
        func keyList(_ keys: [String]) -> String { keys.map(parameter).joined(separator: ", ") }

        let inKnownFolder: String
        if let includedFolders { inKnownFolder = "\(cwd) IS NOT NULL AND \(anyUnder(includedFolders))" } else { inKnownFolder = "\(cwd) IS NOT NULL" }
        let outsideExcluded = excludedFolders.isEmpty ? "1" : "NOT \(anyUnder(excludedFolders))"
        var byFolder = "((\(inKnownFolder) AND \(outsideExcluded))"
        byFolder += includesUnknownFolder ? " OR \(cwd) IS NULL)" : ")"
        let allowed = excludedSessionKeys.isEmpty ? byFolder : "(\(key) NOT IN (\(keyList(excludedSessionKeys))) AND \(byFolder))"
        guard !includedSessionKeys.isEmpty else { return (allowed, bindings) }
        return ("(\(key) IN (\(keyList(includedSessionKeys))) OR \(allowed))", bindings)
    }

    private static func withoutTrailingSlash(_ folder: String) -> String {
        var trimmed = Substring(folder)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return String(trimmed)
    }
}

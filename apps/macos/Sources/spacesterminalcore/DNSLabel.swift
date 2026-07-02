import Foundation

/// Validation and sanitization for a single DNS-1123 label (the part between dots in a hostname).
///
/// Service names and the workspace host slug are both used directly as labels in
/// `<service>.<workspace-slug>.localhost`, so they must be valid DNS labels. This is the single
/// source of truth for that rule, shared by service-name validation and slug capping.
public enum DNSLabel {
    /// Maximum length of a single DNS label per RFC 1123.
    public static let maxLength = 63

    /// A label is valid when it is 1...63 characters of lowercase letters, digits, and hyphens,
    /// starts and ends with a letter or digit, and contains no other characters.
    public static func isValid(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= maxLength else { return false }
        for character in label.unicodeScalars {
            let isLowerAlpha = character >= "a" && character <= "z"
            let isDigit = character >= "0" && character <= "9"
            guard isLowerAlpha || isDigit || character == "-" else { return false }
        }
        guard let first = label.first, let last = label.last else { return false }
        return first != "-" && last != "-"
    }

    /// Coerces an arbitrary string into a valid DNS label: lowercase, runs of disallowed characters
    /// collapsed to single hyphens, leading/trailing hyphens stripped, capped to `maxLength`.
    /// Returns `fallback` when nothing usable remains.
    public static func sanitize(_ value: String, maxLength: Int = maxLength, fallback: String = "x") -> String {
        let lowercased = value.lowercased()
        var result = ""
        var lastWasHyphen = false
        for character in lowercased.unicodeScalars {
            let isLowerAlpha = character >= "a" && character <= "z"
            let isDigit = character >= "0" && character <= "9"
            if isLowerAlpha || isDigit {
                result.unicodeScalars.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen && !result.isEmpty {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result.isEmpty ? fallback : result
    }
}

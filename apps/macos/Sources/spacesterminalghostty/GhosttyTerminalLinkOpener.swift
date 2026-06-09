import AppKit
import Foundation

enum GhosttyTerminalLinkOpener {
    static func resolvedURL(for value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let candidate = URL(string: trimmed), let scheme = candidate.scheme?.lowercased() {
            switch scheme {
            case "http", "https": return candidate
            case "file":
                guard isLocalFileURLHost(candidate.host) else { return nil }
                return URL(fileURLWithPath: candidate.path).standardizedFileURL
            default: return nil
            }
        }

        let expandedPath = NSString(string: trimmed).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }

    @discardableResult static func open(_ value: String, openURL: ((URL) -> Bool)? = nil) -> Bool {
        guard let url = resolvedURL(for: value) else { return false }
        if let openURL { return openURL(url) }
        return NSWorkspace.shared.open(url)
    }

    private static func isLocalFileURLHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true }
        return host.caseInsensitiveCompare("localhost") == .orderedSame
    }
}

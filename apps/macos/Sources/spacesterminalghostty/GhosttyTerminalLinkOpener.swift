#if canImport(AppKit)
    import AppKit
    import Foundation

    public enum GhosttyTerminalLinkOpener {
        /// Resolves a raw terminal link string (as reported by libghostty's OSC 8 / URL-detection
        /// handling) to an openable URL. Relative filesystem paths (anything that isn't `~`-prefixed
        /// or absolute) only resolve when `workingDirectory` is supplied — the session's current
        /// working directory, tracked separately from this parsing layer — and are rejected
        /// otherwise, matching the historical behavior for a link with no directory context.
        ///
        /// Public so the per-pane `TerminalLinkOpenCoordinator` (in `spacesui`) can reuse the exact
        /// tilde/absolute/relative expansion for local file links instead of re-deriving it.
        public static func resolvedURL(for value: String, workingDirectory: String? = nil) -> URL? {
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
            if expandedPath.hasPrefix("/") { return URL(fileURLWithPath: expandedPath).standardizedFileURL }

            guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
            return URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(expandedPath).standardizedFileURL
        }

        /// Resolves and opens `value`. `openURL`, when supplied, replaces the real opening layer
        /// entirely (used by debug/test hooks such as `GhosttyMirrorTerminalView.debugOpenURLHandler`
        /// to intercept opens without touching `NSWorkspace`). Otherwise a web URL is forced through
        /// the default-browser handler and everything else is treated as a local file and
        /// classified/dispatched by `TerminalArtifactHandlerRegistry`. This layer stays free of
        /// loopback-vs-open routing — a later per-pane coordinator decides that before calling here.
        @discardableResult @MainActor static func open(_ value: String, workingDirectory: String? = nil, openURL: ((URL) -> Bool)? = nil) -> Bool {
            guard let url = resolvedURL(for: value, workingDirectory: workingDirectory) else { return false }
            if let openURL { return openURL(url) }

            let registry = TerminalArtifactHandlerRegistry.defaultRegistry()
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return registry.open(url, as: .webURL) }
            return registry.openLocalFile(at: url)
        }

        private static func isLocalFileURLHost(_ host: String?) -> Bool {
            guard let host, !host.isEmpty else { return true }
            return host.caseInsensitiveCompare("localhost") == .orderedSame
        }
    }
#endif

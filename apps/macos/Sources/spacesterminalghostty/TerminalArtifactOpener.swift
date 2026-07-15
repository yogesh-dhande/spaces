#if canImport(AppKit)
    import AppKit
    import Foundation
    import spacesdevicecore

    /// How a resolved terminal artifact (a link or a local file) should be handled once it is
    /// opened. This mirrors `SpacesDeviceTerminalLinkArtifactKind` (the device-preview classification
    /// shared with iOS) plus `.webURL`, which only makes sense for macOS's "open in the default
    /// browser" behavior and has no on-device preview counterpart.
    public enum TerminalArtifactCategory: Sendable, Equatable, Hashable {
        case image
        case video
        case pdf
        case markdown
        case text
        case html
        case webURL

        public init(kind: SpacesDeviceTerminalLinkArtifactKind) {
            switch kind {
            case .image: self = .image
            case .video: self = .video
            case .pdf: self = .pdf
            case .markdown: self = .markdown
            case .text: self = .text
            case .html: self = .html
            }
        }

        /// Classifies a local file URL by extension alone (no server-reported content type is
        /// available for a file already on disk). Returns `nil` for anything
        /// `SpacesDeviceTerminalLinkClassifier` does not recognize as previewable (source files,
        /// archives, extensionless files, and so on).
        public static func category(forFileURL url: URL) -> TerminalArtifactCategory? {
            guard let kind = SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: nil, pathExtension: url.pathExtension) else { return nil }
            return TerminalArtifactCategory(kind: kind)
        }
    }

    /// Dispatches a resolved terminal artifact URL to a per-category handler.
    ///
    /// This is the seam where a later change injects per-category user-chosen app overrides read
    /// from the client settings table (`ClientSettingsKey`) — e.g. "always open PDFs in Preview" —
    /// by building a custom `handlers` dictionary instead of `defaultRegistry()`'s fixed one. No
    /// such settings exist yet, so `defaultRegistry()` is the only registry in use this round.
    @MainActor public struct TerminalArtifactHandlerRegistry {
        public typealias Handler = @MainActor (URL) -> Bool

        private var handlers: [TerminalArtifactCategory: Handler]

        /// Handler for a local file whose category is unclassified (`category(forFileURL:)` returns
        /// `nil`). Kept separate from `handlers` (rather than a `nil`-keyed entry) so tests can
        /// inject a fake in place of `NSWorkspace.shared.open(_:)`.
        private let defaultOpenHandler: Handler

        public init(handlers: [TerminalArtifactCategory: Handler], defaultOpenHandler: @escaping Handler = { NSWorkspace.shared.open($0) }) {
            self.handlers = handlers
            self.defaultOpenHandler = defaultOpenHandler
        }

        /// The macOS-native handler set: every category opens via `NSWorkspace.shared.open(_:)`
        /// except `.webURL` and `.html`, which are forced into the system default browser rather
        /// than whatever app the file's extension is otherwise associated with (e.g. an `.html`
        /// file should render in a browser tab, not open in a text/code editor).
        public static func defaultRegistry() -> TerminalArtifactHandlerRegistry {
            let openInBrowser: Handler = { openInDefaultBrowser($0) }
            let openInWorkspace: Handler = { NSWorkspace.shared.open($0) }
            return TerminalArtifactHandlerRegistry(handlers: [
                .webURL: openInBrowser, .html: openInBrowser, .image: openInWorkspace, .video: openInWorkspace, .pdf: openInWorkspace,
                .markdown: openInWorkspace, .text: openInWorkspace,
            ])
        }

        @discardableResult public func open(_ url: URL, as category: TerminalArtifactCategory) -> Bool {
            guard let handler = handlers[category] else { return defaultOpenHandler(url) }
            return handler(url)
        }

        /// Classifies `url` by file extension and dispatches to the matching handler. An
        /// unclassified file (source code, an archive, anything without a recognized extension)
        /// falls through to `defaultOpenHandler` — deliberately preserving macOS "open anything
        /// local" semantics, e.g. a `.swift` file opens in the user's default editor.
        @discardableResult public func openLocalFile(at url: URL) -> Bool {
            guard let category = TerminalArtifactCategory.category(forFileURL: url) else { return defaultOpenHandler(url) }
            return open(url, as: category)
        }
    }

    /// Forces `url` open in the system default browser rather than letting `NSWorkspace` route it
    /// to whatever app is registered for the URL's scheme or the file's extension. Resolves the
    /// default browser once per call (apps can change their default browser at any time, so this
    /// is not cached across calls) via the app registered to open `https:` URLs.
    @MainActor private func openInDefaultBrowser(_ url: URL) -> Bool {
        guard let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https:")!) else {
            // No app is registered as the default browser (a browserless system). Fall back to a
            // plain open so the OS can still make a best-effort choice, matching how every other
            // category behaves when no override applies.
            return NSWorkspace.shared.open(url)
        }
        // `open(_:withApplicationAt:configuration:)` launches asynchronously; opening a link is
        // fire-and-forget from the caller's perspective, so dispatching it is treated as success.
        NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
#endif

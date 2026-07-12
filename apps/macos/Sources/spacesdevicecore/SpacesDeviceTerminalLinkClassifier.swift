import Foundation

#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

/// Device-previewable kinds a terminal link or Mac file can classify as. `.image`/`.video` preview
/// as media; `.pdf`, `.markdown`, `.text`, and `.html` preview as documents. Anything else (source
/// code, archives, audio, extensionless files) is not previewable and classifies as `nil`.
public enum SpacesDeviceTerminalLinkArtifactKind: String, Codable, Sendable, Equatable {
    case image
    case video
    case pdf
    case markdown
    case text
    case html
}

/// Classifies terminal links and Mac files two ways:
/// - `artifactKind`/`preferredContentType`/`preferredFilenameExtension` decide whether a file is
///   device-previewable and what kind of preview it needs.
/// - `route` decides how a raw link string should be opened (a web URL, a loopback URL that needs a
///   tunnel, or a local file that needs the file resolver).
///
/// This module cross-compiles for Linux (the `spacesd` daemon can run there), where
/// `UniformTypeIdentifiers` is unavailable. `artifactKind` therefore classifies primarily from
/// hand-maintained extension and content-type tables that are shared across platforms and only
/// falls back to `UniformTypeIdentifiers` conformance checks (Apple) or extension sets (Linux) for
/// media types.
public enum SpacesDeviceTerminalLinkClassifier {
    /// Extensions classified before any content-type or UTType lookup, so a locally readable file's
    /// extension always wins over a possibly-wrong or absent server-reported content type.
    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let htmlExtensions: Set<String> = ["html", "htm"]
    private static let pdfExtensions: Set<String> = ["pdf"]
    private static let textExtensions: Set<String> = ["txt", "log", "json", "jsonl", "yaml", "yml", "csv", "tsv", "toml", "ini", "cfg", "conf"]
    private static let textContentTypes: Set<String> = [
        "application/json", "application/jsonl", "application/ndjson", "application/toml", "application/x-ndjson", "application/x-yaml",
        "application/yaml", "text/csv", "text/plain", "text/tab-separated-values", "text/toml", "text/x-yaml", "text/yaml",
    ]

    public static func artifactKind(contentType: String?, pathExtension: String?) -> SpacesDeviceTerminalLinkArtifactKind? {
        let trimmedExtension = normalizedExtension(pathExtension)
        if let trimmedExtension, let kind = sharedArtifactKind(forExtension: trimmedExtension) { return kind }

        let trimmedContentType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedContentType, !trimmedContentType.isEmpty, let kind = sharedArtifactKind(forContentType: trimmedContentType) { return kind }

        #if canImport(UniformTypeIdentifiers)
            if let trimmedContentType, !trimmedContentType.isEmpty, let type = UTType(mimeType: trimmedContentType), let kind = mediaKind(for: type) {
                return kind
            }
            if let trimmedExtension, let type = UTType(filenameExtension: trimmedExtension), let kind = mediaKind(for: type) { return kind }
        #else
            if let trimmedExtension, let kind = mediaKind(forPathExtension: trimmedExtension) { return kind }
        #endif

        return nil
    }

    public static func preferredContentType(pathExtension: String?) -> String? {
        guard let trimmedExtension = normalizedExtension(pathExtension) else { return nil }
        #if canImport(UniformTypeIdentifiers)
            return UTType(filenameExtension: trimmedExtension)?.preferredMIMEType
        #else
            return preferredContentTypesByExtension[trimmedExtension]
        #endif
    }

    public static func preferredFilenameExtension(contentType: String?, fallback: String?) -> String {
        #if canImport(UniformTypeIdentifiers)
            if let contentType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines), !contentType.isEmpty,
                let preferred = UTType(mimeType: contentType)?.preferredFilenameExtension
            {
                return preferred
            }
        #else
            if let contentType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !contentType.isEmpty,
                let preferred = preferredExtensionsByContentType[contentType]
            {
                return preferred
            }
        #endif
        let fallback = fallback?.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)) ?? ""
        return fallback.isEmpty ? "dat" : fallback
    }

    private static func normalizedExtension(_ pathExtension: String?) -> String? {
        let trimmed = pathExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)).lowercased()
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func sharedArtifactKind(forExtension extensionValue: String) -> SpacesDeviceTerminalLinkArtifactKind? {
        if markdownExtensions.contains(extensionValue) { return .markdown }
        if htmlExtensions.contains(extensionValue) { return .html }
        if pdfExtensions.contains(extensionValue) { return .pdf }
        if textExtensions.contains(extensionValue) { return .text }
        return nil
    }

    private static func sharedArtifactKind(forContentType contentType: String) -> SpacesDeviceTerminalLinkArtifactKind? {
        let lowercased = normalizedContentType(contentType)
        if lowercased == "text/markdown" { return .markdown }
        if lowercased == "text/html" { return .html }
        if lowercased == "application/pdf" { return .pdf }
        if lowercased == "image/svg+xml" { return nil }
        if lowercased.hasPrefix("image/") { return .image }
        if lowercased.hasPrefix("video/") { return .video }
        if textContentTypes.contains(lowercased) { return .text }
        return nil
    }

    private static func normalizedContentType(_ contentType: String) -> String {
        let lowercased = contentType.lowercased()
        let baseType = lowercased.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lowercased
        return baseType.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if canImport(UniformTypeIdentifiers)
        /// SVG (and similarly XML-based vector formats) conforms to both `.image` and `.text`; excluding
        /// text-conforming types keeps vector/document formats out of the raster/video media fallback
        /// since they are not classified as previewable media here.
        private static func mediaKind(for type: UTType) -> SpacesDeviceTerminalLinkArtifactKind? {
            if type.conforms(to: .image), !type.conforms(to: .text) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            return nil
        }
    #else
        private static let imageExtensions: Set<String> = ["avif", "bmp", "gif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp"]
        private static let videoExtensions: Set<String> = ["m4v", "mov", "mp4", "mpeg", "mpg", "webm"]
        private static let preferredContentTypesByExtension: [String: String] = [
            "avif": "image/avif", "bmp": "image/bmp", "cfg": "text/plain", "conf": "text/plain", "csv": "text/csv", "gif": "image/gif",
            "heic": "image/heic", "heif": "image/heif", "htm": "text/html", "html": "text/html", "ini": "text/plain", "jpg": "image/jpeg",
            "jpeg": "image/jpeg", "json": "application/json", "jsonl": "application/json", "log": "text/plain", "m4v": "video/x-m4v",
            "markdown": "text/markdown", "md": "text/markdown", "mov": "video/quicktime", "mp4": "video/mp4", "mpeg": "video/mpeg",
            "mpg": "video/mpeg", "pdf": "application/pdf", "png": "image/png", "tif": "image/tiff", "tiff": "image/tiff", "toml": "application/toml",
            "tsv": "text/tab-separated-values", "txt": "text/plain", "webm": "video/webm", "webp": "image/webp", "yaml": "application/x-yaml",
            "yml": "application/x-yaml",
        ]
        private static let preferredExtensionsByContentType: [String: String] = [
            "application/json": "json", "application/pdf": "pdf", "application/toml": "toml", "application/x-yaml": "yaml", "image/avif": "avif",
            "image/bmp": "bmp", "image/gif": "gif", "image/heic": "heic", "image/heif": "heif", "image/jpeg": "jpg", "image/jpg": "jpg",
            "image/png": "png", "image/tiff": "tiff", "image/webp": "webp", "text/csv": "csv", "text/html": "html", "text/markdown": "md",
            "text/plain": "txt", "text/tab-separated-values": "tsv", "video/mp4": "mp4", "video/mpeg": "mpeg", "video/quicktime": "mov",
            "video/webm": "webm", "video/x-m4v": "m4v",
        ]

        private static func mediaKind(forPathExtension pathExtension: String) -> SpacesDeviceTerminalLinkArtifactKind? {
            if imageExtensions.contains(pathExtension) { return .image }
            if videoExtensions.contains(pathExtension) { return .video }
            return nil
        }
    #endif

    public static func route(for rawLink: String) -> SpacesDeviceTerminalLinkRoute? {
        let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A path like "docs/readme.md" or "~/notes.md" must not be mistaken for a scheme'd URL:
        // only treat it as one when URL(string:) both parses it and reports an explicit scheme.
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return .fileLink(trimmed) }

        switch scheme {
        case "http", "https": return isLoopbackHost(url.host) ? .loopbackURL(url) : .webURL(url)
        case "file": return .fileLink(trimmed)
        default: return nil
        }
    }

    /// Case-insensitive loopback host check: exact `localhost` (no subdomain matching), any
    /// `127.x.y.z` dotted-quad, `::1`, and `0.0.0.0`. `URL.host` strips the brackets from an IPv6
    /// literal like `[::1]`, so the bare form is what reaches this check.
    public static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let lowercased = host.lowercased()
        if lowercased == "localhost" || lowercased == "::1" || lowercased == "0.0.0.0" { return true }
        return isLoopbackIPv4DottedQuad(lowercased)
    }

    private static func isLoopbackIPv4DottedQuad(_ host: String) -> Bool {
        let components = host.split(separator: ".")
        guard components.count == 4, components.first == "127" else { return false }
        return components.allSatisfy { component in
            guard let value = Int(component) else { return false }
            return (0...255).contains(value)
        }
    }
}

/// A raw terminal link's routing decision: open a web URL, tunnel to a loopback (localhost) URL, or
/// resolve a local file. Shared by all clients so the "is this link openable directly, or does it
/// need a tunnel or file resolver" decision cannot drift between macOS and iOS.
public enum SpacesDeviceTerminalLinkRoute: Equatable, Sendable {
    case webURL(URL)
    /// An `http`/`https` URL whose host is loopback (`localhost`, `127.0.0.1`-style, `::1`,
    /// `0.0.0.0`). The full URL (host and port intact) is carried through; a future tunnel PR
    /// resolves this case by forwarding the loopback port instead of opening it directly.
    case loopbackURL(URL)
    /// A `file://` URL or a bare/tilde/relative filesystem path. Not resolved to an absolute path
    /// here — the caller passes the raw string to `SpacesDeviceTerminalLinkResolver`, which expands
    /// `~` and relative paths against the session's home and working directory.
    case fileLink(String)
}

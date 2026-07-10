import Foundation

public enum SpacesDeviceTerminalLinkResolverError: LocalizedError, Equatable {
    case missingLink
    case missingWorkingDirectory
    case unsupportedScheme(String)
    case invalidPath
    case blockedPath(String)
    case fileUnavailable
    case unsupportedArtifact
    case invalidLinkID
    case sessionMismatch
    case invalidChunkRange
    case unsupportedFileURLHost(String)

    public var errorDescription: String? {
        switch self {
        case .missingLink: return "Missing terminal link."
        case .missingWorkingDirectory: return "Missing terminal working directory."
        case .unsupportedScheme(let scheme): return "Terminal links with the '\(scheme)' scheme are not supported."
        case .invalidPath: return "Terminal link path is invalid."
        case .blockedPath: return "This file path is not available to device preview."
        case .fileUnavailable: return "Terminal link file is not a readable regular file."
        case .unsupportedArtifact: return "Only image, video, PDF, Markdown, text, and HTML files can be previewed."
        case .invalidLinkID: return "Terminal link transfer ID is invalid."
        case .sessionMismatch: return "Terminal link transfer does not match this session."
        case .invalidChunkRange: return "Terminal link chunk range is invalid."
        case .unsupportedFileURLHost(let host): return "Terminal file URLs for '\(host)' are not local to this Mac."
        }
    }
}

public struct SpacesDeviceTerminalLinkResolver {
    public static let defaultChunkLimit = 256 * 1024
    public static let maximumChunkLimit = 512 * 1024

    private struct LocalLinkPayload: Codable, Equatable {
        let sessionID: String
        let path: String
        let originalLink: String
        let displayName: String
        let contentType: String?
        let artifactKind: SpacesDeviceTerminalLinkArtifactKind
        let byteCount: Int64
    }

    private struct LocalFile {
        let url: URL
        let displayName: String
        let contentType: String?
        let artifactKind: SpacesDeviceTerminalLinkArtifactKind
        let byteCount: Int64
    }

    private static let blockedPathPrefixes = [
        "/System", "/Applications", "/Library", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/etc", "/dev",
        "/cores", "/Network", "/Volumes", "/private/etc", "/private/var/db", "/private/var/root",
    ]

    private static let fixedAllowedPathPrefixes = ["/tmp", "/var/tmp", "/private/tmp", "/private/var/tmp", "/opt", "/usr/local"]

    public static func resolve(
        sessionID: String, link: String?, workingDirectory: String?, workspaceRoots: [String] = [], homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws -> SpacesDeviceTerminalLinkMetadata {
        guard let link = normalizedString(link) else { throw SpacesDeviceTerminalLinkResolverError.missingLink }

        if let url = URL(string: link), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                let isDownloadablePreviewURL = scheme == "https"
                let contentType =
                    isDownloadablePreviewURL ? SpacesDeviceTerminalLinkClassifier.preferredContentType(pathExtension: url.pathExtension) : nil
                let artifactKind =
                    isDownloadablePreviewURL
                    ? SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: contentType, pathExtension: url.pathExtension) : nil
                return SpacesDeviceTerminalLinkMetadata(
                    id: "external|\(url.absoluteString)", source: .externalURL, originalLink: link, displayName: externalDisplayName(for: url),
                    contentType: contentType, artifactKind: artifactKind, byteCount: nil, externalURL: url.absoluteString)
            case "file":
                guard isLocalFileURLHost(url.host) else { throw SpacesDeviceTerminalLinkResolverError.unsupportedFileURLHost(url.host ?? "") }
                return try resolveLocal(
                    sessionID: sessionID, originalLink: link, fileURL: URL(fileURLWithPath: url.path), workingDirectory: nil,
                    workspaceRoots: workspaceRoots, homeDirectory: homeDirectory, fileManager: fileManager)
            default: throw SpacesDeviceTerminalLinkResolverError.unsupportedScheme(scheme)
            }
        }

        return try resolveLocal(
            sessionID: sessionID, originalLink: link, fileURL: nil, workingDirectory: workingDirectory, workspaceRoots: workspaceRoots,
            homeDirectory: homeDirectory, fileManager: fileManager)
    }

    public static func readChunk(
        sessionID: String, linkID: String?, offset: Int64?, limit: Int?, workspaceRoots: [String] = [], homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws -> SpacesDeviceTerminalLinkChunk {
        guard let payload = try decodePayload(linkID) else { throw SpacesDeviceTerminalLinkResolverError.invalidLinkID }
        guard payload.sessionID == sessionID else { throw SpacesDeviceTerminalLinkResolverError.sessionMismatch }
        let file = try validateLocalFile(
            url: URL(fileURLWithPath: payload.path), workspaceRoots: workspaceRoots, homeDirectory: homeDirectory, fileManager: fileManager)
        guard file.artifactKind == payload.artifactKind else { throw SpacesDeviceTerminalLinkResolverError.unsupportedArtifact }

        let offset = offset ?? 0
        let limit = min(max(limit ?? defaultChunkLimit, 1), maximumChunkLimit)
        guard offset >= 0, offset <= file.byteCount else { throw SpacesDeviceTerminalLinkResolverError.invalidChunkRange }

        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(limit, Int(max(file.byteCount - offset, 0)))) ?? Data()
        let nextOffset = offset + Int64(data.count)
        return SpacesDeviceTerminalLinkChunk(
            linkID: linkID ?? "", offset: offset, byteCount: data.count, isFinal: nextOffset >= file.byteCount, base64Data: data.base64EncodedString()
        )
    }

    public static func resolvedLocalFilePath(linkID: String?) throws -> String {
        guard let payload = try decodePayload(linkID) else { throw SpacesDeviceTerminalLinkResolverError.invalidLinkID }
        return payload.path
    }

    /// Whether resolving `link` could need a working directory to anchor a relative local-file path.
    /// Mirrors `resolve`'s own scheme and prefix handling exactly: `http`/`https`/`file` (and any other
    /// scheme, which `resolve` rejects outright) never reach relative-path resolution, and absolute
    /// (`/…`) or tilde (`~`, `~/…`) links resolve directly without one. Only a bare relative local-file
    /// path needs it. Callers use this to skip looking up a session's working directory (which can
    /// require reading session launch/runtime state that may be unavailable) when the link can't
    /// possibly need it, so absolute-path links still resolve when that state is missing.
    public static func requiresWorkingDirectory(link: String?) -> Bool {
        guard let link = normalizedString(link) else { return false }
        if URL(string: link)?.scheme != nil { return false }
        if link == "~" || link.hasPrefix("~/") { return false }
        return !link.hasPrefix("/")
    }

    private static func resolveLocal(
        sessionID: String, originalLink: String, fileURL: URL?, workingDirectory: String?, workspaceRoots: [String], homeDirectory: String,
        fileManager: FileManager
    ) throws -> SpacesDeviceTerminalLinkMetadata {
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else {
            let expandedPath =
                if originalLink == "~" { homeDirectory } else if originalLink.hasPrefix("~/") {
                    URL(fileURLWithPath: homeDirectory, isDirectory: true).appendingPathComponent(String(originalLink.dropFirst(2))).path
                } else { originalLink }
            if expandedPath.hasPrefix("/") {
                resolvedURL = URL(fileURLWithPath: expandedPath)
            } else {
                guard let workingDirectory = normalizedString(workingDirectory) else {
                    throw SpacesDeviceTerminalLinkResolverError.missingWorkingDirectory
                }
                resolvedURL = URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(expandedPath)
            }
        }

        let file = try validateLocalFile(url: resolvedURL, workspaceRoots: workspaceRoots, homeDirectory: homeDirectory, fileManager: fileManager)
        let payload = LocalLinkPayload(
            sessionID: sessionID, path: file.url.path, originalLink: originalLink, displayName: file.displayName, contentType: file.contentType,
            artifactKind: file.artifactKind, byteCount: file.byteCount)
        let linkID = try encodePayload(payload)
        return SpacesDeviceTerminalLinkMetadata(
            id: linkID, source: .localFile, originalLink: originalLink, displayName: file.displayName, contentType: file.contentType,
            artifactKind: file.artifactKind, byteCount: file.byteCount, externalURL: nil)
    }

    private static func validateLocalFile(url: URL, workspaceRoots: [String], homeDirectory: String, fileManager: FileManager) throws -> LocalFile {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolvedURL.path
        guard path.hasPrefix("/") else { throw SpacesDeviceTerminalLinkResolverError.invalidPath }
        guard pathIsAllowed(path, workspaceRoots: workspaceRoots, homeDirectory: homeDirectory) else {
            throw SpacesDeviceTerminalLinkResolverError.blockedPath(path)
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, fileManager.isReadableFile(atPath: path) else {
            throw SpacesDeviceTerminalLinkResolverError.fileUnavailable
        }

        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw SpacesDeviceTerminalLinkResolverError.fileUnavailable }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let contentType = SpacesDeviceTerminalLinkClassifier.preferredContentType(pathExtension: resolvedURL.pathExtension)
        guard let artifactKind = SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: contentType, pathExtension: resolvedURL.pathExtension)
        else {
            throw SpacesDeviceTerminalLinkResolverError.unsupportedArtifact
        }

        return LocalFile(
            url: resolvedURL, displayName: resolvedURL.lastPathComponent, contentType: contentType, artifactKind: artifactKind,
            byteCount: byteCount)
    }

    private static func pathIsAllowed(_ path: String, workspaceRoots: [String], homeDirectory: String) -> Bool {
        guard !blockedPathPrefixes.contains(where: { pathHasPrefix(path, prefix: $0) }) else { return false }
        let resolvedHome = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        if pathHasPrefix(path, prefix: resolvedHome) { return true }
        if fixedAllowedPathPrefixes.contains(where: { pathHasPrefix(path, prefix: $0) }) { return true }
        return workspaceRoots.contains { root in
            let resolvedRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
            return pathHasPrefix(path, prefix: resolvedRoot)
        }
    }

    private static func pathHasPrefix(_ path: String, prefix: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }

    private static func isLocalFileURLHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true }
        return host.caseInsensitiveCompare("localhost") == .orderedSame
    }

    private static func externalDisplayName(for url: URL) -> String {
        let lastPathComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastPathComponent.isEmpty { return lastPathComponent }
        return url.host ?? url.absoluteString
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func encodePayload(_ payload: LocalLinkPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(
            of: "=", with: "")
    }

    private static func decodePayload(_ linkID: String?) throws -> LocalLinkPayload? {
        guard let linkID = normalizedString(linkID) else { return nil }
        var base64 = linkID.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 { base64 += String(repeating: "=", count: 4 - padding) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try JSONDecoder().decode(LocalLinkPayload.self, from: data)
    }
}

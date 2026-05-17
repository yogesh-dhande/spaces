import Foundation

public struct GhosttyEmbeddedPaths: Sendable, Equatable {
    public let xcframeworkRootPath: String
    public let resourcesDirectoryPath: String?

    public init(xcframeworkRootPath: String, resourcesDirectoryPath: String?) {
        self.xcframeworkRootPath = xcframeworkRootPath
        self.resourcesDirectoryPath = resourcesDirectoryPath
    }
}

public enum GhosttyEmbeddedAvailability: Sendable, Equatable {
    case available(GhosttyEmbeddedPaths)
    case unavailable(reason: String)
}

public enum GhosttyEmbeddedLocator {
    public static let xcframeworkEnvironmentVariable = "SPACES_GHOSTTYKIT_XCFRAMEWORK"
    public static let resourcesEnvironmentVariable = "SPACES_GHOSTTY_RESOURCES_DIR"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default, currentDirectoryPath: String? = nil
    ) -> GhosttyEmbeddedAvailability {
        let searchRoots = candidateXCFrameworkRoots(environment: environment, fileManager: fileManager, currentDirectoryPath: currentDirectoryPath)
        for root in searchRoots {
            let xcframeworkURL = URL(fileURLWithPath: root, isDirectory: true)
            guard containsRequiredArtifacts(at: xcframeworkURL, fileManager: fileManager) else { continue }

            let resourcesPath = resolvedResourcesPath(
                environment: environment, xcframeworkRootPath: xcframeworkURL.deletingLastPathComponent().path, fileManager: fileManager)
            return .available(.init(xcframeworkRootPath: xcframeworkURL.path, resourcesDirectoryPath: resourcesPath))
        }

        return .unavailable(reason: missingFrameworkReason(searchRoots: searchRoots))
    }

    private static func candidateXCFrameworkRoots(environment: [String: String], fileManager: FileManager, currentDirectoryPath: String?) -> [String]
    {
        var candidates: [String] = []
        if let override = normalizedEnvironmentPath(environment[xcframeworkEnvironmentVariable]), !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override).standardizedFileURL.path)
        }

        let roots = candidateSearchRoots(fileManager: fileManager, currentDirectoryPath: currentDirectoryPath)
        for root in roots {
            candidates.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("GhosttyKit.xcframework").path)
            candidates.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("GhosttyKit/GhosttyKit.xcframework").path)
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    private static func resolvedResourcesPath(environment: [String: String], xcframeworkRootPath: String, fileManager: FileManager) -> String? {
        if let override = normalizedEnvironmentPath(environment[resourcesEnvironmentVariable]), fileManager.fileExists(atPath: override) {
            return URL(fileURLWithPath: override).standardizedFileURL.path
        }

        let rootURL = URL(fileURLWithPath: xcframeworkRootPath, isDirectory: true)
        let bundledResources = rootURL.appendingPathComponent("Resources/ghostty", isDirectory: true)
        if fileManager.fileExists(atPath: bundledResources.path) { return bundledResources.path }
        return nil
    }

    private static func candidateSearchRoots(fileManager: FileManager, currentDirectoryPath: String?) -> [String] {
        let cwd = currentDirectoryPath ?? fileManager.currentDirectoryPath
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let parentURL = cwdURL.deletingLastPathComponent()
        let roots = [
            cwdURL, cwdURL.appendingPathComponent(".local/ghosttykit", isDirectory: true),
            cwdURL.appendingPathComponent("apps/macos", isDirectory: true),
            cwdURL.appendingPathComponent("apps/macos/.local/ghosttykit", isDirectory: true), parentURL,
            parentURL.appendingPathComponent(".local/ghosttykit", isDirectory: true),
            parentURL.appendingPathComponent("apps/macos", isDirectory: true),
            parentURL.appendingPathComponent("apps/macos/.local/ghosttykit", isDirectory: true),
        ].map(\.path)
        return Array(NSOrderedSet(array: roots)) as? [String] ?? roots
    }

    private static func missingFrameworkReason(searchRoots: [String]) -> String {
        let joined = searchRoots.joined(separator: ", ")
        return
            "GhosttyKit.xcframework is not configured. Set \(xcframeworkEnvironmentVariable) or place GhosttyKit.xcframework under one of: \(joined)"
    }

    private static func containsRequiredArtifacts(at xcframeworkURL: URL, fileManager: FileManager) -> Bool {
        let macOSSliceURL = xcframeworkURL.appendingPathComponent("macos-arm64_x86_64", isDirectory: true)
        let libraryURL = macOSSliceURL.appendingPathComponent("libghostty-internal.a")
        let headersURL = macOSSliceURL.appendingPathComponent("Headers", isDirectory: true)
        return fileManager.fileExists(atPath: libraryURL.path) && fileManager.fileExists(atPath: headersURL.path)
    }

    private static func normalizedEnvironmentPath(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return URL(fileURLWithPath: normalized).standardizedFileURL.path
    }
}

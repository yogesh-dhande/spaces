import Foundation

public struct GhosttyEmbeddedPaths: Sendable, Equatable {
    public let resourcesDirectoryPath: String

    var terminfoDirectoryPath: String {
        URL(fileURLWithPath: resourcesDirectoryPath, isDirectory: true).deletingLastPathComponent().appendingPathComponent(
            "terminfo", isDirectory: true
        ).standardizedFileURL.path
    }

    public init(resourcesDirectoryPath: String) { self.resourcesDirectoryPath = resourcesDirectoryPath }
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
        resolve(
            environment: environment, fileManager: fileManager, currentDirectoryPath: currentDirectoryPath,
            bundleResourcesURL: Bundle.main.resourceURL, executableURL: Bundle.main.executableURL)
    }

    static func resolve(
        environment: [String: String], fileManager: FileManager = .default, currentDirectoryPath: String?, bundleResourcesURL: URL?,
        executableURL: URL?
    ) -> GhosttyEmbeddedAvailability {
        let candidates = candidateResourcesDirectories(
            environment: environment, fileManager: fileManager, currentDirectoryPath: currentDirectoryPath, bundleResourcesURL: bundleResourcesURL,
            executableURL: executableURL)
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return .available(.init(resourcesDirectoryPath: candidate))
            }
        }

        return .unavailable(reason: missingResourcesReason(candidates: candidates))
    }

    private static func candidateResourcesDirectories(
        environment: [String: String], fileManager: FileManager, currentDirectoryPath: String?, bundleResourcesURL: URL?, executableURL: URL?
    ) -> [String] {
        var candidates: [URL] = []
        if let override = normalizedEnvironmentPath(environment[resourcesEnvironmentVariable]) {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let bundleResourcesURL { candidates.append(bundleResourcesURL.appendingPathComponent("ghostty", isDirectory: true)) }
        if let executableURL {
            // The installed LaunchAgent runs ~/.spaces/bin/spacesd, a symlink into the app bundle.
            // Resolve it before looking for the sibling bundled resources directory.
            candidates.append(
                executableURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("ghostty", isDirectory: true))
        }

        // Development artifacts keep resources beside GhosttyKit.xcframework's parent directory.
        for frameworkRoot in candidateXCFrameworkRoots(environment: environment, fileManager: fileManager, currentDirectoryPath: currentDirectoryPath)
        {
            candidates.append(
                URL(fileURLWithPath: frameworkRoot, isDirectory: true).deletingLastPathComponent().appendingPathComponent(
                    "Resources/ghostty", isDirectory: true))
        }

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let path = candidate.standardizedFileURL.path
            return seen.insert(path).inserted ? path : nil
        }
    }

    private static func candidateXCFrameworkRoots(environment: [String: String], fileManager: FileManager, currentDirectoryPath: String?) -> [String]
    {
        var candidates: [String] = []
        if let override = normalizedEnvironmentPath(environment[xcframeworkEnvironmentVariable]) {
            candidates.append(URL(fileURLWithPath: override).standardizedFileURL.path)
        }

        for root in candidateSearchRoots(fileManager: fileManager, currentDirectoryPath: currentDirectoryPath) {
            candidates.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("GhosttyKit.xcframework").path)
            candidates.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("GhosttyKit/GhosttyKit.xcframework").path)
        }
        return candidates
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

    private static func missingResourcesReason(candidates: [String]) -> String {
        "Ghostty runtime resources are not configured. Set \(resourcesEnvironmentVariable) or place them under one of: \(candidates.joined(separator: ", "))"
    }

    private static func normalizedEnvironmentPath(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return URL(fileURLWithPath: normalized).standardizedFileURL.path
    }
}

import Darwin
import Foundation

public enum SpacesProfileSource: String, Sendable, Codable, Equatable {
    case explicitDatabasePath = "explicit-db-path"
    case developmentWorktree = "development-worktree"
    case installedFallback = "installed-fallback"
}

public struct SpacesDevelopmentContext: Sendable, Equatable {
    public let worktreeRoot: String
    public let branchName: String

    public init(worktreeRoot: String, branchName: String) {
        self.worktreeRoot = worktreeRoot
        self.branchName = branchName
    }
}

public struct SpacesProfile: Sendable, Equatable {
    public static let databasePathEnvironmentVariable = "SPACES_DB_PATH"
    public static let runtimeDirectoryEnvironmentVariable = "SPACES_RUNTIME_DIR"

    public let source: SpacesProfileSource
    public let databasePath: String
    public let rootDirectory: String
    public let runtimeDirectory: String
    public let ipcNotificationObject: String
    public let developmentContext: SpacesDevelopmentContext?
    public let branchSlug: String?
    public let worktreeHash: String?

    public init(
        source: SpacesProfileSource, databasePath: String, rootDirectory: String, runtimeDirectory: String, ipcNotificationObject: String,
        developmentContext: SpacesDevelopmentContext?, branchSlug: String?, worktreeHash: String?
    ) {
        self.source = source
        self.databasePath = databasePath
        self.rootDirectory = rootDirectory
        self.runtimeDirectory = runtimeDirectory
        self.ipcNotificationObject = ipcNotificationObject
        self.developmentContext = developmentContext
        self.branchSlug = branchSlug
        self.worktreeHash = worktreeHash
    }

    public static func current() throws -> SpacesProfile {
        let environment = currentProcessEnvironment()
        let fingerprint = cacheFingerprint(
            environment: environment, currentDirectoryPath: FileManager.default.currentDirectoryPath,
            executablePath: currentExecutablePath(currentDirectoryPath: FileManager.default.currentDirectoryPath))

        cachedProfileLock.lock()
        if let cachedProfile, cachedProfileFingerprint == fingerprint {
            cachedProfileLock.unlock()
            return cachedProfile
        }
        cachedProfileLock.unlock()

        let resolved = try resolve(
            environment: environment, homeDirectoryURL: currentHomeDirectoryURL(environment: environment),
            currentDirectoryPath: FileManager.default.currentDirectoryPath)

        cachedProfileLock.lock()
        cachedProfile = resolved
        cachedProfileFingerprint = fingerprint
        cachedProfileLock.unlock()
        return resolved
    }

    static func resetCacheForTesting() {
        cachedProfileLock.lock()
        cachedProfile = nil
        cachedProfileFingerprint = nil
        cachedProfileLock.unlock()
    }

    public static func resolve(
        environment: [String: String], homeDirectoryURL: URL, currentDirectoryPath: String, executablePath: String? = nil,
        fileManager: FileManager = .default, gitProbe: SpacesGitProfileProbe = LiveSpacesGitProfileProbe()
    ) throws -> SpacesProfile {
        if let overridePath = trimmed(environment[databasePathEnvironmentVariable]), !overridePath.isEmpty {
            let databaseURL = absoluteFileURL(path: overridePath, currentDirectoryPath: currentDirectoryPath)
            let profileRoot = databaseURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: profileRoot, withIntermediateDirectories: true)
            let runtimeDirectory = try resolvedRuntimeDirectory(
                environment: environment, currentDirectoryPath: currentDirectoryPath, profileRoot: profileRoot, fileManager: fileManager)
            return SpacesProfile(
                source: .explicitDatabasePath, databasePath: databaseURL.path, rootDirectory: profileRoot.path,
                runtimeDirectory: runtimeDirectory.path, ipcNotificationObject: ipcObject(profileRoot: profileRoot.path), developmentContext: nil,
                branchSlug: nil, worktreeHash: nil)
        }

        if let developmentContext = try resolveDevelopmentContext(
            currentDirectoryPath: currentDirectoryPath, executablePath: executablePath, fileManager: fileManager, gitProbe: gitProbe)
        {
            let branchSlug = slugifyBranchName(developmentContext.branchName)
            let worktreeHash = shortStableHash(canonicalPath(developmentContext.worktreeRoot))
            let profileRoot = homeDirectoryURL.appendingPathComponent(".spaces-dev", isDirectory: true).appendingPathComponent(
                "profiles", isDirectory: true
            ).appendingPathComponent("spaces", isDirectory: true).appendingPathComponent("\(branchSlug)-\(worktreeHash)", isDirectory: true)
            try fileManager.createDirectory(at: profileRoot, withIntermediateDirectories: true)
            let runtimeDirectory = try resolvedRuntimeDirectory(
                environment: environment, currentDirectoryPath: currentDirectoryPath, profileRoot: profileRoot, fileManager: fileManager)
            return SpacesProfile(
                source: .developmentWorktree, databasePath: profileRoot.appendingPathComponent("spaces.db", isDirectory: false).path,
                rootDirectory: profileRoot.path, runtimeDirectory: runtimeDirectory.path,
                ipcNotificationObject: ipcObject(profileRoot: profileRoot.path), developmentContext: developmentContext, branchSlug: branchSlug,
                worktreeHash: worktreeHash)
        }

        let productionRoot = homeDirectoryURL.appendingPathComponent(".spaces", isDirectory: true)
        try fileManager.createDirectory(at: productionRoot, withIntermediateDirectories: true)
        let runtimeDirectory = try resolvedRuntimeDirectory(
            environment: environment, currentDirectoryPath: currentDirectoryPath, profileRoot: productionRoot, fileManager: fileManager)
        return SpacesProfile(
            source: .installedFallback, databasePath: productionRoot.appendingPathComponent("spaces.db", isDirectory: false).path,
            rootDirectory: productionRoot.path, runtimeDirectory: runtimeDirectory.path,
            ipcNotificationObject: ipcObject(profileRoot: productionRoot.path), developmentContext: nil, branchSlug: nil, worktreeHash: nil)
    }

    public static func installedDatabasePath(homeDirectoryURL: URL, fileManager: FileManager = .default) throws -> String {
        let directory = homeDirectoryURL.appendingPathComponent(".spaces", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("spaces.db", isDirectory: false).path
    }

    public static func ipcObject(profileRoot: String) -> String { "spaces.profile.\(shortStableHash(canonicalPath(profileRoot)))" }

    public static func slugifyBranchName(_ branchName: String) -> String {
        let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "HEAD" { return "detached-head" }
        let lowercased = trimmed.lowercased()
        let segments = lowercased.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let slug = segments.joined(separator: "-")
        return slug.isEmpty ? "detached-head" : slug
    }

    public static func shortStableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash).prefix(12).description
    }

    public static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func currentExecutablePath(currentDirectoryPath: String) -> String? {
        if let executableURL = Bundle.main.executableURL { return canonicalPath(executableURL.path) }
        guard let argument0 = CommandLine.arguments.first, !argument0.isEmpty else { return nil }
        return absoluteFileURL(path: argument0, currentDirectoryPath: currentDirectoryPath).path
    }

    private static let cachedProfileLock = NSLock()
    private nonisolated(unsafe) static var cachedProfile: SpacesProfile?
    private nonisolated(unsafe) static var cachedProfileFingerprint: String?

    private static func cacheFingerprint(environment: [String: String], currentDirectoryPath: String, executablePath: String?) -> String {
        [
            environment[databasePathEnvironmentVariable] ?? "", environment[runtimeDirectoryEnvironmentVariable] ?? "", environment["HOME"] ?? "",
            currentDirectoryPath, executablePath ?? "",
        ].joined(separator: "\u{1f}")
    }

    private static func currentProcessEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [databasePathEnvironmentVariable, runtimeDirectoryEnvironmentVariable] {
            if let value = currentEnvironmentValue(for: key) { environment[key] = value } else { environment.removeValue(forKey: key) }
        }
        return environment
    }

    private static func currentHomeDirectoryURL(environment: [String: String]) -> URL {
        if let home = trimmed(environment["HOME"]), !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        #if os(macOS)
            return FileManager.default.homeDirectoryForCurrentUser
        #else
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    private static func currentEnvironmentValue(for key: String) -> String? {
        guard let rawValue = getenv(key) else { return nil }
        return String(cString: rawValue)
    }

    private static func resolveDevelopmentContext(
        currentDirectoryPath: String, executablePath: String?, fileManager: FileManager, gitProbe: SpacesGitProfileProbe
    ) throws -> SpacesDevelopmentContext? {
        #if os(macOS)
            guard let executablePath = executablePath ?? currentExecutablePath(currentDirectoryPath: currentDirectoryPath) else { return nil }
            guard let repoRoot = detectRepoRoot(executablePath: executablePath, fileManager: fileManager) else { return nil }
            return try? gitProbe.resolveDevelopmentContext(repoRootPath: repoRoot)
        #else
            return nil
        #endif
    }

    private static func detectRepoRoot(executablePath: String, fileManager: FileManager) -> String? {
        var currentURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent().standardizedFileURL
        while true {
            let packageURL = currentURL.appendingPathComponent("apps", isDirectory: true).appendingPathComponent("macos", isDirectory: true)
                .appendingPathComponent("Package.swift", isDirectory: false)
            if fileManager.fileExists(atPath: packageURL.path) { return currentURL.path }
            if currentURL.path == "/" || currentURL.path.isEmpty { return nil }
            let parentURL = currentURL.deletingLastPathComponent().standardizedFileURL
            if parentURL.path == currentURL.path { return nil }
            currentURL = parentURL
        }
    }

    private static func resolvedRuntimeDirectory(
        environment: [String: String], currentDirectoryPath: String, profileRoot: URL, fileManager: FileManager
    ) throws -> URL {
        if let override = trimmed(environment[runtimeDirectoryEnvironmentVariable]), !override.isEmpty {
            let overrideURL = absoluteFileURL(path: override, currentDirectoryPath: currentDirectoryPath)
            try fileManager.createDirectory(at: overrideURL, withIntermediateDirectories: true)
            return overrideURL
        }
        let runtimeURL = profileRoot.appendingPathComponent("runtime", isDirectory: true)
        try fileManager.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        return runtimeURL
    }

    private static func absoluteFileURL(path: String, currentDirectoryPath: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL }
        return URL(fileURLWithPath: currentDirectoryPath, isDirectory: true).appendingPathComponent(expanded, isDirectory: false)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    private static func trimmed(_ value: String?) -> String? { value?.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public protocol SpacesGitProfileProbe { func resolveDevelopmentContext(repoRootPath: String) throws -> SpacesDevelopmentContext? }

public struct LiveSpacesGitProfileProbe: SpacesGitProfileProbe {
    public init() {}

    public func resolveDevelopmentContext(repoRootPath: String) throws -> SpacesDevelopmentContext? {
        #if os(macOS)
            let worktreeRoot = try runGit(arguments: ["-C", repoRootPath, "rev-parse", "--show-toplevel"])
            let branchName = try runGit(arguments: ["-C", repoRootPath, "rev-parse", "--abbrev-ref", "HEAD"])
            let trimmedRoot = worktreeRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRoot.isEmpty, !trimmedBranch.isEmpty else { return nil }
            return SpacesDevelopmentContext(worktreeRoot: SpacesProfile.canonicalPath(trimmedRoot), branchName: trimmedBranch)
        #else
            return nil
        #endif
    }

    #if os(macOS)
        private func runGit(arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                throw NSError(domain: "SpacesGitProfileProbe", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
            }
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: outputData, encoding: .utf8) ?? ""
        }
    #endif
}

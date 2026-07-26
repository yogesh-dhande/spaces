import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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

    /// The process's resolved profile, cached behind a fingerprint of every input that can change
    /// while the process runs: the two profile environment overrides, `HOME`, and the working
    /// directory (which resolves relative overrides and a relative `argv[0]`). The fingerprint is
    /// built from `getenv` and a single `getcwd` because `current()` is on hot paths — every
    /// terminal-session path lookup goes through it — and reading the whole process environment
    /// dictionary cost more than the `resolve()` work the cache exists to avoid.
    public static func current() throws -> SpacesProfile {
        let currentDirectoryPath = FileManager.default.currentDirectoryPath
        let fingerprint = cacheFingerprint(
            databasePathOverride: currentEnvironmentValue(for: databasePathEnvironmentVariable),
            runtimeDirectoryOverride: currentEnvironmentValue(for: runtimeDirectoryEnvironmentVariable),
            homeDirectory: currentEnvironmentValue(for: homeEnvironmentVariable), currentDirectoryPath: currentDirectoryPath,
            executablePath: processExecutablePath)

        cachedProfileLock.lock()
        if let cachedProfile, cachedProfileFingerprint == fingerprint {
            cachedProfileLock.unlock()
            return cachedProfile
        }
        cachedProfileLock.unlock()

        // Miss path only: `resolve` takes a full environment dictionary, so hand it the real one
        // rather than a subset the fingerprint happens to cover today.
        let environment = currentProcessEnvironment()
        let resolved = try resolve(
            environment: environment, homeDirectoryURL: currentHomeDirectoryURL(environment: environment), currentDirectoryPath: currentDirectoryPath)

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
            return try makeProfile(
                source: .explicitDatabasePath, profileRoot: databaseURL.deletingLastPathComponent(), databasePath: databaseURL.path,
                environment: environment, currentDirectoryPath: currentDirectoryPath, fileManager: fileManager)
        }

        if let developmentContext = try resolveDevelopmentContext(
            currentDirectoryPath: currentDirectoryPath, executablePath: executablePath, fileManager: fileManager, gitProbe: gitProbe)
        {
            let branchSlug = slugifyBranchName(developmentContext.branchName)
            let worktreeHash = shortStableHash(canonicalPath(developmentContext.worktreeRoot))
            let profileRoot = homeDirectoryURL.appendingPathComponent(".spaces-dev", isDirectory: true).appendingPathComponent(
                "profiles", isDirectory: true
            ).appendingPathComponent("spaces", isDirectory: true).appendingPathComponent("\(branchSlug)-\(worktreeHash)", isDirectory: true)
            return try makeProfile(
                source: .developmentWorktree, profileRoot: profileRoot,
                databasePath: profileRoot.appendingPathComponent("spaces.db", isDirectory: false).path, environment: environment,
                currentDirectoryPath: currentDirectoryPath, fileManager: fileManager, developmentContext: developmentContext,
                branchSlug: branchSlug, worktreeHash: worktreeHash)
        }

        let productionRoot = homeDirectoryURL.appendingPathComponent(".spaces", isDirectory: true)
        return try makeProfile(
            source: .installedFallback, profileRoot: productionRoot,
            databasePath: productionRoot.appendingPathComponent("spaces.db", isDirectory: false).path, environment: environment,
            currentDirectoryPath: currentDirectoryPath, fileManager: fileManager)
    }

    /// The single place a resolved profile becomes real: it applies the test-host refusal, creates the
    /// profile's directories, and builds the value. Every branch of `resolve` funnels through here, so the
    /// refusal is written once and a branch added later inherits it instead of having to remember it.
    private static func makeProfile(
        source: SpacesProfileSource, profileRoot: URL, databasePath: String, environment: [String: String], currentDirectoryPath: String,
        fileManager: FileManager, developmentContext: SpacesDevelopmentContext? = nil, branchSlug: String? = nil, worktreeHash: String? = nil
    ) throws -> SpacesProfile {
        // A test process must never resolve a profile the user's own app, daemon, or CLI is serving —
        // installed or development, and however the path was arrived at, including an explicit
        // SPACES_DB_PATH. Test targets create and mutate real terminal-session state through the resolved
        // profile, so an unisolated run writes fixture sessions into a live database. The rule is a static
        // one about WHERE the database is rather than whether something currently owns it, so the guard
        // cannot depend on whether the developer's app happens to be running. It refuses loudly rather than
        // redirecting to a scratch profile: a redirect would hide the missing isolation and leave the test
        // asserting against a profile it never chose. The check precedes every side effect, so a refused
        // resolution creates no directories.
        if SpacesTestHost.isRunningUnderXCTest(), isLiveUserProfileDatabase(databasePath) {
            throw SpacesProfileResolutionError.testHostRefusedLiveUserProfile(databasePath: databasePath)
        }
        try fileManager.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let runtimeDirectory = try resolvedRuntimeDirectory(
            environment: environment, currentDirectoryPath: currentDirectoryPath, profileRoot: profileRoot, fileManager: fileManager)
        return SpacesProfile(
            source: source, databasePath: databasePath, rootDirectory: profileRoot.path, runtimeDirectory: runtimeDirectory.path,
            ipcNotificationObject: ipcObject(profileRoot: profileRoot.path), developmentContext: developmentContext, branchSlug: branchSlug,
            worktreeHash: worktreeHash)
    }

    public static func installedDatabasePath(homeDirectoryURL: URL, fileManager: FileManager = .default) throws -> String {
        let directory = homeDirectoryURL.appendingPathComponent(".spaces", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("spaces.db", isDirectory: false).path
    }

    /// Whether `databasePath` lives inside a Spaces state root that this account's own app, daemon, or CLI
    /// serves: `~/.spaces/` (installed) or `~/.spaces-dev/profiles/` (per-worktree development profiles),
    /// under the account's own home read from the password database rather than `HOME`. A test that points
    /// `HOME` at a scratch directory is already isolated and resolves normally.
    ///
    /// An unreadable password database answers `true`. That is the safety decision, not a convenience:
    /// "the account home could not be identified" must never be reported as "this is not a live profile",
    /// which would drop the protection in exactly the case where nothing can vouch for the path.
    private static func isLiveUserProfileDatabase(_ databasePath: String) -> Bool {
        guard let accountHomePath = accountHomeDirectoryPath() else { return true }
        let accountHome = URL(fileURLWithPath: accountHomePath, isDirectory: true)
        let liveProfileRoots = [
            accountHome.appendingPathComponent(".spaces", isDirectory: true),
            accountHome.appendingPathComponent(".spaces-dev", isDirectory: true).appendingPathComponent("profiles", isDirectory: true),
        ]
        return liveProfileRoots.contains { isPath(databasePath, under: $0) }
    }

    /// Path containment compared component-wise on canonical paths. A string-prefix test would report
    /// `~/.spaces-devil/spaces.db` as living under `~/.spaces-dev`, and would be defeated by a `..` segment
    /// or a symlinked route into the root; canonicalizing first and comparing whole components is neither.
    private static func isPath(_ path: String, under root: URL) -> Bool {
        let pathComponents = URL(fileURLWithPath: canonicalPath(path)).pathComponents
        let rootComponents = URL(fileURLWithPath: canonicalPath(root.path)).pathComponents
        guard pathComponents.count > rootComponents.count else { return false }
        return Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// The account's home directory from the password database, deliberately ignoring `HOME` so a process
    /// that redirected the environment cannot disguise the account's real home as somewhere else.
    ///
    /// `nil` when the password database has no readable entry for this uid. There is deliberately no
    /// substitute: every Foundation home-directory API honours `HOME`, so falling back to one would
    /// return the very value this function exists to avoid — and each caller's correct response to "the
    /// account home is unknown" differs, so it is theirs to make rather than something to paper over here.
    public static func accountHomeDirectoryPath() -> String? {
        let uid = getuid()
        let rawSize = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        let bufferSize = rawSize > 0 ? Int(rawSize) : 16_384
        var buffer = [CChar](repeating: 0, count: bufferSize)
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let status = getpwuid_r(uid, &record, &buffer, buffer.count, &result)
        guard status == 0, let entry = result else { return nil }
        let path = String(cString: entry.pointee.pw_dir)
        return path.isEmpty ? nil : path
    }

    public static func ipcObject(profileRoot: String) -> String { "spaces.profile.\(shortStableHash(canonicalPath(profileRoot)))" }

    /// Well-known local Caddy router port for the single installed/production instance.
    public static let installedRouterPort = 7391

    /// Default local Caddy router port for this profile. The installed/production profile keeps
    /// the well-known port; dev/worktree/explicit-db profiles derive a distinct deterministic port
    /// so concurrent Spaces instances (multiple worktrees, or the installed app plus a dev build)
    /// don't all try to bind one port — where only the first wins and every other instance's Caddy
    /// silently fails to start, breaking its workspace-service routing.
    public var defaultRouterPort: Int {
        switch source {
        case .installedFallback: return Self.installedRouterPort
        case .developmentWorktree, .explicitDatabasePath: return Self.derivedRouterPort(profileRoot: rootDirectory)
        }
    }

    /// Maps a profile's stable hash into a fixed high port range that avoids the default workspace
    /// service port range (20000–30000) and the OS ephemeral range (49152+).
    public static func derivedRouterPort(profileRoot: String) -> Int {
        let value = UInt64(shortStableHash(canonicalPath(profileRoot)), radix: 16) ?? 0
        return 31000 + Int(value % 10000)  // 31000–40999
    }

    public static func slugifyBranchName(_ branchName: String) -> String {
        let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "HEAD" { return "detached-head" }
        let lowercased = trimmed.lowercased()
        let segments = lowercased.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let slug = segments.joined(separator: "-")
        return slug.isEmpty ? "detached-head" : slug
    }

    /// DNS-safe per-workspace host slug used as the middle label in `<service>.<slug>.localhost`.
    /// Combines a human-readable workspace label with a short stable hash of the workspace id so two
    /// workspaces with the same label get distinct hosts. Git workspaces use the branch label; non-git
    /// workspaces use the project label. Derived deterministically from label + id (never persisted).
    public static func workspaceHostSlug(branch: String?, projectName: String, isGitRepo: Bool, workspaceID: String) -> String {
        let suffix = shortStableHash(workspaceID)
        let maxBaseLength = max(1, DNSLabel.maxLength - suffix.count - 1)
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmedBranch.flatMap { $0.isEmpty ? nil : $0 }.map(slugifyBranchName) ?? (isGitRepo ? slugifyBranchName("") : projectName)
        let base = DNSLabel.sanitize(label, maxLength: maxBaseLength)
        return "\(base)-\(suffix)"
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

    private static let homeEnvironmentVariable = "HOME"

    private static let cachedProfileLock = NSLock()
    private nonisolated(unsafe) static var cachedProfile: SpacesProfile?
    private nonisolated(unsafe) static var cachedProfileFingerprint: String?

    /// Resolved once per process: the executable backing a running process cannot be swapped under
    /// it, and resolving it costs a symlink resolution that `current()` would otherwise repeat on
    /// every call. Swift initializes a `static let` lazily and exactly once, so concurrent callers
    /// share the single resolution.
    private static let processExecutablePath: String? = currentExecutablePath(currentDirectoryPath: FileManager.default.currentDirectoryPath)

    private static func cacheFingerprint(
        databasePathOverride: String?, runtimeDirectoryOverride: String?, homeDirectory: String?, currentDirectoryPath: String,
        executablePath: String?
    ) -> String {
        [databasePathOverride ?? "", runtimeDirectoryOverride ?? "", homeDirectory ?? "", currentDirectoryPath, executablePath ?? ""].joined(
            separator: "\u{1f}")
    }

    /// The process environment with every key the cache fingerprint watches re-read from the C-level
    /// environment, so a `setenv` made after process start resolves the same way it fingerprints —
    /// the fingerprint reads those keys with `getenv`, and resolution must not disagree with it.
    private static func currentProcessEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [databasePathEnvironmentVariable, runtimeDirectoryEnvironmentVariable, homeEnvironmentVariable] {
            if let value = currentEnvironmentValue(for: key) { environment[key] = value } else { environment.removeValue(forKey: key) }
        }
        return environment
    }

    private static func currentHomeDirectoryURL(environment: [String: String]) -> URL {
        if let home = trimmed(environment[homeEnvironmentVariable]), !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
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
            // The executable lives inside a Spaces checkout, so it is a repo-built binary and must derive
            // its profile from the worktree. Falling back to the installed profile (~/.spaces) would open the
            // user's production database with a development build and, on a schema mismatch, crash-loop the
            // installed daemon. A git probe that throws or returns nothing is therefore fatal here — never a
            // silent fallback. Explicit SPACES_DB_PATH overrides are handled earlier in `resolve`, so this
            // path only governs binaries that reached automatic profile detection.
            do {
                guard let context = try gitProbe.resolveDevelopmentContext(repoRootPath: repoRoot) else {
                    throw SpacesProfileResolutionError.repoBuiltGitProbeFailed(
                        executablePath: executablePath, repoRoot: repoRoot, underlyingError: nil)
                }
                return context
            } catch let error as SpacesProfileResolutionError { throw error } catch {
                throw SpacesProfileResolutionError.repoBuiltGitProbeFailed(executablePath: executablePath, repoRoot: repoRoot, underlyingError: error)
            }
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

/// Raised while resolving `SpacesProfile` for a binary that was built inside a Spaces checkout.
/// Such a binary must never fall back to the installed profile, so a failed git probe surfaces
/// loudly instead of silently pointing a development build at the installed daemon's database.
public enum SpacesProfileResolutionError: Error, CustomStringConvertible, LocalizedError {
    /// The git probe for a repo-built executable threw or returned no development context. Carries the
    /// executable path, the detected repo root, and the underlying git failure (when there was one).
    case repoBuiltGitProbeFailed(executablePath: String, repoRoot: String, underlyingError: (any Error)?)

    /// A test process resolved a database inside one of this account's live Spaces profile roots. Carries
    /// the refused database path.
    case testHostRefusedLiveUserProfile(databasePath: String)

    public var description: String {
        switch self {
        case .repoBuiltGitProbeFailed(let executablePath, let repoRoot, let underlyingError):
            let reason = underlyingError.map { String(describing: $0) } ?? "git probe returned no development context"
            return "repo-built executable \(executablePath) could not resolve its development profile from repo root \(repoRoot): "
                + "\(reason). Refusing to fall back to the installed profile (~/.spaces) so a development build cannot open the "
                + "installed daemon's database."
        case .testHostRefusedLiveUserProfile(let databasePath):
            return "a test process resolved \(databasePath), which is inside one of this account's live Spaces profile roots "
                + "(~/.spaces and ~/.spaces-dev/profiles). Refusing it so tests cannot read or write a profile the app, daemon, or CLI "
                + "is serving. Isolate the test by setting \(SpacesProfile.databasePathEnvironmentVariable) to a database OUTSIDE those "
                + "roots — one under the system temporary directory — for the whole test, including any work its background queues "
                + "finish later."
        }
    }

    /// The app's top-level launch catch prints `localizedDescription`; without this conformance that
    /// renders as a generic NSError stub and drops the diagnostics this error exists to carry.
    public var errorDescription: String? { description }
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
            // Drain both pipes before waiting: a child that writes more than the 64KB pipe
            // buffer blocks until someone reads, so waiting first deadlocks both processes.
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                throw NSError(domain: "SpacesGitProfileProbe", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
            }
            return String(data: outputData, encoding: .utf8) ?? ""
        }
    #endif
}

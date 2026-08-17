import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum SpacesProfileSource: String, Sendable, Codable, Equatable {
    case explicitDatabasePath = "explicit-db-path"
    case developmentWorktree = "development-worktree"
    case deployedDevelopmentProfile = "deployed-dev-profile"
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

    /// How this profile was DISCOVERED. Provenance only — diagnostics and error text. Nothing decides what
    /// a profile *is* from this, because the same profile is reachable through several routes: the installed
    /// profile is normally reached by falling through to `~/.spaces`, but an explicit `SPACES_DB_PATH` or a
    /// deployed binary can name the very same root. `isInstalledProfile` answers identity instead.
    public let source: SpacesProfileSource
    public let databasePath: String
    public let rootDirectory: String
    /// Whether this profile IS the installed one, decided by where it resolved (`<home>/.spaces`) rather
    /// than by which branch of `resolve` produced it. Every rule that treats the installed profile
    /// differently — its canonical Device API port, its router port, its daemon binaries, its systemd unit —
    /// keys off this, so a profile reached by an unusual route still gets the installed profile's behavior
    /// instead of being mistaken for a development one.
    public let isInstalledProfile: Bool
    public let runtimeDirectory: String
    public let ipcNotificationObject: String
    public let developmentContext: SpacesDevelopmentContext?
    public let branchSlug: String?
    public let worktreeHash: String?

    public init(
        source: SpacesProfileSource, databasePath: String, rootDirectory: String, isInstalledProfile: Bool, runtimeDirectory: String,
        ipcNotificationObject: String, developmentContext: SpacesDevelopmentContext?, branchSlug: String?, worktreeHash: String?
    ) {
        self.source = source
        self.databasePath = databasePath
        self.rootDirectory = rootDirectory
        self.isInstalledProfile = isInstalledProfile
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

    /// `current()`, except a genuine "no profile could be resolved" collapses to `nil` instead of
    /// throwing, for the product call sites that predate the test-host refusal and read a missing
    /// profile as a normal, render-anyway outcome (reasonable — a repo-built binary whose git probe
    /// failed, say, is rare and callers already have a sensible degraded state for it).
    ///
    /// A refusal is deliberately excluded from that collapse. It is not "no profile" — it is "this
    /// process is not allowed to resolve one" — so callers must never be able to fold it into the same
    /// `nil` branch by reaching for the same `try?`/no-profile idiom they already use for every other
    /// failure. This is the one place that draws that line; every one of #322's nine call sites goes
    /// through here directly (a `throws` call site), through `currentOrNilOnFailureFatalOnRefusal()` in
    /// `spacesui` (a call site with no `throws` to propagate through, where trapping is safe and cheap
    /// because it runs once per user action), or through `currentOrNilLoggingRefusal()` (a call site that
    /// is both non-throwing and too hot or too widely shared to trap on) — instead of repeating the
    /// distinction inline.
    public static func currentOrNilIfUnresolved() throws -> SpacesProfile? { try nilUnlessRefused { try current() } }

    /// The single decision of what counts as a refusal versus a genuine "no profile," shared by every
    /// caller that needs it rather than re-implemented per call site. Generic over the wrapped result so
    /// both `currentOrNilIfUnresolved()` and tests can drive it directly without needing a whole resolved
    /// `SpacesProfile`.
    /// Written as "everything except the one genuine failure" rather than as a list of refusals, so a
    /// refusal added later is loud by default instead of silently joining the `nil` branch.
    static func nilUnlessRefused<T>(_ body: () throws -> T) throws -> T? {
        do { return try body() } catch let error as SpacesProfileResolutionError {
            if case .repoBuiltGitProbeFailed = error { return nil }
            throw error
        } catch { return nil }
    }

    /// Non-throwing counterpart of `currentOrNilIfUnresolved()` for a call site that is not `throws` and,
    /// unlike a `spacesui` UI action, cannot safely trap on a refusal either: the call sits on a path that
    /// is either evaluated on every tick of a hot, background-driven loop (`TerminalOverviewSignal.post`,
    /// fired on every terminal runtime-state change from a detached engine-actor task with no test or
    /// assertion to attribute a crash to) or baked into a default parameter value fanned out across dozens
    /// of call sites, some inside the shared XCTest binary (`SpacesDevicePairingClient.localMacClientInstallationID`,
    /// which a default argument cannot make `throws` — Swift rejects a throwing expression in a default
    /// argument outright). Trapping either would abort the one process hosting every currently running
    /// suite over a resolution failure that may not even belong to whichever test happens to be mid-flight
    /// when a lingering background task reaches this code (a session's queued persistence work can still
    /// be running after that test's own environment override has been restored — see the profile
    /// resolution notes in `docs/implementation.md`).
    ///
    /// So a refusal here is reported, not hidden or trapped: `diagnoseRefusal` runs (by default, writes to
    /// stderr, matching this codebase's existing non-fatal diagnostic convention) and the caller's
    /// existing "no profile" degrade applies exactly as it would for any other resolution failure.
    public static func currentOrNilLoggingRefusal(diagnoseRefusal: (SpacesProfileResolutionError) -> Void = logRefusalToStandardError)
        -> SpacesProfile?
    {
        do { return try nilUnlessRefused { try current() } } catch let error as SpacesProfileResolutionError {
            diagnoseRefusal(error)
            return nil
        } catch { return nil }
    }

    public static func logRefusalToStandardError(_ error: SpacesProfileResolutionError) {
        FileHandle.standardError.write(Data("spaces: profile resolution refused on a path that cannot safely propagate or trap: \(error)\n".utf8))
    }

    public static func resolve(
        environment: [String: String], homeDirectoryURL: URL, currentDirectoryPath: String, executablePath: String? = nil,
        fileManager: FileManager = .default, gitProbe: SpacesGitProfileProbe = LiveSpacesGitProfileProbe()
    ) throws -> SpacesProfile {
        if let overridePath = trimmed(environment[databasePathEnvironmentVariable]), !overridePath.isEmpty {
            let databaseURL = absoluteFileURL(path: overridePath, currentDirectoryPath: currentDirectoryPath)
            return try makeProfile(
                source: .explicitDatabasePath, profileRoot: databaseURL.deletingLastPathComponent(), databasePath: databaseURL.path,
                environment: environment, homeDirectoryURL: homeDirectoryURL, currentDirectoryPath: currentDirectoryPath, fileManager: fileManager)
        }

        // A development build deployed onto a device has no Spaces checkout to derive a profile from, so it
        // states which profile it belongs to by WHERE it is installed: inside that profile's own root. The
        // rule here is the deployed counterpart of the repo-built rule below, and exists for the same
        // reason — a development build that fell through to the installed profile (~/.spaces) would open the
        // installed daemon's production database and, on a schema mismatch, crash-loop it. On a device the
        // installed profile is the only thing left to fall back to, so without this a deployed development
        // daemon silently becomes a second daemon for the installed profile.
        if let executablePath = executablePath ?? currentExecutablePath(currentDirectoryPath: currentDirectoryPath),
            let profileRoot = deployedDevelopmentProfileRoot(executablePath: executablePath)
        {
            let identity = deployedDevelopmentProfileIdentity(profileDirectoryName: profileRoot.lastPathComponent)
            return try makeProfile(
                source: .deployedDevelopmentProfile, profileRoot: profileRoot,
                databasePath: profileRoot.appendingPathComponent("spaces.db", isDirectory: false).path, environment: environment,
                homeDirectoryURL: homeDirectoryURL, currentDirectoryPath: currentDirectoryPath, fileManager: fileManager,
                branchSlug: identity?.branchSlug, worktreeHash: identity?.worktreeHash)
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
                homeDirectoryURL: homeDirectoryURL, currentDirectoryPath: currentDirectoryPath, fileManager: fileManager,
                developmentContext: developmentContext, branchSlug: branchSlug, worktreeHash: worktreeHash)
        }

        let productionRoot = installedRootDirectory(homeDirectoryURL: homeDirectoryURL)
        return try makeProfile(
            source: .installedFallback, profileRoot: productionRoot,
            databasePath: productionRoot.appendingPathComponent("spaces.db", isDirectory: false).path, environment: environment,
            homeDirectoryURL: homeDirectoryURL, currentDirectoryPath: currentDirectoryPath, fileManager: fileManager)
    }

    /// The installed profile's root for a given home directory. The single spelling of `~/.spaces`, shared by
    /// the branch that resolves onto it and the identity test that recognises it.
    public static func installedRootDirectory(homeDirectoryURL: URL) -> URL { homeDirectoryURL.appendingPathComponent(".spaces", isDirectory: true) }

    /// The single place a resolved profile becomes real: it applies the two refusals, decides whether the
    /// resolved root is the installed profile, creates the profile's directories, and builds the value.
    /// Every branch of `resolve` funnels through here, so a rule is written once and a branch added later
    /// inherits it instead of having to remember it.
    private static func makeProfile(
        source: SpacesProfileSource, profileRoot: URL, databasePath: String, environment: [String: String], homeDirectoryURL: URL,
        currentDirectoryPath: String, fileManager: FileManager, developmentContext: SpacesDevelopmentContext? = nil, branchSlug: String? = nil,
        worktreeHash: String? = nil
    ) throws -> SpacesProfile {
        // `SPACES_DB_PATH` names an EPHEMERAL throwaway profile and nothing else — a test run, an E2E
        // harness, a one-off scratch root. Both real profiles are discoverable from a binary's own location
        // with no environment at all (the installed profile by falling through to ~/.spaces, a development
        // profile from the checkout or the deployed root above the executable), so a variable pointing into
        // one of those roots is never how a real profile is meant to be named — it is a leaked binding.
        // Honouring it is what let a daemon serving ~/.spaces be classified as a development profile,
        // assign itself a development-range Device API port, persist it, and orphan every paired client.
        // It refuses loudly and unconditionally, before any directory is created. No product code sets the
        // variable, so nothing a user runs can reach this.
        if source == .explicitDatabasePath, isLiveUserProfilePath(databasePath) {
            throw SpacesProfileResolutionError.explicitDatabasePathInsideLiveUserProfile(path: databasePath)
        }

        // A test process must never resolve a profile the user's own app, daemon, or CLI is serving —
        // installed or development, and however the path was arrived at, including an inherited
        // SPACES_RUNTIME_DIR. Test targets create and mutate real terminal-session state through the
        // resolved profile, so an unisolated run writes fixture sessions into a live database and puts
        // session directories, sockets, and the daemon instance lock inside a live runtime root.
        // BOTH halves are checked because they are independent overrides: a test that binds its own
        // database but inherits a shell's runtime directory is otherwise a live profile in all but name.
        // The database half covers the branches that reach a live root with no override at all — a
        // repo-built test binary deriving its worktree profile, or a test host falling through to
        // ~/.spaces — since an explicit SPACES_DB_PATH into a live root is already refused above, for
        // every process rather than only a test one.
        // The rule is a static one about WHERE the profile is rather than whether something currently owns
        // it, so the guard cannot depend on whether the developer's app happens to be running. It refuses
        // loudly rather than redirecting to a scratch profile: a redirect would hide the missing isolation
        // and leave the test asserting against a profile it never chose. Both checks precede every side
        // effect, so a refused resolution creates no directories.
        let runtimeDirectory = runtimeDirectoryURL(environment: environment, currentDirectoryPath: currentDirectoryPath, profileRoot: profileRoot)
        if SpacesTestHost.isRunningUnderXCTest() {
            if isLiveUserProfilePath(databasePath) {
                throw SpacesProfileResolutionError.testHostRefusedLiveUserProfile(component: .database, path: databasePath)
            }
            if isLiveUserProfilePath(runtimeDirectory.path) {
                throw SpacesProfileResolutionError.testHostRefusedLiveUserProfile(component: .runtimeDirectory, path: runtimeDirectory.path)
            }
        }
        try fileManager.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        return SpacesProfile(
            source: source, databasePath: databasePath, rootDirectory: profileRoot.path,
            isInstalledProfile: canonicalPath(profileRoot.path) == canonicalPath(installedRootDirectory(homeDirectoryURL: homeDirectoryURL).path),
            runtimeDirectory: runtimeDirectory.path, ipcNotificationObject: ipcObject(profileRoot: profileRoot.path),
            developmentContext: developmentContext, branchSlug: branchSlug, worktreeHash: worktreeHash)
    }

    public static func installedDatabasePath(homeDirectoryURL: URL, fileManager: FileManager = .default) throws -> String {
        let directory = installedRootDirectory(homeDirectoryURL: homeDirectoryURL)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("spaces.db", isDirectory: false).path
    }

    /// Whether `path` — a resolved database or runtime directory — lives inside a Spaces state root that
    /// this account's own app, daemon, or CLI serves: `~/.spaces/` (installed) or `~/.spaces-dev/profiles/` (per-worktree development profiles),
    /// under the account's own home read from the password database rather than `HOME`. A test that points
    /// `HOME` at a scratch directory is already isolated and resolves normally.
    ///
    /// An unreadable password database answers `true`. That is the safety decision, not a convenience:
    /// "the account home could not be identified" must never be reported as "this is not a live profile",
    /// which would drop the protection in exactly the case where nothing can vouch for the path.
    static func isLiveUserProfilePath(_ path: String) -> Bool {
        guard let accountHomePath = accountHomeDirectoryPath() else { return true }
        let accountHome = URL(fileURLWithPath: accountHomePath, isDirectory: true)
        let liveProfileRoots = [
            accountHome.appendingPathComponent(".spaces", isDirectory: true),
            accountHome.appendingPathComponent(".spaces-dev", isDirectory: true).appendingPathComponent("profiles", isDirectory: true),
        ]
        return liveProfileRoots.contains { isPath(path, atOrUnder: $0) }
    }

    /// Path containment compared component-wise on canonical paths, INCLUSIVE of the root itself: a root
    /// like `~/.spaces` is live user state in its own right, so a profile that resolves exactly onto it is
    /// the same harm as one inside it — a test would create its session directories, sockets and instance
    /// lock directly in the live state root. Only the runtime directory can land there in practice, since
    /// a database path always names a file within a root rather than the root.
    ///
    /// A string-prefix test would report
    /// `~/.spaces-devil/spaces.db` as living under `~/.spaces-dev`, and would be defeated by a `..` segment
    /// or a symlinked route into the root; canonicalizing first and comparing whole components is neither.
    ///
    /// Components compare case-SENSITIVELY, which matches Linux, where `.SPACES` genuinely is a different
    /// directory. On a case-insensitive macOS volume that means a deliberately case-varied spelling of a
    /// live root (`~/.SPACES/spaces.db`) opens the same database without being recognised — accepted, not
    /// overlooked. This guard exists to catch a test that was never isolated, not to resist evasion, and
    /// nobody writes that spelling by accident; the only reliable way to recover the on-disk case is
    /// `URL.resourceValues(forKeys: [.canonicalPathKey])`, which requires the path to exist and so would
    /// forfeit this check running before anything is created.
    private static func isPath(_ path: String, atOrUnder root: URL) -> Bool {
        let pathComponents = URL(fileURLWithPath: canonicalPath(path)).pathComponents
        let rootComponents = URL(fileURLWithPath: canonicalPath(root.path)).pathComponents
        guard pathComponents.count >= rootComponents.count else { return false }
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
    /// the well-known port; every development profile — worktree, deployed, explicit-db — derives a distinct deterministic port
    /// so concurrent Spaces instances (multiple worktrees, or the installed app plus a dev build)
    /// don't all try to bind one port — where only the first wins and every other instance's Caddy
    /// silently fails to start, breaking its workspace-service routing.
    public var defaultRouterPort: Int { isInstalledProfile ? Self.installedRouterPort : Self.derivedRouterPort(profileRoot: rootDirectory) }

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

    /// The home this profile resolution reads from: an overridden `HOME` when it names one, otherwise the
    /// account's own home. Internal rather than private because the daemon start-plan decision has to find the
    /// LaunchAgent plist under this same home, and `NSHomeDirectory()` (which `SpacesBinaryLayout` defaults to)
    /// ignores `HOME`, so resolving the two independently would let an isolated-home process act on the real
    /// user's agent.
    static func currentHomeDirectoryURL(environment: [String: String]) -> URL {
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

    /// The development profile root a deployed executable lives inside, or `nil` when it does not live in
    /// one. A deployed development profile is recognised purely from the executable's ancestry: the
    /// consecutive path components `.spaces-dev/profiles/spaces/<name>`, where the path through `<name>` is
    /// the profile root.
    ///
    /// The match is deliberately HOME-independent. The binary's own location is the fact worth trusting: a
    /// deployed daemon inherits whatever `HOME` systemd or an SSH command handed it, so anchoring on a
    /// resolved home directory would make the same executable resolve to different profiles depending on
    /// who started it — and a test that points `HOME` at a scratch directory must not change the answer for
    /// a given path either.
    ///
    /// The OUTERMOST match wins: with a nested `.spaces-dev/profiles/spaces/...` tree, the outer sequence is
    /// the profile a deployment installed into and the inner one is content sitting inside it.
    static func deployedDevelopmentProfileRoot(executablePath: String) -> URL? {
        let components = URL(fileURLWithPath: canonicalPath(executablePath)).pathComponents
        let markers = [".spaces-dev", "profiles", "spaces"]
        // The executable is the last component and has to sit strictly inside the profile root, so the
        // marker sequence plus `<name>` must end at least one component before it.
        guard components.count >= markers.count + 2 else { return nil }
        guard let markerIndex = (0...(components.count - markers.count - 2)).first(where: { Array(components[$0..<($0 + markers.count)]) == markers })
        else { return nil }
        var rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components[1..<(markerIndex + markers.count + 1)] { rootURL.appendPathComponent(component, isDirectory: true) }
        return rootURL
    }

    /// The branch slug and worktree hash carried by a deployed profile's directory name, or `nil` when the
    /// name does not have the `<branch-slug>-<12 lowercase hex>` shape a derived development profile name
    /// has. Both halves are absent together: they are only meaningful as the pair that names the worktree
    /// this profile mirrors, and a half-parsed name would put a bogus label in the Bonjour service name.
    private static func deployedDevelopmentProfileIdentity(profileDirectoryName name: String) -> (branchSlug: String, worktreeHash: String)? {
        // Taken from the producer rather than written as a literal, so the two cannot drift apart.
        let hashLength = shortStableHash("").count
        guard name.count > hashLength + 1 else { return nil }
        let separatorIndex = name.index(name.endIndex, offsetBy: -(hashLength + 1))
        guard name[separatorIndex] == "-" else { return nil }
        let worktreeHash = name[name.index(after: separatorIndex)...]
        let lowercaseHexDigits = Set("0123456789abcdef")
        guard worktreeHash.allSatisfy(lowercaseHexDigits.contains) else { return nil }
        return (branchSlug: String(name[name.startIndex..<separatorIndex]), worktreeHash: String(worktreeHash))
    }

    /// The runtime root this profile resolves to, WITHOUT creating it. Kept separate from creating the
    /// directory so `makeProfile` can refuse a live runtime root before anything is written to disk.
    private static func runtimeDirectoryURL(environment: [String: String], currentDirectoryPath: String, profileRoot: URL) -> URL {
        if let override = trimmed(environment[runtimeDirectoryEnvironmentVariable]), !override.isEmpty {
            return absoluteFileURL(path: override, currentDirectoryPath: currentDirectoryPath)
        }
        return profileRoot.appendingPathComponent("runtime", isDirectory: true)
    }

    private static func absoluteFileURL(path: String, currentDirectoryPath: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL }
        return URL(fileURLWithPath: currentDirectoryPath, isDirectory: true).appendingPathComponent(expanded, isDirectory: false)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    private static func trimmed(_ value: String?) -> String? { value?.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Which half of a profile a refusal names. The two are independently overridable, so a caller told only
/// "a live profile" would not know which variable to change.
public enum SpacesProfileComponent: Sendable {
    case database
    case runtimeDirectory

    /// The environment variable that overrides this half.
    public var environmentVariable: String {
        switch self {
        case .database: return SpacesProfile.databasePathEnvironmentVariable
        case .runtimeDirectory: return SpacesProfile.runtimeDirectoryEnvironmentVariable
        }
    }

    public var description: String {
        switch self {
        case .database: return "database"
        case .runtimeDirectory: return "runtime directory"
        }
    }
}

/// Raised while resolving `SpacesProfile`. Every case is loud on purpose: each one describes a process that
/// would otherwise end up serving a profile that is not its own — a development build opening the installed
/// daemon's database, a test writing into live user state, or an inherited environment binding pointing a
/// daemon at another profile's root.
public enum SpacesProfileResolutionError: Error, CustomStringConvertible, LocalizedError {
    /// The git probe for a repo-built executable threw or returned no development context. Carries the
    /// executable path, the detected repo root, and the underlying git failure (when there was one).
    case repoBuiltGitProbeFailed(executablePath: String, repoRoot: String, underlyingError: (any Error)?)

    /// A test process resolved part of a profile inside one of this account's live Spaces profile roots.
    /// Names which half was refused, so a caller knows which override to change, and the refused path.
    case testHostRefusedLiveUserProfile(component: SpacesProfileComponent, path: String)

    /// `SPACES_DB_PATH` named a database inside one of this account's live Spaces profile roots. The
    /// variable points at an ephemeral throwaway profile; a real profile is identified by where the binary
    /// itself lives, never by an inherited environment binding.
    case explicitDatabasePathInsideLiveUserProfile(path: String)

    public var description: String {
        switch self {
        case .repoBuiltGitProbeFailed(let executablePath, let repoRoot, let underlyingError):
            let reason = underlyingError.map { String(describing: $0) } ?? "git probe returned no development context"
            return "repo-built executable \(executablePath) could not resolve its development profile from repo root \(repoRoot): "
                + "\(reason). Refusing to fall back to the installed profile (~/.spaces) so a development build cannot open the "
                + "installed daemon's database."
        case .testHostRefusedLiveUserProfile(let component, let path):
            return "a test process resolved \(path) as its \(component.description), which is inside one of this account's live Spaces "
                + "profile roots (~/.spaces and ~/.spaces-dev/profiles). Refusing it so tests cannot read or write a profile the app, "
                + "daemon, or CLI is serving. Isolate the test by setting \(component.environmentVariable) to a path OUTSIDE those roots "
                + "— one under the system temporary directory — for the whole test, including any work its background queues finish "
                + "later. Alternatively, pass the test's own throwaway database path explicitly to the APIs under test; explicitly "
                + "scoped calls never resolve the profile at all. Both \(SpacesProfile.databasePathEnvironmentVariable) and "
                + "\(SpacesProfile.runtimeDirectoryEnvironmentVariable) have to be isolated, or neither: binding one and inheriting the "
                + "other leaves the test half-attached to a live profile."
        case .explicitDatabasePathInsideLiveUserProfile(let path):
            return "\(SpacesProfile.databasePathEnvironmentVariable) names \(path), which is inside one of this account's live Spaces profile "
                + "roots (~/.spaces and ~/.spaces-dev/profiles). That variable points at an ephemeral throwaway profile only; the installed "
                + "and development profiles are resolved from where the running binary lives, with no environment at all. Refusing it so an "
                + "inherited binding cannot make one profile's daemon serve another's state. Unset "
                + "\(SpacesProfile.databasePathEnvironmentVariable) to run against the profile this binary belongs to, or point it at a path "
                + "OUTSIDE those roots — one under the system temporary directory — for a throwaway profile."
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

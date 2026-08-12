import Foundation
import workspacecore

// Install a hermetic git environment for the whole test process. Other helpers (notably `withMockCommands`)
// temporarily repoint `HOME`/`PATH`/`SHELL` at throwaway directories; without this, a real `git` invocation
// that overlaps such a window reads a bogus `HOME` (no identity, no `~/.gitconfig`) and fails in confusing
// ways. Pinning git's config to `/dev/null` and supplying a fixed identity makes every git call — fixtures
// and the orchestrator's `GitClient` alike — independent of ambient `HOME`/config. The values are constant,
// so applying them once, idempotently, is race-free and never needs restoring, and they never escape the
// test process into the developer's shell.
//
// The `GIT_CONFIG_*` triple disables git's background auto-maintenance (and the legacy `gc.auto` path) for
// every git invocation in the process. Object-adding commands like `git commit` otherwise kick off
// `git maintenance run --auto` in the background, which transiently creates and deletes
// `.git/objects/maintenance.lock`. The cached template repo is built once and then copied with a plain
// filesystem `copyItem`; when a copy enumerates the tree while that lock is momentarily present and git
// deletes it before the copy reaches that entry, the copy fails with ENOENT. Disabling maintenance means no
// such lock file is ever created, so template copies are race-free. Applied via `GIT_CONFIG_COUNT` so it
// layers on top of the `/dev/null` global/system config above.
let installHermeticGitEnvironment: Void = {
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
    setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
    setenv("GIT_CONFIG_COUNT", "2", 1)
    setenv("GIT_CONFIG_KEY_0", "maintenance.auto", 1)
    setenv("GIT_CONFIG_VALUE_0", "false", 1)
    setenv("GIT_CONFIG_KEY_1", "gc.auto", 1)
    setenv("GIT_CONFIG_VALUE_1", "0", 1)
    setenv("GIT_AUTHOR_NAME", "spaces-test", 1)
    setenv("GIT_AUTHOR_EMAIL", "test@example.com", 1)
    setenv("GIT_COMMITTER_NAME", "spaces-test", 1)
    setenv("GIT_COMMITTER_EMAIL", "test@example.com", 1)
    setenv("GIT_TERMINAL_PROMPT", "0", 1)
}()

// Shared git fixture helpers for workspacecore tests.
//
// Building a throwaway repository with real `git init`/`add`/`commit` costs three process spawns each time.
// Across the suite that dominates fixture setup, so a single minimal repository is initialized once per
// requested initial branch and copied (a filesystem copy, not a git spawn) for every fixture that needs a
// clean repo. Mutating tests copy their own isolated repository, so the cached template is never modified.

/// Process-wide cache of minimal initialized git repositories, keyed by initial branch name.
private final class GitTemplateRepoCache: @unchecked Sendable {
    static let shared = GitTemplateRepoCache()

    private let lock = NSLock()
    private var templatesByBranch: [String: URL] = [:]

    func templateRepo(initialBranch: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let cached = templatesByBranch[initialBranch] { return cached }

        let repo = try makeTempDirectory().appendingPathComponent("template", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", initialBranch], cwd: repo.path)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: repo.path)
        templatesByBranch[initialBranch] = repo
        return repo
    }
}

/// A fresh temporary repository named `name` with a single `init` commit on `initialBranch`.
func makeTempGitRepo(name: String, initialBranch: String = "main") throws -> URL {
    let template = try GitTemplateRepoCache.shared.templateRepo(initialBranch: initialBranch)
    let repo = try makeTempDirectory().appendingPathComponent(name, isDirectory: true)
    try FileManager.default.copyItem(at: template, to: repo)
    return repo
}

/// Initialize `directory` (created if necessary) with the same single-commit history as `makeTempGitRepo`.
func initializeGitRepository(at directory: URL, initialBranch: String = "main") throws {
    let template = try GitTemplateRepoCache.shared.templateRepo(initialBranch: initialBranch)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for item in try FileManager.default.contentsOfDirectory(at: template, includingPropertiesForKeys: nil) {
        let destination = directory.appendingPathComponent(item.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: item, to: destination)
    }
}

/// Absolute path to the system `git`, resolved once instead of relying on `/usr/bin/env git` to search
/// `PATH` at spawn time. XCTest `--parallel` runs multiple test classes in the same worker process, so a
/// sibling test's `setenv("PATH", <tempdir>)` window (e.g. `withMockCommands`,
/// `testWorkspaceSetupUsesShellCommandEnvironmentPath`) can otherwise overlap a fixture's `env git`
/// lookup and make it fail to find git at all.
private let gitExecutablePath = "/usr/bin/git"

/// Run `git` in `cwd`, returning stdout and throwing on a non-zero exit. Commit hooks can export
/// GIT_DIR/GIT_WORK_TREE for the repository being committed; tests use throwaway repositories, so those
/// inherited values are stripped to keep each git invocation scoped to the fixture under test.
@discardableResult func runGit(_ arguments: [String], cwd: String) throws -> String {
    _ = installHermeticGitEnvironment
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gitExecutablePath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    var environment = ProcessInfo.processInfo.environment
    // Force a fixed PATH rather than trusting the inherited one: a sibling test elsewhere in this
    // worker process may be mid-`setenv("PATH", <tempdir>)` when this spawns. Git itself is launched by
    // absolute path above, so this PATH only matters for subprocesses git itself may launch.
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment.removeValue(forKey: "GIT_DIR")
    environment.removeValue(forKey: "GIT_WORK_TREE")
    environment.removeValue(forKey: "GIT_INDEX_FILE")
    process.environment = environment
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()

    let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(
            domain: "spaces.tests", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(errorText)"])
    }
    return outputText
}

/// Convenience wrapper that mirrors `runGit` for call sites that read the captured stdout.
@discardableResult func runGitAndCapture(_ arguments: [String], cwd: String) throws -> String { try runGit(arguments, cwd: cwd) }

/// `WorkspaceOrchestrator` with a generous git metadata budget: on a saturated CI runner even local git
/// forks can exceed the 2s product default (`GitClient.init(metadataCommandTimeout:)`), and these tests
/// assert orchestrator behavior, not git latency. A genuinely hung git still fails, just slower.
///
/// Mirrors every parameter of `WorkspaceOrchestrator.init` except `git`, in the same order, so existing
/// `makeTestOrchestrator(...)` call sites convert to `makeTestOrchestrator(...)` by renaming the call
/// alone. Tests that need to control git behavior themselves (an explicit failure-injecting `GitClient`,
/// or an assertion about timeout behavior) should keep constructing `WorkspaceOrchestrator` directly.
func makeTestOrchestrator(
    store: SQLiteStore, projectsRootDirectory: URL? = nil, workspacesRootDirectory: URL? = nil,
    notificationDeliverer: ((String, String, String?) -> Void)? = nil,
    builtInTerminalWindowOpener: WorkspaceOrchestrator.BuiltInTerminalWindowOpener? = nil, deliversTerminalWindowOpens: Bool = true,
    builtInTerminalWindowFocuser: WorkspaceOrchestrator.BuiltInTerminalWindowFocuser? = nil,
    builtInTerminalWindowCloser: WorkspaceOrchestrator.BuiltInTerminalWindowCloser? = nil,
    builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
    builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil,
    builtInTerminalForegroundProcessSampler: WorkspaceOrchestrator.BuiltInTerminalForegroundProcessSampler? = nil,
    daemonHandoffInProgress: (@Sendable () -> Bool)? = nil, currentDate: @escaping () -> Date = Date.init
) -> WorkspaceOrchestrator {
    WorkspaceOrchestrator(
        store: store, projectsRootDirectory: projectsRootDirectory, workspacesRootDirectory: workspacesRootDirectory,
        git: GitClient(metadataCommandTimeout: 30), notificationDeliverer: notificationDeliverer,
        builtInTerminalWindowOpener: builtInTerminalWindowOpener, deliversTerminalWindowOpens: deliversTerminalWindowOpens,
        builtInTerminalWindowFocuser: builtInTerminalWindowFocuser, builtInTerminalWindowCloser: builtInTerminalWindowCloser,
        builtInTerminalSessionTerminator: builtInTerminalSessionTerminator, builtInTerminalSessionLauncher: builtInTerminalSessionLauncher,
        builtInTerminalForegroundProcessSampler: builtInTerminalForegroundProcessSampler, daemonHandoffInProgress: daemonHandoffInProgress,
        currentDate: currentDate)
}

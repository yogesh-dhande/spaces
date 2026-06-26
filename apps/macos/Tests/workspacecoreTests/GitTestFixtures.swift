import Foundation

// Install a hermetic git environment for the whole test process. Other helpers (notably `withMockCommands`)
// temporarily repoint `HOME`/`PATH`/`SHELL` at throwaway directories; without this, a real `git` invocation
// that overlaps such a window reads a bogus `HOME` (no identity, no `~/.gitconfig`) and fails in confusing
// ways. Pinning git's config to `/dev/null` and supplying a fixed identity makes every git call — fixtures
// and the orchestrator's `GitClient` alike — independent of ambient `HOME`/config. The values are constant,
// so applying them once, idempotently, is race-free and never needs restoring, and they never escape the
// test process into the developer's shell.
let installHermeticGitEnvironment: Void = {
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
    setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
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

/// Run `git` in `cwd`, returning stdout and throwing on a non-zero exit. Commit hooks can export
/// GIT_DIR/GIT_WORK_TREE for the repository being committed; tests use throwaway repositories, so those
/// inherited values are stripped to keep each git invocation scoped to the fixture under test.
@discardableResult func runGit(_ arguments: [String], cwd: String) throws -> String {
    _ = installHermeticGitEnvironment
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    var environment = ProcessInfo.processInfo.environment
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

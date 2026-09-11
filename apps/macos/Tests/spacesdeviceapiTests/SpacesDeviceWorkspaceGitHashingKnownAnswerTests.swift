import Foundation
import Testing
import spacesruntimecore

@testable import spacesdeviceapi

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Round-20: `sha256Hex`'s `#elseif canImport(OpenSSL)` branch (Linux) only compiles there, so this suite
/// only actually exercises that branch when it runs on the Linux lane (see `run_linux_tests.sh`); on macOS
/// it exercises the `CryptoKit` branch instead, which is harmless (the assertions are branch-agnostic
/// known-answer values) but does not by itself prove the Linux branch is correct. Both known-answer values
/// are the standard SHA-256 test vectors for their inputs.
@Suite struct SpacesDeviceWorkspaceGitHashingKnownAnswerTests {
    @Test func emptyInputHashesToTheStandardSHA256EmptyDigest() {
        #expect(
            SpacesDeviceWorkspaceGitHashing.sha256Hex(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test func abcHashesToItsKnownSHA256Digest() {
        #expect(
            SpacesDeviceWorkspaceGitHashing.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}

/// `repositoryPaths` resolves each RELATIVE `git rev-parse --git-path` output (the ordinary case: git
/// answers relative to the repository when the command runs inside it) against a base URL built from
/// `workspaceDir`. Without the `isDirectory: true` hint on that base, a plain `URL(fileURLWithPath:)`
/// leaves Foundation to infer directory-ness itself, and a relative output like ".git" can resolve
/// against `workspaceDir`'s PARENT instead of `workspaceDir` itself when that inference does not land the
/// way this resolution needs, silently pointing every downstream watch and read at the wrong tree.
/// Portable (Swift Testing, real git via `RemoteWorkspaceGitClient()` on PATH), so this needs to run on
/// the Linux daemon lane too; placed in this already Linux-whitelisted file rather than
/// `SpacesDeviceWorkspaceGitTests.swift` (not in `Package.swift`'s Linux `sources:` list for this target)
/// to avoid widening that list, the same reasoning `WorkspaceFileWriteModePreservationTests.swift` gives
/// for its own placement.
@Suite struct SpacesDeviceWorkspaceRepositoryPathsTests {
    /// Resolved (`realpath`) form so this fixture's own paths are unambiguous, not because
    /// `repositoryPaths` reports that spelling: it returns Foundation's `standardizedFileURL` rendering of
    /// whatever `git rev-parse` printed, and on macOS `standardizedFileURL` rewrites `/private/var/...`
    /// back to `/var/...` for `/var`, `/tmp`, and `/etc` (macOS's own default temporary directory is itself
    /// a `/var` symlink to `/private/var/...`), the opposite direction from this fixture's own realpath
    /// form. `WorkspaceWatch.realPath` is exactly the normalization that removes that mismatch (see its own
    /// doc comment), which is why it is only applied at the watch layer and not inside `repositoryPaths`
    /// itself; every assertion below runs both sides of the comparison through it so the check does not
    /// depend on which of the two spellings either side happens to produce.
    private func resolvedTemporaryDirectory() -> URL {
        let temporary = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(temporary, nil) else { return URL(fileURLWithPath: temporary, isDirectory: true) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    @discardableResult private func runGit(_ arguments: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] { environment.removeValue(forKey: key) }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            struct GitFixtureError: Error, CustomStringConvertible { let description: String }
            throw GitFixtureError(description: "git \(arguments.joined(separator: " ")) failed")
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func makeStandaloneRepository() throws -> URL {
        let root = resolvedTemporaryDirectory().appendingPathComponent(
            "spaces-repository-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch", "main"], cwd: root.path)
        try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], cwd: root.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: root.path)
        return root
    }

    @Test func aStandaloneClonesRepositoryPathsResolveUnderTheWorkspaceDirItself() throws {
        let root = try makeStandaloneRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try SpacesDeviceWorkspaceFileListEngine.repositoryPaths(
            workspaceDir: root.path, gitClient: RemoteWorkspaceGitClient(), deadlineStart: Date())

        #expect(WorkspaceWatch.realPath(paths.gitDir) == WorkspaceWatch.realPath(root.appendingPathComponent(".git").path))
        #expect(WorkspaceWatch.realPath(paths.commonDir) == WorkspaceWatch.realPath(root.appendingPathComponent(".git").path))
        #expect(WorkspaceWatch.realPath(paths.index) == WorkspaceWatch.realPath(root.appendingPathComponent(".git/index").path))
        #expect(WorkspaceWatch.realPath(paths.head) == WorkspaceWatch.realPath(root.appendingPathComponent(".git/HEAD").path))
    }

    /// A linked worktree's `--git-dir`/`--git-common-dir`/`--git-path` outputs are already ABSOLUTE (they
    /// name paths outside `workspaceDir`, under the main checkout's `.git/worktrees/<name>` and the main
    /// checkout's own `.git`), so this is what proves the `isDirectory: true` fix leaves the absolute-output
    /// case alone: a wrong base URL could only ever corrupt a relative resolution, never an absolute one.
    @Test func aLinkedWorktreesAbsoluteRepositoryPathsAreUnaffectedByTheBaseURLFix() throws {
        let main = try makeStandaloneRepository()
        defer { try? FileManager.default.removeItem(at: main) }
        let worktree = resolvedTemporaryDirectory().appendingPathComponent(
            "spaces-repository-paths-worktree-\(UUID().uuidString)", isDirectory: true)
        try runGit(["worktree", "add", "-q", "-b", "feature", worktree.path], cwd: main.path)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let paths = try SpacesDeviceWorkspaceFileListEngine.repositoryPaths(
            workspaceDir: worktree.path, gitClient: RemoteWorkspaceGitClient(), deadlineStart: Date())

        let expectedGitDir = main.appendingPathComponent(".git/worktrees/\(worktree.lastPathComponent)").path
        #expect(WorkspaceWatch.realPath(paths.gitDir) == WorkspaceWatch.realPath(expectedGitDir))
        #expect(WorkspaceWatch.realPath(paths.commonDir) == WorkspaceWatch.realPath(main.appendingPathComponent(".git").path))
        #expect(WorkspaceWatch.realPath(paths.index) == WorkspaceWatch.realPath(expectedGitDir + "/index"))
        #expect(WorkspaceWatch.realPath(paths.head) == WorkspaceWatch.realPath(expectedGitDir + "/HEAD"))
    }
}

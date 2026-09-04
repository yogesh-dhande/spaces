import Foundation
import Testing
import spacesdevicecore
import spacesruntimecore
import spacesterminalcore

@testable import spacesdeviceapi

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Fixture repositories must not inherit the repository-local Git environment exported by a
/// pre-commit hook. Those variables can redirect `git init`/`git add` into the parent checkout or
/// make an otherwise independent temporary repository use the hook's index and object database.
private func removeGitRepositoryEnvironment(from environment: inout [String: String]) {
    for key in [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_COMMON_DIR", "GIT_DIR", "GIT_GRAFT_FILE",
        "GIT_IMPLICIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_NAMESPACE", "GIT_NO_REPLACE_OBJECTS", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX",
        "GIT_REPLACE_REF_BASE", "GIT_SHALLOW_FILE", "GIT_WORK_TREE",
    ] { environment.removeValue(forKey: key) }
}

@Suite struct SpacesDeviceWorkspacePathResolverTests {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-path-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func resolvesAnExistingFileInsideTheWorkspace() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hi".write(to: workspace.appendingPathComponent("sub/file.txt"), atomically: true, encoding: .utf8)

        let resolved = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: "sub/file.txt", workspaceDir: workspace.path)
        #expect(resolved == workspace.appendingPathComponent("sub/file.txt").resolvingSymlinksInPath().path)
    }

    @Test func resolvesANonExistentCreateTargetByWalkingUpToTheNearestAncestor() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let resolved = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: "sub/new-file.txt", workspaceDir: workspace.path)
        #expect(resolved == workspace.appendingPathComponent("sub/new-file.txt").resolvingSymlinksInPath().path)
    }

    /// Leading/trailing whitespace is a legal filename character — `git` enumerates such files in diffs
    /// like any other — so the resolver must not trim `relativePath` before validating/resolving it; a
    /// trim would silently redirect a read/write to a different (likely nonexistent) path.
    @Test func resolvesAFileWithALeadingSpaceInItsName() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "hi".write(to: workspace.appendingPathComponent(" a.txt"), atomically: true, encoding: .utf8)

        let resolved = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: " a.txt", workspaceDir: workspace.path)
        #expect(resolved == workspace.appendingPathComponent(" a.txt").resolvingSymlinksInPath().path)
    }

    @Test func rejectsADotDotComponent() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        #expect(throws: SpacesDeviceWorkspacePathResolver.PathError.escapesWorkspace) {
            _ = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: "../escape.txt", workspaceDir: workspace.path)
        }
    }

    @Test func rejectsAnAbsolutePath() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        #expect(throws: SpacesDeviceWorkspacePathResolver.PathError.escapesWorkspace) {
            _ = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: "/etc/passwd", workspaceDir: workspace.path)
        }
    }

    @Test func rejectsASymlinkThatEscapesTheWorkspace() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-path-resolve-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("escape-link"), withDestinationURL: outside)

        #expect(throws: SpacesDeviceWorkspacePathResolver.PathError.escapesWorkspace) {
            _ = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: "escape-link/secret.txt", workspaceDir: workspace.path)
        }
    }

    /// A dangling symlink (the link exists; its target does not) must NOT be treated as a plain missing
    /// component: `fileManager.fileExists` follows links and reports `false` for both, so an unguarded walk
    /// would reappend the remaining components literally under the workspace root and let a create/write
    /// land outside it. This is the round-3 codex finding: the link itself must be `lstat`'d and, when it
    /// resolves outside the workspace, rejected exactly like a live escaping symlink.
    @Test func rejectsADanglingSymlinkThatResolvesOutsideTheWorkspace() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-path-resolve-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        // The link's target ("new.txt" under `outside`) does not exist -- dangling -- but still names a
        // location outside the workspace.
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("dangling-outside-link"), withDestinationURL: outside.appendingPathComponent("new.txt"))

        #expect(throws: SpacesDeviceWorkspacePathResolver.PathError.escapesWorkspace) {
            _ = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: "dangling-outside-link", workspaceDir: workspace.path)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
    }

    /// A dangling symlink whose (relative) target resolves back INSIDE the workspace must keep resolving
    /// there -- this is the "Keep mine" recreate / deleted-file read flow: an agent deletes a tracked file
    /// that other in-workspace paths symlink to, and the editor still needs to read/recreate through the
    /// link. Rejecting every dangling symlink outright (rather than resolving-and-recontaining) would break
    /// this product flow.
    @Test func resolvesADanglingSymlinkThatResolvesInsideTheWorkspace() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        // "real.txt" does not exist -- the link is dangling -- but its relative target names a location
        // inside the workspace.
        try FileManager.default.createSymbolicLink(
            atPath: workspace.appendingPathComponent("dangling-inside-link").path, withDestinationPath: "real.txt")

        let resolved = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: "dangling-inside-link", workspaceDir: workspace.path)
        #expect(resolved == workspace.appendingPathComponent("real.txt").resolvingSymlinksInPath().path)
    }

    /// A chain of dangling symlinks longer than the resolver's cap must be rejected rather than looped
    /// indefinitely or followed without bound.
    @Test func rejectsASymlinkChainExceedingTheCap() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        // Each link in the chain points to the next, none of which exist until the final one -- which
        // itself points outside the workspace, so this also confirms the cap fires before that final hop
        // would otherwise be reached.
        let linkCount = 10
        for index in 0..<linkCount {
            let linkName = "link-\(index)"
            let targetName = index == linkCount - 1 ? "/does/not/exist" : "link-\(index + 1)"
            try FileManager.default.createSymbolicLink(atPath: workspace.appendingPathComponent(linkName).path, withDestinationPath: targetName)
        }

        #expect(throws: SpacesDeviceWorkspacePathResolver.PathError.escapesWorkspace) {
            _ = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: "link-0", workspaceDir: workspace.path)
        }
    }
}

@Suite struct SpacesDeviceWorkspaceGitHashingTests {
    @Test func matchesKnownSHA256Vectors() {
        #expect(SpacesDeviceWorkspaceGitHashing.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SpacesDeviceWorkspaceGitHashing.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct SpacesDeviceWorkspaceBinaryGuessTests {
    @Test func plainTextIsNotBinary() { #expect(!SpacesDeviceWorkspaceBinaryGuess.isLikelyBinary(Data("hello world\n".utf8))) }

    @Test func dataContainingANULByteIsBinary() {
        var bytes = Data("hello".utf8)
        bytes.append(0)
        bytes.append(Data("world".utf8))
        #expect(SpacesDeviceWorkspaceBinaryGuess.isLikelyBinary(bytes))
    }
}

/// Exercises `SpacesDeviceWorkspaceDiffEngine` against real git fixture repos: the diff-building and
/// scope-signature logic shells out to the system `git`, so these fixtures are init/commit/modify repos
/// rather than mocks, matching `RemoteWorkspaceGitClientTests`' approach.
@Suite struct SpacesDeviceWorkspaceDiffEngineTests {
    /// Test-only view assembled through the production manifest-plan and per-file patch APIs. It deliberately
    /// does not retain the removed aggregate builder: product requests enumerate once, then ask for exactly
    /// the files their viewport needs.
    private struct DiffFile {
        let path: String
        let oldPath: String?
        let status: SpacesDeviceWorkspaceDiffFileStatus
        let patch: String?
        let isBinary: Bool
        let oldSHA: String?
        let newSHA: String?
        /// Mirrors the manifest chunk's `isSubmodule` (derived from the plan, before any patch is fetched).
        let isSubmodule: Bool
        /// Mirrors the patch chunk's `submodule` metadata (derived from the fetched patch text).
        let submodule: SpacesDeviceWorkspaceDiffSubmoduleChange?
    }

    private struct DiffResult {
        let scopeSignature: String
        let files: [DiffFile]
    }

    @Test func aLargeManifestResolvesEachPathAndKeepsTheFirstDuplicatePlan() {
        let first = SpacesDeviceWorkspaceDiffEngine.DiffFilePlan(path: "duplicate.md", oldPath: nil, status: .modified, source: .untracked)
        let duplicate = SpacesDeviceWorkspaceDiffEngine.DiffFilePlan(
            path: "duplicate.md", oldPath: nil, status: .deleted, source: .tracked(baseRef: "HEAD", targetRef: nil))
        let plans =
            [first]
            + (0..<10_000).map { index in
                SpacesDeviceWorkspaceDiffEngine.DiffFilePlan(
                    path: "Sources/file-" + String(index) + ".swift", oldPath: nil, status: .modified, source: .untracked)
            } + [duplicate]
        let snapshot = SpacesDeviceWorkspaceDiffEngine.DiffPlanSnapshot(scopeSignature: "signature", plans: plans)

        #expect(snapshot.plans.count == 10_002)
        #expect(snapshot.plans[10_000].path == "Sources/file-9999.swift")
        #expect(snapshot.plan(for: "duplicate.md")?.status == .modified)
        #expect(snapshot.plan(for: "Sources/file-9999.swift")?.path == "Sources/file-9999.swift")
        #expect(snapshot.plan(for: "missing.swift") == nil)
    }

    private func buildDiff(
        workspaceDir: String, refName: String?, lastCommit: Bool = false, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date = Date()
    ) throws -> DiffResult {
        let snapshot = try SpacesDeviceWorkspaceDiffEngine.buildDiffPlanSnapshot(
            workspaceDir: workspaceDir, refName: refName, lastCommit: lastCommit, gitClient: gitClient, deadlineStart: deadlineStart)
        let transferDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-diff-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transferDirectory) }
        let files = try snapshot.plans.compactMap { plan -> DiffFile? in
            let outputURL = transferDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: outputURL.path, contents: Data())
            guard
                let transfer = try SpacesDeviceWorkspaceDiffEngine.writeDiffFilePatch(
                    snapshot: snapshot, workspaceDir: workspaceDir, relativePath: plan.path, outputURL: outputURL, gitClient: gitClient,
                    deadlineStart: deadlineStart)
            else { return nil }
            // Match the chunk contract: a refused/non-produced body has no payload, not an empty text
            // patch. This is distinct from a generated patch whose textual contents happen to be empty.
            // A submodule pointer is metadata-only exactly like a binary file — see the server's patch
            // chunk guard (`transfer.file.submodule == nil`) that this ternary mirrors.
            let patch =
                transfer.file.isBinary || transfer.file.submodule != nil || transfer.patchByteCount == 0
                ? nil : String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
            return DiffFile(
                path: transfer.file.path, oldPath: transfer.file.oldPath, status: transfer.file.status, patch: patch,
                isBinary: transfer.file.isBinary, oldSHA: transfer.file.oldSHA, newSHA: transfer.file.newSHA, isSubmodule: plan.isSubmodule,
                submodule: transfer.file.submodule)
        }
        return DiffResult(scopeSignature: snapshot.scopeSignature, files: files)
    }

    @Test func scopeSignatureIsStableWhenTheWorkspaceIsIdle() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        let first = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, gitClient: client)
        let second = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, gitClient: client)
        #expect(first == second)
    }

    @Test func scopeSignatureChangesWhenAFileIsEdited() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        let before = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, gitClient: client)
        try "edited".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let after = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, gitClient: client)
        #expect(before != after)
    }

    // A chmod (e.g. `chmod +x`) on an already-dirty tracked file changes neither HEAD, the porcelain status
    // letter, size, nor mtime (chmod only touches ctime) — yet the resulting diff gains a mode-change line.
    // Folding POSIX mode into the per-file signature line is what makes a subscribed client's poll notice.
    @Test func scopeSignatureChangesWhenAnAlreadyDirtyFileIsChmoded() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        let readmePath = repo.appendingPathComponent("README.md").path

        try "edited".write(toFile: readmePath, atomically: true, encoding: .utf8)
        let before = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, gitClient: client)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readmePath)
        let after = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, gitClient: client)

        #expect(before != after)
    }

    @Test func uncommittedDiffReportsAModifiedTrackedFileAndAnUntrackedAddition() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new file content".write(to: repo.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })

        let modified = try #require(byPath["README.md"])
        #expect(modified.status == .modified)
        #expect(modified.patch?.contains("edited content") == true)

        let untracked = try #require(byPath["NEW.md"])
        #expect(untracked.status == .untracked)
        #expect(untracked.patch?.contains("new file content") == true)
    }

    // Round-10 fix 1: a freshly `git init`ed repo with no commits yet ("unborn HEAD") is still a valid git
    // project (`assertIsGitRepository` accepts it), but every `HEAD` comparison fails against it. Verified
    // empirically against real git before writing this test: `git rev-parse --verify HEAD` fails (exit 128)
    // in this state, `git hash-object -t tree /dev/null` deterministically returns the well-known SHA-1
    // empty-tree id (`4b825dc642cb6eb9a060e54bf8d69288fbee4904`), and a staged-but-uncommitted file is `A
    // ` in `git status --porcelain`, never `??` — so only diffing against the empty tree (not just scanning
    // untracked files) surfaces it.
    @Test func buildDiffOnAnUnbornRepoReportsAStagedAdditionAndAnUntrackedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-diff-engine-unborn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "--initial-branch", "main"], cwd: root.path)
        try "staged content".write(to: root.appendingPathComponent("STAGED.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "STAGED.md"], cwd: root.path)
        try "untracked content".write(to: root.appendingPathComponent("UNTRACKED.md"), atomically: true, encoding: .utf8)
        let client = RemoteWorkspaceGitClient()

        let result = try buildDiff(workspaceDir: root.path, refName: nil, gitClient: client)
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })

        let staged = try #require(byPath["STAGED.md"])
        #expect(staged.status == .added)
        #expect(staged.patch?.contains("staged content") == true)

        let untracked = try #require(byPath["UNTRACKED.md"])
        #expect(untracked.status == .untracked)
        #expect(untracked.patch?.contains("untracked content") == true)
    }

    // Round-9 fix 2: git emits a patch's raw on-disk bytes verbatim, and a file that is not valid UTF-8 is
    // still git's idea of "text" (its own binary sniff looks at content, not encoding). Verified empirically
    // against real git before writing this test: a file that is almost all ASCII plus one lone 0xE9 byte
    // (an invalid UTF-8 continuation on its own — not a valid Latin-1 -> UTF-8 multi-byte sequence either)
    // is diffed by `git diff` as ordinary text, not flagged binary. Before the fix, capturing that patch's
    // bytes through `String(data:encoding:.utf8)` returned nil for the whole capture and `?? ""` silently
    // turned it into an empty patch, hiding the change; `String(decoding:as:)` never fails, so the patch
    // still renders with a U+FFFD replacement character standing in for the invalid byte.
    @Test func aPatchWithAnInvalidUTF8ByteStillRendersInsteadOfBeingEmptied() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        let path = repo.appendingPathComponent("LATIN1.md")
        var original = Data("line one\nline two\n".utf8)
        original.append(0xE9)
        original.append(contentsOf: Data("\nline four\n".utf8))
        try original.write(to: path)
        try runGit(["add", "LATIN1.md"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add latin1 file"], cwd: repo.path)

        var edited = Data("line one\nline two\n".utf8)
        edited.append(0xE9)
        edited.append(contentsOf: Data("\nline four edited\n".utf8))
        try edited.write(to: path)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let file = try #require(result.files.first { $0.path == "LATIN1.md" })
        #expect(file.status == .modified)
        #expect(!file.isBinary)
        let patch = try #require(file.patch)
        #expect(!patch.isEmpty)
        #expect(patch.contains("@@"))
        #expect(patch.contains("line four edited"))
    }

    // `WorkspaceDiffScope` normalizes an empty/whitespace ref to nil (the uncommitted scope), so a client
    // that subscribes with such a ref must see `buildDiff` agree on the same normalization rather than
    // handing an empty argument to `git merge-base` and throwing.
    @Test func aBlankRefNameBehavesIdenticallyToANilRefName() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new file content".write(to: repo.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)

        let nilResult = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let blankResult = try buildDiff(workspaceDir: repo.path, refName: "   ", gitClient: client)

        #expect(nilResult.scopeSignature == blankResult.scopeSignature)
        #expect(Set(nilResult.files.map(\.path)) == Set(blankResult.files.map(\.path)))
        #expect(Set(blankResult.files.map(\.path)) == ["README.md", "NEW.md"])
    }

    // `git diff -M` (which `buildDiff` shells out to for tracked changes) only pairs a rename when both
    // sides are in the index: it never compares a tracked deletion against an untracked file, so a plain
    // filesystem `mv` with no `git add` shows as a `.deleted` tracked file plus a separately-enumerated
    // `.untracked` addition, not a single `.renamed` entry. Staging first (`git add -A`) is the only way
    // this repo's diff engine can ever produce `.renamed`, so that is what this test exercises.
    @Test func aStagedRenameIsDetectedAsARenamedFileWithItsOldPath() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try FileManager.default.moveItem(at: repo.appendingPathComponent("README.md"), to: repo.appendingPathComponent("RENAMED.md"))
        try runGit(["add", "-A"], cwd: repo.path)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let renamed = try #require(result.files.first { $0.path == "RENAMED.md" })
        #expect(renamed.status == .renamed)
        #expect(renamed.oldPath == "README.md")
    }

    // Documents the gap above directly: an unstaged rename is NOT reported as `.renamed` today. It is one
    // `.deleted` tracked file (README.md) plus one `.untracked` addition (RENAMED.md) with the full new
    // content as its patch — correct information, just not identified as a rename.
    @Test func anUnstagedRenameIsNotDetectedAsARenameYet() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try FileManager.default.moveItem(at: repo.appendingPathComponent("README.md"), to: repo.appendingPathComponent("RENAMED.md"))

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })
        #expect(byPath["README.md"]?.status == .deleted)
        #expect(byPath["RENAMED.md"]?.status == .untracked)
        #expect(byPath["RENAMED.md"]?.oldPath == nil)
    }

    @Test func refNameScopeDiffsTheMergeBaseAndIncludesUncommittedChanges() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try runGit(["checkout", "-b", "feature"], cwd: repo.path)
        try "feature content".write(to: repo.appendingPathComponent("FEATURE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "FEATURE.md"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "feature"], cwd: repo.path)
        // Uncommitted change on top of the feature branch, made after branching from main.
        try "uncommitted".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: "main", gitClient: client)
        let paths = Set(result.files.map(\.path))
        // Against `main`'s merge-base, the diff must show both the committed feature-branch file and the
        // still-uncommitted README edit, since the working tree (not HEAD) is the right-hand side.
        #expect(paths.contains("FEATURE.md"))
        #expect(paths.contains("README.md"))
    }

    @Test func mergeBaseMovingChangesTheRefScopedSignature() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try runGit(["checkout", "-b", "feature"], cwd: repo.path)
        try "feature content".write(to: repo.appendingPathComponent("FEATURE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "FEATURE.md"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "feature"], cwd: repo.path)

        let before = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, refName: "main", gitClient: client)

        // Merging `feature` into `main` makes feature's own tip an ancestor of main, so
        // `merge-base(main, feature)` moves forward from the original divergence commit to that tip.
        try runGit(["checkout", "main"], cwd: repo.path)
        try runGit(["merge", "--no-ff", "feature", "-m", "merge feature"], cwd: repo.path)
        try runGit(["checkout", "feature"], cwd: repo.path)

        let after = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, refName: "main", gitClient: client)
        #expect(before != after)
    }

    @Test func baseAdvancingWithoutMovingTheMergeBaseLeavesTheRefScopedSignatureUnchanged() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try runGit(["checkout", "-b", "feature"], cwd: repo.path)
        try "feature content".write(to: repo.appendingPathComponent("FEATURE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "FEATURE.md"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "feature"], cwd: repo.path)

        let before = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, refName: "main", gitClient: client)

        // An unrelated commit on `main` that does not merge `feature` leaves their common ancestor (the
        // original divergence commit) unchanged, so the ref-scoped signature must not change either.
        try runGit(["checkout", "main"], cwd: repo.path)
        try "unrelated".write(to: repo.appendingPathComponent("OTHER.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "OTHER.md"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "unrelated"], cwd: repo.path)
        try runGit(["checkout", "feature"], cwd: repo.path)

        let after = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, refName: "main", gitClient: client)
        #expect(before == after)
    }

    @Test func aLargeUntrackedFileProducesAPatchWithoutAnAggregateCap() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        // The production path writes the patch to a daemon-owned file and sends fixed-size ranges, so a
        // large untracked file remains renderable instead of exposing the former aggregate cap.
        let oversizedContent = String(repeating: "y", count: 1 * 1024 * 1024 + 1024)
        try oversizedContent.write(to: repo.appendingPathComponent("HUGE.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let file = try #require(result.files.first { $0.path == "HUGE.md" })
        #expect(file.status == .untracked)
        #expect(file.patch?.contains("yyyy") == true)
    }

    // A modified regular file and a staged rename-with-score (`Rnnn`, not the bare `R100` a pure
    // no-content-change rename would produce) are the two non-gitlink shapes `--raw -z` reports; both
    // sides of the `:<srcmode> <dstmode> ...` header are ordinary file modes here, so neither must be
    // flagged as a submodule pointer. The gitlink-flagged shapes (added/modified) are covered by the
    // submodule-specific tests below, each of which asserts `isSubmodule == true` on its own gitlink entry.
    @Test func rawDiffParsingLeavesRegularFileEntriesUnflaggedAsSubmodules() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try "line1\nline2\nline3\nline4\nline5\n".write(to: repo.appendingPathComponent("MULTI.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "MULTI.md"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add multi"], cwd: repo.path)

        try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try FileManager.default.moveItem(at: repo.appendingPathComponent("MULTI.md"), to: repo.appendingPathComponent("RENAMED.md"))
        try "line1\nline2\nline3\nline4\nline5\nline6\n".write(to: repo.appendingPathComponent("RENAMED.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], cwd: repo.path)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })

        let modified = try #require(byPath["README.md"])
        #expect(modified.status == .modified)
        #expect(modified.isSubmodule == false)
        #expect(modified.submodule == nil)

        let renamed = try #require(byPath["RENAMED.md"])
        #expect(renamed.status == .renamed)
        #expect(renamed.oldPath == "MULTI.md")
        #expect(renamed.isSubmodule == false)
        #expect(renamed.submodule == nil)
    }

    // `git status --untracked-files=all` still reports a wholly untracked, un-`submodule add`ed nested
    // git repository as one collapsed `?? dir/` record (see `scopeSnapshot`'s untracked-path filter) —
    // there is no product representation for "an entire nested repository, untracked", so it must not
    // appear in the diff at all, gitlink or otherwise.
    @Test func anUntrackedNestedGitRepositoryDoesNotAppearInTheDiff() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let nested = repo.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch", "main"], cwd: nested.path)
        try "hi".write(to: nested.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "f.txt"], cwd: nested.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "nested initial"], cwd: nested.path)
        let client = RemoteWorkspaceGitClient()

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)

        #expect(!result.files.contains { $0.path.hasPrefix("nested") })
    }

    // `submodule add` records the submodule's clone-time `HEAD` as the gitlink's pointer; the commit that
    // adds it has no prior pointer to compare against.
    @Test func submoduleAddedInTheLastCommitReportsNoOldCommit() throws {
        let (superRoot, _, subrepoSHA1) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, lastCommit: true, gitClient: client)
        let sub = try #require(result.files.first { $0.path == "sub" })
        #expect(sub.status == .added)
        #expect(sub.isSubmodule == true)
        #expect(sub.patch == nil)
        let change = try #require(sub.submodule)
        #expect(change.oldCommit == nil)
        #expect(change.newCommit == subrepoSHA1)
        #expect(change.dirty == false)

        // `.gitmodules` is an ordinary tracked text file alongside the gitlink, not itself a pointer.
        let gitmodules = try #require(result.files.first { $0.path == ".gitmodules" })
        #expect(gitmodules.isSubmodule == false)
        #expect(gitmodules.submodule == nil)
    }

    // Replacing a submodule with a regular file at the same path is a git type change (`T`, modes
    // `160000` -> `100644`). Only one side is a gitlink, so the entry stays an ordinary text patch that
    // shows the file's content instead of a pointer row that would hide it.
    @Test func submoduleReplacedByARegularFileIsListedAsAnOrdinaryTextPatch() throws {
        let (superRoot, _, _) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        try runGit(["rm", "-q", "sub"], cwd: superRoot.path)
        try "vendored content\n".write(to: superRoot.appendingPathComponent("sub"), atomically: true, encoding: .utf8)
        try runGit(["add", "sub"], cwd: superRoot.path)

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, gitClient: client)
        let sub = try #require(result.files.first { $0.path == "sub" })
        #expect(sub.isSubmodule == false)
        #expect(sub.submodule == nil)
        let patch = try #require(sub.patch)
        #expect(patch.contains("+vendored content"))
    }

    // The reverse type change: a regular file replaced by a submodule at the same path (`T`, modes
    // `100644` -> `160000`). The destination side is the gitlink here, so this lands on the same pointer
    // row as an ordinary submodule add, not a text patch the Editor would try to read as a directory.
    // `baseCommit` is nil because the source side is a blob, not a commit; the patch's lone
    // `+Subproject commit` line supplies the new commit.
    @Test func aRegularFileReplacedByASubmoduleIsListedAsAPointerRow() throws {
        let (superRoot, subrepo, subrepoSHA1) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        try "vendored content\n".write(to: superRoot.appendingPathComponent("vendored"), atomically: true, encoding: .utf8)
        try runGit(["add", "vendored"], cwd: superRoot.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add vendored file"], cwd: superRoot.path)

        try runGit(["rm", "-q", "vendored"], cwd: superRoot.path)
        try runGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", subrepo.path, "vendored"], cwd: superRoot.path)

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, gitClient: client)
        let vendored = try #require(result.files.first { $0.path == "vendored" })
        #expect(vendored.status == .modified)
        #expect(vendored.isSubmodule == true)
        #expect(vendored.patch == nil)
        let change = try #require(vendored.submodule)
        #expect(change.oldCommit == nil)
        #expect(change.newCommit == subrepoSHA1)
        #expect(change.dirty == false)
    }

    // A submodule renamed without moving its pointer (`git mv sub renamed-sub`, nothing else changed) is a
    // pure rename: git's raw listing reports `R100`, but the per-file patch carries NO `Subproject commit`
    // lines at all — confirmed empirically, `--submodule=short` only prints those lines when the pointer
    // itself changed. The patch alone can therefore never supply either commit id for this case;
    // `parsePatchMetadata` falls back to `--raw`'s base-side commit (`Gitlink.baseCommit`, always real
    // except for an add) and reports it on both sides, since `R100` means the pointer is unchanged.
    @Test func submoduleRenamedWithoutMovingItsPointerKeepsBothCommitIds() throws {
        let (superRoot, _, subrepoSHA1) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        try runGit(["mv", "sub", "renamed-sub"], cwd: superRoot.path)

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, gitClient: client)
        let sub = try #require(result.files.first { $0.path == "renamed-sub" })
        #expect(sub.status == .renamed)
        #expect(sub.oldPath == "sub")
        #expect(sub.isSubmodule == true)
        #expect(sub.patch == nil)
        let change = try #require(sub.submodule)
        #expect(change.oldCommit == subrepoSHA1)
        #expect(change.newCommit == subrepoSHA1)
        #expect(change.dirty == false)
    }

    // The submodule's own worktree can be dirty (edited, uncommitted) without its checked-out commit ever
    // moving away from the pointer recorded in the superproject's `HEAD`. Verified empirically: git's raw
    // listing reports identical src/dst gitlink shas in this case, and the patch's `+Subproject commit`
    // line alone carries the `-dirty` suffix — there is no `index` line at all, which is why
    // `parsePatchMetadata` must gate submodule parsing on the plan's `gitlink` value (known from `--raw`
    // before the patch is even fetched) rather than sniffing for an `index` line as the binary/text path does.
    @Test func submoduleDirtyWorktreeWithNoPointerBumpReportsTheSameOldAndNewCommit() throws {
        let (superRoot, _, subrepoSHA1) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        try "sub v1 - dirty edit".write(to: superRoot.appendingPathComponent("sub/FILE.txt"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, gitClient: client)
        let sub = try #require(result.files.first { $0.path == "sub" })
        #expect(sub.status == .modified)
        #expect(sub.isSubmodule == true)
        #expect(sub.patch == nil)
        let change = try #require(sub.submodule)
        #expect(change.oldCommit == subrepoSHA1)
        #expect(change.newCommit == subrepoSHA1)
        #expect(change.dirty == true)
        // Pins the default: an ordinary dirty-but-unmoved pointer is not a merge conflict.
        #expect(change.unmerged == false)
    }

    // An unstaged pointer move (`git checkout <sha>` inside the submodule, with no `git add sub` in the
    // superproject) is the case `--raw`'s own object ids cannot represent: verified empirically, the raw
    // destination-side id comes back all zeros, identical to an absent side, which is why this engine never
    // reads it for a gitlink. The patch's `Subproject commit` lines report the real old/new commits
    // correctly regardless of whether the bump was staged, so `dirty == false` and both endpoints resolve.
    @Test func submoduleCheckedOutAtAnotherCommitWithoutStagingReportsBothCommits() throws {
        let (superRoot, subrepo, subrepoSHA1) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        let subrepoSHA2 = try commitSecondSubrepoRevision(subrepo: subrepo)
        let subCheckout = superRoot.appendingPathComponent("sub")
        // The checkout was cloned before the second source commit existed; fetch it in before switching.
        try runGit(["fetch", "-q", "origin"], cwd: subCheckout.path)
        try runGit(["checkout", "-q", subrepoSHA2], cwd: subCheckout.path)

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, gitClient: client)
        let sub = try #require(result.files.first { $0.path == "sub" })
        #expect(sub.status == .modified)
        #expect(sub.isSubmodule == true)
        #expect(sub.patch == nil)
        let change = try #require(sub.submodule)
        #expect(change.oldCommit == subrepoSHA1)
        #expect(change.newCommit == subrepoSHA2)
        #expect(change.dirty == false)
    }

    // The top-level submodule directory's own size/mtime/mode do not move when a checkout only rewrites
    // files below a nested directory, and the porcelain letter stays ` M`, so `scopeSignature` must carry
    // the submodule's worktree pointer itself, not just the directory's stat.
    @Test func scopeSignatureChangesWhenASubmoduleCheckoutMovesToACommitThatOnlyTouchesNestedFiles() throws {
        let (superRoot, subrepo, _) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        try FileManager.default.createDirectory(at: subrepo.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "deep v2".write(to: subrepo.appendingPathComponent("nested/deep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "nested/deep.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "nested v2"], cwd: subrepo.path)
        let subrepoSHA2 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        try "deep v3".write(to: subrepo.appendingPathComponent("nested/deep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "nested/deep.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "nested v3"], cwd: subrepo.path)
        let subrepoSHA3 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        let subCheckout = superRoot.appendingPathComponent("sub")
        // The checkout was cloned before these source commits existed; fetch them in before switching.
        try runGit(["fetch", "-q", "origin"], cwd: subCheckout.path)
        try runGit(["checkout", "-q", subrepoSHA2], cwd: subCheckout.path)

        let before = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: superRoot.path, gitClient: client)
        try runGit(["checkout", "-q", subrepoSHA3], cwd: subCheckout.path)
        let after = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: superRoot.path, gitClient: client)

        #expect(before != after)
    }

    // The dirty marker on the pointer row comes from the submodule's own worktree state, which the
    // superproject's directory stat cannot see: an edit to a file nested inside an already pointer-bumped
    // submodule checkout changes neither the `sub` directory's size/mtime/mode nor its porcelain letter.
    @Test func scopeSignatureChangesWhenAFileNestedInsideASubmoduleIsEdited() throws {
        let (superRoot, subrepo, _) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        try FileManager.default.createDirectory(at: subrepo.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "deep v2".write(to: subrepo.appendingPathComponent("nested/deep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "nested/deep.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "nested v2"], cwd: subrepo.path)
        let subrepoSHA2 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        let subCheckout = superRoot.appendingPathComponent("sub")
        // The checkout was cloned before this source commit existed; fetch it in before switching. This
        // leaves the pointer differing from the recorded one, so the row is `Submodule <sha1> -> <sha2>`.
        try runGit(["fetch", "-q", "origin"], cwd: subCheckout.path)
        try runGit(["checkout", "-q", subrepoSHA2], cwd: subCheckout.path)

        let before = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: superRoot.path, gitClient: client)
        // An uncommitted edit inside the submodule, which turns the row's `(dirty)` suffix on.
        try "deep edited".write(to: subCheckout.appendingPathComponent("nested/deep.txt"), atomically: true, encoding: .utf8)
        let after = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: superRoot.path, gitClient: client)

        #expect(before != after)
    }

    // With the pointer staged both times, porcelain reads `M  sub` before and after, the directory stat
    // does not move, and an index-to-worktree diff is empty both times (the worktree pointer equals the
    // staged pointer in both snapshots). Only a HEAD-to-worktree diff sees the pointer change, which is why
    // `scopeSnapshot` names `headSHA` as the revision rather than leaving the comparison at git's default.
    @Test func scopeSignatureChangesWhenAStagedSubmodulePointerIsRestagedAtAnotherCommit() throws {
        let (superRoot, subrepo, _) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        try FileManager.default.createDirectory(at: subrepo.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "deep v2".write(to: subrepo.appendingPathComponent("nested/deep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "nested/deep.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "nested v2"], cwd: subrepo.path)
        let subrepoSHA2 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        try "deep v3".write(to: subrepo.appendingPathComponent("nested/deep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "nested/deep.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "nested v3"], cwd: subrepo.path)
        let subrepoSHA3 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        let subCheckout = superRoot.appendingPathComponent("sub")
        // The checkout was cloned before these source commits existed; fetch them in before switching.
        try runGit(["fetch", "-q", "origin"], cwd: subCheckout.path)
        try runGit(["checkout", "-q", subrepoSHA2], cwd: subCheckout.path)
        try runGit(["add", "sub"], cwd: superRoot.path)

        let before = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: superRoot.path, gitClient: client)
        try runGit(["checkout", "-q", subrepoSHA3], cwd: subCheckout.path)
        try runGit(["add", "sub"], cwd: superRoot.path)
        let after = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: superRoot.path, gitClient: client)

        #expect(before != after)
    }

    // The unborn-HEAD variant of the restaging case: a superproject with no commits yet, whose submodule is
    // staged (`A  sub`) and then restaged at another commit. There is no HEAD to diff against, and an
    // index-to-worktree diff is empty both times, so `scopeSnapshot` must compare against the empty tree,
    // the same base the plan builder renders that state against (`Submodule added <sha>`).
    @Test func scopeSignatureChangesWhenASubmoduleStagedInAnUnbornRepoIsRestagedAtAnotherCommit() throws {
        let (committedSuperRoot, subrepo, _) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: committedSuperRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        try FileManager.default.createDirectory(at: subrepo.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "deep v2".write(to: subrepo.appendingPathComponent("nested/deep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "nested/deep.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "nested v2"], cwd: subrepo.path)
        let subrepoSHA2 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)
        try "deep v3".write(to: subrepo.appendingPathComponent("nested/deep.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "nested/deep.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "nested v3"], cwd: subrepo.path)
        let subrepoSHA3 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        let unbornRoot = committedSuperRoot.deletingLastPathComponent().appendingPathComponent("unborn-super", isDirectory: true)
        try FileManager.default.createDirectory(at: unbornRoot, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch", "main"], cwd: unbornRoot.path)
        try runGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", subrepo.path, "sub"], cwd: unbornRoot.path)
        let subCheckout = unbornRoot.appendingPathComponent("sub")
        try runGit(["checkout", "-q", subrepoSHA2], cwd: subCheckout.path)
        try runGit(["add", "sub"], cwd: unbornRoot.path)

        let before = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: unbornRoot.path, gitClient: client)
        try runGit(["checkout", "-q", subrepoSHA3], cwd: subCheckout.path)
        try runGit(["add", "sub"], cwd: unbornRoot.path)
        let after = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: unbornRoot.path, gitClient: client)

        #expect(before != after)
    }

    // A rename combined with a dirty (but not moved) submodule worktree: `git mv sub renamed-sub` followed
    // by an uncommitted edit inside the renamed checkout. Git's raw listing still reports `R100`, but this
    // time the patch DOES carry `Subproject commit` lines — confirmed empirically, only a pointer-preserving
    // rename with a CLEAN worktree omits them — so the real commits and the dirty flag come from the patch,
    // not from the rename fallback in `submoduleRenamedWithoutMovingItsPointerKeepsBothCommitIds` above.
    @Test func submoduleRenamedWithADirtyWorktreeReportsDirty() throws {
        let (superRoot, _, subrepoSHA1) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        try runGit(["mv", "sub", "renamed-sub"], cwd: superRoot.path)
        try "renamed sub - dirty edit".write(
            to: superRoot.appendingPathComponent("renamed-sub/FILE.txt"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, gitClient: client)
        let sub = try #require(result.files.first { $0.path == "renamed-sub" })
        #expect(sub.status == .renamed)
        #expect(sub.oldPath == "sub")
        #expect(sub.isSubmodule == true)
        #expect(sub.patch == nil)
        let change = try #require(sub.submodule)
        #expect(change.oldCommit == subrepoSHA1)
        #expect(change.newCommit == subrepoSHA1)
        #expect(change.dirty == true)
    }

    // A pointer bump (staged, via `git add sub` inside the superproject) with further uncommitted edits on
    // top of the newly checked-out commit reports both endpoints plus `dirty`: the old side is the clean
    // pointer recorded in `HEAD` (never dirty — it is a fixed commit id, not a worktree), the new side is
    // the submodule's current checkout with its own `-dirty` suffix.
    @Test func submodulePointerBumpedAndDirtyInTheUncommittedScopeReportsBothCommitsAndDirty() throws {
        let (superRoot, subrepo, subrepoSHA1) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        let subrepoSHA2 = try commitSecondSubrepoRevision(subrepo: subrepo)
        let subCheckout = superRoot.appendingPathComponent("sub")
        // The checkout was cloned before the second source commit existed; fetch it in before switching.
        try runGit(["fetch", "-q", "origin"], cwd: subCheckout.path)
        try runGit(["checkout", "-q", subrepoSHA2], cwd: subCheckout.path)
        try runGit(["add", "sub"], cwd: superRoot.path)
        try "sub v2 - dirty edit".write(to: subCheckout.appendingPathComponent("FILE.txt"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, gitClient: client)
        let sub = try #require(result.files.first { $0.path == "sub" })
        #expect(sub.status == .modified)
        #expect(sub.isSubmodule == true)
        #expect(sub.patch == nil)
        let change = try #require(sub.submodule)
        #expect(change.oldCommit == subrepoSHA1)
        #expect(change.newCommit == subrepoSHA2)
        #expect(change.dirty == true)
    }

    // Once the pointer bump is itself committed in the superproject, the `lastCommit` scope reports it as
    // an ordinary committed change: both endpoints set, `dirty == false` (the submodule worktree at commit
    // time was clean — nothing uncommitted survives into a commit).
    @Test func submodulePointerBumpCommittedIsReportedInTheLastCommitScope() throws {
        let (superRoot, subrepo, subrepoSHA1) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        let subrepoSHA2 = try commitSecondSubrepoRevision(subrepo: subrepo)
        let subCheckout = superRoot.appendingPathComponent("sub")
        // The checkout was cloned before the second source commit existed; fetch it in before switching.
        try runGit(["fetch", "-q", "origin"], cwd: subCheckout.path)
        try runGit(["checkout", "-q", subrepoSHA2], cwd: subCheckout.path)
        try runGit(["add", "sub"], cwd: superRoot.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "bump submodule"], cwd: superRoot.path)

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, lastCommit: true, gitClient: client)
        let sub = try #require(result.files.first { $0.path == "sub" })
        #expect(sub.status == .modified)
        #expect(sub.isSubmodule == true)
        #expect(sub.patch == nil)
        let change = try #require(sub.submodule)
        #expect(change.oldCommit == subrepoSHA1)
        #expect(change.newCommit == subrepoSHA2)
        #expect(change.dirty == false)
    }

    // A conflicting merge of two superproject branches that each bump the same submodule pointer to
    // DIVERGING subrepo commits (siblings, neither a fast-forward of the other) leaves `sub` in git's
    // unresolved-conflict index state (`git status` reports `UU sub`). Verified empirically: the raw
    // listing's destination side comes back all zeros for this case (exactly like an unstaged pointer
    // move), and the per-file patch is EMPTY (exactly like a pointer-preserving rename's, see `Gitlink`'s
    // doc comment). Without `unmerged`, `submoduleChange`'s rename fallback would misreport this as an
    // unchanged pointer, hiding the conflict from the Editor entirely.
    @Test func submodulePointerLeftUnmergedByAConflictingMergeIsReportedUnmerged() throws {
        let (superRoot, subrepo, _) = try makeRepoWithSubmodule()
        defer { try? FileManager.default.removeItem(at: superRoot.deletingLastPathComponent()) }
        let client = RemoteWorkspaceGitClient()

        // Two diverging children of S1 in the standalone subrepo: S2 on a side branch, S3 back on main.
        try runGit(["checkout", "-q", "-b", "b2"], cwd: subrepo.path)
        try "sub v2 on b2".write(to: subrepo.appendingPathComponent("FILE.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "FILE.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "sub v2 on b2"], cwd: subrepo.path)
        let subrepoSHA2 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        try runGit(["checkout", "-q", "main"], cwd: subrepo.path)
        try "sub v3 on main".write(to: subrepo.appendingPathComponent("FILE.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "FILE.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "sub v3 on main"], cwd: subrepo.path)
        let subrepoSHA3 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        let subCheckout = superRoot.appendingPathComponent("sub")
        // One fetch of the local "origin" (the standalone subrepo) brings in both new commits, since they
        // sit on two different branches there.
        try runGit(["fetch", "-q", "origin"], cwd: subCheckout.path)

        // Superproject branch "left" bumps the pointer to S2.
        try runGit(["checkout", "-q", "-b", "left"], cwd: superRoot.path)
        try runGit(["checkout", "-q", subrepoSHA2], cwd: subCheckout.path)
        try runGit(["add", "sub"], cwd: superRoot.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "bump sub to S2 on left"], cwd: superRoot.path)

        // "main" bumps the same pointer to the diverging S3 instead.
        try runGit(["checkout", "-q", "main"], cwd: superRoot.path)
        try runGit(["checkout", "-q", subrepoSHA3], cwd: subCheckout.path)
        try runGit(["add", "sub"], cwd: superRoot.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "bump sub to S3 on main"], cwd: superRoot.path)

        // Neither side is an ancestor of the other, so git cannot resolve the gitlink on its own: the
        // merge is expected to stop with a conflict, not to succeed.
        let mergeStatus = try runGitAllowingFailure(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "-c", "core.editor=true", "merge", "left"],
            cwd: superRoot.path)
        #expect(mergeStatus != 0)
        let status = try runGit(["status", "--porcelain"], cwd: superRoot.path)
        #expect(status.contains("UU sub"))

        let result = try buildDiff(workspaceDir: superRoot.path, refName: nil, gitClient: client)
        let sub = try #require(result.files.first { $0.path == "sub" })
        #expect(sub.status == .modified)
        #expect(sub.isSubmodule == true)
        #expect(sub.patch == nil)
        let change = try #require(sub.submodule)
        #expect(change.unmerged == true)
        // HEAD (still "main", since the failed merge never committed) has sub at S3; that is the pointer
        // the worktree currently holds and what the fallback reports on both sides.
        #expect(change.oldCommit == subrepoSHA3)
        #expect(change.newCommit == subrepoSHA3)
        #expect(change.dirty == false)
    }

    // Round-9 fix 3: `buildDiff` now tracks a 45s request-wide deadline (`diffBuildDeadline`) alongside the
    // existing per-file/total-byte caps, reusing the same `truncated` shape once elapsed time crosses it.
    // There is no seam to inject a shorter deadline without adding test-only surface area to the engine's
    // public API, which the round-9 spec explicitly forbids ("Do NOT add a configurable deadline parameter
    // to the public API") — so the 45s cutoff itself has no automated trigger test here. This test instead
    // covers the regression the deadline could introduce: an ordinary small diff, which finishes in
    // milliseconds, must come back exactly as before (no file marked `truncated`), proving the per-loop-
    // iteration deadline check does not misfire for a request nowhere near 45s.
    //
    // Round-12: the per-loop-iteration check is now `remainingTimeout(start:)` itself (via `try?`), which
    // both re-checks the deadline and computes the shrunk-to-the-remaining-budget timeout that `buildFile`/
    // `buildUntrackedFile` pass into their own git captures — round 10 only threaded the budget into
    // `buildDiff`'s up-front commands (merge-base, the raw diff listing, the untracked status scan); round 12 extends
    // the same threading to each file's own patch capture, so a file whose git only starts near the end of
    // the 45s budget gets a correspondingly shrunk timeout instead of a fresh flat 30s. Same seam problem as
    // rounds 9/10 applies here too: proving a per-file capture actually receives a shrunk timeout requires
    // either a configurable deadline (forbidden) or waiting most of the real 45s (too slow/flaky to run in
    // this suite), so there is deliberately no trigger test for the per-file threading either — this test's
    // coverage (an ordinary, fast diff comes back with nothing truncated) already exercises the `buildFile`/
    // `buildUntrackedFile` call sites with the new `timeout:` parameter on the non-expired path, which is the
    // only path a hermetic, fast unit test can reach.
    @Test func anOrdinarySmallDiffIsUnaffectedByTheRequestDeadline() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new file content".write(to: repo.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        #expect(result.files.count == 2)
        for file in result.files { #expect(file.patch != nil) }
    }

    @Test func aNonASCIIFilenameRoundTripsItsExactPathWithAPatch() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        let name = "café.txt"
        try "hi".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try runGit(["add", name], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "add cafe"], cwd: repo.path)
        try "modified".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)

        // The -z name-status output is exact bytes even though the filename is non-ASCII; identity must
        // come from there, not from a (potentially C-quoted) `diff --git a/... b/...` header.
        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let file = try #require(result.files.first { $0.path == name })
        #expect(file.status == .modified)
        #expect(file.patch?.isEmpty == false)
    }

    @Test func aWorkspaceWithNoChangesReportsNoFiles() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        #expect(result.files.isEmpty)
    }

    // `git status`'s default `--untracked-files=normal` collapses every file inside a wholly-untracked
    // directory into one `?? dir/` record. Without `--untracked-files=all` this fixture would report a
    // single meaningless "directory" pseudo-file instead of the two files actually inside it.
    @Test func anUntrackedDirectoryWithTwoFilesReportsBothFilesAndNoDirectoryEntry() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try FileManager.default.createDirectory(at: repo.appendingPathComponent("newdir"), withIntermediateDirectories: true)
        try "one".write(to: repo.appendingPathComponent("newdir/one.md"), atomically: true, encoding: .utf8)
        try "two".write(to: repo.appendingPathComponent("newdir/two.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })

        let one = try #require(byPath["newdir/one.md"])
        #expect(one.status == .untracked)
        #expect(one.patch?.contains("one") == true)

        let two = try #require(byPath["newdir/two.md"])
        #expect(two.status == .untracked)
        #expect(two.patch?.contains("two") == true)

        #expect(!result.files.contains { $0.path.hasSuffix("/") })
        #expect(byPath["newdir/"] == nil)
        #expect(byPath["newdir"] == nil)
    }

    // `attributesOfItem` (lstat) reports a symlink's own type/size, never its target's, but opening it for
    // the binary sniff follows the link. Left unguarded, an untracked symlink to binary content would sniff
    // the target's bytes and misreport `isBinary: true` with no patch, even though `git diff --no-index`
    // treats the symlink itself as a tiny text patch naming the target path (mode 120000).
    @Test func anUntrackedSymlinkToBinaryContentYieldsATextPatchNamingTheTarget() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try Data([0x00, 0x01, 0x02, 0x00]).write(to: repo.appendingPathComponent("BINARY.bin"))
        try runGit(["add", "BINARY.bin"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "add binary"], cwd: repo.path)

        let linkPath = repo.appendingPathComponent("LINK-TO-BINARY")
        try FileManager.default.createSymbolicLink(atPath: linkPath.path, withDestinationPath: "BINARY.bin")

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let link = try #require(result.files.first { $0.path == "LINK-TO-BINARY" })

        #expect(link.status == .untracked)
        #expect(link.isBinary == false)
        #expect(link.patch?.contains("BINARY.bin") == true)
    }

    // A bare untracked FIFO never reaches `buildUntrackedFile` at all: `git status --porcelain
    // --untracked-files=all` itself silently omits any non-regular/non-symlink filesystem entry from its
    // untracked-file scan (verified directly against the system git — a `mkfifo`'d file produces zero
    // status output), so it can never appear in `changedEntries`'s `??` records. The actual reachable danger
    // is a *symlink* to a FIFO: `git status` reports a symlink like any other untracked path (lstat sees a
    // normal directory entry), and — contrary to the "symlink diffs as its own target-path text, never its
    // target" assumption — `git diff --no-index` itself was confirmed (empirically, independent of output
    // flags or argument order) to still block indefinitely when a symlink argument's target is a FIFO. So
    // this is the scenario that must be refused before ever reaching git, and `buildDiff` must return
    // promptly with the symlink as a bare untracked entry and every other file in the diff unaffected.
    @Test func anUntrackedSymlinkToAFIFOLeavesBuildDiffPromptAndOtherFilesUnaffected() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        let fifoPath = repo.appendingPathComponent("FIFO").path
        #expect(mkfifo(fifoPath, 0o644) == 0, "mkfifo failed: \(String(cString: strerror(errno)))")
        let linkPath = repo.appendingPathComponent("LINK-TO-FIFO")
        try FileManager.default.createSymbolicLink(atPath: linkPath.path, withDestinationPath: "FIFO")
        try "new file content".write(to: repo.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })

        let link = try #require(byPath["LINK-TO-FIFO"])
        #expect(link.status == .untracked)
        #expect(link.patch == nil)
        #expect(link.isBinary == false)

        let other = try #require(byPath["NEW.md"])
        #expect(other.status == .untracked)
        #expect(other.patch?.contains("new file content") == true)
    }

    // Without `--untracked-files=all`, `git status`'s directory-collapsed `?? newdir/` record gives
    // `scopeSignature` no per-file mtime to hash for files inside an already-untracked directory, so editing
    // one of them would not necessarily change the directory's own stat and the signature could miss it.
    @Test func scopeSignatureChangesWhenAFileInsideAnAlreadyUntrackedDirectoryIsEdited() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()

        try FileManager.default.createDirectory(at: repo.appendingPathComponent("newdir"), withIntermediateDirectories: true)
        try "one".write(to: repo.appendingPathComponent("newdir/one.md"), atomically: true, encoding: .utf8)
        try "two".write(to: repo.appendingPathComponent("newdir/two.md"), atomically: true, encoding: .utf8)

        let before = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, gitClient: client)
        try "two edited".write(to: repo.appendingPathComponent("newdir/two.md"), atomically: true, encoding: .utf8)
        let after = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: repo.path, gitClient: client)
        #expect(before != after)
    }

    /// A user's `color.ui`/`color.diff = always` config decorates `git diff` output with ANSI escapes even
    /// when stdout is not a terminal. Without `--no-color` on every diff invocation, `parsePatchMetadata`'s
    /// exact-prefix line matching (`"Binary files "`, `"index "`) would silently stop recognizing those
    /// lines — misclassifying a text file as binary and losing its blob SHAs — and the returned patch text
    /// itself would carry escape sequences a client has no reason to expect.
    @Test func colorGitConfigDoesNotLeakAnsiEscapesOrMisclassifyTheFileAsBinary() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try runGit(["config", "color.ui", "always"], cwd: repo.path)
        try runGit(["config", "color.diff", "always"], cwd: repo.path)
        let client = RemoteWorkspaceGitClient()

        try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let file = try #require(result.files.first { $0.path == "README.md" })
        #expect(file.isBinary == false)
        #expect(file.oldSHA != nil)
        #expect(file.newSHA != nil)
        let patch = try #require(file.patch)
        #expect(!patch.contains("\u{1B}"))
    }

    /// A user's `diff.external` config (or `GIT_EXTERNAL_DIFF` in the daemon's environment — same mechanism)
    /// substitutes an external helper for git's own diff generation, and a `.gitattributes` textconv driver
    /// rewrites patch content so it no longer matches the on-disk bytes `workspaceFileRead` returns —
    /// breaking the client's unified-diff rendering and comment line-anchoring either way. Setting
    /// `diff.external` to a command that always fails is the strongest proof that `--no-ext-diff` is
    /// actually present on every invocation: if it were missing, `git diff` would shell out to the helper,
    /// the helper would exit nonzero, and `git diff` itself aborts with "external diff died" — turning
    /// `buildDiff` into a hard failure rather than a silent content-substitution bug that would be harder to
    /// pin on this flag. Covers both diff invocations that produce patch text: the tracked per-file `diff`
    /// and the untracked `diff --no-index`, which carry their own separate argument lists.
    @Test func externalDiffConfigDoesNotBreakOrSubstituteTheGeneratedPatch() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Any command that exits nonzero proves the flag is present: a no-op success command like `true`
        // couldn't distinguish "the flag suppressed the external helper" from "the flag is missing but the
        // helper's substituted output happened to parse anyway."
        try runGit(["config", "diff.external", "false"], cwd: repo.path)
        let client = RemoteWorkspaceGitClient()

        try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "untracked content".write(to: repo.appendingPathComponent("NEW.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)

        let trackedFile = try #require(result.files.first { $0.path == "README.md" })
        #expect(trackedFile.status == .modified)
        let trackedPatch = try #require(trackedFile.patch)
        #expect(trackedPatch.contains("@@"))

        let untrackedFile = try #require(result.files.first { $0.path == "NEW.md" })
        #expect(untrackedFile.status == .untracked)
        let untrackedPatch = try #require(untrackedFile.patch)
        #expect(untrackedPatch.contains("untracked content"))
    }

    /// The pre-read sniff that gates the tracked-vs-binary decision for an untracked file only inspects the
    /// first `sniffLength` bytes and knows nothing about `.gitattributes`, so it calls plain ASCII content
    /// "text" even when a committed `-diff` attribute forces git itself to treat the file as binary. `git
    /// diff --no-index` still emits its own authoritative "Binary files ... differ" marker in that case, and
    /// `buildUntrackedFile` must defer to it exactly as the tracked path already does via
    /// `parsePatchMetadata`, rather than handing the marker line back to the client as if it were a normal
    /// unified-diff patch body.
    @Test func anUntrackedFileWithADiffDisabledAttributeIsReportedAsBinaryDespiteTextContent() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "blob.bin -diff\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try runGit(["add", ".gitattributes"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "attributes"], cwd: repo.path)
        let client = RemoteWorkspaceGitClient()

        try "plain ascii text content, nothing binary here".write(to: repo.appendingPathComponent("blob.bin"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let file = try #require(result.files.first { $0.path == "blob.bin" })
        #expect(file.status == .untracked)
        #expect(file.isBinary == true)
        #expect(file.patch == nil)
    }

    /// After `--`, git still parses each pathspec argument for magic: a legal tracked filename beginning
    /// with `:` (here `:(glob)x`, itself valid long-form glob-magic syntax) would otherwise be interpreted as
    /// a pathspec pattern rather than a literal filename, silently matching nothing even though
    /// `--name-status -z` correctly identified it as changed. `":(literal)\(path)"` forces an exact match.
    @Test func aTrackedFileNamedWithPathspecMagicCharactersGetsItsOwnPatch() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "g1".write(to: repo.appendingPathComponent(":(glob)x"), atomically: true, encoding: .utf8)
        // `git add ':(glob)x'` would itself parse the argument as a pathspec and silently add nothing;
        // `-A` adds by walking the tree instead of parsing each argument as a pathspec.
        try runGit(["add", "-A"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "magic-name"], cwd: repo.path)
        let client = RemoteWorkspaceGitClient()

        try "g2".write(to: repo.appendingPathComponent(":(glob)x"), atomically: true, encoding: .utf8)
        try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let magicFile = try #require(result.files.first { $0.path == ":(glob)x" })
        #expect(magicFile.status == .modified)
        let magicPatch = try #require(magicFile.patch)
        #expect(magicPatch.contains("-g1"))
        #expect(magicPatch.contains("+g2"))
        #expect(!magicPatch.contains("edited content"))
    }

    // Round 13: `git rm --cached f` untracks a file without touching its worktree content, so `f` is
    // simultaneously `.deleted` per `--name-status` (gone from the index) and `??` per `git status`
    // (present on disk) — the same path in two states, not two files. `buildDiff` coalesces this into one
    // `.modified` entry whose patch diffs the base blob against the worktree file (via a scratch
    // `GIT_INDEX_FILE`, see `buildCoalescedDeletedButUntrackedFile`), rather than reporting an unrelated
    // delete-plus-add for the same path.
    @Test func aPathUntrackedViaRmCachedCoalescesIntoASingleModifiedEntry() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "content A\nshared\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "f.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "add f"], cwd: repo.path)
        let client = RemoteWorkspaceGitClient()

        try runGit(["rm", "--cached", "f.txt"], cwd: repo.path)
        try "content B\nshared\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let entries = result.files.filter { $0.path == "f.txt" }
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.status == .modified)
        #expect(entry.oldPath == nil)
        let patch = try #require(entry.patch)
        #expect(patch.contains("-content A"))
        #expect(patch.contains("+content B"))
    }

    @Test func coalescingARecreatedLargeFileDoesNotWriteIntoTheRepositoryObjectStore() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "content A\nshared\n".write(to: repo.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "large.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "add large file"], cwd: repo.path)
        let client = RemoteWorkspaceGitClient()

        try runGit(["rm", "--cached", "large.txt"], cwd: repo.path)
        let largeContent = "content B\n" + String(repeating: "large line\n", count: 64_000)
        try largeContent.write(to: repo.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        let objectsBefore = try runGit(["count-objects", "-v"], cwd: repo.path)

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)

        let objectsAfter = try runGit(["count-objects", "-v"], cwd: repo.path)
        #expect(objectsAfter == objectsBefore)
        let entry = try #require(result.files.first { $0.path == "large.txt" })
        #expect(entry.status == .modified)
        let patch = try #require(entry.patch)
        #expect(patch.contains("-content A"))
        #expect(patch.contains("+content B"))
        #expect(patch.contains("+large line"))
    }

    // The signature/status snapshot is intentionally reused by buildDiff. Model an agent staging an
    // untracked file immediately before the later raw diff listing: the newer enumeration reports the
    // file as tracked while the older snapshot still says `??`, but the response must keep one identity.
    @Test func aFileStagedBetweenStatusAndRawListingIsNotReturnedTwice() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "raced content\n".write(to: repo.appendingPathComponent("raced.txt"), atomically: true, encoding: .utf8)

        let shim = repo.appendingPathComponent("git-race-shim.sh")
        let marker = repo.appendingPathComponent(".race-staged")
        try """
        #!/bin/sh
        case " $* " in
          *" --raw "*)
            if [ ! -e "$SPACES_RACE_MARKER" ]; then
              git -C "$SPACES_RACE_REPO" add raced.txt
              : > "$SPACES_RACE_MARKER"
            fi
            ;;
        esac
        exec git "$@"
        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let client = RemoteWorkspaceGitClient(
            gitExecutable: shim.path, environmentOverrides: ["SPACES_RACE_REPO": repo.path, "SPACES_RACE_MARKER": marker.path])

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)

        #expect(result.files.map(\.path).filter { $0 == "raced.txt" } == ["raced.txt"])
        #expect(result.files.first { $0.path == "raced.txt" }?.status == .added)
    }

    // Same collision, but under a `refName` scope: the base branch has `f.txt`, the working branch commits
    // its deletion, then `f.txt` is recreated untracked (content differs from the base blob). Coalesces the
    // same way as the uncommitted-scope case above.
    @Test func aRefScopedDeletionRecreatedUntrackedCoalescesIntoASingleModifiedEntry() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "base content\nshared\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "f.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "add f"], cwd: repo.path)
        let client = RemoteWorkspaceGitClient()

        try runGit(["checkout", "-b", "feature"], cwd: repo.path)
        try runGit(["rm", "f.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "delete f"], cwd: repo.path)
        try "recreated content\nshared\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: repo.path, refName: "main", gitClient: client)
        let entries = result.files.filter { $0.path == "f.txt" }
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.status == .modified)
        let patch = try #require(entry.patch)
        #expect(patch.contains("-base content"))
        #expect(patch.contains("+recreated content"))
    }

    // The collision is specific to a `.deleted` name-status entry; a rename's recreated `oldPath` is a
    // different path from the rename entry's own (new) `path`, so it must not be swept into the coalescing
    // above and must keep reporting as a plain untracked addition, unpaired from the rename.
    @Test func aRenamesRecreatedOldPathIsNotCoalescedWithTheRenameEntry() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.moveItem(at: repo.appendingPathComponent("README.md"), to: repo.appendingPathComponent("RENAMED.md"))
        try runGit(["add", "-A"], cwd: repo.path)
        try "recreated old path".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let client = RemoteWorkspaceGitClient()

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })
        #expect(byPath["RENAMED.md"]?.status == .renamed)
        #expect(byPath["RENAMED.md"]?.oldPath == "README.md")
        #expect(byPath["README.md"]?.status == .untracked)
    }

    // Round-18 fix, corrected scope: the spec's literal "replace f with a bare FIFO via mkfifo" scenario
    // turns out to never reach `buildCoalescedDeletedButUntrackedFile` at all. Empirically confirmed: `git
    // status --porcelain --untracked-files=all` reports only `D  f.txt` for a bare FIFO recreated at a
    // `git rm --cached`'d path — never a paired `?? f.txt` the way it does for a recreated regular file or
    // symlink — so `deletedButUntrackedPaths` (the intersection this coalescing keys on) never contains it,
    // and the plan keeps the ordinary `.deleted` tracked-file entry instead. That is exactly what this test
    // asserts as the (pre-existing, unaffected-by-this-round) baseline. The scenario that DOES reach the
    // coalescing builder with a non-regular target is a *symlink* to a FIFO (a symlink is an ordinary
    // filesystem entry `git status` does report as `?? f.txt`), covered by the test below.
    @Test func aRecreatedBareFIFODoesNotCoalesceAndStaysAPlainDeletedEntry() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "content A\nshared\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "f.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "add f"], cwd: repo.path)
        let client = RemoteWorkspaceGitClient()

        try runGit(["rm", "--cached", "f.txt"], cwd: repo.path)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("f.txt"))
        let fifoPath = repo.appendingPathComponent("f.txt").path
        #expect(mkfifo(fifoPath, 0o644) == 0, "mkfifo failed: \(String(cString: strerror(errno)))")

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let entries = result.files.filter { $0.path == "f.txt" }
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.status == .deleted)
    }

    // The reachable non-regular-target scenario for the coalescing builder: a symlink (which `git status`
    // does report as untracked) whose target is a FIFO. Round-18's guard lets a symlink through unconditionally
    // (its own content — the link text — is always tiny), and this exercises that path end to end through
    // `buildDiff` rather than only via the ad hoc empirical checks: `update-index --add` on the symlink and
    // the subsequent `diff <compareRef>` against the scratch index must both complete without opening the
    // FIFO target, so `buildDiff` returns promptly with a single coalesced entry rather than hanging.
    @Test func aRecreatedSymlinkToAFIFOCoalescesPromptlyWithoutHanging() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "content A\nshared\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "f.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "add f"], cwd: repo.path)
        let client = RemoteWorkspaceGitClient()

        try runGit(["rm", "--cached", "f.txt"], cwd: repo.path)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("f.txt"))
        let fifoPath = repo.appendingPathComponent("real.fifo").path
        #expect(mkfifo(fifoPath, 0o644) == 0, "mkfifo failed: \(String(cString: strerror(errno)))")
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("f.txt").path, withDestinationPath: "real.fifo")

        let result = try buildDiff(workspaceDir: repo.path, refName: nil, gitClient: client)
        let entries = result.files.filter { $0.path == "f.txt" }
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.status == .modified)
        // Type change (tracked regular file -> symlink) renders as delete-old-content plus add-new-symlink
        // rather than a unified modification; the meaningful assertion is that the new symlink's own link
        // text (its target name) appears, never the FIFO being opened/blocked on.
        #expect(entry.patch?.contains("real.fifo") == true)
    }

    // Round-15 fix: a workspace can be rooted BELOW its repository's root (a monorepo subpackage added as
    // its own project — `Orchestrator.normalizeDir` accepts any dir where `rev-parse --is-inside-work-tree`
    // succeeds, so this is a real, supported configuration). Before this fix, git's `--name-status`/porcelain
    // output came back repo-root-relative while pathspecs/stats were workspace-relative, so a subdir
    // workspace's diffs came back empty, untracked captures failed, out-of-subtree changes leaked in, and
    // `scopeSignature` desynced from what `buildDiff` actually returned. `--relative` on the tracked
    // enumeration/per-file/coalesced captures (empirically confirmed to both scope AND relativize, including
    // patch headers, and to auto-demote a rename crossing the subtree boundary into a plain add/delete) fixes
    // the diff side; a hand-rolled filter-and-strip by `rev-parse --show-prefix` (porcelain has no
    // `--relative` of its own) fixes the untracked-discovery and `scopeSignature` side.
    @Test func trackedModificationInsideTheSubtreeReportsOneWorkspaceRelativeEntryWithAWorkspaceRelativePatch() throws {
        let (root, workspace) = try makeRepoWithSubdirWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteWorkspaceGitClient()

        try "app file edited".write(to: workspace.appendingPathComponent("APP.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: workspace.path, refName: nil, gitClient: client)
        #expect(result.files.count == 1)
        let file = try #require(result.files.first)
        #expect(file.path == "APP.md")
        #expect(file.status == .modified)
        let patch = try #require(file.patch)
        #expect(patch.contains("app file edited"))
        // Patch headers must be workspace-relative (matching `file.path`) for client-side comment anchoring,
        // not repo-root-relative (confirmed empirically: without `--relative`, the pathspec still matches
        // but the header text stays repo-root-relative).
        #expect(patch.contains("a/APP.md"))
        #expect(patch.contains("b/APP.md"))
        #expect(!patch.contains("packages/app/APP.md"))
    }

    @Test func trackedModificationOutsideTheSubtreeIsNotReported() throws {
        let (root, workspace) = try makeRepoWithSubdirWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteWorkspaceGitClient()

        try "other file edited".write(to: root.appendingPathComponent("other/OTHER.md"), atomically: true, encoding: .utf8)
        try "root file edited".write(to: root.appendingPathComponent("ROOT.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: workspace.path, refName: nil, gitClient: client)
        #expect(result.files.isEmpty)
    }

    @Test func untrackedFileInsideTheSubtreeIsReportedWithAPatchAndOutsideIsAbsent() throws {
        let (root, workspace) = try makeRepoWithSubdirWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteWorkspaceGitClient()

        try "new inside content".write(to: workspace.appendingPathComponent("NEWINSIDE.md"), atomically: true, encoding: .utf8)
        try "new outside content".write(to: root.appendingPathComponent("other/NEWOUTSIDE.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: workspace.path, refName: nil, gitClient: client)
        #expect(result.files.count == 1)
        let file = try #require(result.files.first)
        #expect(file.path == "NEWINSIDE.md")
        #expect(file.status == .untracked)
        #expect(file.patch?.contains("new inside content") == true)
    }

    // Round-21 Fix 2: `--show-prefix`'s output is a repo-relative path (plus a trailing slash and git's
    // own trailing newline), and a repo-relative directory can legitimately start with whitespace (e.g. a
    // subpackage literally named " sub"). Before the fix, `.trimmingCharacters(in: .whitespacesAndNewlines)`
    // stripped that leading space along with the trailing newline, so the trimmed prefix (`"sub/"`) no
    // longer matched any of this workspace's own porcelain paths (all reported as `" sub/…"`) and
    // `subtreeScoped` rejected every one of them as apparently outside the subtree — silently reporting an
    // empty diff for a workspace rooted at a leading-space subdirectory. Reuses
    // `makeRepoWithSubdirWorkspace`'s exact shape (an `other/` sibling and a root-level file, both outside
    // the workspace, to prove scoping still excludes them) with only the subdir's name swapped for one that
    // starts with a space.
    @Test func untrackedFileInsideALeadingSpaceSubdirWorkspaceIsReported() throws {
        let (root, workspace) = try makeRepoWithLeadingSpaceSubdirWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteWorkspaceGitClient()

        try "new inside content".write(to: workspace.appendingPathComponent("NEWINSIDE.md"), atomically: true, encoding: .utf8)
        try "new outside content".write(to: root.appendingPathComponent("other/NEWOUTSIDE.md"), atomically: true, encoding: .utf8)

        let result = try buildDiff(workspaceDir: workspace.path, refName: nil, gitClient: client)
        #expect(result.files.count == 1)
        let file = try #require(result.files.first)
        #expect(file.path == "NEWINSIDE.md")
        #expect(file.status == .untracked)
        #expect(file.patch?.contains("new inside content") == true)
    }

    @Test func aStagedRenameFullyInsideTheSubtreeReportsBothPathsWorkspaceRelative() throws {
        let (root, workspace) = try makeRepoWithSubdirWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteWorkspaceGitClient()

        try FileManager.default.moveItem(at: workspace.appendingPathComponent("APP.md"), to: workspace.appendingPathComponent("APP2.md"))
        try runGit(["add", "-A"], cwd: root.path)

        let result = try buildDiff(workspaceDir: workspace.path, refName: nil, gitClient: client)
        let file = try #require(result.files.first { $0.path == "APP2.md" })
        #expect(file.status == .renamed)
        #expect(file.oldPath == "APP.md")
    }

    @Test func scopeSignatureIsStableWhenOnlyAnOutsideFileChangesAndChangesWhenAnInsideFileChanges() throws {
        let (root, workspace) = try makeRepoWithSubdirWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteWorkspaceGitClient()

        let baseline = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: workspace.path, gitClient: client)

        try "other file edited".write(to: root.appendingPathComponent("other/OTHER.md"), atomically: true, encoding: .utf8)
        let afterOutsideEdit = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: workspace.path, gitClient: client)
        #expect(baseline == afterOutsideEdit)

        try "app file edited".write(to: workspace.appendingPathComponent("APP.md"), atomically: true, encoding: .utf8)
        let afterInsideEdit = try SpacesDeviceWorkspaceDiffEngine.scopeSignature(workspaceDir: workspace.path, gitClient: client)
        #expect(afterInsideEdit != afterOutsideEdit)
    }

    // MARK: - Fixture helpers

    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-diff-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch", "main"], cwd: root.path)
        try "initial".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: root.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: root.path)
        return root
    }

    /// A superproject with a submodule already added via `git submodule add` and committed, pointing `sub`
    /// at the returned source repo's first commit. `protocol.file.allow=always` is required for a local
    /// filesystem submodule URL since git 2.38.1 (CVE-2022-39253 hardening); real users add submodules from
    /// https/ssh remotes, where this default does not apply — only this fixture's local-path source needs
    /// the override. Returns the superproject root, the submodule's own (separate, still-clonable) source
    /// repo, and the pointer commit recorded by the add — the value every "no pointer bump yet" test
    /// compares against.
    private func makeRepoWithSubmodule() throws -> (superRoot: URL, subrepo: URL, subrepoSHA1: String) {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-diff-engine-submodule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let subrepo = container.appendingPathComponent("subrepo-source", isDirectory: true)
        try FileManager.default.createDirectory(at: subrepo, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch", "main"], cwd: subrepo.path)
        try "sub v1".write(to: subrepo.appendingPathComponent("FILE.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "FILE.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "sub initial"], cwd: subrepo.path)
        let subrepoSHA1 = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)

        let superRoot = container.appendingPathComponent("super", isDirectory: true)
        try FileManager.default.createDirectory(at: superRoot, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch", "main"], cwd: superRoot.path)
        try "root".write(to: superRoot.appendingPathComponent("ROOT.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "ROOT.md"], cwd: superRoot.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "root initial"], cwd: superRoot.path)
        try runGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", subrepo.path, "sub"], cwd: superRoot.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add submodule"], cwd: superRoot.path)

        return (superRoot, subrepo, subrepoSHA1)
    }

    /// Advances a `makeRepoWithSubmodule` source repo by one more commit, returning its sha. A test that
    /// wants a "pointer bump" fixture calls this and then re-points the superproject's checkout at the
    /// result (`git checkout <sha>` inside `sub`, then `git add sub` to stage the bump).
    @discardableResult private func commitSecondSubrepoRevision(subrepo: URL) throws -> String {
        try "sub v2".write(to: subrepo.appendingPathComponent("FILE.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "FILE.txt"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "sub v2"], cwd: subrepo.path)
        return try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A repo whose `packages/app` directory is added as its own workspace — the monorepo-subpackage
    /// configuration `Orchestrator.normalizeDir` accepts. Returns both the repo root (to make out-of-subtree
    /// changes under `other/` or `ROOT.md`) and the workspace directory itself (`packages/app` — the value
    /// every test using this fixture passes as `workspaceDir`, exactly as the daemon does for a subdir
    /// workspace).
    private func makeRepoWithSubdirWorkspace() throws -> (root: URL, workspace: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-diff-engine-subdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("packages/app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch", "main"], cwd: root.path)
        try "app file".write(to: root.appendingPathComponent("packages/app/APP.md"), atomically: true, encoding: .utf8)
        try "other file".write(to: root.appendingPathComponent("other/OTHER.md"), atomically: true, encoding: .utf8)
        try "root file".write(to: root.appendingPathComponent("ROOT.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], cwd: root.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: root.path)
        return (root, root.appendingPathComponent("packages/app"))
    }

    /// Same shape as `makeRepoWithSubdirWorkspace` (an `other/` sibling and a root-level file, both outside
    /// the workspace), except the workspace subdirectory's own name starts with a space — the round-21 Fix 2
    /// regression case for the `--show-prefix` probes' trimming.
    private func makeRepoWithLeadingSpaceSubdirWorkspace() throws -> (root: URL, workspace: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-diff-engine-space-subdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(" sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch", "main"], cwd: root.path)
        try "app file".write(to: root.appendingPathComponent(" sub/APP.md"), atomically: true, encoding: .utf8)
        try "other file".write(to: root.appendingPathComponent("other/OTHER.md"), atomically: true, encoding: .utf8)
        try "root file".write(to: root.appendingPathComponent("ROOT.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], cwd: root.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: root.path)
        return (root, root.appendingPathComponent(" sub"))
    }

    @discardableResult private func runGit(_ arguments: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        removeGitRepositoryEnvironment(from: &environment)
        process.environment = environment
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "unknown git failure"
            struct GitFixtureError: Error, CustomStringConvertible { let description: String }
            throw GitFixtureError(description: "git \(arguments.joined(separator: " ")) failed: \(message)")
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    /// Like `runGit`, but for a command whose non-zero exit is itself the expected outcome (e.g. a
    /// deliberately conflicting `git merge`): returns the exit status instead of throwing on it.
    @discardableResult private func runGitAllowingFailure(_ arguments: [String], cwd: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        removeGitRepositoryEnvironment(from: &environment)
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// `WorkspaceDiffScope` is `SpacesDeviceAPIServer`'s subscription-registry key (workspace id + normalized ref
/// name); exercising it directly (rather than only through `addWorkspaceDiffSignatureSubscriber`, which needs
/// a live socket) is enough to prove two scopes of the same workspace, and the same scope across workspaces,
/// are distinct registry entries.
@Suite struct SpacesDeviceAPIServerWorkspaceDiffScopeTests {
    @Test func twoScopesOfTheSameWorkspaceWithDifferentRefNamesAreDistinctKeys() {
        let uncommitted = SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: nil)
        let scoped = SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: "main")
        #expect(uncommitted != scoped)
    }

    @Test func anEmptyOrWhitespaceRefNameNormalizesToTheSameScopeAsNil() {
        #expect(
            SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: "")
                == SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: nil))
        #expect(
            SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: "   ")
                == SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: nil))
    }

    @Test func differentWorkspacesWithTheSameRefNameAreDistinctKeys() {
        #expect(
            SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: "main")
                != SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w2", refName: "main"))
    }
}

/// The keepalive cadence decision is extracted onto `SpacesDeviceAPIServer` (rather than left private inside
/// `WorkspaceDiffSignatureSubscription`) specifically so it is testable as pure logic without a live timer or
/// socket: it decides whether the ~2s poll tick should broadcast, either because the signature changed or
/// because it is the 10th idle tick (~20s keepalive cadence).
@Suite struct SpacesDeviceAPIServerKeepaliveCadenceTests {
    @Test func aChangedSignatureAlwaysBroadcastsRegardlessOfTick() {
        #expect(SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: 1, changed: true))
        #expect(SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: 7, changed: true))
    }

    @Test func anUnchangedSignatureOnlyBroadcastsEveryTenthTick() {
        #expect(!SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: 1, changed: false))
        #expect(!SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: 9, changed: false))
        #expect(SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: 10, changed: false))
        #expect(SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: 20, changed: false))
    }

    // Simulates `WorkspaceDiffSignatureSubscription`'s timer handler tick-by-tick, using the same two units
    // (the sentinel constant and the cadence function) it actually composes, to prove a permanently nil
    // `signatureProvider` (the subscribed workspace was deleted) still drives the keepalive rather than
    // silencing the producer altogether: it broadcasts once on the transition into "unavailable", stays
    // quiet for the next 9 ticks since nothing changed, then resumes broadcasting on every 10th tick.
    @Test func aProviderThatPermanentlyReturnsNilStillBroadcastsOnTheTransitionAndOnEveryKeepaliveTick() {
        var lastBroadcastSignature: String?
        var broadcastTicks: [Int] = []
        for tick in 1...21 {
            let signature = Optional<String>.none ?? SpacesDeviceAPIServer.workspaceDiffSignatureUnavailableSentinel
            let changed = signature != lastBroadcastSignature
            guard SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: tick, changed: changed) else { continue }
            lastBroadcastSignature = signature
            broadcastTicks.append(tick)
        }
        // Tick 1: nil -> sentinel is a change from the initial nil, so it broadcasts the transition.
        // Ticks 2-9: sentinel is unchanged and not a keepalive tick, so nothing broadcasts.
        // Ticks 10 and 20: unchanged but the 10th-tick keepalive still fires.
        #expect(broadcastTicks == [1, 10, 20])
    }

    @Test func aFileListProviderThatPermanentlyReturnsNilStillBroadcastsOnTheTransitionAndOnEveryKeepaliveTick() {
        var lastBroadcastSignature: String?
        var broadcastTicks: [Int] = []
        for tick in 1...21 {
            let signature = Optional<String>.none ?? SpacesDeviceAPIServer.workspaceFileListSignatureUnavailableSentinel
            let changed = signature != lastBroadcastSignature
            guard SpacesDeviceAPIServer.workspaceDiffSignatureKeepaliveShouldBroadcast(tick: tick, changed: changed) else { continue }
            lastBroadcastSignature = signature
            broadcastTicks.append(tick)
        }
        #expect(broadcastTicks == [1, 10, 20])
    }
}

/// The terminal stream's keepalive cadence, extracted onto `SpacesDeviceAPIServer` for the same reason as
/// the diff-signature cadence above: both relay paths (Darwin's timer on the relay queue and Linux's timer
/// against the write gate) ask this one question, and it is testable without a session, a socket, or TLS.
@Suite struct TerminalStreamKeepaliveCadenceTests {
    private static let interval = SpacesDeviceAPIServer.terminalStreamKeepaliveIntervalNanoseconds

    @Test func aRelayThatJustWroteOwesNothing() {
        let now: UInt64 = 1_000_000_000_000
        #expect(
            !SpacesDeviceAPIServer.terminalStreamKeepaliveIsDue(
                nowUptimeNanoseconds: now, lastWriteUptimeNanoseconds: now, intervalNanoseconds: Self.interval))
        #expect(
            !SpacesDeviceAPIServer.terminalStreamKeepaliveIsDue(
                nowUptimeNanoseconds: now + Self.interval - 1, lastWriteUptimeNanoseconds: now, intervalNanoseconds: Self.interval))
    }

    @Test func aRelaySilentForTheWholeIntervalOwesAKeepalive() {
        let now: UInt64 = 1_000_000_000_000
        #expect(
            SpacesDeviceAPIServer.terminalStreamKeepaliveIsDue(
                nowUptimeNanoseconds: now + Self.interval, lastWriteUptimeNanoseconds: now, intervalNanoseconds: Self.interval))
        #expect(
            SpacesDeviceAPIServer.terminalStreamKeepaliveIsDue(
                nowUptimeNanoseconds: now + 10 * Self.interval, lastWriteUptimeNanoseconds: now, intervalNanoseconds: Self.interval))
    }

    /// Drives the relay's actual loop: a check every `daemonCheckIntervalSeconds`, each write (real frame or
    /// keepalive) resetting the clock. A terminal that paints once and then goes idle must still put bytes on
    /// the wire on a fixed cadence, and the gap between them must stay well inside the client's timeout.
    @Test func anIdleRelayKeepsWritingOnACadenceTheClientTimeoutTolerates() {
        let checkIntervalNanoseconds = UInt64(TerminalStreamLiveness.daemonCheckIntervalSeconds * 1_000_000_000)
        var lastWrite: UInt64 = 0
        var writeTimes: [UInt64] = []
        // One real frame lands mid-tick, so the first keepalive gap is the worst case the cadence allows.
        let frameTime = checkIntervalNanoseconds / 2
        lastWrite = frameTime
        var now = checkIntervalNanoseconds
        while now <= 120 * 1_000_000_000 {
            if SpacesDeviceAPIServer.terminalStreamKeepaliveIsDue(
                nowUptimeNanoseconds: now, lastWriteUptimeNanoseconds: lastWrite, intervalNanoseconds: Self.interval)
            {
                lastWrite = now
                writeTimes.append(now)
            }
            now += checkIntervalNanoseconds
        }
        let gaps = zip([frameTime] + writeTimes, writeTimes).map { Double($1 - $0) / 1_000_000_000 }
        #expect(gaps.allSatisfy { $0 >= TerminalStreamLiveness.keepaliveIntervalSeconds })
        #expect(gaps.allSatisfy { $0 < TerminalStreamLiveness.silenceTimeoutSeconds })
    }

    /// The two constants are one contract: a client must be able to miss a keepalive (a stalled write, a
    /// scheduling hiccup) without declaring a healthy stream dead.
    @Test func theClientTimeoutToleratesMoreThanTwoMissedKeepalives() {
        #expect(TerminalStreamLiveness.silenceTimeoutSeconds > 2 * TerminalStreamLiveness.keepaliveIntervalSeconds)
        #expect(TerminalStreamLiveness.daemonCheckIntervalSeconds < TerminalStreamLiveness.keepaliveIntervalSeconds)
    }
}

@Suite struct SpacesDeviceWorkspaceFileListSignatureTests {
    @Test func newlineContainingPathsDoNotCollideWithADifferentMembershipShape() {
        let first = SpacesDeviceWorkspaceFileListSignature.value(for: .init(paths: ["a\nb", "c"], truncated: false))
        let second = SpacesDeviceWorkspaceFileListSignature.value(for: .init(paths: ["a", "b\nc"], truncated: false))

        #expect(first != second)
    }
}

@Suite struct SpacesDeviceWorkspaceFileListDetectorTests {
    @Test func gitDetectorIgnoresContentChurnButDetectsMembershipAndOpenabilityChanges() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        let initial = try token(repo, client)

        // A coding agent repeatedly editing an already-listed tracked file must not make the
        // subscription rescan the full tree merely because the content changed.
        try "edited content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(try token(repo, client) == initial)

        let untracked = repo.appendingPathComponent("new.txt")
        try "small".write(to: untracked, atomically: true, encoding: .utf8)
        let added = try token(repo, client)
        #expect(added != initial)

        // The list excludes a file once it crosses workspaceFileRead's cap, even though its git
        // membership is otherwise unchanged, so the detector includes this threshold state.
        try Data(repeating: 0, count: SpacesDeviceAPIServer.workspaceFileMaxBytes + 1).write(to: untracked)
        let oversized = try token(repo, client)
        #expect(oversized != added)

        try FileManager.default.removeItem(at: untracked)
        #expect(try token(repo, client) != oversized)

        try FileManager.default.removeItem(at: repo.appendingPathComponent("README.md"))
        #expect(try token(repo, client) != initial)
    }

    @Test func gitDetectorDetectsCleanTrackedFileShrinkingBelowOpenabilityCap() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        let trackedPath = repo.appendingPathComponent("tracked.bin")
        try Data(repeating: 0, count: SpacesDeviceAPIServer.workspaceFileMaxBytes + 1).write(to: trackedPath)
        try runGit(["add", "tracked.bin"], cwd: repo.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add oversized tracked file"], cwd: repo.path)

        let oversized = try token(repo, client)
        try Data(repeating: 0, count: SpacesDeviceAPIServer.workspaceFileMaxBytes).write(to: trackedPath)

        // A clean tracked file is absent from porcelain, so its cap crossing must still invalidate the
        // detector token even though ordinary content churn for already-listed tracked files is ignored.
        #expect(try token(repo, client) != oversized)
    }

    @Test func gitDetectorDetectsAssumeUnchangedTrackedFileDeletion() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        try "assume unchanged".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add assume unchanged file"], cwd: repo.path)
        try runGit(["update-index", "--assume-unchanged", "tracked.txt"], cwd: repo.path)

        let initial = try token(repo, client)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("tracked.txt"))

        // Assume-unchanged files are hidden from porcelain status, so the cached index metadata must
        // still make a deletion visible to the file-list detector.
        #expect(try token(repo, client) != initial)
    }

    @Test func gitDetectorDetectsAssumeUnchangedFlagAppliedAfterSubscriptionStarts() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        let trackedPath = repo.appendingPathComponent("tracked.txt")
        try "assume unchanged".write(to: trackedPath, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add assume unchanged file"], cwd: repo.path)
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: repo.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let initial = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        try runGit(["update-index", "--assume-unchanged", "tracked.txt"], cwd: repo.path)
        try FileManager.default.removeItem(at: trackedPath)

        #expect(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client) != initial)
    }

    @Test func gitDetectorDetectsSkipWorktreeFlagAppliedAfterSubscriptionStarts() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        let trackedPath = repo.appendingPathComponent("tracked.txt")
        try "skip worktree".write(to: trackedPath, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add skip worktree file"], cwd: repo.path)
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: repo.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let initial = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        try runGit(["update-index", "--skip-worktree", "tracked.txt"], cwd: repo.path)
        try FileManager.default.removeItem(at: trackedPath)

        #expect(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client) != initial)
    }

    @Test func gitDetectorDetectsAssumeUnchangedTransitionWithUnrelatedDirtyEntry() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        let trackedPath = repo.appendingPathComponent("tracked.txt")
        try "assume unchanged".write(to: trackedPath, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add tracked file"], cwd: repo.path)
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: repo.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let initial = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        try runGit(["update-index", "--assume-unchanged", "tracked.txt"], cwd: repo.path)
        try "ignored churn".write(to: repo.appendingPathComponent("ignored.tmp"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: trackedPath)

        #expect(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client) != initial)
    }

    @Test func gitDetectorDetectsSkipWorktreeTransitionWithUnrelatedDirtyEntry() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        let trackedPath = repo.appendingPathComponent("tracked.txt")
        try "skip worktree".write(to: trackedPath, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add tracked file"], cwd: repo.path)
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: repo.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let initial = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        try runGit(["update-index", "--skip-worktree", "tracked.txt"], cwd: repo.path)
        try "ignored churn".write(to: repo.appendingPathComponent("ignored.tmp"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: trackedPath)

        #expect(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client) != initial)
    }

    @Test func gitDetectorDetectsAssumeUnchangedTransitionWithUnrelatedTrackedDirtyEntry() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        let hiddenPath = repo.appendingPathComponent("hidden.txt")
        try "hidden".write(to: hiddenPath, atomically: true, encoding: .utf8)
        try runGit(["add", "hidden.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add hidden file"], cwd: repo.path)
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: repo.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let initial = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        try "ordinary dirty content".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["update-index", "--assume-unchanged", "hidden.txt"], cwd: repo.path)
        try FileManager.default.removeItem(at: hiddenPath)

        #expect(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client) != initial)
    }

    @Test func gitDetectorDetectsCombinedAssumeUnchangedAndSkipWorktreeTransition() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        let trackedPath = repo.appendingPathComponent("tracked.txt")
        try "combined flags".write(to: trackedPath, atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add combined flags file"], cwd: repo.path)
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: repo.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let initial = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        try runGit(["update-index", "--assume-unchanged", "--skip-worktree", "tracked.txt"], cwd: repo.path)
        try FileManager.default.removeItem(at: trackedPath)

        #expect(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client) != initial)
    }

    @Test func gitDetectorDetectsIgnoredToUnignoredTransitionsAndTrackedHeadChanges() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        try "ignored".write(to: repo.appendingPathComponent("ignored.tmp"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("tracked-link.txt").path, withDestinationPath: "ignored.tmp")
        try runGit(["add", "tracked-link.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add symlink"], cwd: repo.path)
        let ignored = try token(repo, client)

        // An ignored target can still determine whether a tracked symlink is openable and therefore
        // listed. Its cap crossing must move the detector without making ignored content churn noisy.
        try Data(repeating: 0, count: SpacesDeviceAPIServer.workspaceFileMaxBytes + 1).write(to: repo.appendingPathComponent("ignored.tmp"))
        #expect(try token(repo, client) != ignored)

        try FileManager.default.removeItem(at: repo.appendingPathComponent(".gitignore"))
        let unignored = try token(repo, client)
        #expect(unignored != ignored)

        try runGit(["add", "-A"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add ignored"], cwd: repo.path)
        #expect(try token(repo, client) != unignored)
    }

    @Test func gitDetectorDetectsTrackedSymlinkTargetChangesInsideIgnoredDirectory() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("ignored", isDirectory: true), withIntermediateDirectories: true)
        try "ignored/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 32).write(to: repo.appendingPathComponent("ignored/target.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("tracked-link.txt").path, withDestinationPath: "ignored/target.txt")
        try runGit(["add", "tracked-link.txt", ".gitignore"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add ignored symlink"], cwd: repo.path)

        let initial = try token(repo, client)
        try Data(repeating: 0, count: SpacesDeviceAPIServer.workspaceFileMaxBytes + 1).write(to: repo.appendingPathComponent("ignored/target.txt"))

        // `git status --ignored=matching` reports only `!! ignored/` for the target directory. The
        // tracked symlink remains clean, so the detector must inspect index mode 120000 entries too.
        #expect(try token(repo, client) != initial)
    }

    @Test func gitDetectorDetectsSparseCheckoutMaterializationChangesForCleanTrackedFiles() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        try "sparse candidate".write(to: repo.appendingPathComponent("sparse.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "sparse.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add sparse candidate"], cwd: repo.path)
        let initial = try token(repo, client)

        try runGit(["sparse-checkout", "init", "--no-cone"], cwd: repo.path)
        try runGit(["sparse-checkout", "set", "README.md"], cwd: repo.path)
        #expect(try token(repo, client) != initial)
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("sparse.txt").path))

        try runGit(["sparse-checkout", "set", "README.md", "sparse.txt"], cwd: repo.path)
        #expect(try token(repo, client) != initial)
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("sparse.txt").path))
    }

    @Test func gitDetectorScopesStatusToANestedWorkspaceDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-file-list-monorepo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("packages/app", isDirectory: true), withIntermediateDirectories: true)
        try "app".write(to: root.appendingPathComponent("packages/app/README.md"), atomically: true, encoding: .utf8)
        try "root".write(to: root.appendingPathComponent("ROOT.md"), atomically: true, encoding: .utf8)
        try runGit(["init", "--initial-branch", "main"], cwd: root.path)
        try runGit(["add", "-A"], cwd: root.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: root.path)
        let workspace = root.appendingPathComponent("packages/app", isDirectory: true)
        let client = RemoteWorkspaceGitClient()
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: workspace.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let initial = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)

        // A monorepo agent can edit another package while this workspace is open. That must not cause
        // this workspace's file-list stream to perform an exact refresh.
        try "root edit".write(to: root.appendingPathComponent("ROOT.md"), atomically: true, encoding: .utf8)
        #expect(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client) == initial)

        try "nested addition".write(to: workspace.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
        #expect(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client) != initial)
    }

    @Test func gitDetectorDetectsGitlinkChangingFromDirectoryToRegularFile() throws {
        let repo = try makeRepository()
        let subrepo = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-file-list-gitlink-(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: subrepo)
        }
        try FileManager.default.createDirectory(at: subrepo, withIntermediateDirectories: true)
        try "submodule".write(to: subrepo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["init", "--initial-branch", "main"], cwd: subrepo.path)
        try runGit(["add", "-A"], cwd: subrepo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: subrepo.path)
        let subrepoSHA = try runGit(["rev-parse", "HEAD"], cwd: subrepo.path).trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["update-index", "--add", "--cacheinfo", "160000,\(subrepoSHA),submodule"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add gitlink"], cwd: repo.path)

        let client = RemoteWorkspaceGitClient()
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: repo.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let initial = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        try "materialized regular file".write(to: repo.appendingPathComponent("submodule"), atomically: true, encoding: .utf8)

        #expect(try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client) != initial)
    }

    @Test func gitDetectorCachesIndexMembershipUntilTheIndexChanges() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = RemoteWorkspaceGitClient()
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: repo.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        _ = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        #expect(context.indexCache.indexScanCount == 1)

        // Agent content churn does not rewrite the index, so stable ticks reuse the cached symlink and
        // skip-worktree sets rather than scanning every index entry again.
        try "content churn".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        #expect(context.indexCache.indexScanCount == 1)

        // Index membership/mode changes invalidate the cache and refresh the set exactly once. This also
        // covers symlink additions/removals without paying the full-index scan on every poll.
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("tracked-link.txt").path, withDestinationPath: "README.md")
        try runGit(["add", "tracked-link.txt"], cwd: repo.path)
        _ = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        #expect(context.indexCache.indexScanCount == 2)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add tracked symlink"], cwd: repo.path)
        _ = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        #expect(context.indexCache.indexScanCount == 3)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("tracked-link.txt"))
        try runGit(["add", "-u"], cwd: repo.path)
        _ = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        #expect(context.indexCache.indexScanCount == 4)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "remove tracked symlink"], cwd: repo.path)
        _ = try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
        #expect(context.indexCache.indexScanCount == 5)
    }

    private func token(_ repo: URL, _ client: RemoteWorkspaceGitClient) throws -> String {
        guard let context = try SpacesDeviceWorkspaceFileListEngine.gitMembershipContext(workspaceDir: repo.path, gitClient: client) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try SpacesDeviceWorkspaceFileListEngine.gitMembershipChangeToken(context: context, gitClient: client)
    }

    private func makeRepository() throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-file-list-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch", "main"], cwd: repo.path)
        try "initial".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "ignored.tmp\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: repo.path)
        return repo
    }

    @discardableResult private func runGit(_ arguments: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        removeGitRepositoryEnvironment(from: &environment)
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

import Foundation
import Testing

@testable import spacesdeviceapi
import spacesdevicecore
import spacesruntimecore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("escape-link"), withDestinationURL: outside)

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

        let resolved = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(
            relativePath: "dangling-inside-link", workspaceDir: workspace.path)
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
            try FileManager.default.createSymbolicLink(
                atPath: workspace.appendingPathComponent(linkName).path, withDestinationPath: targetName)
        }

        #expect(throws: SpacesDeviceWorkspacePathResolver.PathError.escapesWorkspace) {
            _ = try SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: "link-0", workspaceDir: workspace.path)
        }
    }
}

@Suite struct SpacesDeviceWorkspaceGitHashingTests {
    @Test func matchesKnownSHA256Vectors() {
        #expect(
            SpacesDeviceWorkspaceGitHashing.sha256Hex(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(
            SpacesDeviceWorkspaceGitHashing.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct SpacesDeviceWorkspaceBinaryGuessTests {
    @Test func plainTextIsNotBinary() {
        #expect(!SpacesDeviceWorkspaceBinaryGuess.isLikelyBinary(Data("hello world\n".utf8)))
    }

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
    }

    private struct DiffResult {
        let scopeSignature: String
        let files: [DiffFile]
    }

    @Test func aLargeManifestResolvesEachPathAndKeepsTheFirstDuplicatePlan() {
        let first = SpacesDeviceWorkspaceDiffEngine.DiffFilePlan(
            path: "duplicate.md", oldPath: nil, status: .modified, source: .untracked)
        let duplicate = SpacesDeviceWorkspaceDiffEngine.DiffFilePlan(
            path: "duplicate.md", oldPath: nil, status: .deleted,
            source: .tracked(baseRef: "HEAD", targetRef: nil))
        let plans = [first] + (0..<10_000).map { index in
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
        workspaceDir: String, refName: String?, lastCommit: Bool = false, gitClient: RemoteWorkspaceGitClient,
        deadlineStart: Date = Date()
    ) throws -> DiffResult {
        let snapshot = try SpacesDeviceWorkspaceDiffEngine.buildDiffPlanSnapshot(
            workspaceDir: workspaceDir, refName: refName, lastCommit: lastCommit, gitClient: gitClient, deadlineStart: deadlineStart)
        let transferDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-diff-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transferDirectory) }
        let files = try snapshot.plans.compactMap { plan -> DiffFile? in
            let outputURL = transferDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: outputURL.path, contents: Data())
            guard let transfer = try SpacesDeviceWorkspaceDiffEngine.writeDiffFilePatch(
                snapshot: snapshot, workspaceDir: workspaceDir, relativePath: plan.path, outputURL: outputURL, gitClient: gitClient,
                deadlineStart: deadlineStart)
            else { return nil }
            // Match the chunk contract: a refused/non-produced body has no payload, not an empty text
            // patch. This is distinct from a generated patch whose textual contents happen to be empty.
            let patch = transfer.file.isBinary || transfer.patchByteCount == 0
                ? nil
                : String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
            return DiffFile(
                path: transfer.file.path, oldPath: transfer.file.oldPath, status: transfer.file.status, patch: patch,
                isBinary: transfer.file.isBinary, oldSHA: transfer.file.oldSHA, newSHA: transfer.file.newSHA)
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
    // `buildDiff`'s up-front commands (merge-base, name-status, the untracked status scan); round 12 extends
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
        for file in result.files {
            #expect(file.patch != nil)
        }
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

        try "plain ascii text content, nothing binary here".write(
            to: repo.appendingPathComponent("blob.bin"), atomically: true, encoding: .utf8)

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
    // untracked file immediately before the later name-status command: the newer enumeration reports the
    // file as tracked while the older snapshot still says `??`, but the response must keep one identity.
    @Test func aFileStagedBetweenStatusAndNameStatusIsNotReturnedTwice() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "raced content\n".write(to: repo.appendingPathComponent("raced.txt"), atomically: true, encoding: .utf8)

        let shim = repo.appendingPathComponent("git-race-shim.sh")
        let marker = repo.appendingPathComponent(".race-staged")
        try """
            #!/bin/sh
            case " $* " in
              *" --name-status "*)
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
            gitExecutable: shim.path,
            environmentOverrides: ["SPACES_RACE_REPO": repo.path, "SPACES_RACE_MARKER": marker.path])

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

    /// A repo whose `packages/app` directory is added as its own workspace — the monorepo-subpackage
    /// configuration `Orchestrator.normalizeDir` accepts. Returns both the repo root (to make out-of-subtree
    /// changes under `other/` or `ROOT.md`) and the workspace directory itself (`packages/app` — the value
    /// every test using this fixture passes as `workspaceDir`, exactly as the daemon does for a subdir
    /// workspace).
    private func makeRepoWithSubdirWorkspace() throws -> (root: URL, workspace: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-diff-engine-subdir-\(UUID().uuidString)", isDirectory: true)
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
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
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
        #expect(SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: "") == SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: nil))
        #expect(SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: "   ") == SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: nil))
    }

    @Test func differentWorkspacesWithTheSameRefNameAreDistinctKeys() {
        #expect(SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w1", refName: "main") != SpacesDeviceAPIServer.WorkspaceDiffScope(workspaceID: "w2", refName: "main"))
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
}

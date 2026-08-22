import Foundation
import spacesdevicecore
import spacesruntimecore

#if canImport(CryptoKit)
    import CryptoKit
#elseif canImport(OpenSSL)
    import OpenSSL
#endif

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Path containment for the workspace file-read/write Device API commands: a client-supplied
/// `relativePath` must resolve to somewhere inside the workspace's checkout, even through symlinks.
enum SpacesDeviceWorkspacePathResolver {
    enum PathError: Error { case escapesWorkspace }

    /// Resolves `relativePath` against `workspaceDir` and asserts the result stays inside it.
    ///
    /// Rejects an absolute path and any `.`/`..` path component outright, then follows symlinks on the
    /// nearest existing ancestor of the target (the leaf itself may not exist yet — a file-write create —
    /// so containment cannot simply `resolvingSymlinksInPath()` the full candidate path) and asserts that
    /// resolved ancestor is inside the workspace's own resolved root. Any remaining path components past
    /// that ancestor cannot themselves be symlinks (they do not exist on disk), so they are reappended
    /// literally.
    ///
    /// This containment check guards an honest client against path mistakes — traversal, typos, a stale
    /// relative path — not against an adversarial process already running inside the workspace. Everything
    /// under a worktree runs as the same user as this daemon, so a process that could win the race and swap
    /// a validated component for a symlink between this resolution and the later stat/open/write already has
    /// direct filesystem access to everything that race could redirect into; closing the window would need
    /// dirfd/`O_NOFOLLOW` `openat` chains on both platforms for no gain against that trust model. Same
    /// reasoning as the accepted hash-to-rename CAS window in the file-write handler.
    static func resolveContainedPath(relativePath: String, workspaceDir: String, fileManager: FileManager = .default) throws -> String {
        // Validated and resolved exactly as supplied: leading/trailing whitespace is legal in a filename
        // (git enumerates such files in diffs just like any other), so trimming it here would silently
        // redirect a read/write to a different path than the one the client and `git` both agree on.
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { throw PathError.escapesWorkspace }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else { throw PathError.escapesWorkspace }

        let workspaceRoot = URL(fileURLWithPath: workspaceDir, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: relativePath, relativeTo: workspaceRoot).standardizedFileURL

        var existingAncestor = candidate
        var remainder: [String] = []
        while !fileManager.fileExists(atPath: existingAncestor.path) {
            remainder.insert(existingAncestor.lastPathComponent, at: 0)
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { throw PathError.escapesWorkspace }
            existingAncestor = parent
        }
        let resolvedAncestor = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = remainder.reduce(resolvedAncestor) { $0.appendingPathComponent($1) }.standardizedFileURL

        let workspacePrefix = workspaceRoot.path.hasSuffix("/") ? workspaceRoot.path : workspaceRoot.path + "/"
        guard resolvedAncestor.path == workspaceRoot.path || resolvedAncestor.path.hasPrefix(workspacePrefix) else {
            throw PathError.escapesWorkspace
        }
        return resolvedCandidate.path
    }
}

/// Cross-platform SHA-256 over raw bytes, for the file-read/write/CAS hashes. Mirrors
/// `SpacesDevicePairingStore`'s `hash(_:)` pattern but takes `Data` directly rather than a `String`, since
/// file content is not always valid UTF-8.
enum SpacesDeviceWorkspaceGitHashing {
    static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        #elseif canImport(OpenSSL)
            var digest = [UInt8](repeating: 0, count: Int(SHA256_DIGEST_LENGTH))
            if data.isEmpty {
                // `Data().withUnsafeBytes` yields a nil base address on Linux, so the general path below
                // would hit its guard and silently return without hashing anything, leaving `digest` all
                // zero instead of SHA-256's defined empty-input value. Pass a real, unused stack byte with
                // length 0 instead so OpenSSL still runs and produces the correct digest.
                var unusedByte: UInt8 = 0
                _ = OpenSSL.SHA256(&unusedByte, 0, &digest)
            } else {
                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    _ = OpenSSL.SHA256(baseAddress, data.count, &digest)
                }
            }
            return digest.map { String(format: "%02x", $0) }.joined()
        #else
            preconditionFailure("SpacesDeviceWorkspaceGitHashing requires SHA-256 support.")
        #endif
    }
}

/// The same first-N-bytes NUL heuristic git itself uses to decide whether a file is text or binary for
/// diffing purposes, reused here for `workspaceFileRead`'s `isBinaryGuess`.
enum SpacesDeviceWorkspaceBinaryGuess {
    /// Not `private`: `SpacesDeviceWorkspaceDiffEngine`'s untracked-file handling reads exactly this many
    /// bytes via `FileHandle` (never the whole file) so it can reuse this same threshold for its sniff.
    static let sniffLength = 8000

    static func isLikelyBinary(_ data: Data) -> Bool { data.prefix(sniffLength).contains(0) }
}

/// Git-backed support for the workspace file/diff Device API commands: uncommitted/against-ref diff
/// building and the cheap `scopeSignature` change-detection token both `workspaceDiff` and
/// `subscribeWorkspaceDiffSignature`'s poll timer use. Pure functions over an explicit `workspaceDir` and
/// `RemoteWorkspaceGitClient` so they need no server state and can run off any queue.
enum SpacesDeviceWorkspaceDiffEngine {
    /// Per-file and total unified-diff patch caps (see `SpacesDeviceWorkspaceDiffFile.truncated`). A file
    /// over its own cap, or that would push the running total over the total cap, gets `patch = nil` and
    /// `truncated = true` but is never dropped from the result.
    static let perFilePatchByteCap = 1 * 1024 * 1024
    static let totalPatchByteCap = 8 * 1024 * 1024

    /// Bounds every git subprocess this engine spawns, so a wedged repository (a hung textconv/external
    /// diff helper, a stalled filesystem) cannot permanently occupy the workspace's serial queue or the
    /// diff-signature poll queue. 30s is far above any healthy repo operation.
    private static let gitCommandTimeout: TimeInterval = 30

    /// Upper bound on the wall-clock time `buildDiff` spends fetching per-file patches, measured from the
    /// moment it starts. Each file spawns its own git process, and that per-file spawn's own timeout is
    /// itself shrunk to whatever remains of this deadline (via `remainingTimeout`, never a flat
    /// `gitCommandTimeout`) — otherwise a file whose git only starts near the end of the budget would still
    /// get a fresh full timeout, and total runtime would scale with file count with no ceiling of its own.
    /// Kept under the client's ~60s request timeout so the daemon always finishes and answers — with the
    /// same truncated shape the per-file/total byte caps already use for whatever files did not fit — rather
    /// than continuing to spawn git for a request the client has already abandoned while still holding the
    /// workspace's serial queue.
    private static let diffBuildDeadline: TimeInterval = 45

    /// Caps one of `buildDiff`'s up-front commands (`scopeSignature`'s own probes, the merge-base, the
    /// `--name-status` enumeration, the untracked `status` scan) to whatever remains of `diffBuildDeadline`
    /// from `start`, never more than `gitCommandTimeout`. `gitCommandTimeout` alone only guards a single
    /// hung git process; without this, several up-front commands each stalling for most of their own 30s
    /// budget could hold the workspace's serial queue for minutes before the per-file loop's own deadline
    /// check (below) is ever reached. This keeps the SUM of one request's up-front commands inside the same
    /// client-abandonment horizon the per-file loop already respects, so the daemon never keeps doing git
    /// work for a request the client has already given up on. Throws the same error shape
    /// `runGitAndCapture` itself throws on an ordinary per-command timeout once the remainder reaches zero,
    /// so a caller sees one consistent error regardless of which command tipped the request over.
    private static func remainingTimeout(start: Date) throws -> TimeInterval {
        let remaining = diffBuildDeadline - Date().timeIntervalSince(start)
        guard remaining > 0 else {
            throw SpacesRuntimeError.gitCommandFailed(
                message: "Git command timed out after \(diffBuildDeadline)s: request-wide deadline elapsed")
        }
        return min(gitCommandTimeout, remaining)
    }

    /// Normalizes a client-supplied `refName` the same way for every pull-side consumer here
    /// (`scopeSignature`, `buildDiff`) — nil, empty, or whitespace-only all mean "no ref: diff against
    /// HEAD", never an empty argument handed to `git merge-base`. This must agree with
    /// `WorkspaceDiffScope`'s own normalization in `SpacesDeviceAPIServer.swift`: that type decides which
    /// scope a `subscribeWorkspaceDiffSignature` client is subscribed to, and if the two normalizations ever
    /// diverged, a blank ref could subscribe successfully as the uncommitted scope while every pull against
    /// that same blank ref failed with a merge-base error on an empty argument.
    static func normalizedRefName(_ refName: String?) -> String? {
        guard let trimmed = refName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The one shared refusal both `workspaceDiff` and `subscribeWorkspaceDiffSignature` need for a
    /// non-git workspace directory. A single workspace can be just a project directory with no `.git` (a
    /// supported product type, see docs/spec.md), yet the workspace picker offers Diff for every workspace
    /// regardless of whether it is one — so without this check, the first git invocation inside
    /// `scopeSignature`/`buildDiff` (`rev-parse HEAD`, say) would fail and surface as a generic
    /// `gitCommandFailed`, giving the client no renderable reason to distinguish "not a repo" from any other
    /// git failure. `RemoteWorkspaceGitClient.isRepo` already runs the canonical `rev-parse
    /// --is-inside-work-tree` probe on its own `metadataCommandTimeout`, so this only translates a `false`
    /// into the typed error both call sites throw. Whether to still show the Diff entry point at all for a
    /// non-git workspace is left to the client — a UI-phase decision this error exists to make possible, not
    /// one this daemon-side check makes on the client's behalf.
    static func assertIsGitRepository(workspaceDir: String, gitClient: RemoteWorkspaceGitClient) throws {
        guard gitClient.isRepo(path: workspaceDir) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Workspace directory is not a git repository."])
        }
    }

    /// Cheap change-detection token: sha256 over the HEAD commit, the raw `git status --porcelain -z`
    /// bytes, each dirty/untracked file's size, modification time, and POSIX mode, and — when `refName` is
    /// given — the merge-base of `refName` and `HEAD`. Mode is included alongside size/mtime because a
    /// chmod (e.g. an executable-bit flip) on an already-dirty file changes none of the other inputs (chmod
    /// only touches ctime) even though it does produce a mode-change line in the diff. Recomputing this is
    /// the entire cost of one
    /// `subscribeWorkspaceDiffSignature` poll tick, so it deliberately never shells out to `git diff` for
    /// the uncommitted-scope inputs (that is the expensive part `workspaceDiff` itself pays for, on
    /// demand) — `merge-base` is the one exception, since it is the only way to detect the diff base
    /// itself moving (e.g. the branch being reviewed gets merged into `refName` from elsewhere) rather than
    /// just the working tree changing. When `merge-base` fails (the ref was deleted, say), an error-marker
    /// string is folded in instead of the resolved SHA, so the signature still changes exactly once rather
    /// than silently pinning to a stale value.
    /// `deadlineStart` is nil on the standalone poll path (`subscribeWorkspaceDiffSignature`'s timer calls
    /// this directly), which keeps today's behavior: each command gets its own flat `gitCommandTimeout` with
    /// no request-wide budget, because a poll tick has no such budget to share. `buildDiff` passes its own
    /// `start` here so this call's commands are folded into the same request-wide deadline (`remainingTimeout`)
    /// as `buildDiff`'s other up-front commands.
    static func scopeSignature(workspaceDir: String, refName: String? = nil, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date? = nil)
        throws -> String
    {
        let headSHA = (try? gitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "HEAD"],
            timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // `--untracked-files=all` (rather than git's default `normal`) is required here: the default
        // collapses every file inside a wholly-untracked directory into one `?? dir/` record, so editing a
        // file inside an already-untracked directory would not change this signature (the directory's own
        // mtime need not change when a file inside it is edited) even though `buildDiff` would show that
        // edit once the client re-fetches. `all` reports each file individually, so per-file `size`/`mtime`
        // below sees it.
        let statusOutput = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "status", "--porcelain", "-z", "--untracked-files=all"],
            timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout)
        // See `buildDiff`'s comment on the same probe: a workspace can be a monorepo subpackage rooted
        // below its repository's root (`Orchestrator.normalizeDir` accepts any dir where `rev-parse
        // --is-inside-work-tree` succeeds), so porcelain's repo-root-relative paths must be scoped down to
        // just this subtree and relativized before they feed the hash or the per-file stat below — `git
        // status` has no `--relative` of its own (confirmed against real git: `error: unknown option
        // 'relative'`), unlike the `diff` invocations below. `--show-prefix` answers correctly even in an
        // unborn repo (no commits yet), since it is purely CWD-based.
        let prefix = (try? gitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--show-prefix"],
            timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var input = Data((headSHA + "\n").utf8)
        // The common case — a workspace rooted AT the repository root, `prefix.isEmpty` — must hash
        // byte-for-byte what it always has, so an existing subscription's signature does not change (and
        // re-fire once) purely because subtree scoping was added. Only a workspace rooted below the repo
        // root takes the scoped/stripped/reserialized path.
        let scopedEntries: [PorcelainEntry]
        if prefix.isEmpty {
            input.append(Data(statusOutput.utf8))
            scopedEntries = changedEntries(fromPorcelainZ: statusOutput)
        } else {
            scopedEntries = subtreeScoped(changedEntries(fromPorcelainZ: statusOutput), prefix: prefix)
            input.append(serializeScoped(scopedEntries))
        }

        if let normalizedRef = normalizedRefName(refName) {
            let mergeBase =
                (try? gitClient.runGitAndCapture(
                    ["-C", workspaceDir, "merge-base", normalizedRef, "HEAD"],
                    timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "merge-base-error"
            input.append(Data("merge-base:\(mergeBase)\n".utf8))
        }

        let fileManager = FileManager.default
        for entry in scopedEntries {
            let fullPath = (workspaceDir as NSString).appendingPathComponent(entry.path)
            if let attributes = try? fileManager.attributesOfItem(atPath: fullPath), let size = attributes[.size] as? Int,
                let modified = attributes[.modificationDate] as? Date
            {
                // `mode` (raw POSIX permission bits, -1 if unavailable) is folded in alongside size/mtime
                // because a chmod (e.g. flipping the executable bit) on an already-dirty tracked file changes
                // none of HEAD, the porcelain status letter, size, or mtime (chmod only touches ctime, which
                // this signature does not read) — yet the resulting unified diff does gain a mode-change
                // line. Without `mode` here, that change would be invisible to a subscribed client's poll.
                let mode = attributes[.posixPermissions] as? Int ?? -1
                input.append(Data("\(entry.path)|\(size)|\(modified.timeIntervalSince1970)|\(mode)\n".utf8))
            } else {
                // Raced with a delete between the status scan and this stat; still folds into the
                // signature (as a distinct value from a present file) so the poll still detects the change.
                input.append(Data("\(entry.path)|missing\n".utf8))
            }
        }
        return SpacesDeviceWorkspaceGitHashing.sha256Hex(input)
    }

    /// One file identified by `git diff -M --name-status -z` (tracked) or by a `??` record in `git status
    /// --porcelain -z` (untracked). `path`/`oldPath`/`status` here are authoritative for the returned
    /// `SpacesDeviceWorkspaceDiffFile` — the per-file patch fetched via `source` is used only for its text
    /// (and, for a binary file, the "Binary files ... differ" marker and blob SHAs), never for identity.
    private struct DiffFilePlan {
        enum Source {
            /// Arguments for `git -c core.quotepath=false diff -M <ref> -- [oldPath] path`.
            case tracked(diffArguments: [String])
            case untracked
            /// A path `--name-status` reports `.deleted` relative to `compareRef` but that `git status`
            /// ALSO reports untracked (`git rm --cached f` followed by editing `f`; or, ref-scoped, a base
            /// branch deleting a file the working branch later recreated without staging it). Coalesced
            /// into one modified-file entry — see `buildCoalescedDeletedButUntrackedFile` — instead of
            /// reporting the same path twice as an unrelated delete plus add.
            case deletedButUntrackedInWorktree(compareRef: String)
        }
        let path: String
        let oldPath: String?
        let status: SpacesDeviceWorkspaceDiffFileStatus
        let source: Source
    }

    /// Builds the structured diff for `workspaceDiff`. `refName == nil` diffs uncommitted changes against
    /// `HEAD`; a non-nil `refName` diffs the merge-base of `refName` and `HEAD` against the working tree
    /// (so it also includes uncommitted changes — reviewing work against a base branch means "everything
    /// since it diverged, including what is not committed yet"). Untracked files never show up in `git
    /// diff` output regardless of the ref compared against, so they are enumerated separately via `git
    /// status` and synthesized as add-diffs.
    ///
    /// Identity first, patches second, capped as they are fetched: `git diff -M --name-status -z` (cheap,
    /// unbounded — its output is one line per changed file, never a patch body) enumerates every changed
    /// tracked file's authoritative `path`/`oldPath`/`status` up front. Each file's patch is then fetched
    /// individually with a per-invocation byte cap, so an oversized file's patch is never materialized in
    /// the first place; once the running total across all files reaches the total cap, remaining files are
    /// reported `truncated = true` without spawning `git` for them at all.
    static func buildDiff(workspaceDir: String, refName: String?, gitClient: RemoteWorkspaceGitClient) throws -> SpacesDeviceWorkspaceDiffResult {
        let start = Date()
        let signature = try scopeSignature(workspaceDir: workspaceDir, refName: refName, gitClient: gitClient, deadlineStart: start)

        let compareRef: String
        if let normalizedRef = normalizedRefName(refName) {
            // Reviewing against a base branch in a commit-less repo is meaningless, so an unborn `HEAD`
            // here is left to fail honestly with `merge-base`'s own typed git error rather than being
            // papered over — unlike the nil-`refName` path below, which treats an unborn `HEAD` as a
            // supported "changes in a repo with no commits yet" case.
            compareRef = try gitClient.runGitAndCapture(
                ["-C", workspaceDir, "merge-base", normalizedRef, "HEAD"], timeout: try remainingTimeout(start: start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Detect an unborn `HEAD` (a freshly `git init`ed repo with no commits yet — still a valid git
            // project, and `assertIsGitRepository` above already accepted it) with one cheap probe. The
            // timeout is resolved *before* the probe itself, as its own statement outside the `try?`, so a
            // request-deadline expiry here propagates as a hard failure instead of being swallowed and
            // misread as "HEAD doesn't exist" — those are different conditions and must not collapse into
            // the same fallback.
            let headProbeTimeout = try remainingTimeout(start: start)
            let headExists =
                (try? gitClient.runGitAndCapture(["-C", workspaceDir, "rev-parse", "--verify", "HEAD"], timeout: headProbeTimeout)) != nil
            if headExists {
                compareRef = "HEAD"
            } else {
                // No commits exist yet, so there is no tree to diff against — compare against git's empty
                // tree instead, which makes every tracked/staged file report as an addition. That is
                // exactly what "changes in a repo with no commits" means, and it is the only way to surface
                // a *staged* file in this state: an unborn repo's staged files are already in the index, so
                // `git status`'s `??` (untracked) records never include them, and a scan of untracked files
                // alone would silently miss them. The empty tree id is computed per call via `git
                // hash-object -t tree /dev/null` rather than hardcoded as the well-known SHA-1 constant
                // (`4b825dc642cb6eb9a060e54bf8d69288fbee4904`), so this stays correct for a repo created
                // with a non-SHA-1 object format (`git init --object-format=sha256`), where that constant
                // would not resolve to anything.
                compareRef = try gitClient.runGitAndCapture(
                    ["-C", workspaceDir, "hash-object", "-t", "tree", "/dev/null"], timeout: try remainingTimeout(start: start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // `-M` turns on rename detection so a pure rename reports as `.renamed` (with `patch` describing
        // just the delta, if any) instead of a delete plus an unrelated add. `--no-color`: without it, a
        // user's `color.ui`/`color.diff = always` config decorates output with ANSI escapes that
        // `parsePatchMetadata` does not expect (`index`/`Binary files` lines go unrecognized) and that would
        // otherwise pollute the returned patch text. `--no-ext-diff --no-textconv`: patches must be git's own
        // unified format with content matching the on-disk bytes, because the client renders them as unified
        // diffs and anchors comments to raw file lines; without these flags, a user's `diff.external` /
        // `GIT_EXTERNAL_DIFF` config (e.g. difftastic) or a `.gitattributes` textconv driver could substitute
        // or rewrite the patch content entirely — or, for the external-diff case, make the whole request fail
        // or return arbitrary non-unified output. Applied uniformly to every `git diff` invocation below,
        // including `--name-status` (which no external-diff driver fires for anyway), so a future argument
        // edit can't reintroduce the hole on one call and not another.
        // `--relative`: a workspace can be rooted below its repository's root (a monorepo subpackage
        // added as its own project — `Orchestrator.normalizeDir` accepts any dir where `rev-parse
        // --is-inside-work-tree` succeeds). Without it, `--name-status` reports repo-root-relative paths
        // while every per-file pathspec below is workspace-relative, so nothing matches; with it, git both
        // limits this enumeration to the CWD's subtree (out-of-workspace changes are correctly excluded —
        // the pane reviews THIS workspace) and reports every path relative to that subtree, including in
        // `diff --git`/`---`/`+++` headers, which is what keeps patch-header paths aligned with entry paths
        // for client anchoring. A no-op, byte-for-byte, when `workspaceDir` IS the repo root (empirically
        // confirmed).
        let nameStatusOutput = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "diff", "-M", "--no-color", "--no-ext-diff", "--no-textconv", "--relative", "--name-status", "-z", compareRef],
            timeout: try remainingTimeout(start: start))
        var plans = parseNameStatusZ(nameStatusOutput).map { entry -> DiffFilePlan in
            let diffArguments: [String]
            // `:(literal)` forces git to match each pathspec argument as an exact path rather than parsing
            // it for magic: a legal tracked filename that happens to start with `:` (e.g. `:foo` or
            // `:(glob)x`) would otherwise be interpreted as pathspec magic itself, silently matching nothing
            // (an empty patch, even though `--name-status` above correctly identified it as changed) or, for
            // other magic keywords, unrelated files. `--name-status -z` above takes no per-file pathspec, so
            // it is unaffected and stays the source of truth for which paths actually changed.
            //
            // `entry.path`/`entry.oldPath` are already workspace-relative (from `--relative` above), and
            // pathspecs resolve against CWD (`workspaceDir`) by default, so no further adjustment is needed
            // here — only `--relative` itself must also be passed so the per-file patch's own headers come
            // out workspace-relative rather than repo-root-relative (confirmed empirically: the pathspec
            // match succeeds either way, but only `--relative` also relativizes the `diff --git a/... b/...`
            // header text).
            if let oldPath = entry.oldPath {
                diffArguments = [
                    "-C", workspaceDir, "-c", "core.quotepath=false", "diff", "-M", "--no-color", "--no-ext-diff", "--no-textconv", "--relative",
                    compareRef, "--", ":(literal)\(oldPath)", ":(literal)\(entry.path)",
                ]
            } else {
                diffArguments = [
                    "-C", workspaceDir, "-c", "core.quotepath=false", "diff", "-M", "--no-color", "--no-ext-diff", "--no-textconv", "--relative",
                    compareRef, "--", ":(literal)\(entry.path)",
                ]
            }
            return DiffFilePlan(path: entry.path, oldPath: entry.oldPath, status: entry.status, source: .tracked(diffArguments: diffArguments))
        }

        // `--untracked-files=all`: see `scopeSignature`'s comment on the same flag. Without it, a wholly
        // untracked directory collapses into one `?? dir/` record and this would synthesize a single
        // add-diff for the directory itself instead of one per file inside it.
        let statusOutput = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "status", "--porcelain", "-z", "--untracked-files=all"], timeout: try remainingTimeout(start: start))
        // `git status` has no `--relative` (see `scopeSignature`'s comment on the same probe), so a
        // subtree-rooted workspace needs its porcelain paths scoped and stripped by hand via the repo
        // prefix. A no-op when the workspace IS the repo root (`prefix.isEmpty`), matching the enumeration
        // above.
        let prefix = (try? gitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--show-prefix"], timeout: try remainingTimeout(start: start)))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scopedStatusEntries =
            prefix.isEmpty ? changedEntries(fromPorcelainZ: statusOutput) : subtreeScoped(changedEntries(fromPorcelainZ: statusOutput), prefix: prefix)
        // `--untracked-files=all` should mean every `??` record is already a file, never a directory, but
        // the filter costs nothing and defends against any edge git itself has not been audited against
        // (e.g. a submodule or other non-regular-file entry reported with a trailing slash).
        let untrackedPaths = scopedStatusEntries.filter { $0.status == "??" && !$0.path.hasSuffix("/") }.map(\.path)

        // A path can appear in both enumerations above under exactly one collision shape: `--name-status`
        // reports it `.deleted` relative to `compareRef` (gone from the tree/index) while `git status` ALSO
        // reports it untracked (`??`, present on disk). Any other name-status entry means the path is still
        // in the index, so it can never simultaneously be `??`; and a rename's `oldPath`, if recreated
        // untracked, is a different path from the rename entry's own `path` (the new path), so it is never
        // mistaken for this collision either — both verified against real git before wiring this in. Left
        // unhandled, the same path would report as two unrelated entries (a delete and an add) instead of
        // the one content change it actually is.
        let untrackedPathSet = Set(untrackedPaths)
        let deletedButUntrackedPaths = Set(plans.filter { $0.status == .deleted && untrackedPathSet.contains($0.path) }.map(\.path))
        if !deletedButUntrackedPaths.isEmpty {
            plans = plans.map { plan in
                guard deletedButUntrackedPaths.contains(plan.path) else { return plan }
                return DiffFilePlan(path: plan.path, oldPath: nil, status: .modified, source: .deletedButUntrackedInWorktree(compareRef: compareRef))
            }
        }
        plans += untrackedPaths.filter { !deletedButUntrackedPaths.contains($0) }
            .map { path in DiffFilePlan(path: path, oldPath: nil, status: .untracked, source: .untracked) }

        var totalPatchBytes = 0
        var overTotalCap = false
        // Checked once per iteration, before spawning git for that file, so a file already in flight when
        // the deadline passes still finishes cleanly rather than being cut off mid-process. Sticky like
        // `overTotalCap`: once tripped, every remaining file reports the same truncated shape with no git
        // spawned for it — an elapsed check does not un-trip on its own.
        var pastDeadline = false
        var files: [SpacesDeviceWorkspaceDiffFile] = []
        files.reserveCapacity(plans.count)
        for plan in plans {
            if overTotalCap || pastDeadline {
                files.append(SpacesDeviceWorkspaceDiffFile(path: plan.path, oldPath: plan.oldPath, status: plan.status, truncated: true))
                continue
            }
            // `remainingTimeout` both re-checks the deadline (throwing once the remainder reaches zero) and
            // yields the correctly shrunk per-file timeout in one call, so this replaces what used to be a
            // separate `Date() >= deadline` check ahead of a flat `gitCommandTimeout` passed to `buildFile`.
            // A per-file *expiry* here must land on the same truncated-file shape every other cap in this
            // loop uses, never a thrown request-level error — the request-level throw out of
            // `remainingTimeout` is reserved for the up-front commands above, where there is no per-file
            // identity yet to truncate onto. `try?` deliberately discards that thrown case rather than
            // propagating it: expiry becoming `nil` here is exactly the "sticky, truncate the rest" outcome
            // this loop already has a shape for.
            guard let fileTimeout = try? remainingTimeout(start: start) else {
                pastDeadline = true
                files.append(SpacesDeviceWorkspaceDiffFile(path: plan.path, oldPath: plan.oldPath, status: plan.status, truncated: true))
                continue
            }
            let file = try buildFile(for: plan, workspaceDir: workspaceDir, gitClient: gitClient, timeout: fileTimeout)
            if let patch = file.patch {
                let patchBytes = patch.utf8.count
                guard totalPatchBytes + patchBytes <= totalPatchByteCap else {
                    overTotalCap = true
                    files.append(
                        SpacesDeviceWorkspaceDiffFile(
                            path: plan.path, oldPath: plan.oldPath, status: plan.status, isBinary: file.isBinary, truncated: true))
                    continue
                }
                totalPatchBytes += patchBytes
            }
            files.append(file)
        }

        return SpacesDeviceWorkspaceDiffResult(scopeSignature: signature, files: files)
    }

    /// `timeout` is the caller's already-shrunk-to-the-request-deadline budget (see `buildDiff`'s loop,
    /// which resolves it via `remainingTimeout` before calling in), never a flat `gitCommandTimeout` — a
    /// file whose git only starts near the end of `diffBuildDeadline` must not get a fresh full timeout, or
    /// the request can run well past the client's own abandonment horizon while still holding the
    /// workspace's serial queue.
    ///
    /// `runGitAndCapture`'s `maxOutputBytes: perFilePatchByteCap + 1` caps RAW captured bytes, but every
    /// engine call site decodes that raw output with a lossy `String(decoding:as:)` (see the doc comment on
    /// `RemoteWorkspaceGitClient.runGitAndCapture`) that turns each invalid UTF-8 byte into a 3-byte U+FFFD
    /// replacement. A patch built mostly of invalid bytes can therefore pass the raw cap comfortably and
    /// still decode to roughly 3x that size, reaching the client with no `truncated` flag even though it is
    /// well over the per-file contract — the 8-MiB aggregate cap in `buildDiff` still holds regardless, since
    /// it sums post-decode `utf8.count`, but the per-file guarantee would be silently broken. Rechecking the
    /// decoded size here (skipped for a binary patch, whose short "Binary files ... differ" marker is never
    /// large regardless of the raw content's byte validity, and whose `patch` field is discarded anyway)
    /// keeps the per-file cap honest post-decode, not just pre-decode.
    private static func exceedsPerFilePatchByteCapAfterDecode(_ patchText: String, isBinary: Bool) -> Bool {
        !isBinary && patchText.utf8.count > perFilePatchByteCap
    }

    /// A timeout that fires mid-capture is *not* mapped to a truncated entry here: `runGitAndCapture`
    /// throws the same `.gitCommandFailed` shape for a deadline-shortened timeout and for a genuinely hung
    /// git process under the ordinary 30s budget, and there is no clean signal here to tell those two apart
    /// without a message-string heuristic. Rather than guess, this keeps the pre-existing behavior for that
    /// case (propagate as a whole-request failure) and only fixes the timeout *value* passed in above; only
    /// the byte-cap overrun below degrades to a truncated file, exactly as before.
    private static func buildFile(for plan: DiffFilePlan, workspaceDir: String, gitClient: RemoteWorkspaceGitClient, timeout: TimeInterval) throws
        -> SpacesDeviceWorkspaceDiffFile
    {
        switch plan.source {
        case .tracked(let diffArguments):
            do {
                let patchText = try gitClient.runGitAndCapture(diffArguments, timeout: timeout, maxOutputBytes: perFilePatchByteCap + 1)
                let metadata = parsePatchMetadata(patchText)
                if exceedsPerFilePatchByteCapAfterDecode(patchText, isBinary: metadata.isBinary) {
                    return SpacesDeviceWorkspaceDiffFile(path: plan.path, oldPath: plan.oldPath, status: plan.status, truncated: true)
                }
                return SpacesDeviceWorkspaceDiffFile(
                    path: plan.path, oldPath: plan.oldPath, status: plan.status, patch: metadata.isBinary ? nil : patchText,
                    isBinary: metadata.isBinary, truncated: false, oldSHA: metadata.oldSHA, newSHA: metadata.newSHA)
            } catch SpacesRuntimeError.outputExceededCap {
                return SpacesDeviceWorkspaceDiffFile(path: plan.path, oldPath: plan.oldPath, status: plan.status, truncated: true)
            }
        case .untracked:
            return try buildUntrackedFile(path: plan.path, workspaceDir: workspaceDir, gitClient: gitClient, timeout: timeout)
        case .deletedButUntrackedInWorktree(let compareRef):
            return try buildCoalescedDeletedButUntrackedFile(
                path: plan.path, compareRef: compareRef, workspaceDir: workspaceDir, gitClient: gitClient, timeout: timeout)
        }
    }

    /// Builds the single coalesced entry for a `.deletedButUntrackedInWorktree` plan (see that case's
    /// comment): a path `--name-status` reports `.deleted` relative to `compareRef` while `git status`
    /// separately reports it untracked, because the worktree file is not staged for it. Diffing that
    /// directly would either compare against nothing (git has no tracked content to diff `--no-index`
    /// style two ways at once) or require hand-assembling a patch header — this instead stages the
    /// worktree file into a scratch index scoped to this one call via `GIT_INDEX_FILE`, so an ordinary
    /// `git diff <compareRef>` sees `path` as a tracked, modified file and emits a native patch with
    /// correct `a/`/`b/` headers and real blob SHAs (empirically verified against real git: `update-index
    /// --add` under a temp `GIT_INDEX_FILE` followed by `diff <compareRef> -- path` reproduces exactly the
    /// base-blob-vs-worktree patch, including the `index <old>..<new> <mode>` line `parsePatchMetadata`
    /// already parses for every other tracked capture).
    ///
    /// `update-index --add` also writes the worktree content as a loose object into the repository's real
    /// object store (the same side effect `git add` has) — accepted here rather than avoided: this is a
    /// same-user local repository, the object store is content-addressed so re-diffing the same content
    /// never grows it, and an unreferenced loose object is exactly what `git gc` already prunes. That write
    /// is bounded by `perFilePatchByteCap`: the pre-stat gate below truncates an over-cap regular file
    /// before ever calling `update-index`, so this never hashes/writes more than that cap's worth of content
    /// regardless of the recreated file's actual on-disk size.
    ///
    /// The scratch index is a bare per-call temp file (never a real index git would otherwise recognize),
    /// created empty by the first `update-index --add` and removed in `defer` regardless of outcome.
    private static func buildCoalescedDeletedButUntrackedFile(
        path: String, compareRef: String, workspaceDir: String, gitClient: RemoteWorkspaceGitClient, timeout: TimeInterval
    ) throws -> SpacesDeviceWorkspaceDiffFile {
        // Mirrors `buildUntrackedFile`'s pre-stat gate (lstat via `attributesOfItem`, never `open`), run
        // BEFORE any git invocation — this builder has none of that guard otherwise, and `update-index --add`
        // unconditionally reads and SHA-hashes whatever is at `path` to write it as a loose object. Kept as
        // its own duplicated-but-commented gate rather than sharing a helper with `buildUntrackedFile`: the
        // two return incompatible shapes (`.untracked` there, `.modified` here) and only the untracked path
        // needs the binary pre-sniff (a sub-cap binary here is cheap to stage, and the existing
        // `parsePatchMetadata.isBinary` handling downstream already classifies it correctly), so a shared
        // helper would mostly be a parameterized fork rather than a real reduction in duplication.
        let fullPath = (workspaceDir as NSString).appendingPathComponent(path)
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath), let size = attributes[.size] as? Int else {
            // Raced with a delete between the status scan and this stat. The plan already replaced the
            // tracked `.deleted` name-status entry with this coalesced one, so there is no tracked delete
            // left to fall back to — report a bare modified entry (nil patch, not truncated) rather than
            // attempting to reconstruct a delete patch for a file that vanished mid-request. Same honesty
            // rationale as `buildUntrackedFile`'s own raced-delete branch.
            return SpacesDeviceWorkspaceDiffFile(path: path, status: .modified)
        }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else {
            // A recreated FIFO/socket/device must never reach `update-index --add`. Empirically verified
            // against real git (2.50.1): contrary to the naive "git must open it to hash it, so it blocks"
            // assumption, `update-index --add` on a bare FIFO fails IMMEDIATELY ("error: unsupported file
            // type" / "fatal: Unable to process path") — git's own lstat-based type check refuses it before
            // any open/hash attempt, so this specific command does not hang. The guard is still required,
            // though: that immediate failure is an ordinary nonzero-exit `gitCommandFailed` this switch
            // branch has no truncation path for, so left unguarded it would abort the WHOLE `buildDiff`
            // request over one recreated special file instead of degrading just this one entry — the same
            // failure mode `buildUntrackedFile`'s own non-regular guard exists to avoid, just via a fast
            // failure here rather than a hang.
            //
            // In practice this branch is defense-in-depth rather than the common case: `git status`'s own
            // untracked-file scan silently omits a bare non-regular path (empirically confirmed — a `.deleted`
            // tracked entry recreated as a bare FIFO shows only as `D  path`, never paired with `?? path`), so
            // `deletedButUntrackedPaths` never contains one and this coalescing path is not invoked for it at
            // all; the reachable case here is the same scan-to-build race the unstattable guard above handles,
            // just for a type change (regular/symlink at scan time, replaced by a non-regular file before this
            // runs) instead of a delete.
            return SpacesDeviceWorkspaceDiffFile(path: path, status: .modified)
        }
        if type == .typeRegular {
            guard size <= perFilePatchByteCap else {
                // Without this, `update-index --add` below would read and SHA-hash the entire file and write
                // it as a loose object into the repository's real object store regardless of size — a
                // read-only diff request writing a multi-GB object into `.git/objects`, and re-paying the
                // full hash cost on every subsequent pull of the same oversized recreated file.
                return SpacesDeviceWorkspaceDiffFile(path: path, status: .modified, truncated: true)
            }
        } else {
            // type == .typeSymbolicLink. Unlike `buildUntrackedFile`'s equivalent branch, this needs no
            // followed-`stat()` guard for a symlink whose target is itself a FIFO: empirically verified
            // against real git (2.50.1) that BOTH `update-index --add` on such a symlink AND the subsequent
            // `diff <compareRef>` against the scratch index below complete immediately and never touch the
            // target — `update-index --add` records a mode-120000 entry from the link text alone (lstat +
            // readlink, no open), and the resulting diff is the ordinary "link text changed" patch, exactly
            // as `buildUntrackedFile`'s own no-index diff treats an untracked symlink. A symlink's own
            // content (the link text) is always tiny regardless of what it resolves to, so it is let through
            // here unconditionally.
        }

        let scratchIndexPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("spaces-workspacediff-\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(atPath: scratchIndexPath) }
        let scratchIndexEnvironment = ["GIT_INDEX_FILE": scratchIndexPath]

        _ = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "update-index", "--add", "--", path], timeout: timeout, environmentOverrides: scratchIndexEnvironment)
        do {
            // `--relative`: see `buildDiff`'s comment on the same flag — keeps this patch's own headers
            // workspace-relative for a subtree-rooted workspace, a no-op otherwise. `path` (from `plan.path`,
            // already workspace-relative via the `--relative`-scoped `--name-status` enumeration) resolves
            // against CWD (`workspaceDir`) the same way regardless.
            let patch = try gitClient.runGitAndCapture(
                [
                    "-C", workspaceDir, "-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--relative",
                    compareRef, "--", ":(literal)\(path)",
                ],
                timeout: timeout, maxOutputBytes: perFilePatchByteCap + 1, environmentOverrides: scratchIndexEnvironment)
            let metadata = parsePatchMetadata(patch)
            if exceedsPerFilePatchByteCapAfterDecode(patch, isBinary: metadata.isBinary) {
                return SpacesDeviceWorkspaceDiffFile(path: path, status: .modified, truncated: true)
            }
            // An empty patch means the worktree content is byte-identical to the base blob — the only way
            // `git rm --cached f` (or the ref-scoped equivalent) can leave `f` reporting dirty with no
            // actual content difference. `nil` here (never the empty string) rather than folding it back
            // into `.deleted`: `git status` itself still calls this path modified/dirty, so `.modified`
            // with nothing to show is the more honest of the two mischaracterizations.
            let patchValue: String? = patch.isEmpty || metadata.isBinary ? nil : patch
            return SpacesDeviceWorkspaceDiffFile(
                path: path, status: .modified, patch: patchValue, isBinary: metadata.isBinary, oldSHA: metadata.oldSHA, newSHA: metadata.newSHA)
        } catch SpacesRuntimeError.outputExceededCap {
            return SpacesDeviceWorkspaceDiffFile(path: path, status: .modified, truncated: true)
        }
    }

    // MARK: - `git status --porcelain -z` parsing

    private struct PorcelainEntry { let status: String; let path: String; let origPath: String? }

    /// Parses NUL-delimited `git status --porcelain -z` output. Each record is `XY PATH`, except for a
    /// rename/copy (`X` or `Y` is `R`/`C`), whose original path follows as its own NUL-terminated record
    /// with no `XY ` prefix.
    private static func changedEntries(fromPorcelainZ output: String) -> [PorcelainEntry] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [PorcelainEntry] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.count > 3 else { continue }
            let status = String(token.prefix(2))
            let path = String(token.dropFirst(3))
            var origPath: String?
            if status.contains("R") || status.contains("C"), index < tokens.count {
                origPath = tokens[index]
                index += 1
            }
            entries.append(PorcelainEntry(status: status, path: path, origPath: origPath))
        }
        return entries
    }

    /// Scopes `entries` (parsed from a repo-root-relative `git status --porcelain -z`) down to just the
    /// subtree a workspace rooted below its repository root owns, and strips `prefix` from every path field
    /// so the result is workspace-relative — matching what `buildDiff`'s own `--relative`-scoped tracked
    /// enumeration reports for the same files. `git status` has no `--relative` of its own (confirmed
    /// against real git: `error: unknown option 'relative'`), so this is the client-side equivalent, shared
    /// by both `scopeSignature` and `buildDiff`'s untracked-file discovery — the one definition both must
    /// use, per the fix this implements.
    ///
    /// An entry is kept when its current path (`path` — the *new* path for a rename, see `changedEntries`'s
    /// doc) lies under `prefix`; `origPath` is stripped too when it also falls under `prefix`, and left
    /// root-relative otherwise (a rename moved a file IN from outside the subtree). Nothing downstream reads
    /// `origPath` — `scopeSignature`'s stat loop and the untracked filter both key off `path` alone — so
    /// this asymmetry has no observable effect beyond what the hash below folds in.
    ///
    /// A rename crossing the boundary the OTHER way (moved OUT of the subtree) is dropped entirely: its
    /// current path is outside `prefix`, even though the file did disappear from inside the workspace. This
    /// differs from the *diff* side (`--name-status --relative`), where git itself auto-demotes such a
    /// rename into a plain deletion of the inside path — porcelain has no equivalent demotion, and
    /// reconstructing "the old half was inside, so treat this as a delete" is not attempted here. Accepted
    /// narrow gap: it only matters for a *staged* rename that also happens to cross this exact subtree
    /// boundary, and self-corrects the moment anything else in the workspace changes and re-trips
    /// `scopeSignature` on its own.
    private static func subtreeScoped(_ entries: [PorcelainEntry], prefix: String) -> [PorcelainEntry] {
        entries.compactMap { entry in
            guard entry.path.hasPrefix(prefix) else { return nil }
            let strippedPath = String(entry.path.dropFirst(prefix.count))
            let strippedOrig = entry.origPath.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
            return PorcelainEntry(status: entry.status, path: strippedPath, origPath: strippedOrig)
        }
    }

    /// Deterministic byte encoding of already subtree-scoped/stripped porcelain entries, fed into
    /// `scopeSignature`'s hash in place of the raw `git status --porcelain -z` bytes once a non-empty
    /// subtree `prefix` is in play — the original NUL-delimited stream cannot simply be sliced back out in
    /// scoped order, so this reconstructs an equivalent stable encoding from the parsed, already-scoped
    /// entries instead. The exact shape is private to this hash input (never surfaced to a client); only
    /// that it is a deterministic function of `entries` matters.
    private static func serializeScoped(_ entries: [PorcelainEntry]) -> Data {
        var data = Data()
        for entry in entries {
            data.append(Data("\(entry.status) \(entry.path)\0".utf8))
            if let origPath = entry.origPath {
                data.append(Data("\(origPath)\0".utf8))
            }
        }
        return data
    }

    // MARK: - `git diff --name-status -z` parsing

    private struct NameStatusEntry { let status: SpacesDeviceWorkspaceDiffFileStatus; let path: String; let oldPath: String? }

    /// Parses `git diff -M --name-status -z <ref>` output: NUL-delimited records, `STATUS\0PATH\0` for an
    /// add/modify/delete, or `STATUS\0OLDPATH\0NEWPATH\0` for a rename/copy (`R100`, `C75`, ...) — the old
    /// path comes first, matching `--name-status`'s tab-separated "old TAB new" ordering. This -z output is
    /// the one and only source of `path`/`oldPath`/`status` on every returned file: it is exact bytes
    /// (never C-quoted), unlike `git diff`'s human-readable `diff --git a/... b/...` header.
    private static func parseNameStatusZ(_ output: String) -> [NameStatusEntry] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [NameStatusEntry] = []
        var index = 0
        while index < tokens.count {
            let statusToken = tokens[index]
            index += 1
            guard let statusLetter = statusToken.first else { continue }
            switch statusLetter {
            case "R", "C":
                guard index + 1 < tokens.count else { continue }
                let oldPath = tokens[index]
                let newPath = tokens[index + 1]
                index += 2
                entries.append(NameStatusEntry(status: .renamed, path: newPath, oldPath: oldPath))
            case "A":
                guard index < tokens.count else { continue }
                entries.append(NameStatusEntry(status: .added, path: tokens[index], oldPath: nil))
                index += 1
            case "D":
                guard index < tokens.count else { continue }
                entries.append(NameStatusEntry(status: .deleted, path: tokens[index], oldPath: nil))
                index += 1
            default:  // M, T, and anything else git reports as a plain content change.
                guard index < tokens.count else { continue }
                entries.append(NameStatusEntry(status: .modified, path: tokens[index], oldPath: nil))
                index += 1
            }
        }
        return entries
    }

    /// Extracts just the "Binary files ... differ" marker and the `index <old>..<new>` blob SHAs from one
    /// file's `git diff` output — the only pieces of a patch body this engine still parses, now that
    /// identity comes from `--name-status -z`.
    private static func parsePatchMetadata(_ patchText: String) -> (isBinary: Bool, oldSHA: String?, newSHA: String?) {
        var isBinary = false
        var oldSHA: String?
        var newSHA: String?
        for line in patchText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Binary files "), line.hasSuffix(" differ") {
                isBinary = true
            } else if line.hasPrefix("index ") {
                let shaField = line.dropFirst("index ".count).split(separator: " ").first ?? ""
                let shas = shaField.split(separator: ".", omittingEmptySubsequences: true)
                if shas.count >= 2 {
                    oldSHA = String(shas[0])
                    newSHA = String(shas[1])
                }
            }
        }
        return (isBinary, oldSHA, newSHA)
    }

    /// Synthesizes an add-diff for one untracked file via `git diff --no-index /dev/null <path>` (per the
    /// Phase 2 spec's recipe). `--no-index` uses `--exit-code` semantics — exit 1 whenever the compared
    /// paths differ, which is always true here since one side is `/dev/null` — so `allowedExitCodes: [0,
    /// 1]` tells `runGitAndCapture` that is expected, not a failure.
    ///
    /// Bounded at every step so a large untracked file is never fully materialized: size is checked before
    /// any read, the binary guess reads only its first `sniffLength` bytes, and the patch capture itself is
    /// capped at `perFilePatchByteCap`.
    private static func buildUntrackedFile(path: String, workspaceDir: String, gitClient: RemoteWorkspaceGitClient, timeout: TimeInterval) throws
        -> SpacesDeviceWorkspaceDiffFile
    {
        let fullPath = (workspaceDir as NSString).appendingPathComponent(path)
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath), let size = attributes[.size] as? Int else {
            // Raced with a delete/rename between the status scan and this stat; report it as an empty
            // untracked addition rather than failing the whole diff for one file that vanished mid-request.
            return SpacesDeviceWorkspaceDiffFile(path: path, status: .untracked)
        }

        // `attributesOfItem` has lstat semantics: for a symlink it reports the link's own type and size,
        // never the target's. Opening the path for the sniff below, though, follows the link (`FileHandle`
        // uses stat semantics) — so the two disagree about what "this file" is. That asymmetry is the trap:
        // `git diff --no-index` itself treats an untracked symlink as its own tiny text content (a one-line
        // mode-120000 patch naming the target path), so sniffing what the link *resolves to* would
        // misreport a symlink-to-binary-content as `isBinary` with no patch. A symlink therefore skips the
        // regular-file size cap and byte sniff entirely (its own "content" is always small text). Anything
        // else non-regular (FIFO, socket, device, ...) must never be opened or handed to `git` at all:
        // opening a FIFO here blocks indefinitely waiting for a writer with no timeout, and even the bounded
        // git subprocess timeout would still stall this whole `workspaceDiff` pull for up to 30s over one
        // special file. Such a path is reported as a bare untracked entry with no patch instead.
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else {
            return SpacesDeviceWorkspaceDiffFile(path: path, status: .untracked)
        }

        if type == .typeRegular {
            guard size <= perFilePatchByteCap else {
                return SpacesDeviceWorkspaceDiffFile(path: path, status: .untracked, truncated: true)
            }

            guard let handle = FileHandle(forReadingAtPath: fullPath) else {
                return SpacesDeviceWorkspaceDiffFile(path: path, status: .untracked)
            }
            defer { try? handle.close() }
            let sniff = (try? handle.read(upToCount: SpacesDeviceWorkspaceBinaryGuess.sniffLength)) ?? Data()
            guard !SpacesDeviceWorkspaceBinaryGuess.isLikelyBinary(sniff) else {
                return SpacesDeviceWorkspaceDiffFile(path: path, status: .untracked, isBinary: true)
            }
        } else {
            // type == .typeSymbolicLink. Naively handing every symlink straight to `git diff --no-index`
            // (as the "diffs the link itself, never its target" behavior above would suggest) is not
            // actually safe: empirically, `git diff --no-index` still blocks indefinitely on a symlink
            // whose target is a FIFO, regardless of output format or which side of the compare it is on —
            // its no-index diff machinery does not stop at lstat either. So this independently confirms,
            // via a *followed* `stat` (never `open`, so it cannot itself block even against a FIFO), that
            // the link's ultimate target is either a regular file or does not exist (a dangling symlink,
            // which git safely reports as link text without ever touching a target) before it is safe to
            // hand to git. Any other resolved type (FIFO, socket, device, directory, ...) is refused the
            // same way a directly non-regular untracked path is: a bare entry with no patch, without ever
            // invoking git on it.
            var targetStat = stat()
            if stat(fullPath, &targetStat) == 0, (targetStat.st_mode & S_IFMT) != S_IFREG {
                return SpacesDeviceWorkspaceDiffFile(path: path, status: .untracked)
            }
        }

        do {
            let patch = try gitClient.runGitAndCapture(
                [
                    "-C", workspaceDir, "-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-index", "--",
                    "/dev/null", path,
                ],
                timeout: timeout, allowedExitCodes: [0, 1], maxOutputBytes: perFilePatchByteCap + 1)
            // The sniff above is only an advisory early-out that avoids spawning git for obvious binaries —
            // it sees at most `sniffLength` bytes and knows nothing of `.gitattributes` (a `-diff` attribute
            // forces git to treat even plain-text content as binary). Git's own "Binary files ... differ"
            // marker in the captured patch is authoritative, so run it through the same `parsePatchMetadata`
            // the tracked path uses and defer to it.
            let metadata = parsePatchMetadata(patch)
            if exceedsPerFilePatchByteCapAfterDecode(patch, isBinary: metadata.isBinary) {
                return SpacesDeviceWorkspaceDiffFile(path: path, status: .untracked, truncated: true)
            }
            return SpacesDeviceWorkspaceDiffFile(
                path: path, status: .untracked, patch: metadata.isBinary ? nil : patch, isBinary: metadata.isBinary, oldSHA: metadata.oldSHA,
                newSHA: metadata.newSHA)
        } catch SpacesRuntimeError.outputExceededCap {
            return SpacesDeviceWorkspaceDiffFile(path: path, status: .untracked, truncated: true)
        }
    }
}

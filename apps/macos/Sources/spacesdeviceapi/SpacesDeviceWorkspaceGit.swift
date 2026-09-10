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
    enum PathError: Error { case escapesWorkspace, containsSymbolicLink }

    /// Returns the lexical workspace path only when every existing component is a non-symlink.
    /// Inline diff editing renders a patch for this exact path, so following a contained symlink would
    /// let Save update a different file than the patch's identity. Ordinary Editor access continues to
    /// use `resolveContainedPath`, where contained symlinks are intentional.
    static func resolveDirectPath(relativePath: String, workspaceDir: String, fileManager: FileManager = .default) throws -> String {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { throw PathError.escapesWorkspace }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." }) else { throw PathError.escapesWorkspace }

        let workspaceRoot = URL(fileURLWithPath: workspaceDir, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var candidate = workspaceRoot
        for component in components {
            candidate.appendPathComponent(String(component), isDirectory: false)
            if let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                attributes[.type] as? FileAttributeType == .typeSymbolicLink
            {
                throw PathError.containsSymbolicLink
            }
        }
        return candidate.path
    }

    /// Whether a gitlink's checkout at `repoRelativePath` under `repoDir` is one this daemon may run git
    /// in. Three facts, all required: no component of the path is a symlink or a `.`/`..` traversal, the
    /// path itself is a real directory, and that directory holds its own `.git` (a file for a normal `git
    /// submodule` checkout, whose real git dir lives under the superproject's `.git/modules`, a directory
    /// for an older-style one).
    ///
    /// Every part of the diff, the file listing, the signature, and the revision reads that descends into a
    /// submodule asks this first, so they all agree on what counts as a checkout. Two of the three facts
    /// are load-bearing rather than optimizations. The `.git` requirement is: git's ancestor search
    /// resolves a command run with `-C <uninitialized submodule directory>` against the SUPERPROJECT
    /// instead of failing, so a caller that skipped it would silently answer about the repository above.
    /// The symlink rule is what keeps the daemon inside the workspace: a tracked gitlink whose directory
    /// has been replaced by a symlink to a repository elsewhere on the machine is a path git itself does
    /// not treat as that submodule's checkout, and following it would stream an unrelated repository's
    /// files, patches, and blobs as though they were part of this workspace. `attributesOfItem` reports the
    /// link itself rather than its target, so the leaf's own type settles it, and `resolveDirectPath`
    /// applies the same rule to every component above the leaf.
    ///
    /// A path that fails any of the three is not an error here: it means "no checkout to descend into",
    /// which every caller already has an honest representation for (a pointer-only row, an unlisted
    /// submodule, a path that belongs to the repository above it).
    static func isContainedGitlinkCheckout(repoDir: String, repoRelativePath: String, fileManager: FileManager = .default) -> Bool {
        guard
            let checkoutPath = try? resolveDirectPath(relativePath: repoRelativePath, workspaceDir: repoDir, fileManager: fileManager),
            let attributes = try? fileManager.attributesOfItem(atPath: checkoutPath),
            attributes[.type] as? FileAttributeType == .typeDirectory
        else { return false }
        return fileManager.fileExists(atPath: (checkoutPath as NSString).appendingPathComponent(".git"))
    }

    /// Resolves `relativePath` against `workspaceDir` and asserts the result stays inside it.
    ///
    /// Rejects an absolute path and any `.`/`..` path component outright, then follows symlinks on the
    /// nearest existing ancestor of the target (the leaf itself may not exist yet — a file-write create —
    /// so containment cannot simply `resolvingSymlinksInPath()` the full candidate path) and asserts that
    /// resolved ancestor is inside the workspace's own resolved root.
    ///
    /// A DANGLING symlink (the link itself exists; its target does not) is not skipped as if it were a
    /// plain missing component: `fileManager.fileExists` follows links, so it reports `false` for a
    /// dangling link exactly like it does for a component that is not there at all, and treating the two
    /// the same would let a dangling link steer a create/write outside the workspace unchecked. Instead,
    /// each component that `fileExists` calls missing is `lstat`'d — via `attributesOfItem`, which reports
    /// the link itself rather than its (absent) target — and, if it is a symlink, its target is substituted
    /// in and the walk continues from there, exactly as a live symlink's target already is. A dangling link
    /// pointing back inside the workspace must keep resolving there (an agent deleting a tracked file and
    /// the editor's "Keep mine" recreating it through the same relative link, or a plain missing-file read,
    /// must not break); only a dangling link that resolves outside the workspace is rejected. A link chain
    /// is capped at `maxSymlinkSubstitutions` to bound the walk.
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

        // Bounds the number of dangling-symlink substitutions the walk below will follow, matching typical
        // kernel SYMLOOP_MAX behavior for a live-symlink chain.
        let maxSymlinkSubstitutions = 8
        var symlinkSubstitutions = 0

        var existingAncestor = candidate
        var remainder: [String] = []
        while !fileManager.fileExists(atPath: existingAncestor.path) {
            if let attributes = try? fileManager.attributesOfItem(atPath: existingAncestor.path),
                (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
            {
                symlinkSubstitutions += 1
                guard symlinkSubstitutions <= maxSymlinkSubstitutions else { throw PathError.escapesWorkspace }

                let target = try fileManager.destinationOfSymbolicLink(atPath: existingAncestor.path)
                let targetURL =
                    target.hasPrefix("/")
                    ? URL(fileURLWithPath: target).standardizedFileURL
                    : URL(fileURLWithPath: target, relativeTo: existingAncestor.deletingLastPathComponent()).standardizedFileURL
                existingAncestor = remainder.reduce(targetURL) { $0.appendingPathComponent($1) }.standardizedFileURL
                remainder = []
                continue
            }
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

    /// Streams `atPath` through an incremental SHA-256 hasher in fixed chunks rather than materializing
    /// the whole file as one `Data` (unlike `sha256Hex`, used by `workspaceFileRead`/`workspaceFileWrite`,
    /// which cap at 10 MiB because they return content over the wire). The file-signature poll only needs
    /// the hash, never the content, so per the phase 5 spec it is not subject to that cap — this hashes a
    /// file of any size a chunk at a time. Returns nil on any read error (the poll's provider-failure /
    /// skip-tick signal), never throws.
    static func streamingSHA256Hex(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let chunkSize = 1_048_576
        #if canImport(CryptoKit)
            var hasher = SHA256()
            while true {
                // `read(upToCount:)` returns nil to signal ordinary EOF, not just to report a thrown read
                // error — collapsing both cases into "no chunk, stop" via a bare `try?` would make the loop
                // exit at EOF before ever finalizing a hash for any file. A genuine I/O error is instead
                // caught explicitly and reported as this function's own nil ("provider failure") result.
                let chunk: Data?
                do { chunk = try handle.read(upToCount: chunkSize) } catch { return nil }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        #elseif canImport(OpenSSL)
            var context = SHA256_CTX()
            guard OpenSSL.SHA256_Init(&context) == 1 else { return nil }
            while true {
                // See the CryptoKit branch above: nil here means ordinary EOF, not a read failure.
                let chunk: Data?
                do { chunk = try handle.read(upToCount: chunkSize) } catch { return nil }
                guard let chunk, !chunk.isEmpty else { break }
                let updated = chunk.withUnsafeBytes { rawBuffer -> Int32 in
                    guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return OpenSSL.SHA256_Update(&context, baseAddress, chunk.count)
                }
                guard updated == 1 else { return nil }
            }
            // A zero-byte file never enters the loop above, so `SHA256_Update` is never called for it —
            // matching `sha256Hex`'s own empty-input special case, `SHA256_Final` alone still produces the
            // correct empty-input digest without needing a dummy `Update` call.
            var digest = [UInt8](repeating: 0, count: Int(SHA256_DIGEST_LENGTH))
            guard OpenSSL.SHA256_Final(&digest, &context) == 1 else { return nil }
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
/// building and the cheap `scopeSignature` change-detection token both the manifest endpoint and
/// `subscribeWorkspaceDiffSignature`'s poll timer use. Pure functions over an explicit `workspaceDir` and
/// `RemoteWorkspaceGitClient` so they need no server state and can run off any queue.
enum SpacesDeviceWorkspaceDiffEngine {
    /// Bounds every git subprocess this engine spawns, so a wedged repository (a hung textconv/external
    /// diff helper, a stalled filesystem) cannot permanently occupy the workspace's serial queue or the
    /// diff-signature poll queue. 30s is far above any healthy repo operation.
    private static let gitCommandTimeout: TimeInterval = 30

    /// Upper bound on the wall-clock time a manifest or initial file-patch request spends validating and
    /// building its immediate git work. It is measured from `deadlineStart`, a clock the caller starts
    /// BEFORE repository/ref validation even runs, and threads through both `assertRefIsResolvable` and
    /// `buildDiffPlanSnapshot` unchanged. Before this, `assertRefIsResolvable` and the plan builder each started their own
    /// fresh `Date()`, so validation and patch-building silently stacked into a COMBINED wall-clock time
    /// that could exceed this deadline several times over (repo probe + ref validation + a full fresh
    /// manifest/patch budget) while the client had already abandoned the request at its own ~60s timeout —
    /// holding the workspace's serial git queue for work nobody would read the answer to, with the client's
    /// retry then queued behind it. Sharing one clock across all three steps closes that gap: whatever
    /// wall-clock time repo/ref validation already spent is deducted from what the operation gets, so the sum
    /// of a request's git work can never outlive this single window.
    ///
    /// Each patch producer receives a timeout shrunk to whatever remains of this deadline (via
    /// `remainingTimeout`, never a flat `gitCommandTimeout`). Kept under the client's ~60s request timeout
    /// so the daemon never continues to occupy a workspace's serial queue for a request the client has
    /// already abandoned.
    private static let diffBuildDeadline: TimeInterval = 45

    /// Caps one of the manifest plan's up-front commands (`scopeSignature`'s own probes, the merge-base, the
    /// `--raw` enumeration, the untracked `status` scan) to whatever remains of `diffBuildDeadline`
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
            throw SpacesRuntimeError.gitCommandFailed(message: "Git command timed out after \(diffBuildDeadline)s: request-wide deadline elapsed")
        }
        return min(gitCommandTimeout, remaining)
    }

    /// `git rev-parse --show-prefix` terminates its output with exactly one trailing newline, but a leading
    /// space or tab in its output is not incidental whitespace to discard — it is part of the subtree path
    /// itself (a repo-relative directory can legitimately be named e.g. `" sub"`). The shared scope
    /// snapshot used by `scopeSignature` and `buildDiffPlanSnapshot` uses this instead of
    /// `.trimmingCharacters(in: .whitespacesAndNewlines)`, which would strip that leading whitespace and
    /// make `subtreeScoped` compare porcelain paths against a mismatched prefix, silently rejecting the
    /// workspace's own entries as apparently outside its subtree.
    private static func strippingTrailingNewline(_ output: String) -> String {
        var result = output
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    /// Normalizes a client-supplied `refName` the same way for every pull-side consumer here
    /// (`scopeSignature`, `buildDiffPlanSnapshot`) — nil, empty, or whitespace-only all mean "no ref: diff against
    /// HEAD", never an empty argument handed to `git merge-base`. This must agree with
    /// `WorkspaceDiffScope`'s own normalization in `SpacesDeviceAPIServer.swift`: that type decides which
    /// scope a `subscribeWorkspaceDiffSignature` client is subscribed to, and if the two normalizations ever
    /// diverged, a blank ref could subscribe successfully as the uncommitted scope while every pull against
    /// that same blank ref failed with a merge-base error on an empty argument.
    static func normalizedRefName(_ refName: String?) -> String? {
        guard let trimmed = refName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The one shared refusal both `workspaceDiffManifestChunk` and `subscribeWorkspaceDiffSignature` need for a
    /// non-git workspace directory. A single workspace can be just a project directory with no `.git` (a
    /// supported product type, see docs/spec.md), yet the workspace picker offers Diff for every workspace
    /// regardless of whether it is one — so without this check, the first git invocation inside
    /// `scopeSignature`/`buildDiffPlanSnapshot` (`rev-parse HEAD`, say) would fail and surface as a generic
    /// `gitCommandFailed`, giving the client no renderable reason to distinguish "not a repo" from any other
    /// git failure. `RemoteWorkspaceGitClient.isRepoStrict` runs the canonical `rev-parse
    /// --is-inside-work-tree` probe on its own `metadataCommandTimeout`, so this only translates a
    /// confirmed-not-a-repo `false` into the typed error both call sites throw.
    ///
    /// Uses `isRepoStrict`, not `isRepo`: `isRepo`'s `try?` collapses "git could not run to completion"
    /// (spawn failure, timeout, a wedged process) into the same `false` as git's own honest "not a
    /// repository" answer, which would misreport a transient daemon hiccup as this function's durable 400
    /// (`invalidArgument`) — a rejection the client's retry classification (`root.ts`'s `refreshDiff`) never
    /// retries, since a real non-repo will fail identically forever. `isRepoStrict` keeps those two outcomes
    /// apart: a confirmed non-repo still throws this same 400 below, while an execution failure propagates
    /// out of this function uncaught, surfacing as the existing retryable `gitCommandFailed` →
    /// `.internalError` shape instead.
    ///
    /// Whether to still show the Diff entry point at all for a non-git workspace is left to the client — a
    /// UI-phase decision this error exists to make possible, not one this daemon-side check makes on the
    /// client's behalf.
    static func assertIsGitRepository(workspaceDir: String, gitClient: RemoteWorkspaceGitClient) throws {
        guard try gitClient.isRepoStrict(path: workspaceDir) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Workspace directory is not a git repository."])
        }
    }

    /// Verifies a caller-supplied ref resolves to a real commit before `buildDiffPlanSnapshot` spends the rest of its
    /// budget on it. The plan builder's ref-resolution step (`git merge-base <ref> HEAD`) throws the exact
    /// same `.gitCommandFailed` shape for "no such ref" as it does for a transient git failure (a wedged
    /// process, a timeout) — so without this separate, cheap probe up front, the wire-level `.internalError`
    /// mapping (`SpacesDeviceAPIServer.errorCode(for:)`) cannot tell a caller's typo from the daemon's own
    /// trouble, and the client's retry classification (`root.ts`'s `refreshDiff`) depends on exactly that
    /// distinction: a bad ref must never be retried (it will fail identically forever), a transient failure
    /// should be. `^{commit}` requires the ref to resolve to (or dereference to) a commit object, matching
    /// what `merge-base` itself needs of it; `--quiet` suppresses git's own stderr chatter for a bad ref,
    /// since this call's only signal to its caller is throw-vs-not-throw.
    ///
    /// round-14 Fix 1: exit code, not throw-vs-not-throw, is the signal that actually distinguishes "bad ref"
    /// from "daemon trouble" here. `git rev-parse --verify --quiet <ref>^{commit}` exits 0 with the resolved
    /// SHA on stdout when the ref resolves, and exits 1 with EMPTY stdout when it does not — that is exactly
    /// what `--quiet` is for, a clean two-way signal instead of stderr text. Passing `allowedExitCodes: [0,
    /// 1]` and letting this call throw normally (no `try?`) means exit 1 with empty output is the ONLY
    /// outcome read as a bad ref below; every actually-thrown failure — a timeout, an exhausted request-wide
    /// deadline (`remainingTimeout` itself throwing before the process even starts), or any other process
    /// failure (an exit code outside `{0, 1}`, e.g. a corrupt repository) — propagates OUT of this function
    /// uncaught. The server's normal error mapping then turns that into `.internalError`, which the client's
    /// retry classification already retries with backoff — that is the whole point of not catching it here:
    /// reclassifying a thrown failure back into this function's own 400 would silently re-fold transient
    /// trouble into a permanent rejection, breaking the exact distinction this function exists to preserve.
    static func assertRefIsResolvable(workspaceDir: String, refName: String, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date) throws {
        let resolved = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--verify", "--quiet", "\(refName)^{commit}"], timeout: try remainingTimeout(start: deadlineStart),
            allowedExitCodes: [0, 1])
        guard !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Ref '\(refName)' could not be resolved in this workspace."])
        }
    }

    /// Cheap change-detection token: sha256 over the HEAD commit, the raw `git status --porcelain -z`
    /// bytes, each dirty/untracked file's size, modification time, and POSIX mode, and — when `refName` is
    /// given — the merge-base of `refName` and `HEAD`. Mode is included alongside size/mtime because a
    /// chmod (e.g. an executable-bit flip) on an already-dirty file changes none of the other inputs (chmod
    /// only touches ctime) even though it does produce a mode-change line in the diff. Recomputing this is
    /// the entire cost of one
    /// `subscribeWorkspaceDiffSignature` poll tick, so it deliberately never shells out to `git diff` for
    /// the uncommitted-scope inputs (that is the expensive part the manifest endpoint pays for, on
    /// demand) — `merge-base` is the one exception, since it is the only way to detect the diff base
    /// itself moving (e.g. the branch being reviewed gets merged into `refName` from elsewhere) rather than
    /// just the working tree changing. When `merge-base` fails (the ref was deleted, say), an error-marker
    /// string is folded in instead of the resolved SHA, so the signature still changes exactly once rather
    /// than silently pinning to a stale value.
    /// `deadlineStart` is nil on the standalone poll path (`subscribeWorkspaceDiffSignature`'s timer calls
    /// this directly), which keeps today's behavior: each command gets its own flat `gitCommandTimeout` with
    /// no request-wide budget, because a poll tick has no such budget to share. `buildDiffPlanSnapshot` passes its own
    /// `start` here so this call's commands are folded into the same request-wide deadline (`remainingTimeout`)
    /// as the plan builder's other up-front commands.
    static func scopeSignature(
        workspaceDir: String, refName: String? = nil, lastCommit: Bool = false, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date? = nil
    ) throws -> String {
        try scopeSnapshot(workspaceDir: workspaceDir, refName: refName, lastCommit: lastCommit, gitClient: gitClient, deadlineStart: deadlineStart)
            .signature
    }

    /// `buildDiffPlanSnapshot` needs the same HEAD/status/prefix facts that form the signature. Keeping them in this
    /// request-local value avoids immediately spawning the same metadata commands again; subscription polls
    /// call `scopeSignature` above and discard the extra fields without retaining workspace state.
    private struct ScopeSnapshot {
        let signature: String
        let headSHA: String
        let scopedEntries: [PorcelainEntry]?
    }

    private static func scopeSnapshot(
        workspaceDir: String, refName: String? = nil, lastCommit: Bool = false, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date? = nil
    ) throws -> ScopeSnapshot {
        // `--verify --quiet` + `allowedExitCodes: [0, 1]` (no `try?`), not a bare `rev-parse HEAD`: an
        // unborn HEAD (a freshly `git init`ed repo, still a valid git project) exits 1 with empty stdout,
        // which is the durable, legitimate reason for `headSHA` to be `""` here. A `try?`/`?? ""` collapse would instead
        // fold "git could not run to completion" (spawn failure, timeout) into that same `""`, silently
        // misreporting a transient daemon hiccup as an unborn-HEAD repo and leaving `scopeSignature` stuck on
        // a signature that never changes again until something else perturbs it. Letting the throw propagate
        // instead surfaces as the normal retryable `gitCommandFailed` failure this whole function already
        // exits with for `statusOutput`'s or `prefix`'s own git invocation just below.
        let headSHA = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--verify", "--quiet", "HEAD"],
            timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout, allowedExitCodes: [0, 1]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // The lastCommit scope is committed-only: its diff never involves the working tree, so its
        // signature must not either. It depends on nothing but the resolved HEAD commit — not `git
        // status`, not any file's size/mtime/mode — so this returns immediately, before any of those other
        // commands run, rather than computing and then discarding inputs the lastCommit diff never reads. An
        // unborn HEAD (`headSHA` empty) is a stable, valid state of its own, so it hashes a fixed sentinel
        // rather than the empty string, keeping the signature a legitimate, non-empty token rather than an
        // artifact of `headSHA` happening to be blank.
        //
        // Accepted: initializing (or fetching into) a submodule turns its pointer-only row into a nested
        // listing without moving HEAD, so an open Last Commit view keeps the pointer-only row until the
        // next scope switch or commit. Running `git submodule update` in the middle of reviewing a commit
        // is rare, the view corrects itself the moment either happens, and folding a per-submodule
        // readability probe into every 2s tick would cost every Last Commit subscriber a walk of the
        // gitlink tree to catch that window.
        if lastCommit {
            let signature = SpacesDeviceWorkspaceGitHashing.sha256Hex(Data("last-commit:\(headSHA.isEmpty ? "unborn" : headSHA)\n".utf8))
            return ScopeSnapshot(signature: signature, headSHA: headSHA, scopedEntries: nil)
        }

        // `--untracked-files=all` (rather than git's default `normal`) is required here: the default
        // collapses every file inside a wholly-untracked directory into one `?? dir/` record, so editing a
        // file inside an already-untracked directory would not change this signature (the directory's own
        // mtime need not change when a file inside it is edited) even though the manifest plan would show that
        // edit once the client re-fetches. `all` reports each file individually, so per-file `size`/`mtime`
        // below sees it.
        let statusOutput = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "status", "--porcelain", "-z", "--untracked-files=all"],
            timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout)
        // A workspace can be a monorepo subpackage rooted
        // below its repository's root (`Orchestrator.normalizeDir` accepts any dir where `rev-parse
        // --is-inside-work-tree` succeeds), so porcelain's repo-root-relative paths must be scoped down to
        // just this subtree and relativized before they feed the hash or the per-file stat below — `git
        // status` has no `--relative` of its own (confirmed against real git: `error: unknown option
        // 'relative'`), unlike the `diff` invocations below. `--show-prefix` answers correctly even in an
        // unborn repo (no commits yet), since it is purely CWD-based.
        // No `try?`/`?? ""` here: `assertIsGitRepository`/`buildDiffPlanSnapshot` have already confirmed this is a real repository
        // by the time `scopeSignature` runs, so this probe should never legitimately fail — a genuine
        // failure here must propagate as a normal thrown error rather than being folded into an empty
        // prefix, which git also produces on a plain SUCCESS (a workspace rooted exactly at its repo root).
        // Those are two different outcomes; collapsing them together previously let a transient failure
        // here silently blend into the "no scoping needed" case rather than surfacing as a retryable error.
        // Only the trailing newline git appends is stripped here — see `strippingTrailingNewline`'s doc
        // comment for why a leading space/tab must survive.
        let prefix = strippingTrailingNewline(
            try gitClient.runGitAndCapture(
                ["-C", workspaceDir, "rev-parse", "--show-prefix"], timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout))

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
                    timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout
                ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "merge-base-error"
            input.append(Data("merge-base:\(mergeBase)\n".utf8))
        }

        let fileManager = FileManager.default
        // Entries whose porcelain record stats as a directory, collected alongside the per-entry stat loop
        // below so the gitlink diff and the submodule recursion after the loop can name exactly those paths
        // without a second pass over `scopedEntries`.
        var directoryEntries: [PorcelainEntry] = []
        for entry in scopedEntries {
            let fullPath = (workspaceDir as NSString).appendingPathComponent(entry.path)
            if let attributes = try? fileManager.attributesOfItem(atPath: fullPath), let size = attributes[.size] as? Int,
                let modified = attributes[.modificationDate] as? Date
            {
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    directoryEntries.append(entry)
                }
                // `mode` (raw POSIX permission bits, -1 if unavailable) is folded in alongside size/mtime
                // because a chmod (e.g. flipping the executable bit) on an already-dirty tracked file changes
                // none of HEAD, the porcelain status letter, size, or mtime (chmod only touches ctime, which
                // this signature does not read) — yet the resulting unified diff does gain a mode-change
                // line. Without `mode` here, that change would be invisible to a subscribed client's poll.
                let mode = attributes[.posixPermissions] as? Int ?? -1
                input.append(Data("\(entry.path)|\(size)|\(modified.timeIntervalSince1970)|\(mode)\n".utf8))
                // round-16 Fix 3, accepted risk: an already-dirty file rewritten with DIFFERENT content of
                // the exact SAME byte size, whose mtime is then deliberately restored to its original value
                // (e.g. `rsync --times`, `touch -r`, or any other timestamp-preserving copy), changes none of
                // this signature's inputs — HEAD, the porcelain status letter, `size`, `modified`, and `mode`
                // above all stay identical — so no signature-change event fires and a subscribed client's diff
                // pane stays stale on the old content until some unrelated change elsewhere in the workspace
                // happens to re-fire the poll. Accepted as v1 behavior rather than fixed, for three reasons:
                // (1) it is narrow and deliberate, not something ordinary editing hits — a plain write always
                // advances mtime, and APFS/ext4 both carry nanosecond-resolution timestamps, so an equal-mtime
                // collision never occurs naturally; triggering this requires a tool that explicitly restores
                // timestamps AND happens to produce byte-identical length on a file that was already dirty.
                // (2) it self-heals: any other signature input moving anywhere in the workspace (a different
                // file's mtime, a git status change, HEAD moving) re-fires the poll, and the resulting pull
                // re-reads every file's actual content fresh, so the stale diff never persists indefinitely.
                // (3) both alternatives considered were rejected as disproportionate: reading ctime instead of
                // mtime would catch this (userspace tools cannot restore ctime), but `FileAttributeKey` does
                // not expose ctime, so it would require dropping to a raw `stat()` syscall just for this one
                // edge case; content-hashing every file would also catch it, but would reintroduce exactly the
                // unbounded per-poll hashing cost the codebase's sibling per-file signature deliberately avoids
                // for the same reason — see `SpacesDeviceAPIServer.computeWorkspaceFileScopeSignature`'s
                // `workspaceFileSignatureOversizedSentinel`, which substitutes a stable sentinel instead of
                // hashing a file's content on every 2s poll tick once it crosses a size cap, rather than
                // reading `size`/`modified`/`mode` off `FileManager.attributesOfItem` above the way this loop
                // does — both fixes are disproportionate for a narrow, deliberate-timestamp-
                // restoration edge case.
            } else {
                // Raced with a delete between the status scan and this stat; still folds into the
                // signature (as a distinct value from a present file) so the poll still detects the change.
                input.append(Data("\(entry.path)|missing\n".utf8))
            }
        }

        // Accepted, the vs-ref twin of the Last Commit acceptance above: both the pointer fold here and the
        // recursive fold below are driven by `directoryEntries`, which come from the porcelain, so a
        // submodule whose pointer moved only in a commit the ref comparison spans, with a clean checkout
        // sitting at the recorded commit, is named by neither. Initializing or deinitializing that checkout
        // then changes nothing this signature reads, and an open vs-ref diff keeps showing the pointer row
        // alone (or keeps its nested files after a deinit) until the next real change or scope switch.
        // Running `git submodule update` or `git submodule deinit` in the middle of a review is rare, either
        // event corrects the view, and catching the window would mean walking every gitlink in the
        // comparison on every 2s tick for every vs-ref subscriber, including the workspaces whose
        // submodules never move.
        input.append(
            try gitlinkPointerSignatureInput(
                repoDir: workspaceDir, headSHA: headSHA, candidatePaths: directoryEntries.map(\.path), gitClient: gitClient,
                deadlineStart: deadlineStart))

        // The pointer-level diff folded in above sees a submodule's checkout only as a commit id plus a
        // `-dirty` marker, both of which stay identical while the submodule's own files keep changing: a
        // second edit to an already-modified file inside it, a new untracked file, or any change one level
        // deeper inside a nested submodule all leave the marker exactly where it was. Those files are part
        // of what the diff pane renders, so the signature has to move when they do; otherwise a subscribed client
        // holds a stale nested listing until something unrelated in the workspace perturbs the poll.
        //
        // Only a submodule porcelain already reported as changed is walked, so a workspace with no
        // submodules (and one whose submodules are all clean) still spawns no extra command per tick. A
        // wholly untracked nested repository is excluded: it is not a submodule, has no pointer row, and
        // therefore contributes no nested entries to keep fresh.
        for entry in directoryEntries where entry.status != "??" {
            guard SpacesDeviceWorkspacePathResolver.isContainedGitlinkCheckout(repoDir: workspaceDir, repoRelativePath: entry.path) else {
                continue
            }
            let subDir = (workspaceDir as NSString).appendingPathComponent(entry.path)
            let subSignature = try submoduleScopeSignature(subDir: subDir, depth: 1, gitClient: gitClient, deadlineStart: deadlineStart)
            input.append(Data("submodule-scope:\(entry.path):\(subSignature)\n".utf8))
        }

        return ScopeSnapshot(signature: SpacesDeviceWorkspaceGitHashing.sha256Hex(input), headSHA: headSHA, scopedEntries: scopedEntries)
    }

    /// The pointer-level view of `candidatePaths` in `repoDir`, for that repository's own scope signature.
    /// The workspace's snapshot and every nested submodule's signature share it, so a pointer move is seen
    /// at whatever depth it happens, including one whose checkout cannot be descended into at all.
    ///
    /// With `--untracked-files=all`, the only porcelain entries that are directories are gitlinks
    /// (submodule checkouts) and wholly untracked nested repositories; an ordinary untracked directory is
    /// expanded to its individual files by that flag, so it never reaches here as a directory entry.
    ///
    /// The per-entry stat lines a caller hashes are blind to a submodule's own worktree: a checkout inside
    /// it that only rewrites files under a nested directory, or an uncommitted edit to such a file, changes
    /// neither the `sub` directory's size/mtime/mode nor the porcelain letter (` M` either way), yet it
    /// changes the pointer row's reported commit or its `(dirty)` marker. So a HEAD-to-worktree `git diff
    /// --submodule=short` for exactly those directory entries is folded in here, rather than the default
    /// index-to-worktree comparison: the rendered pointer row is always compare-ref-to-worktree (HEAD, or
    /// the merge-base for a vs-ref scope, either way already hashed by the caller as
    /// `headSHA`/`merge-base:...`), and an index-to-worktree diff goes empty the moment the pointer is staged (`git add sub`), which
    /// would miss a further `git checkout <sha>` + `git add sub` restaging the pointer at yet another
    /// commit: porcelain stays `M  sub`, the directory stat does not move, and an index-to-worktree diff
    /// is empty before and after, yet the rendered row moves from `Submodule S1 -> S2` to `Submodule S1 ->
    /// S3`. Naming `headSHA` here gets the same `Subproject commit <sha>[-dirty]` lines the pointer row's
    /// rendering reads regardless of what is currently staged; the index side of a pointer move is
    /// already covered by the porcelain letters the caller hashes. On an unborn HEAD (`headSHA` empty) the
    /// comparison is git's empty tree, computed the same way `buildDiffPlanSnapshot` computes its own compare ref
    /// for that state (see the comment there for why it is not a hardcoded constant): a submodule staged
    /// in a repo with no commits renders as `Submodule added <sha>`, and restaging it at another commit
    /// keeps porcelain at `A  sub` with an empty index-to-worktree diff, so only a diff against the empty
    /// tree sees that pointer move. A gitlink left unmerged by a conflicting merge produces an empty diff
    /// here (git has no merged content to diff against), which is fine: the row for an unmerged pointer does
    /// not report worktree dirtiness in the first place (see `submoduleChange(from:gitlink:)`'s doc
    /// comment), so there is nothing this diff would need to surface for that case. A wholly untracked
    /// nested repository (also a directory entry here) contributes nothing to this diff either, since it
    /// is on neither side of a HEAD-to-worktree comparison.
    ///
    /// This only runs when such an entry exists, so a repository without submodules pays nothing extra on
    /// this signature's 2s poll tick. `--submodule=short` is passed for the same reason as every other
    /// `diff` invocation in this file: it pins the patch format against a user's `diff.submodule` config
    /// rather than letting it collapse to a one-line summary. `diff.ignoreSubmodules` /
    /// `submodule.<name>.ignore` are deliberately left in force here too, matching
    /// `buildDiffPlanSnapshot`'s own accepted behavior of honoring that per-submodule suppression.
    private static func gitlinkPointerSignatureInput(
        repoDir: String, headSHA: String, candidatePaths: [String], gitClient: RemoteWorkspaceGitClient, deadlineStart: Date?
    ) throws -> Data {
        guard !candidatePaths.isEmpty else { return Data() }
        var arguments = [
            "-C", repoDir, "-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short",
            "--relative",
        ]
        let compareRevision: String
        if headSHA.isEmpty {
            compareRevision = try gitClient.runGitAndCapture(
                ["-C", repoDir, "hash-object", "-t", "tree", "/dev/null"],
                timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            compareRevision = headSHA
        }
        arguments.append(compareRevision)
        arguments.append("--")
        arguments.append(contentsOf: candidatePaths.map { ":(literal)\($0)" })
        let submoduleOutput = try gitClient.runGitAndCapture(
            arguments, timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout)
        return Data("submodules:\n\(submoduleOutput)".utf8)
    }

    /// One initialized submodule checkout's own contribution to its parent's scope signature: its resolved
    /// `HEAD`, its full porcelain status bytes, the size/mtime/mode of every path that status names, the
    /// pointer-level view of its own gitlinks, and, recursively, the same for each of its own changed
    /// submodules. The same inputs the top-level snapshot
    /// hashes, for the same reason: a submodule's files are diffed exactly like the workspace's own.
    ///
    /// The `lastCommit` scope does not reach here: its diff is between two commits of the workspace's own
    /// repository, so the pointers it compares are fixed by the parent's `HEAD` alone and nothing inside a
    /// submodule checkout can change what it renders.
    private static func submoduleScopeSignature(
        subDir: String, depth: Int, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date?
    ) throws -> String {
        let headSHA = try gitClient.runGitAndCapture(
            ["-C", subDir, "rev-parse", "--verify", "--quiet", "HEAD"],
            timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout, allowedExitCodes: [0, 1]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let statusOutput = try gitClient.runGitAndCapture(
            ["-C", subDir, "status", "--porcelain", "-z", "--untracked-files=all"],
            timeout: try deadlineStart.map(remainingTimeout(start:)) ?? gitCommandTimeout)

        // Accepted: the worktree dirt folded in here is not filtered by the parent's submodule ignore policy,
        // so an edit inside a `dirty`-ignored submodule still moves the signature and buys a manifest
        // rebuild that produces exactly the rows the client already has. The rows stay correct and the cost
        // is one redundant rebuild on a 2s tick, while teaching the signature the policy would repeat that
        // per-repository config resolution on every tick for a case the policy itself makes rare.
        var input = Data("head:\(headSHA.isEmpty ? "unborn" : headSHA)\n".utf8)
        input.append(Data(statusOutput.utf8))
        let fileManager = FileManager.default
        var directoryEntries: [PorcelainEntry] = []
        for entry in changedEntries(fromPorcelainZ: statusOutput) {
            let fullPath = (subDir as NSString).appendingPathComponent(entry.path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath), let size = attributes[.size] as? Int,
                let modified = attributes[.modificationDate] as? Date
            else {
                input.append(Data("\(entry.path)|missing\n".utf8))
                continue
            }
            if attributes[.type] as? FileAttributeType == .typeDirectory { directoryEntries.append(entry) }
            let mode = attributes[.posixPermissions] as? Int ?? -1
            input.append(Data("\(entry.path)|\(size)|\(modified.timeIntervalSince1970)|\(mode)\n".utf8))
        }

        // The same pointer-level fold the workspace's own snapshot does, for this repository's gitlinks. It
        // is what notices a pointer restaged from one commit to another inside this submodule: the porcelain
        // bytes above read the same letters for the same path either way, the checkout directory's stat does
        // not move, and a submodule whose checkout is absent is not descended into below, so nothing else
        // here would change.
        input.append(
            try gitlinkPointerSignatureInput(
                repoDir: subDir, headSHA: headSHA, candidatePaths: directoryEntries.map(\.path), gitClient: gitClient,
                deadlineStart: deadlineStart))

        // Mirrors the depth bound the diff itself honors: past it there are no nested entries to keep
        // fresh, so there is nothing left for a signature to notice.
        if depth < maxSubmoduleDepth {
            for entry in directoryEntries where entry.status != "??" {
                guard SpacesDeviceWorkspacePathResolver.isContainedGitlinkCheckout(repoDir: subDir, repoRelativePath: entry.path) else { continue }
                let nestedDir = (subDir as NSString).appendingPathComponent(entry.path)
                let nestedSignature = try submoduleScopeSignature(
                    subDir: nestedDir, depth: depth + 1, gitClient: gitClient, deadlineStart: deadlineStart)
                input.append(Data("submodule-scope:\(entry.path):\(nestedSignature)\n".utf8))
            }
        }
        return SpacesDeviceWorkspaceGitHashing.sha256Hex(input)
    }

    /// The gitlink's commit id on the comparison-base (source) side of `git diff --raw --no-abbrev`, present
    /// only when the source side is itself a gitlink (git object mode `160000`). That excludes an add
    /// (source absent, mode `000000`) and a file-to-submodule type change (source is a regular file, i.e. a
    /// blob id, not a commit): for both, `baseCommit` is nil and the patch's `+Subproject commit` line
    /// alone supplies the new commit.
    ///
    /// The raw record's destination (worktree) side is never read for a gitlink, because it is unreliable
    /// in exactly the cases where it would matter: an unstaged pointer move (`git checkout <sha>` inside
    /// the submodule with no `git add`) prints an all-zero destination, identical to an absent side, and a
    /// rename combined with an unstaged pointer move makes git split the entry into an add plus a delete
    /// whose add-side id is a stale index value rather than the worktree's actual pointer (both confirmed
    /// empirically). A submodule's real old/new commit ids come from the per-file patch's `Subproject
    /// commit` lines instead, which git prints correctly for every one of those cases, see
    /// `parsePatchMetadata`. The one case the patch is silent on is a pointer-preserving rename (`git mv sub
    /// renamed-sub` with no pointer change): its `R100` status means the pointer is identical on both sides,
    /// so `baseCommit` names that unchanged pointer directly.
    ///
    /// An unmerged pointer left behind by a conflicting merge (superproject index status `UU`/`AA`/`DD`/
    /// `AU`/`UA`/`DU`/`UD`) produces an EMPTY per-file patch too, exactly like a pointer-preserving rename:
    /// git has no merged content to diff, so `--submodule=short` prints nothing. The patch alone therefore
    /// cannot tell the two cases apart; only the porcelain status snapshot `buildDiffPlanSnapshot` already
    /// reads for this scope names the conflict, which is why `unmerged` is threaded through here rather than
    /// re-derived from the patch.
    struct Gitlink: Sendable {
        let baseCommit: String?
        let unmerged: Bool
        /// Whether this comparison descended into the submodule's own repository, which requires both a
        /// readable checkout (`submoduleIsReadable`) and room under the depth bound. `parseRawZ` cannot know
        /// this from the listing alone, so it produces `false` here and `expandSubmodulePlans` resolves the
        /// real value as it nests each pointer row's own changed files.
        let checkedOut: Bool
        /// The parent repository's effective ignore policy for this submodule (see
        /// `submoduleIgnorePolicies`). It decides whether the row's own worktree is looked at: the pointer
        /// row's patch is generated under exactly this policy, so the row reports dirtiness only when the
        /// repository configured git to report it, and a policy that hides dirt also stops the nested
        /// worktree entries. `parseRawZ` cannot know it, so it produces `.none` and `expandSubmodulePlans`
        /// resolves the real value there, exactly as it does for `checkedOut`.
        let ignorePolicy: SubmoduleIgnorePolicy
    }

    /// What a repository has told git to overlook about one of its submodules, in git's own spelling. Git
    /// applies this to `diff` and `status` alike, so it decides both what the enumeration sees and what the
    /// pointer row's patch says.
    ///  - `none`: report everything, a pointer move and a dirty worktree alike. The default.
    ///  - `untracked`: a submodule holding nothing but untracked files is not dirty.
    ///  - `dirty`: the submodule's worktree is never dirty; pointer moves are still reported.
    ///  - `all`: the submodule is not reported at all, so no row ever reaches the client for it.
    enum SubmoduleIgnorePolicy: String, Sendable {
        case none
        case untracked
        case dirty
        case all

        /// How much each policy hides, least to most.
        private var strictness: Int {
            switch self {
            case .none: return 0
            case .untracked: return 1
            case .dirty: return 2
            case .all: return 3
            }
        }

        /// The policy that hides more of the two. A submodule's effective policy is the strictest along the
        /// chain above it: a repository that says it does not want to hear about one submodule's worktree is
        /// saying that about everything nested inside that worktree too, since a submodule checked out
        /// inside it is part of it. Without this, an ancestor's `untracked` would stop at its own checkout
        /// and a nested submodule's new files would come back through the row beneath it.
        func strictest(_ other: SubmoduleIgnorePolicy) -> SubmoduleIgnorePolicy { strictness >= other.strictness ? self : other }
    }

    /// A repository's effective ignore policy per submodule, resolved once for the whole repository.
    struct SubmoduleIgnoreSettings: Sendable {
        /// `diff.ignoreSubmodules`, which applies to every submodule this repository does not name.
        let repositoryDefault: SubmoduleIgnorePolicy
        let byPath: [String: SubmoduleIgnorePolicy]

        static let unconfigured = SubmoduleIgnoreSettings(repositoryDefault: .none, byPath: [:])

        func policy(forRepoRelativePath path: String) -> SubmoduleIgnorePolicy { byPath[path] ?? repositoryDefault }
    }

    /// One file identified by `git diff -M --raw -z` (tracked) or by a `??` record in `git status
    /// --porcelain -z` (untracked). The plan intentionally retains only file identity and immutable git
    /// references, not a patch body or full command array, so a short-lived manifest session is compact.
    struct DiffFilePlan: Sendable {
        enum Source {
            /// `baseRef` is compared with `targetRef` when non-nil (last-commit), otherwise with the
            /// working tree (uncommitted/base-ref scopes).
            case tracked(baseRef: String, targetRef: String?)
            case untracked
            /// A path `--raw` reports `.deleted` relative to `compareRef` but that `git status`
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
        /// Non-nil when the destination side of the change is a gitlink (git object mode `160000`), or the
        /// destination is absent and the source was a gitlink (a delete), i.e. `path` is a submodule
        /// pointer, not file content; see `parseRawZ`'s classification comment. Carries only the gitlink's
        /// base-side commit id (see `Gitlink`); the pointer's actual old/new commits come from the per-file
        /// patch's `Subproject commit` lines in `parsePatchMetadata`, with this value used only as the
        /// fallback for a pointer-preserving rename, whose patch has none. Only `--raw`'s tracked entries
        /// can set this; an untracked or coalesced-deleted-but-untracked plan is always a plain file (a
        /// wholly untracked nested repository is filtered out before it ever becomes a plan, see
        /// `buildRepoPlans`).
        let gitlink: Gitlink?
        /// Absolute directory of the git repository that owns this file: the workspace checkout for a file
        /// the workspace's own repository tracks, a submodule's checkout for one inside a submodule. Every
        /// git command that produces this file's patch runs there.
        let repoDir: String
        /// Workspace-relative path of the submodule that owns this file, nil for a top-level file. A
        /// submodule's own pointer row belongs to the repository above it, so the pointer row's
        /// `submodulePath` names that outer repository's enclosing submodule (nil at the top level), never
        /// the submodule the row itself points at.
        let submodulePath: String?

        /// True when `gitlink` is present, i.e. `path` is a submodule pointer rather than file content.
        var isSubmodule: Bool { gitlink != nil }

        /// `path` as `repoDir`'s own repository names it. Per-file pathspecs and patch prefixes need this
        /// repo-relative form, while the client only ever sees the workspace-relative `path`; both are
        /// derived from the same single invariant, `path == submodulePath + "/" + repoRelativePath`, so the
        /// two can never drift apart.
        var repoRelativePath: String { Self.repoRelative(path, submodulePath: submodulePath) }
        var repoRelativeOldPath: String? { oldPath.map { Self.repoRelative($0, submodulePath: submodulePath) } }

        private static func repoRelative(_ path: String, submodulePath: String?) -> String {
            guard let submodulePath else { return path }
            return String(path.dropFirst(submodulePath.count + 1))
        }

        init(
            path: String, oldPath: String?, status: SpacesDeviceWorkspaceDiffFileStatus, source: Source, repoDir: String,
            submodulePath: String? = nil, gitlink: Gitlink? = nil
        ) {
            self.path = path
            self.oldPath = oldPath
            self.status = status
            self.source = source
            self.repoDir = repoDir
            self.submodulePath = submodulePath
            self.gitlink = gitlink
        }

        var comparisonBaseRevision: String? {
            switch source {
            case .tracked(let baseRef, _), .deletedButUntrackedInWorktree(let baseRef): return baseRef
            case .untracked: return nil
            }
        }
    }

    /// A daemon-held manifest plan. Patch work is deferred until a client asks for a particular file, so a
    /// large working tree can paint its sidebar before one slow/generated patch delays every other file.
    /// It pins the enumeration and comparison refs, not live worktree bytes: each file body is captured when
    /// its first range is requested, while the signature stream schedules a later manifest generation for
    /// ordinary concurrent agent churn.
    struct DiffPlanSnapshot: Sendable {
        let scopeSignature: String
        let plans: [DiffFilePlan]

        /// Manifest requests arrive in viewport order, so resolving a file by repeatedly scanning the
        /// plan would make a large manifest quadratic. Keep the first plan for a path: that preserves the
        /// existing `first(where:)` behavior even if a raced enumeration ever contains a duplicate.
        private let planIndexByPath: [String: Int]

        init(scopeSignature: String, plans: [DiffFilePlan]) {
            self.scopeSignature = scopeSignature
            self.plans = plans
            var indexByPath: [String: Int] = [:]
            indexByPath.reserveCapacity(plans.count)
            for (index, plan) in plans.enumerated() { if indexByPath[plan.path] == nil { indexByPath[plan.path] = index } }
            self.planIndexByPath = indexByPath
        }

        func plan(for relativePath: String) -> DiffFilePlan? {
            guard let index = planIndexByPath[relativePath] else { return nil }
            return plans[index]
        }
    }

    /// Builds one manifest plan. `refName == nil` diffs uncommitted changes against
    /// `HEAD`; a non-nil `refName` diffs the merge-base of `refName` and `HEAD` against the working tree
    /// (so it also includes uncommitted changes — reviewing work against a base branch means "everything
    /// since it diverged, including what is not committed yet"). Untracked files never show up in `git
    /// diff` output regardless of the ref compared against, so they are enumerated separately via `git
    /// status` and synthesized as add-diffs.
    ///
    /// `deadlineStart` is supplied by the server before repository/ref validation so the whole immediate
    /// operation shares one deadline.
    static func buildDiffPlanSnapshot(
        workspaceDir: String, refName: String?, lastCommit: Bool = false, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date = Date()
    ) throws -> DiffPlanSnapshot {
        let start = deadlineStart
        let snapshot = try scopeSnapshot(
            workspaceDir: workspaceDir, refName: refName, lastCommit: lastCommit, gitClient: gitClient, deadlineStart: start)
        let signature = snapshot.signature

        if lastCommit {
            return try buildLastCommitPlans(
                workspaceDir: workspaceDir, gitClient: gitClient, signature: signature, headSHA: snapshot.headSHA, deadlineStart: start)
        }

        let compareRef: String
        if let normalizedRef = normalizedRefName(refName) {
            // Reviewing against a base branch in a commit-less repo is meaningless, so an unborn `HEAD`
            // here is left to fail honestly with `merge-base`'s own typed git error rather than being
            // papered over — unlike the nil-`refName` path below, which treats an unborn `HEAD` as a
            // supported "changes in a repo with no commits yet" case.
            let mergeBase = try gitClient.runGitAndCapture(
                ["-C", workspaceDir, "merge-base", normalizedRef, "HEAD"], timeout: try remainingTimeout(start: start), allowedExitCodes: [0, 1]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mergeBase.isEmpty else {
                throw NSError(
                    domain: "SpacesDeviceAPIServer", code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Refs '\(normalizedRef)' and HEAD have no common history."])
            }
            compareRef = mergeBase
        } else {
            // `scopeSnapshot` already distinguished an unborn HEAD from an execution failure while building
            // the signature, so reuse that exact answer rather than immediately paying for the same probe.
            if !snapshot.headSHA.isEmpty {
                compareRef = snapshot.headSHA
            } else {
                // No commits exist yet, so there is no tree to diff against — compare against git's empty
                // tree instead, which makes every tracked/staged file report as an addition. That is
                // exactly what "changes in a repo with no commits" means, and it is the only way to surface
                // a *staged* file in this state: an unborn repo's staged files are already in the index, so
                // `git status`'s `??` (untracked) records never include them, and a scan of untracked files
                // alone would silently miss them. See `emptyTreeObject` for why the id is computed per call
                // rather than hardcoded.
                compareRef = try emptyTreeObject(repoDir: workspaceDir, gitClient: gitClient, deadlineStart: start)
            }
        }
        // The signature has already read and subtree-scoped the same porcelain snapshot this request needs
        // for untracked/collision plans. It is present for every non-last-commit scope.
        guard let scopedStatusEntries = snapshot.scopedEntries else {
            preconditionFailure("A working-tree diff snapshot must contain scoped status entries.")
        }

        let plans = try buildRepoPlans(
            repoDir: workspaceDir, compareRef: compareRef, targetRef: nil, submodulePath: nil, statusEntries: scopedStatusEntries,
            inheritedIgnore: .none, depth: 0, gitClient: gitClient, deadlineStart: start)
        return DiffPlanSnapshot(scopeSignature: signature, plans: plans)
    }

    /// Enumerates one repository's changed files, then nests each submodule pointer row's own changed files
    /// directly after it, recursively. The snapshot this feeds stays a flat, ordered list (pointer row,
    /// then that submodule's entries, themselves pointer-then-children) rather than a tree: the manifest
    /// chunk transport, the patch transfer store, and `planIndexByPath` all key off one workspace-relative
    /// path, and a nested shape would have to be flattened again at every one of those boundaries. Order
    /// alone carries the nesting the client renders.
    ///
    /// `repoDir` is the directory git runs in: the workspace checkout for the workspace's own repository, a
    /// submodule's checkout when nested. `compareRef` is the base side (a commit, or git's empty tree for a
    /// repository with no commits on that side); `targetRef` nil compares against the working tree
    /// (uncommitted and vs-ref scopes), non-nil against a second commit (the last-commit scope, which has no
    /// working-tree or untracked involvement at all). `submodulePath` is the workspace-relative path of the
    /// submodule this repository is, nil at the top level; it is what turns each repo-relative path git
    /// reports into the workspace-relative `path` the client sees. `statusEntries` is the porcelain snapshot
    /// for a working-tree scope, already scoped and relativized to `repoDir`; it is nil exactly when
    /// `targetRef` is non-nil. `inheritedIgnore` is the effective ignore policy of the submodule this
    /// repository IS, `.none` at the top level, which every gitlink below it is at least as strict as.
    private static func buildRepoPlans(
        repoDir: String, compareRef: String, targetRef: String?, submodulePath: String?, statusEntries: [PorcelainEntry]?,
        inheritedIgnore: SubmoduleIgnorePolicy, depth: Int, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date
    ) throws -> [DiffFilePlan] {
        let pathPrefix = submodulePath.map { "\($0)/" } ?? ""

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
        // including `--raw` (which no external-diff driver fires for anyway), so a future argument
        // edit can't reintroduce the hole on one call and not another.
        // `--submodule=short` pins the patch-body format `parsePatchMetadata` parses for a gitlink
        // (`-Subproject commit X` / `+Subproject commit Y[-dirty]`) against a user's `diff.submodule`
        // config: set to `log` (or `diff`), that config replaces the whole gitlink patch body with a
        // one-line commit-log/full-diff summary instead (confirmed empirically), which would make a
        // submodule change silently unparseable. `--raw`'s own listing format is unaffected by
        // `diff.submodule` either way (confirmed empirically), so this is applied here purely for
        // uniformity with the patch-producing calls below rather than because this call needs it.
        // `--relative`: a workspace can be rooted below its repository's root (a monorepo subpackage
        // added as its own project — `Orchestrator.normalizeDir` accepts any dir where `rev-parse
        // --is-inside-work-tree` succeeds). Without it, `--raw` reports repo-root-relative paths
        // while every per-file pathspec below is workspace-relative, so nothing matches; with it, git both
        // limits this enumeration to the CWD's subtree (out-of-workspace changes are correctly excluded —
        // the pane reviews THIS workspace) and reports every path relative to that subtree, including in
        // `diff --git`/`---`/`+++` headers, which is what keeps patch-header paths aligned with entry paths
        // for client anchoring. A no-op, byte-for-byte, when `repoDir` IS the repo root (empirically
        // confirmed), which every nested submodule checkout is.
        //
        // `--raw` (rather than `--name-status`) is the enumeration format: it is the only -z listing that
        // reports each side's git object mode, which is how a submodule pointer (gitlink, mode `160000`) is
        // told apart from an ordinary tracked file: `--name-status` gives no way to see that. `-c
        // submodule.recurse=0` is deliberately NOT added here: per `git help config`, `submodule.recurse`
        // only affects `checkout`/`fetch`/`grep`/`pull`/`push`/`read-tree`/`reset`/`restore`/`switch` (and
        // `branch`, gated on `submodule.propagateBranches`), `diff` and `status` are not in that list, and
        // empirically a `submodule.recurse=true` workspace produces byte-identical `--raw`/`--submodule=short`
        // output to one without it. That holds for the nested invocations this function makes of itself too,
        // which are the same `diff`/`status` commands run one directory deeper.
        //
        // `--ignore-submodules=none` is deliberately NOT added either, so `diff.ignoreSubmodules` and
        // `submodule.<name>.ignore` (commonly `ignore = dirty` in `.gitmodules`, to stop a submodule's own
        // untracked/modified worktree content from showing as a pointer change) stay in force: that
        // configuration exists precisely to suppress those entries from the repository's own diffs, git and
        // other tools honor it, and `git status` honors the same per-submodule setting, so overriding it here
        // would list an entry `git status` does not show and the listing's git-poll membership detector (which
        // is itself status-derived) would never agree with. A submodule change the repository configured git
        // to ignore is therefore not listed, and neither are the submodule's own changed files, since they
        // hang off a pointer row that never appears.
        //
        // What that default leaves out, with no such configuration set at all, is a submodule whose ONLY
        // change is untracked content: git's diff default is `--ignore-submodules=untracked`, so this
        // listing emits no record for it, while `git status` reports it ` M sub` (both confirmed
        // empirically). The porcelain block below synthesizes that one row from the status entry, rather
        // than this flag forcing every configured-away row back in with it.
        var rawArguments = [
            "-C", repoDir, "diff", "-M", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--relative", "--raw",
            "--no-abbrev", "-z", compareRef,
        ]
        if let targetRef { rawArguments.append(targetRef) }
        let rawOutput = try gitClient.runGitAndCapture(rawArguments, timeout: try remainingTimeout(start: deadlineStart))
        var plans = parseRawZ(rawOutput).map { entry -> DiffFilePlan in
            // `entry.path`/`entry.oldPath` are repo-relative (from `--relative` above); `pathPrefix` lifts
            // them to workspace-relative for the client, while `DiffFilePlan.repoRelativePath` strips the
            // prefix back off for the per-file pathspecs the patch writers hand to git.
            return DiffFilePlan(
                path: pathPrefix + entry.path, oldPath: entry.oldPath.map { pathPrefix + $0 }, status: entry.status,
                source: .tracked(baseRef: compareRef, targetRef: targetRef), repoDir: repoDir, submodulePath: submodulePath,
                gitlink: entry.gitlink)
        }

        // A committed comparison has no worktree, so nothing a policy could hide is in the picture and the
        // settings stay unread: `statusEntries` is non-nil exactly for the working-tree scopes.
        var ignoreSettings = SubmoduleIgnoreSettings.unconfigured
        if let statusEntries {
            // A submodule pointer left in an unresolved-conflict index state by a conflicting merge produces an
            // EMPTY per-file patch, exactly like a pointer-preserving rename's: `parseRawZ` alone cannot tell
            // the two cases apart (see `Gitlink`'s doc comment). The porcelain status snapshot already read
            // above is what names the conflict, so remap every gitlink plan whose path it marks unmerged before
            // patches are ever fetched.
            //
            // Accepted: this only remaps gitlinks the raw listing already produced. A submodule that BOTH sides
            // of a merge added at the same path (porcelain `AA`, HEAD has no entry) yields no raw record, so it
            // has no plan and is absent from the manifest until the conflict is resolved. Synthesizing a plan
            // from the status entry alone would need a source for its pointer that the raw listing does not
            // supply; the state is transient and the conflict is visible in `git status`, so the row is not
            // worth a second listing path.
            //
            // Also accepted: `baseCommit` is the pointer recorded at `compareRef`, which in a named-ref scope
            // is the merge base rather than HEAD. While the pointer is unmerged its patch is empty, so the row
            // falls back to `baseCommit` alone and, when the merge base recorded a different pointer than HEAD,
            // names that older commit instead of HEAD's side. Reading HEAD's stage-2 entry here would add a
            // second `ls-files -u`/`ls-tree` pass to every named-ref listing for a state that lasts only until
            // the conflict is resolved and that Uncommitted, the scope a conflict is resolved in, reports
            // correctly (its `compareRef` is HEAD).
            let unmergedPaths = Set(statusEntries.filter { isUnmergedPorcelainStatus($0.status) }.map { pathPrefix + $0.path })
            if !unmergedPaths.isEmpty {
                plans = plans.map { plan in
                    guard let gitlink = plan.gitlink, unmergedPaths.contains(plan.path) else { return plan }
                    return DiffFilePlan(
                        path: plan.path, oldPath: plan.oldPath, status: plan.status, source: plan.source, repoDir: plan.repoDir,
                        submodulePath: plan.submodulePath,
                        gitlink: Gitlink(
                            baseCommit: gitlink.baseCommit, unmerged: true, checkedOut: gitlink.checkedOut,
                            ignorePolicy: gitlink.ignorePolicy))
                }
            }

            // The pointer row for a submodule the raw listing above dropped: one whose checkout sits at the
            // recorded commit and whose only change is untracked content (see the `--ignore-submodules`
            // paragraph above). Without it that submodule's new files have no row to nest under and the
            // whole submodule is missing from the diff.
            //
            // Deriving the row from the porcelain rather than forcing the raw listing to emit it keeps two
            // things true. The repository's `submodule.<name>.ignore` configuration still decides which
            // submodules are listed at all, because `git status` honors it. And every row this adds is one
            // the scope signature already refreshes, because the signature's recursive per-submodule fold
            // walks the same porcelain directory entries; a row forced in past that configuration would
            // have gone stale on screen instead.
            //
            // A porcelain entry that names a directory is a submodule or nothing: `--untracked-files=all`
            // expands an ordinary untracked directory into its files, and a wholly untracked nested
            // repository comes through as a `??` record, excluded here as it is below. The `ls-tree`
            // confirming the gitlink runs only for such a directory, so a workspace without submodules
            // spawns no extra git command. An unmerged entry is skipped: a conflicted pointer the raw
            // listing did not name stays absent, exactly as the acceptance above describes.
            let rawNamedPaths = Set(plans.map(\.path))
            var pointerCandidates: [(repoRelativePath: String, baseCommit: String)] = []
            for entry in statusEntries
            where entry.status != "??" && !isUnmergedPorcelainStatus(entry.status) && !rawNamedPaths.contains(pathPrefix + entry.path) {
                var isDirectory: ObjCBool = false
                let entryDir = (repoDir as NSString).appendingPathComponent(entry.path)
                guard FileManager.default.fileExists(atPath: entryDir, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                guard
                    let baseCommit = try recordedGitlinkCommit(
                        repoDir: repoDir, treeish: compareRef, repoRelativePath: entry.path, gitClient: gitClient,
                        timeout: try remainingTimeout(start: deadlineStart))
                else { continue }
                pointerCandidates.append((entry.path, baseCommit))
            }

            if !pointerCandidates.isEmpty || plans.contains(where: { $0.gitlink != nil }) {
                ignoreSettings = try submoduleIgnoreSettings(repoDir: repoDir, gitClient: gitClient, deadlineStart: deadlineStart)
            }

            // Only a submodule the repository leaves fully reported gets a row synthesized for it. Under
            // `untracked` git's diff default IS the policy, so there is no gap to close; under `dirty` the
            // porcelain reports nothing to build a row from; and under `all` the porcelain still names a
            // STAGED pointer move that the diff deliberately hides (confirmed empirically), which is
            // precisely the row a synthesis must not resurrect.
            for candidate in pointerCandidates where ignoreSettings.policy(forRepoRelativePath: candidate.repoRelativePath) == .none {
                plans.append(
                    DiffFilePlan(
                        path: pathPrefix + candidate.repoRelativePath, oldPath: nil, status: .modified,
                        source: .tracked(baseRef: compareRef, targetRef: targetRef), repoDir: repoDir, submodulePath: submodulePath,
                        // `checkedOut` and `ignorePolicy` are placeholders here, resolved for every pointer row alike by
                        // `pointerPlan` once the expansion below has probed the checkout and the policy.
                        gitlink: Gitlink(baseCommit: candidate.baseCommit, unmerged: false, checkedOut: false, ignorePolicy: .none)))
            }

            // `--untracked-files=all` normally means every `??` record is already a file, never a directory,
            // except a nested, un-added git repository (`git init`'d inside the workspace but never `git
            // submodule add`ed): git status does not descend across that repository boundary even with `all`,
            // so it reports the whole thing as one directory record, `?? dir/`, trailing slash included.
            // Skipped here (no plan is created for it) because `writeUntrackedPatch` below reads the path as a
            // regular file and would fail trying to diff a directory; there is also no product representation
            // for "an entire nested repository, untracked" to give it.
            let untrackedPaths = statusEntries.filter { $0.status == "??" && !$0.path.hasSuffix("/") }.map { pathPrefix + $0.path }

            // A path can legitimately appear in both snapshots when `--raw` reports it `.deleted`
            // relative to `compareRef` while the earlier status snapshot reports it untracked (`??`, present on
            // disk). That is one content change and is coalesced below. A non-deleted overlap is a race: an agent
            // staged the file after the status snapshot but before the newer raw enumeration. In that
            // case the newer tracked plan is authoritative and the stale untracked plan must be suppressed, or
            // the response contains duplicate file IDs. A rename's recreated `oldPath` remains distinct because
            // the tracked plan is keyed by the rename's new `path`.
            let untrackedPathSet = Set(untrackedPaths)
            let trackedPathSet = Set(plans.map(\.path))
            let deletedButUntrackedPaths = Set(plans.filter { $0.status == .deleted && untrackedPathSet.contains($0.path) }.map(\.path))
            if !deletedButUntrackedPaths.isEmpty {
                plans = plans.map { plan in
                    guard deletedButUntrackedPaths.contains(plan.path) else { return plan }
                    return DiffFilePlan(
                        path: plan.path, oldPath: nil, status: .modified, source: .deletedButUntrackedInWorktree(compareRef: compareRef),
                        repoDir: plan.repoDir, submodulePath: plan.submodulePath)
                }
            }
            plans += untrackedPaths.filter { !deletedButUntrackedPaths.contains($0) && !trackedPathSet.contains($0) }.map { path in
                DiffFilePlan(path: path, oldPath: nil, status: .untracked, source: .untracked, repoDir: repoDir, submodulePath: submodulePath)
            }
        }

        let expanded = try expandSubmodulePlans(
            plans: plans, repoDir: repoDir, compareRef: compareRef, targetRef: targetRef, ignoreSettings: ignoreSettings,
            inheritedIgnore: inheritedIgnore, depth: depth, gitClient: gitClient, deadlineStart: deadlineStart)
        // One path, one row, is what every consumer downstream assumes: manifest chunks, the patch transfer
        // store, `DiffPlanSnapshot.plan(for:)`, and the client's own file ids all key by the
        // workspace-relative path, so a second row for a path would appear as a duplicate file resolving to
        // the first row's metadata. Every enumeration above is written to hold that (untracked entries are
        // filtered against the tracked set, a deleted path present on disk is coalesced into one row, and a
        // descended submodule drops the superproject's rows for its subtree), so this states the invariant in
        // debug builds instead of a dedupe pass running over every manifest.
        assert(Set(expanded.map(\.path)).count == expanded.count, "Diff plans contain duplicate paths: \(expanded.map(\.path))")
        return expanded
    }

    /// Maximum number of submodule levels the diff descends. A submodule at this depth keeps its pointer
    /// row, contributes no nested entries, and reports `checkedOut: false` to say so. The bound exists
    /// because `.gitmodules` graphs are user-authored and a superproject can point a submodule back at an
    /// ancestor, which would otherwise make this recursion (and the signature fold and file listing that
    /// mirror it) unbounded inside a single request. Eight levels is far past any real vendoring layout.
    static let maxSubmoduleDepth = 8

    /// Resolves each submodule pointer plan's `checkedOut` state and splices the submodule's own changed
    /// files in directly after its pointer row, keeping the snapshot's flat pointer-then-children order.
    ///
    /// A submodule contributes nested entries only when the comparison still has a submodule on its new
    /// side, its checkout is readable for this comparison (see `submoduleIsReadable`), and the depth bound
    /// allows descending. Failing any of those is reported the same way, as `checkedOut: false`, because
    /// the client sees the same thing in each case: a pointer row standing alone. A clean submodule
    /// never reaches here at all: with no pointer move and no dirty worktree it produces no raw record, so
    /// there is no row to nest under.
    private static func expandSubmodulePlans(
        plans: [DiffFilePlan], repoDir: String, compareRef: String, targetRef: String?, ignoreSettings: SubmoduleIgnoreSettings,
        inheritedIgnore: SubmoduleIgnorePolicy, depth: Int, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date
    ) throws -> [DiffFilePlan] {
        guard plans.contains(where: { $0.gitlink != nil }) else { return plans }
        var expanded: [DiffFilePlan] = []
        expanded.reserveCapacity(plans.count)
        // Path prefixes of the submodules this expansion descended into, which own every row below them
        // (see the descent below for the rule). A listing can name a path under a gitlink either side of
        // the pointer row, so the ownership is applied in both directions: here for the rows still ahead,
        // and at the descent for any this loop already appended.
        var ownedSubtrees: [String] = []
        for plan in plans {
            guard !ownedSubtrees.contains(where: { plan.path.hasPrefix($0) }) else { continue }
            guard let gitlink = plan.gitlink else {
                expanded.append(plan)
                continue
            }
            // Carried on every pointer row, including the ones that return early below, because it is the
            // policy the row's own patch is written under. One rule decides it for every row at every
            // level: whichever of this repository's setting for the submodule and the policy inherited from
            // above hides more (see `strictest`).
            let policy = ignoreSettings.policy(forRepoRelativePath: plan.repoRelativePath).strictest(inheritedIgnore)
            // A removed pointer has no submodule on its new side to look inside, and a removal is the only
            // shape that lacks one: every other status leaves a gitlink at the plan's path on the new side,
            // whether that side is a tree or the working tree. So this is also what keeps a committed scope
            // from ever descending with a nil target commit, which one level lower would silently mean "the
            // working tree" and compare a committed scope against live bytes.
            //
            // The checkout directory can still be sitting there, readable and holding the recorded commit
            // (`git rm --cached <sub>` leaves it behind as an untracked nested repository), so the
            // readability probe below would say yes and a working-tree scope would then list that leftover
            // repository's own local changes under a row the diff is reporting as deleted. Those changes
            // belong to no comparison here: nothing tracks them any more.
            guard plan.status != .deleted else {
                expanded.append(pointerPlan(plan, gitlink: gitlink, checkedOut: false, ignorePolicy: policy))
                continue
            }
            // At the depth bound nothing under this pointer would be shown, so the row reports itself
            // exactly as an unreadable checkout does: pointer only, nothing nested, which is what
            // `checkedOut` promises a client. Deciding it here also skips the pointer lookups and the
            // readability probe below, whose only purpose is to serve a descent that cannot happen.
            guard depth < maxSubmoduleDepth else {
                expanded.append(pointerPlan(plan, gitlink: gitlink, checkedOut: false, ignorePolicy: policy))
                continue
            }
            let subDir = (repoDir as NSString).appendingPathComponent(plan.repoRelativePath)
            // The commits this comparison records for the pointer, read from the trees themselves rather
            // than from `--raw`'s object ids, which are unreliable for a gitlink (see `Gitlink`'s doc
            // comment). A nil base is a submodule being added; the target side is always recorded here,
            // since the removal that would leave it empty returned above.
            //
            // The base side is looked up at the pre-rename path: a renamed submodule is recorded under its
            // old name in the comparison tree, so looking it up by the new name would find nothing and make
            // the recursion below diff the checkout against the empty tree, listing every file in the
            // submodule as added.
            let baseCommit = try recordedGitlinkCommit(
                repoDir: repoDir, treeish: compareRef, repoRelativePath: plan.repoRelativeOldPath ?? plan.repoRelativePath, gitClient: gitClient,
                timeout: try remainingTimeout(start: deadlineStart))
            let targetCommit = try targetRef.flatMap {
                try recordedGitlinkCommit(
                    repoDir: repoDir, treeish: $0, repoRelativePath: plan.repoRelativePath, gitClient: gitClient,
                    timeout: try remainingTimeout(start: deadlineStart))
            }
            let checkedOut = try submoduleIsReadable(
                repoDir: repoDir, repoRelativePath: plan.repoRelativePath, recordedCommits: [baseCommit, targetCommit].compactMap { $0 },
                gitClient: gitClient, deadlineStart: deadlineStart)
            expanded.append(pointerPlan(plan, gitlink: gitlink, checkedOut: checkedOut, ignorePolicy: policy))
            guard checkedOut else { continue }
            // `dirty` and `all` tell git the submodule's worktree is not to be looked at, and the nested
            // entries are exactly that worktree. The pointer row stays (a pointer move is not worktree
            // state, and `dirty` still reports it), it simply has nothing under it, which is the same thing
            // `git diff` shows for this repository. `checkedOut` keeps saying the checkout is readable
            // rather than being repurposed to mean "suppressed": the client's own pointer text is what
            // explains an empty row here, and calling a present checkout absent would be a lie.
            guard policy == .none || policy == .untracked else { continue }
            let subCompareRef = try baseCommit ?? emptyTreeObject(repoDir: subDir, gitClient: gitClient, deadlineStart: deadlineStart)
            // A working-tree scope needs the submodule's own untracked files, which never appear in `git
            // diff` output; a committed scope has no working tree involved at all, so it reads no status.
            // Under `untracked` the submodule's own untracked files are the one thing the parent asked not
            // to be told about, so they are dropped here rather than filtered out of the finished plans:
            // the porcelain snapshot is the only thing that puts an untracked file in the listing at all.
            let subStatusEntries =
                targetRef == nil
                ? changedEntries(
                    fromPorcelainZ: try gitClient.runGitAndCapture(
                        ["-C", subDir, "status", "--porcelain", "-z", "--untracked-files=all"],
                        timeout: try remainingTimeout(start: deadlineStart))
                ).filter { policy != .untracked || $0.status != "??" }
                : nil
            // A descended submodule owns its whole subtree: the checkout is what lives at those paths now,
            // and the nested plans below describe every one of its files against the submodule's own base.
            // The superproject can still have rows of its own down there, because a tracked directory
            // replaced by a submodule at the same path leaves a deleted `A/foo` in this listing next to the
            // new gitlink `A`; those rows describe the tree the checkout replaced. Manifests and
            // `plan(for:)` key by one workspace-relative path and keep the first match, so leaving both in
            // would give one file two rows carrying whichever metadata happened to land first.
            //
            // This is conditional on the descent actually happening. A pointer row that nests nothing (not
            // checked out, dirt the policy hides, or the depth bound) leaves the superproject's rows alone,
            // since then they are the only truth for that subtree.
            //
            // The reverse transition, a submodule removed and ordinary files committed at `A/foo`, needs
            // nothing here: the removed pointer never descends (see the deleted guard above), so the
            // superproject's rows are already the only ones.
            // The trailing slash is what keeps a sibling named `A2` out of `A`'s subtree.
            let ownedSubtree = plan.path + "/"
            expanded.removeAll { $0.path.hasPrefix(ownedSubtree) }
            ownedSubtrees.append(ownedSubtree)
            expanded += try buildRepoPlans(
                repoDir: subDir, compareRef: subCompareRef, targetRef: targetCommit, submodulePath: plan.path, statusEntries: subStatusEntries,
                inheritedIgnore: policy, depth: depth + 1, gitClient: gitClient, deadlineStart: deadlineStart)
        }
        return expanded
    }

    /// The submodule's own pointer row, rebuilt with the readability this expansion resolved. Every other
    /// field is the plan `parseRawZ` produced.
    private static func pointerPlan(_ plan: DiffFilePlan, gitlink: Gitlink, checkedOut: Bool, ignorePolicy: SubmoduleIgnorePolicy)
        -> DiffFilePlan
    {
        DiffFilePlan(
            path: plan.path, oldPath: plan.oldPath, status: plan.status, source: plan.source, repoDir: plan.repoDir,
            submodulePath: plan.submodulePath,
            gitlink: Gitlink(
                baseCommit: gitlink.baseCommit, unmerged: gitlink.unmerged, checkedOut: checkedOut, ignorePolicy: ignorePolicy))
    }

    /// The commit id `treeish` records for the gitlink at `repoRelativePath`, or nil when that tree has no
    /// gitlink there. `ls-tree` is the structured authority for this: it reports the entry's mode, so a path
    /// that holds an ordinary file or directory on that side (a type change, or the pointer's add/remove
    /// side) is distinguished from a real gitlink rather than being read as one. `:(literal)` keeps a
    /// filename containing pathspec magic from matching something else.
    static func recordedGitlinkCommit(
        repoDir: String, treeish: String, repoRelativePath: String, gitClient: RemoteWorkspaceGitClient, timeout: TimeInterval
    ) throws -> String? {
        let output = try gitClient.runGitAndCapture(
            ["-C", repoDir, "ls-tree", "-z", treeish, "--", ":(literal)\(repoRelativePath)"], timeout: timeout)
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, fields[0] == "160000" else { continue }
            return String(fields[2])
        }
        return nil
    }

    /// The effective ignore policy this repository applies to each of its submodules, keyed by the
    /// submodule's repo-relative path. Git's own precedence, in three `git config` reads: the repository's
    /// own config (`.git/config`, where `git submodule` writes a user's private per-submodule override)
    /// wins over `.gitmodules` (where a project ships the setting for everyone it clones to), and
    /// `diff.ignoreSubmodules` is the default for a submodule neither of them names. A gitlink with no
    /// `.gitmodules` entry has no name for the per-submodule keys to attach to, so only that default
    /// reaches it. A value git does not recognize is read as `none`, which is how git treats it too.
    ///
    /// Read once per repository rather than once per pointer row, and only for a working-tree scope that
    /// has a gitlink in play: a committed comparison has no worktree for any of this to hide.
    private static func submoduleIgnoreSettings(repoDir: String, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date) throws
        -> SubmoduleIgnoreSettings
    {
        let repositoryDefault = SubmoduleIgnorePolicy(
            rawValue: try gitClient.runGitAndCapture(
                ["-C", repoDir, "config", "--get", "diff.ignoreSubmodules"], timeout: try remainingTimeout(start: deadlineStart),
                allowedExitCodes: [0, 1]
            ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? .none
        // `.gitmodules` lives at the repository's top level, and `repoDir` is not that for a workspace
        // rooted below it (a monorepo subpackage, which `Orchestrator.normalizeDir` accepts as its own
        // project). Naming the file relative to `repoDir` would simply not find it, and its `path` values
        // are relative to that top level rather than to the workspace, so the prefix has to come off each
        // one before it can match a gitlink's repo-relative path. One `rev-parse` answers both, and a
        // workspace at the repository root takes the same path through this with an empty prefix.
        let location = try gitClient.runGitAndCapture(
            ["-C", repoDir, "rev-parse", "--show-toplevel", "--show-prefix"], timeout: try remainingTimeout(start: deadlineStart))
        let lines = location.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else {
            throw SpacesRuntimeError.gitCommandFailed(message: "git rev-parse did not report this repository's top level: \(location)")
        }
        let workspacePrefix = lines[1]
        let moduleEntries = try submoduleConfigEntries(
            repoDir: repoDir, file: (lines[0] as NSString).appendingPathComponent(".gitmodules"), gitClient: gitClient,
            deadlineStart: deadlineStart)
        guard !moduleEntries.isEmpty else { return SubmoduleIgnoreSettings(repositoryDefault: repositoryDefault, byPath: [:]) }
        // The repository's own config is found through its git dir rather than the working directory, so
        // this read answers the same from any depth and needs no prefix handling (confirmed empirically).
        let overrideEntries = try submoduleConfigEntries(repoDir: repoDir, file: nil, gitClient: gitClient, deadlineStart: deadlineStart)

        var byPath: [String: SubmoduleIgnorePolicy] = [:]
        for (key, path) in moduleEntries where key.hasSuffix(".path") {
            // A submodule outside the workspace's own subtree keeps its prefix and is dropped: `--relative`
            // already keeps it out of the enumeration, so no row can ever ask for its policy.
            guard path.hasPrefix(workspacePrefix) else { continue }
            let repoRelativePath = String(path.dropFirst(workspacePrefix.count))
            guard !repoRelativePath.isEmpty else { continue }
            let name = String(key.dropFirst("submodule.".count).dropLast(".path".count))
            guard let raw = overrideEntries["submodule.\(name).ignore"] ?? moduleEntries["submodule.\(name).ignore"] else { continue }
            byPath[repoRelativePath] = SubmoduleIgnorePolicy(rawValue: raw) ?? .none
        }
        return SubmoduleIgnoreSettings(repositoryDefault: repositoryDefault, byPath: byPath)
    }

    /// Every `submodule.*` key one config source holds, as key/value pairs. `-z` is what makes the parse
    /// safe: a config value may contain newlines, and only the NUL record separator tells one entry from
    /// the next (git writes each record as `key\nvalue`). Exit code 1 means the pattern matched nothing, or
    /// the file is not there at all, which are the same answer here: no submodule keys.
    private static func submoduleConfigEntries(
        repoDir: String, file: String?, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date
    ) throws -> [String: String] {
        var arguments = ["-C", repoDir, "config"]
        if let file { arguments += ["-f", file] }
        arguments += ["-z", "--get-regexp", "^submodule\\."]
        let output = try gitClient.runGitAndCapture(
            arguments, timeout: try remainingTimeout(start: deadlineStart), allowedExitCodes: [0, 1])
        var entries: [String: String] = [:]
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let newline = record.firstIndex(of: "\n") else { continue }
            entries[String(record[..<newline])] = String(record[record.index(after: newline)...])
        }
        return entries
    }

    /// Whether a submodule checkout can be descended into for this comparison. Two facts, both required:
    /// the path is a checkout this daemon may run git in at all (see `isContainedGitlinkCheckout`, which
    /// covers the uninitialized, removed, and symlinked-away cases without spawning a git process), and
    /// every commit the comparison records is present there.
    ///
    /// The commit check catches the remaining case, a checkout that exists but cannot describe this
    /// comparison: a shallow submodule clone, or one whose recorded pointer was never fetched. Descending
    /// there would fail mid-request with a bare git error instead of reporting an honest pointer-only row.
    private static func submoduleIsReadable(
        repoDir: String, repoRelativePath: String, recordedCommits: [String], gitClient: RemoteWorkspaceGitClient, deadlineStart: Date
    ) throws -> Bool {
        guard SpacesDeviceWorkspacePathResolver.isContainedGitlinkCheckout(repoDir: repoDir, repoRelativePath: repoRelativePath) else {
            return false
        }
        let subDir = (repoDir as NSString).appendingPathComponent(repoRelativePath)
        for commit in recordedCommits {
            let resolved = try gitClient.runGitAndCapture(
                ["-C", subDir, "rev-parse", "--verify", "--quiet", "\(commit)^{commit}"], timeout: try remainingTimeout(start: deadlineStart),
                allowedExitCodes: [0, 1]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else { return false }
        }
        return true
    }

    /// Git's empty tree object for `repoDir`, the base side used when a comparison has no commit on that
    /// side at all (an unborn HEAD, a root commit, a submodule being added). Computed per repository via
    /// `hash-object -t tree /dev/null` rather than hardcoded as the well-known SHA-1 constant
    /// (`4b825dc642cb6eb9a060e54bf8d69288fbee4904`), so it stays correct for a repository created with a
    /// non-SHA-1 object format (`git init --object-format=sha256`), where that constant resolves to nothing.
    private static func emptyTreeObject(repoDir: String, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date) throws -> String {
        try gitClient.runGitAndCapture(["-C", repoDir, "hash-object", "-t", "tree", "/dev/null"], timeout: try remainingTimeout(start: deadlineStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The immutable metadata and patch-file length for one daemon-owned patch transfer. The patch itself
    /// stays on disk; callers read it in bounded byte ranges instead of ever materializing it as a `String`.
    struct FilePatchTransfer {
        let scopeSignature: String
        let file: SpacesDeviceWorkspaceDiffFileMetadata
        let patchByteCount: Int64
    }

    /// Builds exactly one file patch from a plan retained by the manifest session. It deliberately accepts
    /// the already-enumerated plan rather than rebuilding it: K streamed files therefore do one workspace
    /// status/raw-diff walk plus K per-file diffs, not K complete workspace walks.
    static func writeDiffFilePatch(
        snapshot: DiffPlanSnapshot, relativePath: String, outputURL: URL, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date
    ) throws -> FilePatchTransfer? {
        guard let plan = snapshot.plan(for: relativePath) else { return nil }

        let wrotePatch = try writePatch(for: plan, outputURL: outputURL, gitClient: gitClient, deadlineStart: deadlineStart)
        let patchByteCount = wrotePatch ? fileByteCount(at: outputURL) : 0
        let metadata =
            wrotePatch ? patchMetadata(at: outputURL, gitlink: plan.gitlink) : (isBinary: false, oldSHA: nil, newSHA: nil, submodule: nil)
        let file = SpacesDeviceWorkspaceDiffFileMetadata(
            path: plan.path, oldPath: plan.oldPath, status: plan.status, isBinary: metadata.isBinary, oldSHA: metadata.oldSHA, newSHA: metadata.newSHA,
            targetRevision: {
                guard case .tracked(_, let targetRef?) = plan.source else { return nil }
                return targetRef
            }(), submodule: metadata.submodule, submodulePath: plan.submodulePath
        )
        return FilePatchTransfer(scopeSignature: snapshot.scopeSignature, file: file, patchByteCount: patchByteCount)
    }

    /// Writes a git diff to the caller's private temporary file. `git --output` leaves stdout empty, so
    /// `runGitAndCapture` retains its established timeout/error handling without retaining the patch body in
    /// daemon memory.
    private static func writePatch(for plan: DiffFilePlan, outputURL: URL, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date) throws -> Bool {
        let timeout = try remainingTimeout(start: deadlineStart)
        switch plan.source {
        case .tracked(let baseRef, let targetRef):
            try gitClient.runGitWithFileOutput(
                trackedDiffArguments(for: plan, baseRef: baseRef, targetRef: targetRef, outputURL: outputURL), timeout: timeout)
            return true
        case .untracked:
            return try writeUntrackedPatch(for: plan, outputURL: outputURL, gitClient: gitClient, timeout: timeout)
        case .deletedButUntrackedInWorktree(let compareRef):
            return try writeCoalescedDeletedButUntrackedPatch(
                for: plan, compareRef: compareRef, outputURL: outputURL, gitClient: gitClient, deadlineStart: deadlineStart)
        }
    }

    /// The `a/` and `b/` header prefixes for one plan's patch. A file inside a submodule is diffed by that
    /// submodule's own repository, so git would otherwise write submodule-relative header paths (`a/file`)
    /// for a row the client knows by its workspace-relative path (`sub/file`), the paths the client anchors
    /// comments and inline edits to. Folding the submodule's path into the prefixes makes every header agree
    /// with the row's identity without rewriting patch bytes afterwards. A top-level file passes no prefix
    /// arguments at all, so its patch stays byte-for-byte what git produces by default.
    private static func patchPrefixArguments(for plan: DiffFilePlan) -> [String] {
        guard let submodulePath = plan.submodulePath else { return [] }
        return ["--src-prefix=a/\(submodulePath)/", "--dst-prefix=b/\(submodulePath)/"]
    }

    /// `:(literal)` forces git to match each pathspec argument as an exact path rather than parsing it for
    /// magic: a legal tracked filename that happens to start with `:` (e.g. `:foo` or `:(glob)x`) would
    /// otherwise be interpreted as pathspec magic itself, silently matching nothing (an empty patch, even
    /// though the `--raw` enumeration correctly identified it as changed) or, for other magic keywords,
    /// unrelated files. The `--raw -z` enumeration takes no per-file pathspec, so it is unaffected and stays
    /// the source of truth for which paths actually changed. The pathspec is repo-relative because pathspecs
    /// resolve against the CWD, which is `plan.repoDir`; `--relative` is still passed so the patch's own
    /// headers come out relative to that directory rather than to the repository root (confirmed
    /// empirically: the pathspec match succeeds either way, but only `--relative` also relativizes the
    /// `diff --git a/... b/...` header text).
    ///
    /// A pointer row names its repository's effective ignore policy for that submodule explicitly, rather
    /// than leaving the body to git's `untracked` default. The default is wrong in both directions here:
    /// for an unconfigured submodule dirty from untracked content alone it prints an EMPTY body, which
    /// `parsePatchMetadata` can only read as an unchanged pointer with a clean worktree, contradicting the
    /// files listed under the row; and for a submodule configured `dirty` it would mark the row dirty after
    /// the enumeration already decided that worktree is not to be looked at. Naming the policy makes the
    /// body say exactly what this repository configured git to say. Only a gitlink takes the argument,
    /// since it is the only row whose content is a submodule.
    private static func trackedDiffArguments(for plan: DiffFilePlan, baseRef: String, targetRef: String?, outputURL: URL) -> [String] {
        var arguments = [
            "-C", plan.repoDir, "-c", "core.quotepath=false", "diff", "--output=\(outputURL.path)", "-M", "--no-color", "--no-ext-diff",
            "--no-textconv", "--submodule=short", "--relative",
        ]
        if let gitlink = plan.gitlink { arguments.append("--ignore-submodules=\(gitlink.ignorePolicy.rawValue)") }
        arguments.append(contentsOf: patchPrefixArguments(for: plan))
        arguments.append(baseRef)
        if let targetRef { arguments.append(targetRef) }
        arguments.append("--")
        if let oldPath = plan.repoRelativeOldPath { arguments.append(":(literal)\(oldPath)") }
        arguments.append(":(literal)\(plan.repoRelativePath)")
        return arguments
    }

    private static func fileByteCount(at url: URL) -> Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }

    /// Git's `index`/`Binary files ... differ`/`Subproject commit` header lines always precede any hunk
    /// body. Sampling a fixed prefix keeps binary/SHA/submodule classification bounded even when the
    /// textual patch is hundreds of MB.
    private static func patchMetadata(at url: URL, gitlink: Gitlink?) -> (
        isBinary: Bool, oldSHA: String?, newSHA: String?, submodule: SpacesDeviceWorkspaceDiffSubmoduleChange?
    ) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return (false, nil, nil, nil) }
        defer { try? handle.close() }
        let prefix: Data
        do { prefix = try handle.read(upToCount: 128 * 1024) ?? Data() } catch { return (false, nil, nil, nil) }
        return parsePatchMetadata(String(decoding: prefix, as: UTF8.self), gitlink: gitlink)
    }

    /// The transfer path retains the old untracked safety rules but intentionally removes the old visible
    /// patch-size cap: its output goes to a private file and reaches the client only through 4 MiB chunks.
    private static func writeUntrackedPatch(for plan: DiffFilePlan, outputURL: URL, gitClient: RemoteWorkspaceGitClient, timeout: TimeInterval)
        throws -> Bool
    {
        let fullPath = (plan.repoDir as NSString).appendingPathComponent(plan.repoRelativePath)
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath) else { return false }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { return false }
        if type == .typeSymbolicLink {
            var targetStat = stat()
            if stat(fullPath, &targetStat) == 0, (targetStat.st_mode & S_IFMT) != S_IFREG { return false }
        }
        var arguments = [
            "-C", plan.repoDir, "-c", "core.quotepath=false", "diff", "--output=\(outputURL.path)", "--no-color", "--no-ext-diff",
            "--no-textconv", "--no-index",
        ]
        arguments.append(contentsOf: patchPrefixArguments(for: plan))
        arguments.append(contentsOf: ["--", "/dev/null", plan.repoRelativePath])
        try gitClient.runGitWithFileOutput(arguments, timeout: timeout, allowedExitCodes: [0, 1])
        return true
    }

    /// A deleted-plus-untracked collision needs a scratch index to make Git describe the worktree file
    /// against the comparison ref as one coherent patch. `git update-index` hashes the worktree file, so
    /// the scratch index also gets a scratch object directory with the repository's objects as read-only
    /// alternates; otherwise merely viewing a diff would permanently add the recreated file's blob to the
    /// user's repository. The patch body is written directly to the transfer file, so the extra Git
    /// operation adds neither an in-memory size cap nor repeated work per range.
    private static func writeCoalescedDeletedButUntrackedPatch(
        for plan: DiffFilePlan, compareRef: String, outputURL: URL, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date
    ) throws -> Bool {
        let repoDir = plan.repoDir
        let path = plan.repoRelativePath
        let fullPath = (repoDir as NSString).appendingPathComponent(path)
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath) else { return false }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { return false }

        let objectDirectoryOutput = try gitClient.runGitAndCapture(
            ["-C", repoDir, "rev-parse", "--git-path", "objects"], timeout: try remainingTimeout(start: deadlineStart))
        let objectDirectoryPath = objectDirectoryOutput.hasSuffix("\n") ? String(objectDirectoryOutput.dropLast()) : objectDirectoryOutput
        guard !objectDirectoryPath.isEmpty else {
            throw SpacesRuntimeError.gitCommandFailed(message: "git rev-parse --git-path objects returned an empty path.")
        }
        let objectDirectoryURL = URL(
            fileURLWithPath: objectDirectoryPath, isDirectory: true, relativeTo: URL(fileURLWithPath: repoDir, isDirectory: true)
        ).standardizedFileURL
        let scratchDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
            "spaces-workspacediff-\(UUID().uuidString)", isDirectory: true)
        let scratchObjectsURL = scratchDirectoryURL.appendingPathComponent("objects", isDirectory: true)
        try fileManager.createDirectory(at: scratchObjectsURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratchDirectoryURL) }
        let scratchIndexEnvironment = [
            "GIT_INDEX_FILE": scratchDirectoryURL.appendingPathComponent("index").path, "GIT_OBJECT_DIRECTORY": scratchObjectsURL.path,
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": objectDirectoryURL.path,
        ]
        _ = try gitClient.runGitAndCapture(
            ["-C", repoDir, "update-index", "--add", "--", path], timeout: try remainingTimeout(start: deadlineStart),
            environmentOverrides: scratchIndexEnvironment)
        let diffTimeout = try remainingTimeout(start: deadlineStart)
        var diffArguments = [
            "-C", repoDir, "-c", "core.quotepath=false", "diff", "--output=\(outputURL.path)", "--no-color", "--no-ext-diff",
            "--no-textconv", "--relative",
        ]
        diffArguments.append(contentsOf: patchPrefixArguments(for: plan))
        diffArguments.append(contentsOf: [compareRef, "--", ":(literal)\(path)"])
        try gitClient.runGitWithFileOutput(diffArguments, timeout: diffTimeout, environmentOverrides: scratchIndexEnvironment)
        return true
    }

    /// The lastCommit scope's diff: committed-only, `git diff <parent> HEAD` with the exact same flags as
    /// every other diff invocation in this engine, and no working-tree or untracked involvement at all — no
    /// `git status`, no `deletedButUntrackedInWorktree` coalescing, since neither concept applies to a diff
    /// between two commits. Root commit and unborn HEAD are the same two special cases the manifest plan's
    /// nil-`refName` path already handles, probed the same way, but note the base case flips: THIS scope has
    /// no working tree to fall back on, so an unborn HEAD only ever has one legitimate outcome —
    /// nothing has been committed yet, so the "last commit" is empty.
    private static func buildLastCommitPlans(
        workspaceDir: String, gitClient: RemoteWorkspaceGitClient, signature: String, headSHA: String, deadlineStart: Date
    ) throws -> DiffPlanSnapshot {
        guard !headSHA.isEmpty else {
            // No commits exist yet, so there is no "last commit" to diff — an empty file list, not an
            // error, matching the manifest plan's treatment of an unborn HEAD as a supported state rather than
            // a failure.
            return DiffPlanSnapshot(scopeSignature: signature, plans: [])
        }

        // `<headSHA>^` resolves the snapshotted commit's first parent; `--verify --quiet` +
        // `allowedExitCodes: [0, 1]` reads a
        // root commit's "no such ref" (exit 1, empty stdout) as a legitimate answer rather than a failure,
        // exactly like every other resolvability probe in this file.
        let parentProbe = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--verify", "--quiet", "\(headSHA)^"], timeout: try remainingTimeout(start: deadlineStart),
            allowedExitCodes: [0, 1]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let parent: String
        if parentProbe.isEmpty {
            // Root commit: diff the empty tree against the snapshotted HEAD so every file it introduces
            // reports as an addition.
            parent = try emptyTreeObject(repoDir: workspaceDir, gitClient: gitClient, deadlineStart: deadlineStart)
        } else {
            parent = parentProbe
        }

        // Two explicit positional refs (`parent headSHA`), not a single `compareRef` against the working
        // tree, is what makes this diff committed-only; `statusEntries: nil` is the same statement on the
        // untracked side. A submodule nested under this scope is compared the same way, between the pointers
        // its two commits record.
        let plans = try buildRepoPlans(
            repoDir: workspaceDir, compareRef: parent, targetRef: headSHA, submodulePath: nil, statusEntries: nil, inheritedIgnore: .none,
            depth: 0, gitClient: gitClient, deadlineStart: deadlineStart)

        return DiffPlanSnapshot(scopeSignature: signature, plans: plans)
    }

    // MARK: - `git status --porcelain -z` parsing

    private struct PorcelainEntry {
        let status: String
        let path: String
        let origPath: String?
    }

    /// Whether a `git status --porcelain` two-letter `XY` code names an index entry a merge left in an
    /// unresolved-conflict state, per `git status`'s own documented short-format table: both sides touched
    /// it (`UU`), both added it (`AA`), both deleted it (`DD`), or one side deleted while the other side
    /// changed it (`AU`/`UA`/`DU`/`UD`). Used to flag a submodule gitlink whose per-file patch git prints
    /// empty because there is no merged content to diff (see `Gitlink`'s doc comment).
    private static func isUnmergedPorcelainStatus(_ status: String) -> Bool {
        ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(status)
    }

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
    /// so the result is workspace-relative — matching the manifest plan's `--relative`-scoped tracked
    /// enumeration reports for the same files. `git status` has no `--relative` of its own (confirmed
    /// against real git: `error: unknown option 'relative'`), so this is the client-side equivalent, shared
    /// by both `scopeSignature` and the manifest plan's untracked-file discovery — the one definition both must
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
    /// differs from the *diff* side (`--raw --relative`), where git itself auto-demotes such a
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
            if let origPath = entry.origPath { data.append(Data("\(origPath)\0".utf8)) }
        }
        return data
    }

    // MARK: - `git diff --raw -z` parsing

    private struct RawEntry {
        let status: SpacesDeviceWorkspaceDiffFileStatus
        let path: String
        let oldPath: String?
        /// Non-nil when `path` is a submodule pointer rather than file content, per `parseRawZ`'s
        /// destination-decides classification; carries that gitlink's base-side commit id (see `Gitlink`).
        let gitlink: Gitlink?
    }

    /// Parses `git diff -M --raw --no-abbrev -z <ref>` output: NUL-delimited records of the form
    /// `:<srcmode> <dstmode> <srcsha> <dstsha> <status>\0PATH\0` for an add/modify/delete, or
    /// `...<status>\0OLDPATH\0NEWPATH\0` for a rename/copy (`R100`, `C75`, ...): the old path comes first,
    /// matching `--name-status`'s tab-separated "old TAB new" ordering, which `--raw` otherwise mirrors
    /// exactly. This -z output is the one and only source of `path`/`oldPath`/`status` on every returned
    /// file: it is exact bytes (never C-quoted), unlike `git diff`'s human-readable `diff --git a/... b/...`
    /// header.
    ///
    /// `--raw` rather than `--name-status` because it is the only -z listing format that also reports each
    /// side's git object mode, which is how a submodule pointer (gitlink, mode `160000`) is told apart from
    /// an ordinary tracked file before ever reading its patch body; see the classification comment below
    /// for exactly which side decides. `--no-abbrev` (added at both call sites) makes the `srcsha`/`dstsha`
    /// fields full 40-char object ids instead of git's default abbreviation; for a gitlink entry this parser
    /// keeps only the base (src) side, as `Gitlink.baseCommit`; the destination side is unreliable for a
    /// gitlink (see that type's doc comment) and is never read.
    private static func parseRawZ(_ output: String) -> [RawEntry] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [RawEntry] = []
        var index = 0
        while index < tokens.count {
            let header = tokens[index]
            index += 1
            guard header.hasPrefix(":") else { continue }
            let fields = header.dropFirst().split(separator: " ")
            guard fields.count >= 5 else { continue }
            // The destination side decides whether this row is a read-only pointer or an editable text
            // patch, because that is the state the Editor would actually act on: a destination mode of
            // `160000` is a gitlink, whether the source was an existing gitlink (an ordinary pointer move)
            // or a regular file (`T`, a file replaced by a submodule at the same path), both land the user
            // on the same pointer row. A destination that is an ordinary file, even one replacing a removed
            // submodule (source `160000`, a reverse `T`), is ordinary file content, not a pointer row that
            // would hide it. The one entry with no destination at all is a delete, where the removed
            // gitlink's own mode (source `160000`) is what makes it a pointer row.
            let isSubmodule = fields[1] == "160000" || (fields[0] == "160000" && fields[1] == "000000")
            // `baseCommit` (see `Gitlink`) exists only when the source side is itself a gitlink: a
            // file-to-submodule type change's source is a regular file, i.e. a blob id, not a commit, so
            // `baseCommit` is nil there and the patch's `+Subproject commit` line alone supplies the new
            // commit (`Submodule added <sha>`).
            // `unmerged` is not knowable from `--raw` alone; `buildDiffPlanSnapshot` remaps it to `true` for
            // a gitlink whose path the porcelain status snapshot reports as unresolved-conflict, once that
            // snapshot is in hand.
            let gitlink: Gitlink? =
                isSubmodule
                    ? Gitlink(
                        baseCommit: fields[0] == "160000" ? String(fields[2]) : nil, unmerged: false, checkedOut: false, ignorePolicy: .none)
                    : nil
            guard let statusLetter = fields[4].first else { continue }
            switch statusLetter {
            case "R", "C":
                guard index + 1 < tokens.count else { continue }
                let oldPath = tokens[index]
                let newPath = tokens[index + 1]
                index += 2
                entries.append(RawEntry(status: .renamed, path: newPath, oldPath: oldPath, gitlink: gitlink))
            case "A":
                guard index < tokens.count else { continue }
                entries.append(RawEntry(status: .added, path: tokens[index], oldPath: nil, gitlink: gitlink))
                index += 1
            case "D":
                guard index < tokens.count else { continue }
                entries.append(RawEntry(status: .deleted, path: tokens[index], oldPath: nil, gitlink: gitlink))
                index += 1
            default:  // M, T, and anything else git reports as a plain content change.
                guard index < tokens.count else { continue }
                entries.append(RawEntry(status: .modified, path: tokens[index], oldPath: nil, gitlink: gitlink))
                index += 1
            }
        }
        return entries
    }

    /// Extracts just the "Binary files ... differ" marker, the `index <old>..<new>` blob SHAs, or, for a
    /// submodule pointer, its old/new commit ids and dirty flag, from one file's `git diff` output.
    ///
    /// A gitlink's commit ids come from the patch body's `Subproject commit` lines (`submoduleChange`
    /// below), because git resolves the submodule's actual worktree state there in every case that matters:
    /// an unstaged pointer move, a staged pointer move, and a dirty-but-unmoved worktree all print the
    /// correct ids (with a `-dirty` suffix on whichever side is dirty), while `--raw`'s own object ids are
    /// unreliable for those same cases (see `Gitlink`'s doc comment) and so are never used for this. The one
    /// case the patch body is silent on is a pointer-preserving rename (`git mv sub renamed-sub` with no
    /// pointer change): its `R100` status means the pointer is identical on both sides, so `gitlink`'s
    /// base-side id from `--raw` names that unchanged pointer directly.
    private static func parsePatchMetadata(_ patchText: String, gitlink: Gitlink?) -> (
        isBinary: Bool, oldSHA: String?, newSHA: String?, submodule: SpacesDeviceWorkspaceDiffSubmoduleChange?
    ) {
        if let gitlink {
            return (false, nil, nil, submoduleChange(from: patchText, gitlink: gitlink))
        }
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
        return (isBinary, oldSHA, newSHA, nil)
    }

    /// Parses a gitlink patch body's `Subproject commit` lines under `--submodule=short`: `-Subproject
    /// commit <sha>[-dirty]` is the old commit, `+Subproject commit <sha>[-dirty]` is the new one, and a
    /// `-dirty` suffix on either line means the submodule's own worktree has uncommitted changes. When the
    /// patch has at least one such line, these are the pointer's real old/new commits (an added submodule
    /// has only a `+` line and no old commit, a removed one only a `-` line and no new commit). When it has
    /// none, the pointer is either a pointer-preserving rename or an unmerged pointer left by a conflicting
    /// merge (see `Gitlink`'s doc comment): both print an empty patch, and are told apart only by
    /// `gitlink.unmerged`, never by the patch itself. Either way `gitlink.baseCommit` is reported as both
    /// the old and new commit: for a rename it names the unchanged pointer, and for an unmerged pointer it
    /// names the pointer the worktree currently holds (HEAD's side). Dirtiness is not derived for either
    /// case, so `dirty` is always false here: a rename with a dirty worktree takes the patch-parsing path
    /// above instead (see `submoduleRenamedWithADirtyWorktreeReportsDirty`), and an unmerged pointer's
    /// combined diff carries no `Subproject commit` line for this parser to read a `-dirty` suffix from.
    private static func submoduleChange(from patchText: String, gitlink: Gitlink) -> SpacesDeviceWorkspaceDiffSubmoduleChange {
        var oldCommit: String?
        var newCommit: String?
        var dirty = false
        var sawSubprojectLine = false
        for line in patchText.split(separator: "\n", omittingEmptySubsequences: false) {
            let isOld = line.hasPrefix("-Subproject commit ")
            let isNew = line.hasPrefix("+Subproject commit ")
            guard isOld || isNew else { continue }
            sawSubprojectLine = true
            let prefix = isOld ? "-Subproject commit " : "+Subproject commit "
            var sha = String(line.dropFirst(prefix.count))
            if sha.hasSuffix("-dirty") {
                sha.removeLast("-dirty".count)
                dirty = true
            }
            if isOld { oldCommit = sha } else { newCommit = sha }
        }
        // Accepted: for an unmerged gitlink (`gitlink.unmerged`), git's combined diff never carries a
        // `Subproject commit` line even when the checkout itself also has uncommitted changes, so `dirty`
        // can never be reported true while `unmerged` is true. Probing the submodule's own worktree state
        // separately (e.g. running `git status` inside it) to surface that combination is not worth it: the
        // state is transient by nature (the user's next step is resolving the conflict), and once resolved
        // the normal patch-parsing path above reports dirtiness again as usual.
        guard sawSubprojectLine else {
            return SpacesDeviceWorkspaceDiffSubmoduleChange(
                oldCommit: gitlink.baseCommit, newCommit: gitlink.baseCommit, dirty: false, unmerged: gitlink.unmerged,
                checkedOut: gitlink.checkedOut)
        }
        return SpacesDeviceWorkspaceDiffSubmoduleChange(
            oldCommit: oldCommit, newCommit: newCommit, dirty: dirty, unmerged: gitlink.unmerged, checkedOut: gitlink.checkedOut)
    }

}

/// Enumerates every path inside a workspace's checkout the user would consider part of the workspace.
/// Backs the `workspaceFileList` Device API command (the Editor pane's file tree and quick-open), which
/// — unlike the manifest/chunk diff API — must serve BOTH product workspace types (see docs/spec.md on non-git
/// projects): a non-git workspace's Editor has no other way to open a file now that the old direct-path
/// input is gone, so this engine picks one of two listing strategies per call rather than refusing the
/// non-git case:
///  - Git checkout: tracked files plus untracked, non-ignored files, excluding a tracked file that has
///    been deleted on disk (`listGitFiles`).
///  - Plain directory: every regular file on disk, recursively (`listFilesystemFiles`), since there is no
///    index to consult.
///
/// Both strategies enforce one shared contract, via `isOpenableFile`: every entry this engine returns is
/// openable through `workspaceFileRead`, and every file `workspaceFileRead` can open is listed. A symlink
/// is the one entry kind where those two directions are not simply the same lstat check — it is openable
/// exactly when `workspaceFileRead`'s own path resolver would resolve it to a regular file inside the
/// workspace, never merely by its own on-disk type. A regular file (or a symlink resolving to one) larger
/// than `SpacesDeviceAPIServer.workspaceFileMaxBytes` is excluded too: `workspaceFileRead` rejects it with
/// `.payloadTooLarge`, so listing it would offer a file this engine already knows can never be opened.
enum SpacesDeviceWorkspaceFileListEngine {
    final class GitMembershipIndexCache: @unchecked Sendable {
        struct EntrySet: Equatable {
            let symlinkPaths: [String]
            let skipWorktreePaths: [String]
            let oversizedPaths: [String]
            let assumeUnchangedPaths: [String]
            let gitlinkPaths: [String]
        }

        private let lock = NSLock()
        private var didLoad = false
        private var fingerprint: String?
        private var metadataFingerprint: String?
        private var entries = EntrySet(symlinkPaths: [], skipWorktreePaths: [], oversizedPaths: [], assumeUnchangedPaths: [], gitlinkPaths: [])
        private(set) var indexScanCount = 0

        func entries(for fingerprint: String?, metadataFingerprint: String?, refreshMetadata: Bool, loader: () throws -> EntrySet) rethrows
            -> EntrySet
        {
            lock.lock()
            if didLoad, self.fingerprint == fingerprint, !refreshMetadata || self.metadataFingerprint == metadataFingerprint {
                let entries = self.entries
                lock.unlock()
                return entries
            }
            lock.unlock()

            let loaded = try loader()
            lock.lock()
            indexScanCount += 1
            didLoad = true
            self.fingerprint = fingerprint
            self.metadataFingerprint = metadataFingerprint
            entries = loaded
            lock.unlock()
            return loaded
        }
    }

    /// Per-submodule index caches, minted on first use and keyed by checkout directory, so the recursive
    /// membership detector gives each submodule the same "only re-scan its index when its logical HEAD or
    /// index metadata moved" treatment the workspace's own repository gets. Held by the workspace's context
    /// rather than rebuilt per tick, which is what makes that caching survive from one poll to the next; a
    /// submodule initialized later simply mints its cache on the tick that first sees it.
    /// The caches one file-list subscription keeps for its whole life: the workspace repository's own index
    /// cache and one per submodule checkout. Both belong to the subscription rather than to a tick, because
    /// their entire purpose is to let a tick reuse what an earlier tick already read; minting them per tick
    /// would make every 2s poll rescan every index it walks.
    final class MembershipCaches: @unchecked Sendable {
        let workspaceIndex = GitMembershipIndexCache()
        let submodules = SubmoduleIndexCaches()
        let repositoryPaths = RepositoryPathCache()
    }

    /// Where one repository keeps the four files a detector tick stats. They are fixed for as long as the
    /// repository is the same repository, so they are resolved once per subscription and then only stat'd:
    /// `--git-path` is the only way to learn them (a submodule's real git dir lives under the
    /// superproject's `.git/modules`, and `GIT_INDEX_FILE`/`GIT_COMMON_DIR` can move any of them), and
    /// asking git for them on every tick was most of what a steady tick used to spend.
    struct RepositoryPaths: Sendable {
        let index: String
        let sparseCheckout: String
        let head: String
        /// The git dir refs live in, which for a linked worktree is the main repository's, not this
        /// worktree's. `HEAD` itself is per worktree; the branch it names, `packed-refs`, and the reftable
        /// are shared.
        let commonDir: String
    }

    final class RepositoryPathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String: RepositoryPaths] = [:]

        func paths(for repoDir: String, load: () throws -> RepositoryPaths) rethrows -> RepositoryPaths {
            lock.lock()
            let cached = paths[repoDir]
            lock.unlock()
            if let cached { return cached }

            let loaded = try load()
            lock.lock()
            paths[repoDir] = loaded
            lock.unlock()
            return loaded
        }
    }

    final class SubmoduleIndexCaches: @unchecked Sendable {
        private let lock = NSLock()
        private var caches: [String: GitMembershipIndexCache] = [:]

        func cache(forDirectory directory: String) -> GitMembershipIndexCache {
            lock.lock()
            defer { lock.unlock() }
            if let existing = caches[directory] { return existing }
            let created = GitMembershipIndexCache()
            caches[directory] = created
            return created
        }
    }

    struct GitMembershipContext: Sendable, Equatable {
        let workspaceDir: String
        let workspacePrefix: String
        let indexCache: GitMembershipIndexCache
        let submoduleCaches: SubmoduleIndexCaches
        let repositoryPaths: RepositoryPathCache
        /// How many submodule levels below the workspace this context sits; bounds the recursion the same
        /// way `SpacesDeviceWorkspaceDiffEngine.maxSubmoduleDepth` bounds the diff's.
        let depth: Int

        static func == (lhs: GitMembershipContext, rhs: GitMembershipContext) -> Bool {
            lhs.workspaceDir == rhs.workspaceDir && lhs.workspacePrefix == rhs.workspacePrefix
        }
    }

    private enum MembershipState: String {
        case listed
        case oversized
        case missing
        case notOpenable
    }

    private struct MembershipEntry {
        let status: String
        let path: String
        let origPath: String?
    }

    /// Bounds one `git` subprocess this engine spawns, mirroring
    /// `SpacesDeviceWorkspaceDiffEngine.gitCommandTimeout`'s reasoning (a wedged repository must not
    /// permanently occupy the workspace's serial git queue).
    private static let gitCommandTimeout: TimeInterval = 30

    /// Upper bound on the wall-clock git time one `workspaceFileList` request gets, shared by the
    /// workspace's own repository and every submodule the traversal enters. Without a shared window each
    /// repository would start a fresh `gitCommandTimeout`, so a workspace with nested submodules could
    /// occupy its serial git queue for repositories times 30 seconds while the client abandoned the request
    /// at its own 60 second timeout; the same reasoning, and the same 45 second figure, as
    /// `SpacesDeviceWorkspaceDiffEngine.diffBuildDeadline` and `SpacesDeviceWorkspaceRefListEngine`'s.
    private static let fileListDeadline: TimeInterval = 45

    /// Caps one command of a deadline-bound traversal to whatever remains of `budget` from `start`, never
    /// more than a single command's own `gitCommandTimeout`. `budget` is the whole operation's window:
    /// `fileListDeadline` for a listing request, and `gitCommandTimeout` for one detector tick, which is
    /// exactly the budget the tick's single top-level `git status` already had to itself. Throws the error
    /// `runGitAndCapture` throws on an ordinary per-command timeout, so a traversal that runs out of time
    /// fails its caller the same way one stalled command does.
    private static func remainingTimeout(start: Date, budget: TimeInterval) throws -> TimeInterval {
        let remaining = budget - Date().timeIntervalSince(start)
        guard remaining > 0 else {
            throw SpacesRuntimeError.gitCommandFailed(message: "Git command timed out after \(budget)s: shared deadline elapsed")
        }
        return min(gitCommandTimeout, remaining)
    }

    /// Hard cap on the number of paths returned; `SpacesDeviceWorkspaceFileListResult.truncated` is
    /// `true` when the workspace has more paths than this, and `paths` holds only the first (sorted)
    /// slice up to the cap. A ceiling on response size and client-side memory, not a limit the product
    /// otherwise tunes around.
    static let maxPaths = 50_000

    /// Picks the listing strategy for `workspaceDir`. `isRepoStrict` (not `isRepo`) so an execution
    /// failure (spawn failure, timeout, a wedged process) propagates as a thrown, retryable error instead
    /// of being silently misread as "not a repo" and falling through to the filesystem walk — the same
    /// distinction `SpacesDeviceWorkspaceDiffEngine.assertIsGitRepository` draws for the same probe.
    ///
    /// Deliberately probes the directory's on-disk state rather than reading the owning project's
    /// persisted git/non-git kind: the listing must describe what is on disk NOW. The divergent case is
    /// a non-git project whose directory later becomes a repository (an agent running `git init` there,
    /// say) — the persisted kind would keep selecting the filesystem walk, which would then enumerate
    /// `.git`'s thousands of internal files into the listing, while the probe switches to the git
    /// strategy and lists exactly the tracked and untracked-non-ignored files the user means. The
    /// reverse direction cannot silently degrade: a repository that stops answering the probe with a
    /// clean "not a repo" (rather than an execution failure, which throws per the above) has genuinely
    /// lost its git metadata, at which point the plain-directory walk IS the honest listing.
    ///
    /// The probe's ancestor search (`--is-inside-work-tree` answers true anywhere inside a repository,
    /// not just at its root) cannot create a disagreement with the persisted kind either: registration
    /// computes `isGitRepo` with this same probe (`Orchestrator.normalizeDir` via `GitClient.isRepo`),
    /// so a directory nested inside another repository registers as a git project in the first place.
    /// The two can only diverge when the on-disk state changes after registration, which is exactly the
    /// case above, where the probe is the honest answer.
    ///
    /// `maxPaths` is the cap this call enforces; it defaults to the product's own `maxPaths` and is
    /// overridden only by the test that exercises capping across the submodule recursion, which cannot
    /// afford to materialize 50,000 real files.
    /// `deadlineStart` starts this request's shared `fileListDeadline` window; every git command the
    /// traversal spawns, in the workspace's repository and in every submodule below it, is capped to what
    /// remains of it, so a stalled submodule fails the request instead of extending it.
    static func listFiles(workspaceDir: String, gitClient: RemoteWorkspaceGitClient, maxPaths: Int = maxPaths, deadlineStart: Date = Date()) throws
        -> SpacesDeviceWorkspaceFileListResult
    {
        guard try gitClient.isRepoStrict(path: workspaceDir) else { return listFilesystemFiles(workspaceDir: workspaceDir, maxPaths: maxPaths) }
        return try listGitFiles(workspaceDir: workspaceDir, gitClient: gitClient, maxPaths: maxPaths, deadlineStart: deadlineStart)
    }

    /// `caches` is the subscription's own, so consecutive ticks reuse the index scans they already paid
    /// for, at every level. A one-off call (the exact listing, a test) passes none and gets caches that
    /// live exactly as long as the call, which is the same thing as having none.
    static func gitMembershipContext(
        workspaceDir: String, gitClient: RemoteWorkspaceGitClient, caches: MembershipCaches? = nil, deadlineStart: Date = Date()
    ) throws -> GitMembershipContext? {
        guard try gitClient.isRepoStrict(path: workspaceDir) else { return nil }
        let prefix = strippingTrailingNewline(
            try gitClient.runGitAndCapture(
                ["-C", workspaceDir, "rev-parse", "--show-prefix"], timeout: try remainingTimeout(start: deadlineStart, budget: gitCommandTimeout)))
        let caches = caches ?? MembershipCaches()
        return GitMembershipContext(
            workspaceDir: workspaceDir, workspacePrefix: prefix, indexCache: caches.workspaceIndex, submoduleCaches: caches.submodules,
            repositoryPaths: caches.repositoryPaths, depth: 0)
    }

    /// Cheap detector for "would `workspaceFileList` produce a different exact `{paths, truncated}`
    /// result?" on a git checkout. It intentionally tracks only membership-affecting facts:
    /// resolved `HEAD` commit for clean tracked-set changes, plus a scoped
    /// `git status --porcelain -z --untracked-files=all --ignored=matching` reduction that ignores
    /// ordinary same-membership content churn while still noticing additions/removals/renames,
    /// ignored↔unignored transitions, and a dirty/untracked file crossing the 10 MiB openability
    /// threshold. The exact listing is recomputed only when this token changes.
    /// `deadlineStart` is the tick's own clock: every command this level and every nested level spawns is
    /// capped to what remains of the single `gitCommandTimeout` budget the tick's top-level `git status`
    /// used to have to itself, so a stalled submodule fails the tick (with the error a stalled status
    /// throws, which the poller already handles) rather than adding another 30 seconds per repository.
    static func gitMembershipChangeToken(context: GitMembershipContext, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date = Date()) throws
        -> String
    {
        let statusOutput = try gitClient.runGitAndCapture(
            ["-C", context.workspaceDir, "status", "--porcelain", "-z", "--untracked-files=all", "--ignored=matching", "--", "."],
            timeout: try remainingTimeout(start: deadlineStart, budget: gitCommandTimeout),
            environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"])
        let entries = membershipEntries(fromPorcelainZ: statusOutput, workspacePrefix: context.workspacePrefix)
        let paths = try context.repositoryPaths.paths(for: context.workspaceDir) {
            try repositoryPaths(workspaceDir: context.workspaceDir, gitClient: gitClient, deadlineStart: deadlineStart)
        }
        // Read this after status: status is run with optional index locks disabled, so ordinary content
        // churn does not rewrite the index and visibility-flag edits are represented by settled metadata.
        let indexMetadataFingerprint = fileMetadataFingerprint(path: paths.index)
        let head = headFingerprint(paths: paths)

        var input = Data()
        input.append(Data("head:\(head)\n".utf8))
        for entry in entries {
            if entry.status == "??" {
                input.append(Data("untracked|\(entry.path)|\(membershipState(path: entry.path, workspaceDir: context.workspaceDir).rawValue)\n".utf8))
                continue
            }
            if entry.status == "!!" {
                // Ignored files do not list by themselves, but an ignored in-workspace file can be
                // the target of a tracked symlink. Its threshold/type transition then changes that
                // tracked entry's openability, so retain only this membership-relevant state.
                input.append(Data("ignored|\(entry.path)|\(membershipState(path: entry.path, workspaceDir: context.workspaceDir).rawValue)\n".utf8))
                continue
            }
            if entry.status.contains("R") || entry.status.contains("C") {
                input.append(
                    Data(
                        "rename|\(entry.origPath ?? "")|\(entry.path)|\(membershipState(path: entry.path, workspaceDir: context.workspaceDir).rawValue)\n"
                            .utf8))
                continue
            }
            if entry.status.contains("D") {
                input.append(Data("deleted|\(entry.path)\n".utf8))
                continue
            }
            if entry.status.contains("A") {
                input.append(Data("added|\(entry.path)|\(membershipState(path: entry.path, workspaceDir: context.workspaceDir).rawValue)\n".utf8))
                continue
            }
            let state = membershipState(path: entry.path, workspaceDir: context.workspaceDir)
            if state != .listed { input.append(Data("openability|\(entry.path)|\(state.rawValue)\n".utf8)) }
        }
        // Git refreshes the index's stat-cache fields while running `status`, so its mtime is not a
        // logical index-change signal: using it here would re-scan a large index on every content edit.
        // HEAD and the sparse-checkout pattern file are the relevant cheap signals for the cached mode
        // set. Staged symlink changes are already represented in the scoped porcelain entries below;
        // committed symlink changes move HEAD and refresh the set.
        let indexRefreshKey = "head:\(head)|sparse:\(fileMetadataFingerprint(path: paths.sparseCheckout))"
        let indexEntries = try context.indexCache.entries(for: indexRefreshKey, metadataFingerprint: indexMetadataFingerprint, refreshMetadata: true)
        { try trackedIndexEntries(workspaceDir: context.workspaceDir, gitClient: gitClient, deadlineStart: deadlineStart) }
        for path in indexEntries.skipWorktreePaths {
            // `git status` intentionally stays quiet for a clean skip-worktree entry even when sparse
            // checkout materializes or removes its file. Include the on-disk membership state so those
            // transitions invalidate the cached exact listing.
            input.append(Data("skip-worktree|\(path)|\(membershipState(path: path, workspaceDir: context.workspaceDir).rawValue)\n".utf8))
        }
        // Porcelain collapses an ignored directory to one `!! ignored/` entry. That is not enough to
        // detect a tracked symlink whose target lives below that directory: the symlink itself is clean,
        // while its target can cross the 10 MiB/openability boundary that determines whether the symlink
        // appears in the exact listing. Read the index's symlink entries directly and retain only their
        // current openability state; ordinary content churn for a still-listed target remains ignored.
        for path in indexEntries.symlinkPaths {
            let state = membershipState(path: path, workspaceDir: context.workspaceDir)
            if state != .listed { input.append(Data("symlink|\(path)|\(state.rawValue)\n".utf8)) }
        }
        // Clean tracked regular files are absent from porcelain. Keep checking only files that were
        // already known to be oversized, so a shrink below the openability cap is observed without
        // stat'ing every tracked file on every stable poll tick.
        for path in indexEntries.oversizedPaths {
            input.append(Data("oversized|\(path)|\(membershipState(path: path, workspaceDir: context.workspaceDir).rawValue)\n".utf8))
        }
        for path in indexEntries.assumeUnchangedPaths {
            input.append(Data("assume-unchanged|\(path)|\(membershipState(path: path, workspaceDir: context.workspaceDir).rawValue)\n".utf8))
        }
        for path in indexEntries.gitlinkPaths {
            input.append(Data("gitlink|\(path)|\(membershipState(path: path, workspaceDir: context.workspaceDir).rawValue)\n".utf8))
        }
        // The listing descends into every initialized submodule, so this detector has to as well: a file
        // added, removed, or renamed inside a submodule changes what `workspaceFileList` returns while
        // leaving every input above untouched (the superproject sees only a dirty gitlink, whose porcelain
        // letter and directory stat do not move for a membership change one level down). Each submodule's
        // own token is computed exactly as this one is and folded in under its path, so the recursion
        // inherits the same "re-scan only when the index logically moved" caching. An uninitialized
        // submodule contributes nothing here for the same reason it contributes no paths.
        //
        // The cost model this recursion commits to: one `git status` per initialized submodule per tick,
        // and nothing else. Every other fact a level reads is cached for the subscription's whole life,
        // the repository's git-dir paths after one `rev-parse` and its index contents after one `ls-files`,
        // and the per-tick reads left over are stats and one small file read. So a tick grows linearly in
        // the number of checked-out submodules, at one process each, and what bounds that growth is the
        // tick's own shared deadline: every level's commands draw down the one `gitCommandTimeout` window
        // opened at the tick's start, so a deeply nested or stalled workspace fails the tick inside that
        // window instead of spending a fresh 30 seconds per repository.
        if context.depth < SpacesDeviceWorkspaceDiffEngine.maxSubmoduleDepth {
            for path in indexEntries.gitlinkPaths {
                guard
                    SpacesDeviceWorkspacePathResolver.isContainedGitlinkCheckout(repoDir: context.workspaceDir, repoRelativePath: path)
                else { continue }
                let subDir = (context.workspaceDir as NSString).appendingPathComponent(path)
                let subContext = GitMembershipContext(
                    workspaceDir: subDir, workspacePrefix: "", indexCache: context.submoduleCaches.cache(forDirectory: subDir),
                    submoduleCaches: context.submoduleCaches, repositoryPaths: context.repositoryPaths, depth: context.depth + 1)
                let token = try gitMembershipChangeToken(context: subContext, gitClient: gitClient, deadlineStart: deadlineStart)
                input.append(Data("submodule|\(path)|\(token)\n".utf8))
            }
        }
        return SpacesDeviceWorkspaceGitHashing.sha256Hex(input)
    }

    /// The four per-repository paths a tick stats, in one `rev-parse`. Resolved once per subscription per
    /// repository through `RepositoryPathCache`; a repository whose git dir is moved underneath a live
    /// subscription (absorbing a nested `.git`, for instance) keeps the paths it started with until the
    /// subscription ends, which costs it HEAD-move detection while its own `git status` keeps reporting
    /// every membership change in its worktree.
    private static func repositoryPaths(workspaceDir: String, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date) throws -> RepositoryPaths {
        let output = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--git-path", "index", "--git-path", "info/sparse-checkout", "--git-path", "HEAD",
             "--git-common-dir"], timeout: try remainingTimeout(start: deadlineStart, budget: gitCommandTimeout))
        // Git answers relative to the repository when the command runs inside it and absolutely for a
        // submodule's own git dir, so each line is resolved against the directory it was asked in.
        let resolved = output.split(separator: "\n", omittingEmptySubsequences: true).map {
            URL(fileURLWithPath: String($0), relativeTo: URL(fileURLWithPath: workspaceDir)).standardizedFileURL.path
        }
        guard resolved.count == 4 else {
            throw SpacesRuntimeError.gitCommandFailed(message: "git rev-parse did not report this repository's paths: \(output)")
        }
        return RepositoryPaths(index: resolved[0], sparseCheckout: resolved[1], head: resolved[2], commonDir: resolved[3])
    }

    /// A file's identity and last write, as a signal that it was rewritten. `absent` is a state of its own,
    /// so a file appearing or disappearing moves the fingerprint like a rewrite does.
    ///
    /// The index is read this way because `git status` runs with optional index locks disabled, so ordinary
    /// content churn does not rewrite it and a tick can still observe a real visibility-flag edit without
    /// scanning unchanged entries. The sparse-checkout pattern file is read this way because a pattern
    /// update is the one clean tracked-file membership transition status leaves silent.
    private static func fileMetadataFingerprint(path: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "absent" }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(fileNumber):\(size):\(modified)"
    }

    /// What `HEAD` points at, read from the ref files rather than from `git rev-parse HEAD`. A commit
    /// changes tracked membership even when the working tree is clean, so a tick has to see HEAD move, but
    /// spawning a process per repository to learn that is the whole per-submodule cost this avoids.
    ///
    /// `HEAD`'s own bytes settle the two cases it answers directly: a detached HEAD holds the commit id
    /// itself, and a symbolic ref names the branch, so switching branches changes them. For a symbolic ref
    /// the branch's own file is then read the same way, which covers every place a ref update can land:
    /// the loose ref file, `packed-refs` (where `git pack-refs` moves it, deleting the loose file), and the
    /// reftable, whose table list is rewritten on every update and which is the only one of the three that
    /// exists at all in a repository using that backend. Git writes each of them by renaming a fresh file
    /// into place, so an update always changes an identity this reads.
    private static func headFingerprint(paths: RepositoryPaths) -> String {
        let head = (try? String(contentsOfFile: paths.head, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unborn"
        var input = "head:\(head)"
        if head.hasPrefix("ref: ") {
            let refPath = (paths.commonDir as NSString).appendingPathComponent(String(head.dropFirst("ref: ".count)))
            input += "|ref:\(fileMetadataFingerprint(path: refPath))"
        }
        input += "|packed:\(fileMetadataFingerprint(path: (paths.commonDir as NSString).appendingPathComponent("packed-refs")))"
        input += "|reftable:\(fileMetadataFingerprint(path: (paths.commonDir as NSString).appendingPathComponent("reftable/tables.list")))"
        return input
    }

    /// Returns tracked symlinks, gitlinks, visibility-flagged paths, and oversized regular files from one index
    /// scan. This is refreshed only when the logical HEAD/sparse or cheap index metadata fingerprint moves,
    /// so stable 2s detector ticks do not repeatedly walk a large index.
    private static func trackedIndexEntries(workspaceDir: String, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date) throws
        -> GitMembershipIndexCache.EntrySet
    {
        let output = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "ls-files", "--cached", "-v", "--stage", "-z"],
            timeout: try remainingTimeout(start: deadlineStart, budget: gitCommandTimeout))
        var symlinks = Set<String>()
        var skipWorktree = Set<String>()
        var oversized = Set<String>()
        var assumeUnchanged = Set<String>()
        var gitlinks = Set<String>()
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let metadata = record[..<tab]
            let fields = metadata.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let path = String(record[record.index(after: tab)...])
            if metadata.first == "S" || metadata.first == "s" { skipWorktree.insert(path) }
            if metadata.first == "h" || metadata.first == "s" { assumeUnchanged.insert(path) }
            if fields[1] == "120000" { symlinks.insert(path) }
            if fields[1] == "160000" { gitlinks.insert(path) }
            if fields[1] != "120000", membershipState(path: path, workspaceDir: workspaceDir) == .oversized { oversized.insert(path) }
        }
        return GitMembershipIndexCache.EntrySet(
            symlinkPaths: symlinks.sorted(), skipWorktreePaths: skipWorktree.sorted(), oversizedPaths: oversized.sorted(),
            assumeUnchangedPaths: assumeUnchanged.sorted(), gitlinkPaths: gitlinks.sorted())
    }

    /// Lists every path the workspace's checkout owns, including the files inside every initialized
    /// submodule, sorted ascending and capped at `maxPaths`. `gitRepositoryPaths` walks the repositories;
    /// each one contributes two `ls-files` calls scoped to its own directory via `-C`:
    ///  - `--cached --others --exclude-standard`: every tracked path, plus every untracked path that
    ///    isn't gitignored.
    ///  - `--deleted`: tracked paths git still knows about but that are missing on disk right now.
    /// That repository's contribution is the first set minus the second: a tracked-but-deleted file is
    /// never something the user would consider "in" the workspace, even though git's index still names it.
    ///
    /// Unlike `git status --porcelain`/`git diff` (see `SpacesDeviceWorkspaceDiffEngine.subtreeScoped`'s
    /// doc comment), `git -C <dir> ls-files` already reports paths relative to `<dir>` rather than the
    /// repository root (confirmed empirically against real git), so a workspace rooted below its
    /// repository root (a monorepo subpackage) needs no separate prefix-stripping step here, and a
    /// submodule's own listing needs nothing but its gitlink path prepended.
    ///
    /// `paths` is captured and sorted in full up front (streaming the two `ls-files` subprocesses into a
    /// bounded walk is deliberately out of scope), but `isOpenableFile` then walks that already-sorted
    /// list one path at a time and stops as soon as it has collected `maxPaths` openable entries plus
    /// found one more past them — it never stats the whole set first and caps afterward. A workspace with
    /// hundreds of thousands of entries would otherwise pay one lstat per path (and, for every tracked
    /// symlink among them, a second resolution through `SpacesDeviceWorkspacePathResolver`) before this
    /// function could return anything, holding this workspace's serial git queue — shared with every
    /// other `workspaceFileRead`/`Write`/`Diff` request against it — for seconds. Stopping early is
    /// behaviorally IDENTICAL to filtering the entire sorted list and capping afterward: both produce the
    /// same first-`maxPaths`-openable-paths prefix in the same order (a submodule gitlink or any other
    /// unopenable path sorting inside that prefix is skipped in place, never replacing a later real file
    /// with a gap), and `truncated` is `true` under exactly the same condition — at least one more
    /// openable path exists beyond that prefix. The only difference is how much of the tail this function
    /// ever bothers to stat.
    private static func listGitFiles(workspaceDir: String, gitClient: RemoteWorkspaceGitClient, maxPaths: Int, deadlineStart: Date) throws
        -> SpacesDeviceWorkspaceFileListResult
    {
        var submodules: [SpacesDeviceWorkspaceFileListSubmodule] = []
        let paths = try gitRepositoryPaths(
            repoDir: workspaceDir, pathPrefix: "", depth: 0, gitClient: gitClient, deadlineStart: deadlineStart, submodules: &submodules
        ).sorted()

        var openablePaths: [String] = []
        openablePaths.reserveCapacity(min(paths.count, maxPaths))
        var truncated = false
        for path in paths {
            guard isOpenableFile(path: path, workspaceDir: workspaceDir) else { continue }
            guard openablePaths.count < maxPaths else {
                truncated = true
                break
            }
            openablePaths.append(path)
        }
        return SpacesDeviceWorkspaceFileListResult(
            paths: openablePaths, truncated: truncated, submodules: submodules.sorted { $0.path < $1.path })
    }

    /// One repository's own paths, prefixed to workspace-relative form, plus every initialized submodule's,
    /// recursively. The Editor treats a submodule's files as ordinary workspace files: they open, edit, and
    /// save through the same handlers, since a checkout directory resolves like any other directory, so the
    /// listing that feeds the tree and quick-open has to name them.
    ///
    /// The gitlink path itself is already among this repository's `ls-files` output and is filtered out by
    /// `isOpenableFile` (it is a directory on disk); `submodules` is what tells the client that directory is
    /// a submodule rather than a plain folder, and which commit it sits at. An uninitialized submodule has
    /// no repository to list and is left out of both, matching the diff's pointer-only row for the same
    /// state.
    private static func gitRepositoryPaths(
        repoDir: String, pathPrefix: String, depth: Int, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date,
        submodules: inout [SpacesDeviceWorkspaceFileListSubmodule]
    ) throws -> [String] {
        let presentOutput = try gitClient.runGitAndCapture(
            ["-C", repoDir, "ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z"],
            timeout: try remainingTimeout(start: deadlineStart, budget: fileListDeadline))
        let deletedOutput = try gitClient.runGitAndCapture(
            ["-C", repoDir, "ls-files", "--deleted", "-z"], timeout: try remainingTimeout(start: deadlineStart, budget: fileListDeadline))
        // Compare path bytes, not Strings: Swift String equality uses canonical Unicode equivalence, while
        // Git (and Linux filesystems) permits NFC and NFD spellings to be distinct names. This also keeps a
        // deleted NFD path from accidentally filtering a still-present NFC path (or vice versa).
        let deleted = Set(splitNULDelimited(deletedOutput).map { Array($0.utf8) })
        // Ask Git to collapse duplicate index stages, rather than putting paths in Set<String>. Git's
        // deduplicator compares the raw path bytes, so two distinct Linux filenames that happen to
        // normalize to the same Swift String remain distinct. The unresolved-conflict case still emits
        // one path because Git's --deduplicate removes repeated index stages.
        var paths = splitNULDelimited(presentOutput).filter { !deleted.contains(Array($0.utf8)) }.map { pathPrefix + $0 }

        guard depth < SpacesDeviceWorkspaceDiffEngine.maxSubmoduleDepth else { return paths }
        for gitlink in try trackedGitlinkPaths(repoDir: repoDir, gitClient: gitClient, deadlineStart: deadlineStart) {
            // Without this check git's ancestor search would resolve `ls-files` inside an uninitialized
            // submodule against the repository above it, listing that repository's files a second time under
            // the submodule's prefix, and a checkout replaced by a symlink would list a repository from
            // outside the workspace entirely.
            guard SpacesDeviceWorkspacePathResolver.isContainedGitlinkCheckout(repoDir: repoDir, repoRelativePath: gitlink) else { continue }
            let subDir = (repoDir as NSString).appendingPathComponent(gitlink)
            // The checkout's own commit, which the tree labels the submodule folder with. A checkout whose
            // HEAD does not resolve holds no commit to name and no state a client could describe, so it is
            // left out exactly as an uninitialized one is rather than listed with an empty label.
            let commit = strippingTrailingNewline(
                try gitClient.runGitAndCapture(
                    ["-C", subDir, "rev-parse", "--verify", "--quiet", "HEAD"],
                    timeout: try remainingTimeout(start: deadlineStart, budget: fileListDeadline), allowedExitCodes: [0, 1]))
            guard !commit.isEmpty else { continue }
            let submodulePath = pathPrefix + gitlink
            submodules.append(SpacesDeviceWorkspaceFileListSubmodule(path: submodulePath, commit: commit))
            paths += try gitRepositoryPaths(
                repoDir: subDir, pathPrefix: submodulePath + "/", depth: depth + 1, gitClient: gitClient, deadlineStart: deadlineStart,
                submodules: &submodules)
        }
        return paths
    }

    /// Every gitlink (git object mode `160000`) this repository's index records, repo-relative. `ls-files
    /// --stage` is the listing that carries entry modes; the plain `--cached` listing above reports a
    /// gitlink as an ordinary path with no way to tell it apart from a file.
    private static func trackedGitlinkPaths(repoDir: String, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date) throws -> [String] {
        let output = try gitClient.runGitAndCapture(
            ["-C", repoDir, "ls-files", "--stage", "-z"], timeout: try remainingTimeout(start: deadlineStart, budget: fileListDeadline))
        var paths: [String] = []
        var seen = Set<[UInt8]>()
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            guard record[..<tab].split(separator: " ", omittingEmptySubsequences: true).first == "160000" else { continue }
            let path = String(record[record.index(after: tab)...])
            // An unresolved merge leaves one index record per populated stage, all naming the same
            // submodule, and `--deduplicate` collapses stages only for a listing that shows filenames alone
            // (confirmed empirically against real git). Descending once per stage would list that
            // checkout's files two or three times over, name the submodule as many times, and spend the
            // duplicates against the listing cap. Deduplicating on raw path bytes rather than Swift String
            // equality keeps two genuinely distinct filenames that normalize alike (NFC versus NFD, which
            // git and Linux filesystems treat as different names) apart, matching the listing above.
            guard seen.insert(Array(path.utf8)).inserted else { continue }
            paths.append(path)
        }
        return paths
    }

    /// Whether `path` (workspace-relative) is safely openable through `workspaceFileRead` — the one
    /// predicate both listing strategies below share, so the module's two-way contract (every listed
    /// entry opens; every openable file is listed) holds identically for both. `attributesOfItem(atPath:)`
    /// reports the path's own lstat-style type — never a symlink's target, see
    /// `SpacesDeviceWorkspacePathResolver`'s doc comment for the same distinction — which alone settles
    /// every non-symlink case: `.typeRegular` (and, per the size check below, not too large) is openable;
    /// `.typeDirectory` is not (a submodule gitlink, mode 160000, is a directory on disk that `ls-files`
    /// still reports as an ordinary tracked path); a stat failure is not (a sparse-checkout
    /// `skip-worktree` entry with nothing on disk, or an ordinary file deleted in the window between the
    /// caller's enumeration and this check).
    ///
    /// A symlink is the one type that lstat alone cannot settle, so this defers to
    /// `SpacesDeviceWorkspacePathResolver.resolveContainedPath` — the exact same resolution/containment
    /// logic `workspaceFileRead`'s handler runs against a client-supplied path — to ask whether `path`
    /// resolves anywhere at all: a thrown `escapesWorkspace` (the target is outside the workspace) means
    /// not openable. When it does resolve, a second lstat on the RESOLVED path (already symlink-free, so
    /// this stat needs no further resolution) decides the rest exactly as `workspaceFileRead` itself
    /// would when it later stats that same resolved path: `.typeRegular` and within the size cap is
    /// openable, anything else (a directory, a stat failure for a dangling target, or an oversized target)
    /// is not.
    ///
    /// Both regular-file branches also enforce `SpacesDeviceAPIServer.workspaceFileMaxBytes`: a file over
    /// that cap is stat-openable but `workspaceFileRead`'s handler rejects it with `.payloadTooLarge`, so
    /// listing it here would offer something ⌘P and the Files tree could never actually open. Referencing
    /// the handler's own constant (rather than a second literal) keeps the cap defined once.
    private static func isOpenableFile(path: String, workspaceDir: String) -> Bool {
        let fullPath = (workspaceDir as NSString).appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath) else { return false }
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular: return isWithinMaxBytes(attributes)
        case .typeSymbolicLink:
            guard let resolvedPath = try? SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: path, workspaceDir: workspaceDir),
                let resolvedAttributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
            else { return false }
            return resolvedAttributes[.type] as? FileAttributeType == .typeRegular && isWithinMaxBytes(resolvedAttributes)
        default:  // A directory, or a non-regular special file (fifo, socket, ...).
            return false
        }
    }

    /// Whether a regular file's `attributesOfItem` result is within `workspaceFileRead`'s read cap. A
    /// missing/non-numeric `.size` (which `attributesOfItem` should never produce for a regular file) is
    /// treated as not openable rather than assumed small, matching this predicate's fail-closed stance
    /// elsewhere (a stat failure or unresolved symlink is likewise "not openable").
    private static func isWithinMaxBytes(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let size = attributes[.size] as? Int else { return false }
        return size <= SpacesDeviceAPIServer.workspaceFileMaxBytes
    }

    /// Lists every openable file under a plain (non-git) workspace directory: recursive, workspace-relative
    /// paths, sorted ascending, capped at `maxPaths`. `FileManager`'s enumerator already matches the git
    /// path's semantics closely enough to keep the two strategies at parity: it includes dotfiles (git
    /// tracks dotfiles too, so the git branch above lists them the same way) and does not itself descend
    /// into a symlinked directory. `isOpenableFile` then decides each entry exactly as the git branch
    /// does: a symlink to a regular file inside the workspace is listed (it is openable through
    /// `workspaceFileRead`, so it is no longer excluded merely for being a symlink), while a symlink to a
    /// directory or to anywhere outside the workspace is not.
    ///
    /// Unlike `listGitFiles`, this cannot stop early once it has `maxPaths` openable entries: the
    /// enumerator's traversal order is not sorted, and the sorted-first-`maxPaths` contract needs the
    /// full path set in hand before it can be sorted at all. A plain-directory workspace large enough for
    /// that ordering cost to matter is the rarer of the two product shapes (a workspace at that scale is
    /// almost always a git checkout, which takes the bounded path above), and the enumerator already pays
    /// one stat per entry for the type check regardless of where the cap ultimately lands, so there is no
    /// cheaper walk available here to fall back to.
    private static func listFilesystemFiles(workspaceDir: String, maxPaths: Int) -> SpacesDeviceWorkspaceFileListResult {
        guard let enumerator = FileManager.default.enumerator(atPath: workspaceDir) else {
            return SpacesDeviceWorkspaceFileListResult(paths: [], truncated: false)
        }
        var paths: [String] = []
        while let relativePath = enumerator.nextObject() as? String {
            guard isOpenableFile(path: relativePath, workspaceDir: workspaceDir) else { continue }
            paths.append(relativePath)
        }
        paths.sort()
        guard paths.count > maxPaths else { return SpacesDeviceWorkspaceFileListResult(paths: paths, truncated: false) }
        return SpacesDeviceWorkspaceFileListResult(paths: Array(paths.prefix(maxPaths)), truncated: true)
    }

    /// Splits `-z` (NUL-delimited) `ls-files` output into individual paths, dropping the empty trailing
    /// token a terminal NUL produces.
    private static func splitNULDelimited(_ output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    private static func strippingTrailingNewline(_ output: String) -> String {
        var result = output
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func membershipState(path: String, workspaceDir: String) -> MembershipState {
        let fullPath = (workspaceDir as NSString).appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath) else { return .missing }
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular: return isWithinMaxBytes(attributes) ? .listed : .oversized
        case .typeSymbolicLink:
            guard let resolvedPath = try? SpacesDeviceWorkspacePathResolver.resolveContainedPath(relativePath: path, workspaceDir: workspaceDir),
                let resolvedAttributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
            else { return .notOpenable }
            guard resolvedAttributes[.type] as? FileAttributeType == .typeRegular else { return .notOpenable }
            return isWithinMaxBytes(resolvedAttributes) ? .listed : .oversized
        default: return .notOpenable
        }
    }

    private static func membershipEntries(fromPorcelainZ output: String, workspacePrefix: String) -> [MembershipEntry] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [MembershipEntry] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.count > 3 else { continue }
            let status = String(token.prefix(2))
            let repoRelativePath = String(token.dropFirst(3))
            var repoRelativeOrigPath: String?
            if status.contains("R") || status.contains("C"), index < tokens.count {
                repoRelativeOrigPath = tokens[index]
                index += 1
            }
            if workspacePrefix.isEmpty {
                entries.append(MembershipEntry(status: status, path: repoRelativePath, origPath: repoRelativeOrigPath))
                continue
            }

            let pathInWorkspace = repoRelativePath.hasPrefix(workspacePrefix)
            let origInWorkspace = repoRelativeOrigPath?.hasPrefix(workspacePrefix) ?? false
            guard pathInWorkspace || origInWorkspace else { continue }

            if status.contains("R") || status.contains("C") {
                switch (pathInWorkspace, origInWorkspace) {
                case (true, true):
                    entries.append(
                        MembershipEntry(
                            status: status, path: String(repoRelativePath.dropFirst(workspacePrefix.count)),
                            origPath: repoRelativeOrigPath.map { String($0.dropFirst(workspacePrefix.count)) }))
                case (true, false):
                    entries.append(MembershipEntry(status: "A ", path: String(repoRelativePath.dropFirst(workspacePrefix.count)), origPath: nil))
                case (false, true):
                    entries.append(
                        MembershipEntry(status: " D", path: String((repoRelativeOrigPath ?? "").dropFirst(workspacePrefix.count)), origPath: nil))
                case (false, false): break
                }
                continue
            }

            guard pathInWorkspace else { continue }
            entries.append(MembershipEntry(status: status, path: String(repoRelativePath.dropFirst(workspacePrefix.count)), origPath: nil))
        }
        return entries
    }

}

/// Backs the read-only `workspaceRefList` Device API command: the branch and recent-commit lists the
/// Compare dialog's ref search offers when building a `ref`/`lastCommit` diff scope. Local-only — no
/// `ls-remote` — since this only needs to offer refs the workspace already knows about, not discover new
/// ones from origin; the manifest plan itself already requires no network access either.
enum SpacesDeviceWorkspaceRefListEngine {
    /// Mirrors `SpacesDeviceWorkspaceDiffEngine.gitCommandTimeout`'s reasoning: a wedged repository must
    /// not permanently occupy the workspace's serial git queue.
    private static let gitCommandTimeout: TimeInterval = 30

    /// One budget for repository validation, both branch enumerations, and both commit-history
    /// probes. Kept below the client's 60-second large-payload timeout so an abandoned ref-list
    /// request cannot continue occupying the workspace's serial git queue.
    private static let refListDeadline: TimeInterval = 45

    private static func remainingTimeout(start: Date) throws -> TimeInterval {
        let remaining = refListDeadline - Date().timeIntervalSince(start)
        guard remaining > 0 else {
            throw SpacesRuntimeError.gitCommandFailed(message: "Git command timed out after \(refListDeadline)s: request-wide deadline elapsed")
        }
        return min(gitCommandTimeout, remaining)
    }

    /// Hard cap on returned branch names; `branchesTruncated` is `true` when the workspace has more.
    static let maxBranches = 1000

    /// Hard cap on returned commits; `commitsTruncated` is `true` when HEAD's history has more.
    static let maxCommits = 300

    /// Non-git workspace (a supported product type, see docs/spec.md) has no refs at all: empty lists with
    /// both truncation flags `false`, not an error — mirroring `SpacesDeviceWorkspaceFileListEngine`'s own
    /// non-git handling of the sibling `workspaceFileList` command.
    static func listRefs(workspaceDir: String, baseBranch: String?, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date = Date()) throws
        -> SpacesDeviceWorkspaceRefListResult
    {
        guard try gitClient.isRepoStrict(path: workspaceDir) else {
            return SpacesDeviceWorkspaceRefListResult(branches: [], branchesTruncated: false, commits: [], commitsTruncated: false)
        }
        let (branches, branchesTruncated) = try listBranches(
            workspaceDir: workspaceDir, baseBranch: baseBranch, gitClient: gitClient, deadlineStart: deadlineStart)
        let (commits, commitsTruncated) = try listCommits(workspaceDir: workspaceDir, gitClient: gitClient, deadlineStart: deadlineStart)
        return SpacesDeviceWorkspaceRefListResult(
            branches: branches, branchesTruncated: branchesTruncated, commits: commits, commitsTruncated: commitsTruncated)
    }

    /// Every name returned here must be independently resolvable with `git rev-parse --verify
    /// <name>^{commit}`, since the Compare dialog feeds a selected entry straight into
    /// `assertRefIsResolvable`. Local branches (`refs/heads`) are listed under their own short name;
    /// remote branches (`refs/remotes/origin`) are listed under their full `origin/<name>` short name,
    /// with only the synthetic `origin/HEAD` entry dropped. A local `foo` and `origin/foo` are distinct
    /// refs that can point at different commits, so both are kept as distinct entries — no stripping the
    /// `origin/` prefix, and no cross-dedup between the two sets, unlike `workspacecore/GitClient
    /// .branchOptions`'s merged local-name shape (which this also differs from by skipping that function's
    /// live `ls-remote --heads origin` call and its `defaultBranch` fallback, neither of which this
    /// local-only, read-only listing needs). The combined set is deduped (a name can only repeat if the
    /// same ref were listed twice) and sorted with `localizedStandardCompare`.
    private static func listBranches(workspaceDir: String, baseBranch: String?, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date) throws -> (
        branches: [String], truncated: Bool
    ) {
        var branches = Set<String>()
        let local = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "for-each-ref", "--format=%(refname:short)", "refs/heads"], timeout: try remainingTimeout(start: deadlineStart))
        for raw in local.split(separator: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { branches.insert(trimmed) }
        }
        let remote = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"],
            timeout: try remainingTimeout(start: deadlineStart))
        for raw in remote.split(separator: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "origin/HEAD", trimmed.hasPrefix("origin/") else { continue }
            branches.insert(trimmed)
        }
        let sorted = branches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard sorted.count > maxBranches else { return (sorted, false) }
        var capped = Array(sorted.prefix(maxBranches))
        // Workspaces store a bare configured base name. Prefer that local ref when present; otherwise
        // preserve the corresponding origin-tracking ref. Reserving one slot keeps the configured base
        // selectable even when more than `maxBranches` lexicographically earlier refs exist.
        let listedBaseBranch = baseBranch.flatMap { branches.contains($0) ? $0 : branches.contains("origin/\($0)") ? "origin/\($0)" : nil }
        if let listedBaseBranch, !capped.contains(listedBaseBranch) {
            capped[capped.count - 1] = listedBaseBranch
            capped.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return (capped, true)
    }

    /// The most recent commits reachable from HEAD, newest first, each with its full sha and subject. An
    /// unborn HEAD (no commits yet, still a valid git project) is probed for separately, the same way
    /// every other unborn-HEAD check in this file is, and reports as an empty, untruncated list rather
    /// than an error.
    private static func listCommits(workspaceDir: String, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date) throws -> (
        commits: [SpacesDeviceWorkspaceRefListCommit], truncated: Bool
    ) {
        let headProbe = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--verify", "--quiet", "HEAD"], timeout: try remainingTimeout(start: deadlineStart),
            allowedExitCodes: [0, 1]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headProbe.isEmpty else { return ([], false) }

        // `%H%x00%s`: full sha, a NUL, then the commit's subject line, one record per `%n`-terminated
        // (newline) line — a subject can never itself contain a NUL or a newline, so splitting each line
        // once on the NUL cleanly separates the two fields. `-n <maxCommits + 1>` fetches one commit past
        // the cap so truncation is detected without a separate `rev-list --count` call.
        let output = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "log", "--no-color", "--format=%H%x00%s", "-n", "\(maxCommits + 1)", "HEAD"],
            timeout: try remainingTimeout(start: deadlineStart))
        let commits: [SpacesDeviceWorkspaceRefListCommit] = output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\u{0}" as Character, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return SpacesDeviceWorkspaceRefListCommit(sha: String(parts[0]), subject: String(parts[1]))
        }
        guard commits.count > maxCommits else { return (commits, false) }
        return (Array(commits.prefix(maxCommits)), true)
    }
}

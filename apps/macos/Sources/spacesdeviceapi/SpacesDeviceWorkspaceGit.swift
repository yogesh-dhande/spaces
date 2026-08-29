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
        return ScopeSnapshot(signature: SpacesDeviceWorkspaceGitHashing.sha256Hex(input), headSHA: headSHA, scopedEntries: scopedEntries)
    }

    /// One file identified by `git diff -M --name-status -z` (tracked) or by a `??` record in `git status
    /// --porcelain -z` (untracked). The plan intentionally retains only file identity and immutable git
    /// references, not a patch body or full command array, so a short-lived manifest session is compact.
    struct DiffFilePlan: Sendable {
        enum Source {
            /// `baseRef` is compared with `targetRef` when non-nil (last-commit), otherwise with the
            /// working tree (uncommitted/base-ref scopes).
            case tracked(baseRef: String, targetRef: String?)
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
                // alone would silently miss them. The empty tree id is computed per call via `git
                // hash-object -t tree /dev/null` rather than hardcoded as the well-known SHA-1 constant
                // (`4b825dc642cb6eb9a060e54bf8d69288fbee4904`), so this stays correct for a repo created
                // with a non-SHA-1 object format (`git init --object-format=sha256`), where that constant
                // would not resolve to anything.
                compareRef = try gitClient.runGitAndCapture(
                    ["-C", workspaceDir, "hash-object", "-t", "tree", "/dev/null"], timeout: try remainingTimeout(start: start)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
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
            return DiffFilePlan(path: entry.path, oldPath: entry.oldPath, status: entry.status, source: .tracked(baseRef: compareRef, targetRef: nil))
        }

        // The signature has already read and subtree-scoped the same porcelain snapshot this request needs
        // for untracked/collision plans. Both optionals are present for every non-last-commit scope.
        guard let scopedStatusEntries = snapshot.scopedEntries else {
            preconditionFailure("A working-tree diff snapshot must contain scoped status entries.")
        }
        // `--untracked-files=all` should mean every `??` record is already a file, never a directory, but
        // the filter costs nothing and defends against any edge git itself has not been audited against
        // (e.g. a submodule or other non-regular-file entry reported with a trailing slash).
        let untrackedPaths = scopedStatusEntries.filter { $0.status == "??" && !$0.path.hasSuffix("/") }.map(\.path)

        // A path can legitimately appear in both snapshots when `--name-status` reports it `.deleted`
        // relative to `compareRef` while the earlier status snapshot reports it untracked (`??`, present on
        // disk). That is one content change and is coalesced below. A non-deleted overlap is a race: an agent
        // staged the file after the status snapshot but before the newer name-status enumeration. In that
        // case the newer tracked plan is authoritative and the stale untracked plan must be suppressed, or
        // the response contains duplicate file IDs. A rename's recreated `oldPath` remains distinct because
        // the tracked plan is keyed by the rename's new `path`.
        let untrackedPathSet = Set(untrackedPaths)
        let trackedPathSet = Set(plans.map(\.path))
        let deletedButUntrackedPaths = Set(plans.filter { $0.status == .deleted && untrackedPathSet.contains($0.path) }.map(\.path))
        if !deletedButUntrackedPaths.isEmpty {
            plans = plans.map { plan in
                guard deletedButUntrackedPaths.contains(plan.path) else { return plan }
                return DiffFilePlan(path: plan.path, oldPath: nil, status: .modified, source: .deletedButUntrackedInWorktree(compareRef: compareRef))
            }
        }
        plans += untrackedPaths.filter { !deletedButUntrackedPaths.contains($0) && !trackedPathSet.contains($0) }.map { path in
            DiffFilePlan(path: path, oldPath: nil, status: .untracked, source: .untracked)
        }

        return DiffPlanSnapshot(scopeSignature: signature, plans: plans)
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
    /// status/name-status walk plus K per-file diffs, not K complete workspace walks.
    static func writeDiffFilePatch(
        snapshot: DiffPlanSnapshot, workspaceDir: String, relativePath: String, outputURL: URL, gitClient: RemoteWorkspaceGitClient,
        deadlineStart: Date
    ) throws -> FilePatchTransfer? {
        guard let plan = snapshot.plan(for: relativePath) else { return nil }

        let wrotePatch = try writePatch(
            for: plan, workspaceDir: workspaceDir, outputURL: outputURL, gitClient: gitClient, deadlineStart: deadlineStart)
        let patchByteCount = wrotePatch ? fileByteCount(at: outputURL) : 0
        let metadata = wrotePatch ? patchMetadata(at: outputURL) : (isBinary: false, oldSHA: nil, newSHA: nil)
        let file = SpacesDeviceWorkspaceDiffFileMetadata(
            path: plan.path, oldPath: plan.oldPath, status: plan.status, isBinary: metadata.isBinary, oldSHA: metadata.oldSHA, newSHA: metadata.newSHA
        )
        return FilePatchTransfer(scopeSignature: snapshot.scopeSignature, file: file, patchByteCount: patchByteCount)
    }

    /// Writes a git diff to the caller's private temporary file. `git --output` leaves stdout empty, so
    /// `runGitAndCapture` retains its established timeout/error handling without retaining the patch body in
    /// daemon memory.
    private static func writePatch(
        for plan: DiffFilePlan, workspaceDir: String, outputURL: URL, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date
    ) throws -> Bool {
        let timeout = try remainingTimeout(start: deadlineStart)
        switch plan.source {
        case .tracked(let baseRef, let targetRef):
            try gitClient.runGitWithFileOutput(
                trackedDiffArguments(for: plan, workspaceDir: workspaceDir, baseRef: baseRef, targetRef: targetRef, outputURL: outputURL),
                timeout: timeout)
            return true
        case .untracked:
            return try writeUntrackedPatch(path: plan.path, workspaceDir: workspaceDir, outputURL: outputURL, gitClient: gitClient, timeout: timeout)
        case .deletedButUntrackedInWorktree(let compareRef):
            return try writeCoalescedDeletedButUntrackedPatch(
                path: plan.path, compareRef: compareRef, workspaceDir: workspaceDir, outputURL: outputURL, gitClient: gitClient,
                deadlineStart: deadlineStart)
        }
    }

    private static func trackedDiffArguments(for plan: DiffFilePlan, workspaceDir: String, baseRef: String, targetRef: String?, outputURL: URL)
        -> [String]
    {
        var arguments = [
            "-C", workspaceDir, "-c", "core.quotepath=false", "diff", "--output=\(outputURL.path)", "-M", "--no-color", "--no-ext-diff",
            "--no-textconv", "--relative", baseRef,
        ]
        if let targetRef { arguments.append(targetRef) }
        arguments.append("--")
        if let oldPath = plan.oldPath { arguments.append(":(literal)\(oldPath)") }
        arguments.append(":(literal)\(plan.path)")
        return arguments
    }

    private static func fileByteCount(at url: URL) -> Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }

    /// Git's `index` and `Binary files ... differ` header lines always precede any hunk body. Sampling a
    /// fixed prefix keeps binary/SHA classification bounded even when the textual patch is hundreds of MB.
    private static func patchMetadata(at url: URL) -> (isBinary: Bool, oldSHA: String?, newSHA: String?) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return (false, nil, nil) }
        defer { try? handle.close() }
        let prefix: Data
        do { prefix = try handle.read(upToCount: 128 * 1024) ?? Data() } catch { return (false, nil, nil) }
        return parsePatchMetadata(String(decoding: prefix, as: UTF8.self))
    }

    /// The transfer path retains the old untracked safety rules but intentionally removes the old visible
    /// patch-size cap: its output goes to a private file and reaches the client only through 4 MiB chunks.
    private static func writeUntrackedPatch(
        path: String, workspaceDir: String, outputURL: URL, gitClient: RemoteWorkspaceGitClient, timeout: TimeInterval
    ) throws -> Bool {
        let fullPath = (workspaceDir as NSString).appendingPathComponent(path)
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath) else { return false }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { return false }
        if type == .typeSymbolicLink {
            var targetStat = stat()
            if stat(fullPath, &targetStat) == 0, (targetStat.st_mode & S_IFMT) != S_IFREG { return false }
        }
        try gitClient.runGitWithFileOutput(
            [
                "-C", workspaceDir, "-c", "core.quotepath=false", "diff", "--output=\(outputURL.path)", "--no-color", "--no-ext-diff",
                "--no-textconv", "--no-index", "--", "/dev/null", path,
            ], timeout: timeout, allowedExitCodes: [0, 1])
        return true
    }

    /// A deleted-plus-untracked collision needs a scratch index to make Git describe the worktree file
    /// against the comparison ref as one coherent patch. `git update-index` hashes the worktree file, so
    /// the scratch index also gets a scratch object directory with the repository's objects as read-only
    /// alternates; otherwise merely viewing a diff would permanently add the recreated file's blob to the
    /// user's repository. The patch body is written directly to the transfer file, so the extra Git
    /// operation adds neither an in-memory size cap nor repeated work per range.
    private static func writeCoalescedDeletedButUntrackedPatch(
        path: String, compareRef: String, workspaceDir: String, outputURL: URL, gitClient: RemoteWorkspaceGitClient, deadlineStart: Date
    ) throws -> Bool {
        let fullPath = (workspaceDir as NSString).appendingPathComponent(path)
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath) else { return false }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { return false }

        let objectDirectoryOutput = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "rev-parse", "--git-path", "objects"], timeout: try remainingTimeout(start: deadlineStart))
        let objectDirectoryPath = objectDirectoryOutput.hasSuffix("\n") ? String(objectDirectoryOutput.dropLast()) : objectDirectoryOutput
        guard !objectDirectoryPath.isEmpty else {
            throw SpacesRuntimeError.gitCommandFailed(message: "git rev-parse --git-path objects returned an empty path.")
        }
        let objectDirectoryURL = URL(
            fileURLWithPath: objectDirectoryPath, isDirectory: true, relativeTo: URL(fileURLWithPath: workspaceDir, isDirectory: true)
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
            ["-C", workspaceDir, "update-index", "--add", "--", path], timeout: try remainingTimeout(start: deadlineStart),
            environmentOverrides: scratchIndexEnvironment)
        let diffTimeout = try remainingTimeout(start: deadlineStart)
        try gitClient.runGitWithFileOutput(
            [
                "-C", workspaceDir, "-c", "core.quotepath=false", "diff", "--output=\(outputURL.path)", "--no-color", "--no-ext-diff",
                "--no-textconv", "--relative", compareRef, "--", ":(literal)\(path)",
            ], timeout: diffTimeout, environmentOverrides: scratchIndexEnvironment)
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
            // Root commit: diff the empty tree against the snapshotted HEAD so every file it introduces reports as an
            // addition — see the manifest plan's identical empty-tree handling for why this is computed per call
            // rather than hardcoded as the well-known SHA-1 constant.
            parent = try gitClient.runGitAndCapture(
                ["-C", workspaceDir, "hash-object", "-t", "tree", "/dev/null"], timeout: try remainingTimeout(start: deadlineStart)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            parent = parentProbe
        }

        // Same flags as every other diff invocation in this engine — see the manifest plan's comment block above
        // for the full rationale for each one. Two explicit positional refs (`parent headSHA`), not a single
        // `compareRef` against the working tree, is what makes this diff committed-only.
        let nameStatusOutput = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "diff", "-M", "--no-color", "--no-ext-diff", "--no-textconv", "--relative", "--name-status", "-z", parent, headSHA],
            timeout: try remainingTimeout(start: deadlineStart))
        let plans = parseNameStatusZ(nameStatusOutput).map { entry in
            DiffFilePlan(path: entry.path, oldPath: entry.oldPath, status: entry.status, source: .tracked(baseRef: parent, targetRef: headSHA))
        }

        return DiffPlanSnapshot(scopeSignature: signature, plans: plans)
    }

    // MARK: - `git status --porcelain -z` parsing

    private struct PorcelainEntry {
        let status: String
        let path: String
        let origPath: String?
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
            if let origPath = entry.origPath { data.append(Data("\(origPath)\0".utf8)) }
        }
        return data
    }

    // MARK: - `git diff --name-status -z` parsing

    private struct NameStatusEntry {
        let status: SpacesDeviceWorkspaceDiffFileStatus
        let path: String
        let oldPath: String?
    }

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

    struct GitMembershipContext: Sendable, Equatable {
        let workspaceDir: String
        let workspacePrefix: String
        let indexCache: GitMembershipIndexCache

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

    /// Bounds the `git ls-files` subprocesses this engine spawns — mirrors
    /// `SpacesDeviceWorkspaceDiffEngine.gitCommandTimeout`'s reasoning (a wedged repository must not
    /// permanently occupy the workspace's serial git queue).
    private static let gitCommandTimeout: TimeInterval = 30

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
    static func listFiles(workspaceDir: String, gitClient: RemoteWorkspaceGitClient) throws -> SpacesDeviceWorkspaceFileListResult {
        guard try gitClient.isRepoStrict(path: workspaceDir) else { return listFilesystemFiles(workspaceDir: workspaceDir) }
        return try listGitFiles(workspaceDir: workspaceDir, gitClient: gitClient)
    }

    static func gitMembershipContext(workspaceDir: String, gitClient: RemoteWorkspaceGitClient, indexCache: GitMembershipIndexCache? = nil) throws
        -> GitMembershipContext?
    {
        guard try gitClient.isRepoStrict(path: workspaceDir) else { return nil }
        let prefix = strippingTrailingNewline(
            try gitClient.runGitAndCapture(["-C", workspaceDir, "rev-parse", "--show-prefix"], timeout: gitCommandTimeout))
        return GitMembershipContext(workspaceDir: workspaceDir, workspacePrefix: prefix, indexCache: indexCache ?? GitMembershipIndexCache())
    }

    /// Cheap detector for "would `workspaceFileList` produce a different exact `{paths, truncated}`
    /// result?" on a git checkout. It intentionally tracks only membership-affecting facts:
    /// resolved `HEAD` commit for clean tracked-set changes, plus a scoped
    /// `git status --porcelain -z --untracked-files=all --ignored=matching` reduction that ignores
    /// ordinary same-membership content churn while still noticing additions/removals/renames,
    /// ignored↔unignored transitions, and a dirty/untracked file crossing the 10 MiB openability
    /// threshold. The exact listing is recomputed only when this token changes.
    static func gitMembershipChangeToken(context: GitMembershipContext, gitClient: RemoteWorkspaceGitClient) throws -> String {
        let statusOutput = try gitClient.runGitAndCapture(
            ["-C", context.workspaceDir, "status", "--porcelain", "-z", "--untracked-files=all", "--ignored=matching", "--", "."],
            timeout: gitCommandTimeout, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"])
        let entries = membershipEntries(fromPorcelainZ: statusOutput, workspacePrefix: context.workspacePrefix)
        // Read this after status: status is run with optional index locks disabled, so ordinary content
        // churn does not rewrite the index and visibility-flag edits are represented by settled metadata.
        let indexMetadataFingerprint = try gitIndexMetadataFingerprint(workspaceDir: context.workspaceDir, gitClient: gitClient)
        // `HEAD` itself may be a symbolic ref, whose file stays unchanged while the ref it names
        // advances. Hash the resolved commit rather than HEAD/index metadata: staging ordinary
        // content edits changes index metadata but not the list, while a commit changes tracked
        // membership even when the working tree is clean. An unborn repository has no HEAD commit
        // but remains a valid git workspace, so represent that stable state explicitly.
        let head = strippingTrailingNewline(
            try gitClient.runGitAndCapture(
                ["-C", context.workspaceDir, "rev-parse", "--verify", "--quiet", "HEAD"], timeout: gitCommandTimeout, allowedExitCodes: [0, 1]))

        var input = Data()
        input.append(Data("head:\(head.isEmpty ? "unborn" : head)\n".utf8))
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
        let indexRefreshKey = "head:\(head)|sparse:\(try sparseCheckoutFingerprint(workspaceDir: context.workspaceDir, gitClient: gitClient))"
        let indexEntries = try context.indexCache.entries(for: indexRefreshKey, metadataFingerprint: indexMetadataFingerprint, refreshMetadata: true)
        { try trackedIndexEntries(workspaceDir: context.workspaceDir, gitClient: gitClient) }
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
        return SpacesDeviceWorkspaceGitHashing.sha256Hex(input)
    }

    /// Returns a cheap logical-index refresh signal. `git status` rewrites index stat-cache fields during
    /// ordinary content churn, so the index file's mtime is intentionally not used. A sparse-checkout
    /// pattern update is the clean tracked-file membership transition that status leaves silent; its
    /// pattern file identity captures that update without scanning all index entries. Staged symlink
    /// additions/removals appear in scoped porcelain, and committed changes move HEAD.
    private static func sparseCheckoutFingerprint(workspaceDir: String, gitClient: RemoteWorkspaceGitClient) throws -> String {
        let rawPath = strippingTrailingNewline(
            try gitClient.runGitAndCapture(["-C", workspaceDir, "rev-parse", "--git-path", "info/sparse-checkout"], timeout: gitCommandTimeout))
        let sparsePath = URL(fileURLWithPath: rawPath, relativeTo: URL(fileURLWithPath: workspaceDir)).standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sparsePath) else { return "absent" }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(fileNumber):\(size):\(modified)"
    }

    /// The index file's metadata is a cheap signal for visibility-flag edits made after a subscription
    /// starts. `git status` disables optional index locks, so ordinary content churn does not rewrite the
    /// index and dirty ticks can still observe real flag changes without scanning unchanged entries.
    private static func gitIndexMetadataFingerprint(workspaceDir: String, gitClient: RemoteWorkspaceGitClient) throws -> String {
        let rawPath = strippingTrailingNewline(
            try gitClient.runGitAndCapture(["-C", workspaceDir, "rev-parse", "--git-path", "index"], timeout: gitCommandTimeout))
        let indexPath = URL(fileURLWithPath: rawPath, relativeTo: URL(fileURLWithPath: workspaceDir)).standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: indexPath) else { return "absent" }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(fileNumber):\(size):\(modified)"
    }

    /// Returns tracked symlinks, gitlinks, visibility-flagged paths, and oversized regular files from one index
    /// scan. This is refreshed only when the logical HEAD/sparse or cheap index metadata fingerprint moves,
    /// so stable 2s detector ticks do not repeatedly walk a large index.
    private static func trackedIndexEntries(workspaceDir: String, gitClient: RemoteWorkspaceGitClient) throws -> GitMembershipIndexCache.EntrySet {
        let output = try gitClient.runGitAndCapture(["-C", workspaceDir, "ls-files", "--cached", "-v", "--stage", "-z"], timeout: gitCommandTimeout)
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

    /// Lists every path a git checkout owns, sorted ascending and capped at `maxPaths`. Two `ls-files`
    /// calls, both scoped to `workspaceDir` via `-C`:
    ///  - `--cached --others --exclude-standard`: every tracked path, plus every untracked path that
    ///    isn't gitignored.
    ///  - `--deleted`: tracked paths git still knows about but that are missing on disk right now.
    /// The result is the first set minus the second — a tracked-but-deleted file is never something the
    /// user would consider "in" the workspace, even though git's index still names it.
    ///
    /// Unlike `git status --porcelain`/`git diff` (see `SpacesDeviceWorkspaceDiffEngine.subtreeScoped`'s
    /// doc comment), `git -C <dir> ls-files` already reports paths relative to `<dir>` rather than the
    /// repository root — confirmed empirically against real git — so a workspace rooted below its
    /// repository root (a monorepo subpackage) needs no separate prefix-stripping step here.
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
    private static func listGitFiles(workspaceDir: String, gitClient: RemoteWorkspaceGitClient) throws -> SpacesDeviceWorkspaceFileListResult {
        let presentOutput = try gitClient.runGitAndCapture(
            ["-C", workspaceDir, "ls-files", "--cached", "--others", "--exclude-standard", "-z"], timeout: gitCommandTimeout)
        let deletedOutput = try gitClient.runGitAndCapture(["-C", workspaceDir, "ls-files", "--deleted", "-z"], timeout: gitCommandTimeout)
        let deleted = Set(splitNULDelimited(deletedOutput))
        let paths = splitNULDelimited(presentOutput).filter { !deleted.contains($0) }.sorted()

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
        return SpacesDeviceWorkspaceFileListResult(paths: openablePaths, truncated: truncated)
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
    private static func listFilesystemFiles(workspaceDir: String) -> SpacesDeviceWorkspaceFileListResult {
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

import Foundation
import systembridge

public final class GitClient {
    public enum RemoteBranchLookupStatus {
        case exists
        case missing
    }

    public struct RemoteDefaultBranchFile: Sendable {
        public let defaultBranch: String
        public let contents: String?

        public init(defaultBranch: String, contents: String?) {
            self.defaultBranch = defaultBranch
            self.contents = contents
        }
    }

    private let gitExecutable: String
    private let environmentOverrides: [String: String]
    private let metadataCommandTimeout: TimeInterval

    public init(gitExecutable: String? = nil, environmentOverrides: [String: String] = [:], metadataCommandTimeout: TimeInterval = 2) {
        self.gitExecutable = gitExecutable ?? ExecutableLocator.resolve(.git) ?? "git"
        self.environmentOverrides = environmentOverrides
        self.metadataCommandTimeout = metadataCommandTimeout
    }

    public func isRepo(path: String) -> Bool {
        (try? runGitAndCapture(["-C", path, "rev-parse", "--is-inside-work-tree"], timeout: metadataCommandTimeout)) != nil
    }

    public func defaultBranch(path: String) -> String? {
        if let output = try? runGitAndCapture(["-C", path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], timeout: metadataCommandTimeout) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = trimmed.split(separator: "/").last { return String(slash) }
        }
        if branchExists(path: path, branch: "main") { return "main" }
        if branchExists(path: path, branch: "master") { return "master" }
        return nil
    }

    public func branchExists(path: String, branch: String) -> Bool {
        let status = (try? runGit(["-C", path, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], timeout: metadataCommandTimeout)) ?? 1
        return status == 0
    }

    public func hasRemote(path: String, name: String = "origin") -> Bool {
        let status = (try? runGit(["-C", path, "remote", "get-url", name], timeout: metadataCommandTimeout)) ?? 1
        return status == 0
    }

    public func remoteBranchExists(path: String, branch: String) -> Bool { (try? remoteBranchLookupStatus(path: path, branch: branch)) == .exists }

    public func remoteBranchLookupStatus(path: String, branch: String) throws -> RemoteBranchLookupStatus {
        guard hasRemote(path: path) else { return .missing }
        let arguments = ["-C", path, "ls-remote", "--exit-code", "--heads", "origin", branch]
        let process = makeGitProcess(arguments)
        let err = Pipe()
        process.standardError = err
        try process.run()
        try waitForProcess(process, timeout: metadataCommandTimeout, arguments: arguments)
        switch process.terminationStatus {
        case 0: return .exists
        case 2: return .missing
        default:
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw WorkspaceError.gitCommandFailed(message: message)
        }
    }

    public func branchOptions(path: String, includeLiveRemoteHeads: Bool = true) -> [String] {
        var branches = Set<String>()
        if let local = try? runGitAndCapture(
            ["-C", path, "for-each-ref", "--format=%(refname:short)", "refs/heads"], timeout: metadataCommandTimeout)
        {
            let values = local.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            branches.formUnion(values.filter { !$0.isEmpty })
        }
        if let remote = try? runGitAndCapture(
            ["-C", path, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"], timeout: metadataCommandTimeout)
        {
            for raw in remote.split(separator: "\n") {
                let trimmed = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "origin/HEAD" else { continue }
                if let stripped = trimmed.replacingPrefix("origin/"), !stripped.isEmpty { branches.insert(stripped) }
            }
        }
        // Include live remote heads when explicitly requested so latency-sensitive UI paths can stay local-only.
        if includeLiveRemoteHeads,
            let remoteHeads = try? runGitAndCapture(["-C", path, "ls-remote", "--heads", "origin"], timeout: metadataCommandTimeout)
        {
            for raw in remoteHeads.split(separator: "\n") {
                let columns = raw.split(separator: "\t", omittingEmptySubsequences: true)
                guard columns.count == 2 else { continue }
                let ref = String(columns[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let branch = ref.replacingPrefix("refs/heads/"), !branch.isEmpty { branches.insert(branch) }
            }
        }
        if let defaultBranch = defaultBranch(path: path), !defaultBranch.isEmpty { branches.insert(defaultBranch) }
        return branches.sorted { lhs, rhs in lhs.localizedStandardCompare(rhs) == .orderedAscending }
    }

    /// Creates `branch` fresh at `baseBranch` and checks it out in a new worktree.
    ///
    /// Distinct from `createWorktree`, which attaches a worktree to a branch that already exists somewhere and
    /// therefore prefers `refs/remotes/origin/<branch>` when only the remote has it. The caller here has
    /// established the opposite — the branch exists neither in `refs/heads` nor on the remote — so a
    /// `refs/remotes/origin/<branch>` still present in this clone is a leftover of a branch deleted on the
    /// remote by another clone and never pruned here. Starting from it would silently put the new branch at
    /// that obsolete tip instead of the base the user chose, so this path reads only the base.
    public func createWorktreeOnNewBranch(
        path repoPath: String, worktreePath: String, branch: String, baseBranch: String?, allowRemoteBranchLookup: Bool
    ) throws {
        if let startPoint = try resolveStartPoint(path: repoPath, baseBranch: baseBranch, allowRemoteBranchLookup: allowRemoteBranchLookup) {
            try runGitOrThrow(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath, startPoint])
            return
        }
        try runGitOrThrow(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath])
    }

    /// Attaches a new worktree to `branch`, which the caller has established already exists locally or on the
    /// remote. Creating a branch that exists nowhere is `createWorktreeOnNewBranch`'s job.
    public func createWorktree(
        path repoPath: String, worktreePath: String, branch: String, baseBranch: String? = nil, allowRemoteBranchLookup: Bool = true
    ) throws {
        if branchExists(path: repoPath, branch: branch) {
            try runGitOrThrow(["-C", repoPath, "worktree", "add", worktreePath, branch])
            return
        }
        if remoteTrackingBranchExists(path: repoPath, branch: branch) {
            try runGitOrThrow(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath, "origin/\(branch)"])
            return
        }
        if allowRemoteBranchLookup {
            switch try remoteBranchLookupStatus(path: repoPath, branch: branch) {
            case .exists:
                try fetchRemoteBranch(path: repoPath, branch: branch)
                try runGitOrThrow(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath, "origin/\(branch)"])
                return
            case .missing: break
            }
        }
        if let startPoint = try resolveStartPoint(path: repoPath, baseBranch: baseBranch, allowRemoteBranchLookup: allowRemoteBranchLookup) {
            try runGitOrThrow(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath, startPoint])
            return
        }
        try runGitOrThrow(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath])
    }

    public func removeWorktree(path repoPath: String, worktreePath: String) throws {
        try runGitOrThrow(["-C", repoPath, "worktree", "remove", "--force", worktreePath])
    }

    public func pruneWorktrees(path repoPath: String) throws { try runGitOrThrow(["-C", repoPath, "worktree", "prune"]) }

    /// Absolute path of the repository's git common directory (the shared `.git`
    /// that holds `worktrees/` and the canonical `HEAD`). Resolved via
    /// `rev-parse --git-common-dir` so it is correct whether `path` is the main
    /// checkout or a linked worktree. Returns `nil` when `path` is not a repo.
    public func commonDirectory(path repoPath: String) -> String? {
        guard let output = try? runGitAndCapture(["-C", repoPath, "rev-parse", "--git-common-dir"]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed, relativeTo: URL(fileURLWithPath: repoPath)).standardizedFileURL
        return url.resolvingSymlinksInPath().path
    }

    public func listWorktrees(path repoPath: String) throws -> [WorktreeInfo] {
        let output = try runGitAndCapture(["-C", repoPath, "worktree", "list", "--porcelain"])
        return parseWorktreeList(output)
    }

    private func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
        var worktrees: [WorktreeInfo] = []
        var currentWorktree: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if let path = currentWorktree["worktree"] {
                    worktrees.append(WorktreeInfo(path: path, head: currentWorktree["HEAD"], branch: currentWorktree["branch"]))
                }
                currentWorktree = [:]
                continue
            }
            if let spaceIndex = trimmed.firstIndex(of: " ") {
                let key = String(trimmed[..<spaceIndex])
                let value = String(trimmed[trimmed.index(after: spaceIndex)...])
                currentWorktree[key] = value
            }
        }
        if let path = currentWorktree["worktree"] {
            worktrees.append(WorktreeInfo(path: path, head: currentWorktree["HEAD"], branch: currentWorktree["branch"]))
        }
        return worktrees
    }

    public func clone(url: String, destination: String, bare: Bool = false) throws {
        if bare {
            try runGitOrThrow(["clone", "--bare", url, destination])
            return
        }
        try runGitOrThrow(["clone", url, destination])
    }

    /// Resolves the repository's declared default branch from its symbolic HEAD.
    ///
    /// Git imports should follow the repository owner-selected default branch, not infer a branch
    /// by name. A symbolic HEAD that does not point at an existing branch is treated as unresolved.
    public func repositoryDefaultBranch(path repoPath: String) throws -> String {
        let branch: String
        do {
            branch = try runGitAndCapture(["-C", repoPath, "symbolic-ref", "--short", "HEAD"], timeout: metadataCommandTimeout).trimmingCharacters(
                in: .whitespacesAndNewlines)
        } catch { throw WorkspaceError.invalidArgument(message: "Could not determine the repository's default branch.") }
        guard !branch.isEmpty, branchExists(path: repoPath, branch: branch) else {
            throw WorkspaceError.invalidArgument(message: "Could not determine the repository's default branch.")
        }
        return branch
    }

    /// Reads a single file from the default branch of a remote repository without a full clone.
    ///
    /// Used to load `spaces.yaml` for the add-project preview: a blobless, no-checkout, shallow
    /// clone follows the repository's HEAD and downloads the tip commit and its trees but no file
    /// contents, so only the requested blob is fetched on demand by `git show`. Returns `nil` when
    /// the file is absent on the default branch; throws when the repository itself cannot be reached
    /// or does not declare a usable default branch.
    public func readRemoteDefaultBranchFile(gitURL: String, path: String) throws -> RemoteDefaultBranchFile {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-remote-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try runGitOrThrow(["clone", "--filter=blob:none", "--no-checkout", "--depth", "1", gitURL, tempDirectory.path])
        let defaultBranch = try repositoryDefaultBranch(path: tempDirectory.path)
        // `ls-tree` reads local tree objects (already fetched by the blobless clone), so it tells
        // us whether the file exists on the default branch without a second network round trip.
        let listing = try runGitAndCapture(["-C", tempDirectory.path, "ls-tree", "--name-only", defaultBranch, path])
        guard listing.split(whereSeparator: \.isNewline).contains(where: { $0 == path }) else {
            return RemoteDefaultBranchFile(defaultBranch: defaultBranch, contents: nil)
        }
        let contents = try runGitAndCapture(["-C", tempDirectory.path, "show", "\(defaultBranch):\(path)"])
        return RemoteDefaultBranchFile(defaultBranch: defaultBranch, contents: contents)
    }

    @discardableResult public func deleteBranch(path repoPath: String, branch: String) throws -> Bool {
        guard branchExists(path: repoPath, branch: branch) else { return false }
        try runGitOrThrow(["-C", repoPath, "branch", "-D", branch])
        return true
    }

    @discardableResult public func deleteRemoteBranch(path repoPath: String, branch: String) throws -> Bool {
        guard try remoteBranchLookupStatus(path: repoPath, branch: branch) == .exists else { return false }
        try runGitOrThrow(["-C", repoPath, "push", "origin", "--delete", branch])
        return true
    }

    public func renameCurrentBranch(path worktreePath: String, to branch: String) throws {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace branch is required.") }
        let currentOutput = try runGitAndCapture(["-C", worktreePath, "rev-parse", "--abbrev-ref", "HEAD"])
        let currentBranch = currentOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch != "HEAD" else { throw WorkspaceError.invalidArgument(message: "Cannot rename branch for detached HEAD worktree.") }
        guard currentBranch != trimmedBranch else { return }
        try runGitOrThrow(["-C", worktreePath, "branch", "-m", trimmedBranch])
    }

    public func refreshWorktreeFastForwardOnly(path worktreePath: String, branch: String, hostName: String) throws -> RemoteWorktreeRefreshResult {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace branch is required.") }
        try blockIfDirtyWorktree(path: worktreePath, branch: trimmedBranch, hostName: hostName)
        let beforeRevision = try revision(path: worktreePath, ref: "HEAD")
        do {
            switch try remoteBranchLookupStatus(path: worktreePath, branch: trimmedBranch) {
            case .exists: break
            case .missing:
                throw RemoteWorktreeRefreshBlock(
                    hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .missingBranch,
                    detail: "origin/\(trimmedBranch) does not exist.")
            }
        } catch let block as RemoteWorktreeRefreshBlock { throw block } catch {
            throw remoteRefreshBlock(hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .fetchFailed, error: error)
        }
        do { try fetchRemoteBranch(path: worktreePath, branch: trimmedBranch) } catch {
            throw remoteRefreshBlock(hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .fetchFailed, error: error)
        }

        let remoteRef = "refs/remotes/origin/\(trimmedBranch)"
        let currentBranch = try currentBranchName(path: worktreePath)
        if currentBranch != trimmedBranch {
            try blockIfUntrackedFilesWouldBeOverwritten(path: worktreePath, branch: trimmedBranch, hostName: hostName, targetRef: remoteRef)
            try checkoutBranch(path: worktreePath, branch: trimmedBranch, hostName: hostName, remoteRef: remoteRef)
        }

        let remoteRevision = try revision(path: worktreePath, ref: remoteRef)
        let currentRevision = try revision(path: worktreePath, ref: "HEAD")
        if currentRevision == remoteRevision {
            return RemoteWorktreeRefreshResult(
                hostName: hostName, path: worktreePath, branch: trimmedBranch, beforeRevision: beforeRevision, afterRevision: currentRevision,
                fastForwarded: beforeRevision != currentRevision)
        }
        guard try isAncestor(path: worktreePath, ancestor: "HEAD", descendant: remoteRef) else {
            throw RemoteWorktreeRefreshBlock(
                hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .divergentHistory,
                detail: "HEAD is not an ancestor of origin/\(trimmedBranch).")
        }
        try blockIfUntrackedFilesWouldBeOverwritten(path: worktreePath, branch: trimmedBranch, hostName: hostName, targetRef: remoteRef)
        do { try runGitOrThrow(["-C", worktreePath, "merge", "--ff-only", remoteRef]) } catch {
            throw remoteRefreshBlock(hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .checkoutFailed, error: error)
        }
        let afterRevision = try revision(path: worktreePath, ref: "HEAD")
        return RemoteWorktreeRefreshResult(
            hostName: hostName, path: worktreePath, branch: trimmedBranch, beforeRevision: beforeRevision, afterRevision: afterRevision,
            fastForwarded: beforeRevision != afterRevision)
    }

    private func runGit(_ arguments: [String], timeout: TimeInterval? = nil) throws -> Int32 {
        let process = makeGitProcess(arguments)
        try process.run()
        try waitForProcess(process, timeout: timeout, arguments: arguments)
        return process.terminationStatus
    }

    public func runGitAndCapture(_ arguments: [String], timeout: TimeInterval? = nil) throws -> String {
        let process = makeGitProcess(arguments)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        try waitForProcess(process, timeout: timeout, arguments: arguments)
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw WorkspaceError.gitCommandFailed(message: message)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private func runGitOrThrow(_ arguments: [String]) throws {
        let process = makeGitProcess(arguments)
        let out = Pipe()
        let err = Pipe()

        process.standardOutput = out
        process.standardError = err

        try process.run()
        try waitForProcess(process, timeout: nil, arguments: arguments)

        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw WorkspaceError.gitCommandFailed(message: message)
        }
    }

    private func resolveStartPoint(path: String, baseBranch: String?, allowRemoteBranchLookup: Bool) throws -> String? {
        guard let baseBranch = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !baseBranch.isEmpty else { return nil }
        if branchExists(path: path, branch: baseBranch) { return baseBranch }
        if remoteTrackingBranchExists(path: path, branch: baseBranch) { return "origin/\(baseBranch)" }
        if allowRemoteBranchLookup {
            switch try remoteBranchLookupStatus(path: path, branch: baseBranch) {
            case .exists:
                try fetchRemoteBranch(path: path, branch: baseBranch)
                return "origin/\(baseBranch)"
            case .missing: break
            }
        }
        throw WorkspaceError.invalidArgument(message: "Base branch not found: \(baseBranch)")
    }

    private func fetchRemoteBranch(path: String, branch: String) throws {
        try runGitOrThrow(["-C", path, "fetch", "origin", "refs/heads/\(branch):refs/remotes/origin/\(branch)"])
    }

    private func blockIfDirtyWorktree(path: String, branch: String, hostName: String) throws {
        let status = try runGitAndCapture(["-C", path, "status", "--porcelain=v1", "--untracked-files=no"]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard status.isEmpty else {
            throw RemoteWorktreeRefreshBlock(hostName: hostName, path: path, branch: branch, reason: .dirtyWorktree, detail: status)
        }
    }

    private func blockIfUntrackedFilesWouldBeOverwritten(path: String, branch: String, hostName: String, targetRef: String) throws {
        let changedPaths = Set(
            try runGitAndCapture(["-C", path, "diff", "--name-only", "--diff-filter=ACDMRTUXB", "HEAD..\(targetRef)"]).split(separator: "\n").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        guard !changedPaths.isEmpty else { return }
        let untrackedPaths = Set(
            try runGitAndCapture(["-C", path, "ls-files", "--others", "--exclude-standard"]).split(separator: "\n").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        let conflicts = changedPaths.intersection(untrackedPaths).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard conflicts.isEmpty else {
            throw RemoteWorktreeRefreshBlock(
                hostName: hostName, path: path, branch: branch, reason: .untrackedOverwriteRisk,
                detail: "Untracked files would be overwritten: \(conflicts.joined(separator: ", "))")
        }
    }

    private func checkoutBranch(path: String, branch: String, hostName: String, remoteRef: String) throws {
        let arguments =
            branchExists(path: path, branch: branch)
            ? ["-C", path, "checkout", branch] : ["-C", path, "checkout", "-b", branch, "--track", remoteRef]
        do { try runGitOrThrow(arguments) } catch {
            let reason =
                gitErrorMessage(error).contains("untracked working tree files would be overwritten")
                ? RemoteWorktreeRefreshBlockReason.untrackedOverwriteRisk : .checkoutFailed
            throw remoteRefreshBlock(hostName: hostName, path: path, branch: branch, reason: reason, error: error)
        }
    }

    private func currentBranchName(path: String) throws -> String {
        try runGitAndCapture(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func revision(path: String, ref: String) throws -> String {
        try runGitAndCapture(["-C", path, "rev-parse", "--verify", "\(ref)^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isAncestor(path: String, ancestor: String, descendant: String) throws -> Bool {
        let status = try runGit(["-C", path, "merge-base", "--is-ancestor", ancestor, descendant])
        switch status {
        case 0: return true
        case 1: return false
        default: throw WorkspaceError.gitCommandFailed(message: "merge-base exited with status \(status)")
        }
    }

    private func remoteRefreshBlock(hostName: String, path: String, branch: String, reason: RemoteWorktreeRefreshBlockReason, error: any Error)
        -> RemoteWorktreeRefreshBlock
    { RemoteWorktreeRefreshBlock(hostName: hostName, path: path, branch: branch, reason: reason, detail: gitErrorMessage(error)) }

    private func gitErrorMessage(_ error: any Error) -> String {
        if case WorkspaceError.gitCommandFailed(let message) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func remoteTrackingBranchExists(path: String, branch: String) -> Bool {
        let status = (try? runGit(["-C", path, "show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branch)"])) ?? 1
        return status == 0
    }

    private func makeGitProcess(_ arguments: [String]) -> Process {
        let process = Process()
        if gitExecutable.contains("/") {
            process.executableURL = URL(fileURLWithPath: gitExecutable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [gitExecutable] + arguments
        }
        process.environment = gitEnvironment()
        return process
    }

    private func gitEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        for (key, value) in environmentOverrides { environment[key] = value }
        return environment
    }

    private func waitForProcess(_ process: Process, timeout: TimeInterval?, arguments: [String]) throws {
        guard let timeout else {
            process.waitUntilExit()
            return
        }

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        // The process may have already exited before the handler was installed; in that case
        // it never fires, so skip the wait and reap the status directly below.
        if process.isRunning, completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            let commandDescription = ([gitExecutable] + arguments).joined(separator: " ")
            throw WorkspaceError.gitCommandFailed(message: "Git command timed out after \(timeout)s: \(commandDescription)")
        }
        process.waitUntilExit()
    }

}

extension String {
    fileprivate func replacingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

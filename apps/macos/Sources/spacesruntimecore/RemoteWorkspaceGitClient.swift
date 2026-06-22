import Foundation

public enum SpacesRuntimeError: LocalizedError, Equatable {
    case gitCommandFailed(message: String)
    case invalidArgument(message: String)

    public var errorDescription: String? {
        switch self {
        case .gitCommandFailed(let message): "Git command failed: \(message)"
        case .invalidArgument(let message): "Invalid argument: \(message)"
        }
    }
}

public enum RemoteWorkspaceRefreshBlockReason: String, Codable, Sendable, Equatable {
    case dirtyWorktree
    case untrackedOverwriteRisk
    case divergentHistory
    case missingBranch
    case fetchFailed
    case checkoutFailed
}

public struct RemoteWorkspaceRefreshResult: Codable, Sendable, Equatable {
    public let hostName: String
    public let path: String
    public let branch: String
    public let beforeRevision: String
    public let afterRevision: String
    public let fastForwarded: Bool

    public init(hostName: String, path: String, branch: String, beforeRevision: String, afterRevision: String, fastForwarded: Bool) {
        self.hostName = hostName
        self.path = path
        self.branch = branch
        self.beforeRevision = beforeRevision
        self.afterRevision = afterRevision
        self.fastForwarded = fastForwarded
    }
}

public struct RemoteWorkspaceRefreshBlock: LocalizedError, Sendable, Equatable {
    public let hostName: String
    public let path: String
    public let branch: String
    public let reason: RemoteWorkspaceRefreshBlockReason
    public let detail: String?

    public init(hostName: String, path: String, branch: String, reason: RemoteWorkspaceRefreshBlockReason, detail: String? = nil) {
        self.hostName = hostName
        self.path = path
        self.branch = branch
        self.reason = reason
        self.detail = detail
    }

    public var errorDescription: String? {
        var message = "Remote workspace sync blocked on \(hostName): \(path) at branch \(branch). \(guidance)"
        if let detail, !detail.isEmpty { message += " Detail: \(detail)" }
        return message
    }

    public var guidance: String {
        switch reason {
        case .dirtyWorktree: "Commit, discard, or move local changes on the device before launching."
        case .untrackedOverwriteRisk: "Move or remove untracked files that would be overwritten before launching."
        case .divergentHistory: "Reconcile the remote worktree branch history so it can fast-forward to the workspace branch tip."
        case .missingBranch: "Push the workspace branch or choose a workspace with a branch reachable from the device."
        case .fetchFailed: "Fix remote repository access from the device, then retry."
        case .checkoutFailed: "Fix the remote worktree checkout error on the device, then retry."
        }
    }
}

public final class RemoteWorkspaceGitClient {
    public enum RemoteBranchLookupStatus {
        case exists
        case missing
    }

    private let gitExecutable: String
    private let environmentOverrides: [String: String]
    private let metadataCommandTimeout: TimeInterval

    public init(gitExecutable: String? = nil, environmentOverrides: [String: String] = [:], metadataCommandTimeout: TimeInterval = 2) {
        self.gitExecutable = gitExecutable ?? Self.resolveGitExecutable(environment: ProcessInfo.processInfo.environment) ?? "git"
        self.environmentOverrides = environmentOverrides
        self.metadataCommandTimeout = metadataCommandTimeout
    }

    public func isRepo(path: String) -> Bool {
        (try? runGitAndCapture(["-C", path, "rev-parse", "--is-inside-work-tree"], timeout: metadataCommandTimeout)) != nil
    }

    public func branchExists(path: String, branch: String) -> Bool {
        let status = (try? runGit(["-C", path, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], timeout: metadataCommandTimeout)) ?? 1
        return status == 0
    }

    public func hasRemote(path: String, name: String = "origin") -> Bool {
        let status = (try? runGit(["-C", path, "remote", "get-url", name], timeout: metadataCommandTimeout)) ?? 1
        return status == 0
    }

    public func remoteBranchLookupStatus(path: String, branch: String) throws -> RemoteBranchLookupStatus {
        guard hasRemote(path: path) else { return .missing }
        let arguments = ["-C", path, "ls-remote", "--exit-code", "--heads", "origin", branch]
        let process = makeGitProcess(arguments)
        process.standardOutput = Pipe()
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
            throw SpacesRuntimeError.gitCommandFailed(message: message)
        }
    }

    public func refreshWorktreeFastForwardOnly(path worktreePath: String, branch: String, hostName: String) throws -> RemoteWorkspaceRefreshResult {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { throw SpacesRuntimeError.invalidArgument(message: "Workspace branch is required.") }
        try blockIfDirtyWorktree(path: worktreePath, branch: trimmedBranch, hostName: hostName)
        let beforeRevision = try revision(path: worktreePath, ref: "HEAD")
        do {
            switch try remoteBranchLookupStatus(path: worktreePath, branch: trimmedBranch) {
            case .exists: break
            case .missing:
                throw RemoteWorkspaceRefreshBlock(
                    hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .missingBranch,
                    detail: "origin/\(trimmedBranch) does not exist.")
            }
        } catch let block as RemoteWorkspaceRefreshBlock { throw block } catch {
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
            return RemoteWorkspaceRefreshResult(
                hostName: hostName, path: worktreePath, branch: trimmedBranch, beforeRevision: beforeRevision, afterRevision: currentRevision,
                fastForwarded: beforeRevision != currentRevision)
        }
        guard try isAncestor(path: worktreePath, ancestor: "HEAD", descendant: remoteRef) else {
            throw RemoteWorkspaceRefreshBlock(
                hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .divergentHistory,
                detail: "HEAD is not an ancestor of origin/\(trimmedBranch).")
        }
        try blockIfUntrackedFilesWouldBeOverwritten(path: worktreePath, branch: trimmedBranch, hostName: hostName, targetRef: remoteRef)
        do { try runGitOrThrow(["-C", worktreePath, "merge", "--ff-only", remoteRef]) } catch {
            throw remoteRefreshBlock(hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .checkoutFailed, error: error)
        }
        let afterRevision = try revision(path: worktreePath, ref: "HEAD")
        return RemoteWorkspaceRefreshResult(
            hostName: hostName, path: worktreePath, branch: trimmedBranch, beforeRevision: beforeRevision, afterRevision: afterRevision,
            fastForwarded: beforeRevision != afterRevision)
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
            throw SpacesRuntimeError.gitCommandFailed(message: message)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private func runGit(_ arguments: [String], timeout: TimeInterval? = nil) throws -> Int32 {
        let process = makeGitProcess(arguments)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        try waitForProcess(process, timeout: timeout, arguments: arguments)
        return process.terminationStatus
    }

    private func runGitOrThrow(_ arguments: [String]) throws {
        let process = makeGitProcess(arguments)
        let err = Pipe()
        process.standardOutput = Pipe()
        process.standardError = err

        try process.run()
        try waitForProcess(process, timeout: nil, arguments: arguments)

        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw SpacesRuntimeError.gitCommandFailed(message: message)
        }
    }

    private func fetchRemoteBranch(path: String, branch: String) throws {
        try runGitOrThrow(["-C", path, "fetch", "origin", "refs/heads/\(branch):refs/remotes/origin/\(branch)"])
    }

    private func blockIfDirtyWorktree(path: String, branch: String, hostName: String) throws {
        let status = try runGitAndCapture(["-C", path, "status", "--porcelain=v1", "--untracked-files=no"]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard status.isEmpty else {
            throw RemoteWorkspaceRefreshBlock(hostName: hostName, path: path, branch: branch, reason: .dirtyWorktree, detail: status)
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
            throw RemoteWorkspaceRefreshBlock(
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
                ? RemoteWorkspaceRefreshBlockReason.untrackedOverwriteRisk : .checkoutFailed
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
        default: throw SpacesRuntimeError.gitCommandFailed(message: "merge-base exited with status \(status)")
        }
    }

    private func remoteRefreshBlock(hostName: String, path: String, branch: String, reason: RemoteWorkspaceRefreshBlockReason, error: any Error)
        -> RemoteWorkspaceRefreshBlock
    { RemoteWorkspaceRefreshBlock(hostName: hostName, path: path, branch: branch, reason: reason, detail: gitErrorMessage(error)) }

    private func gitErrorMessage(_ error: any Error) -> String {
        if case SpacesRuntimeError.gitCommandFailed(let message) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                let commandDescription = ([gitExecutable] + arguments).joined(separator: " ")
                throw SpacesRuntimeError.gitCommandFailed(message: "Git command timed out after \(timeout)s: \(commandDescription)")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func resolveGitExecutable(environment: [String: String]) -> String? {
        let preferredAbsolutePaths = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git", "/opt/local/bin/git"]
        let defaultPATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        let mergedPATH = [environment["PATH"], defaultPATH].compactMap { $0 }.joined(separator: ":")
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        for directory in mergedPATH.split(separator: ":").map(String.init) where !directory.isEmpty {
            append(URL(fileURLWithPath: directory).appending(path: "git").path)
        }
        for path in preferredAbsolutePaths { append(path) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

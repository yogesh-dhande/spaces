import Foundation
import appctl

public final class GitClient {
    public init() {}

    public func isRepo(path: String) -> Bool { (try? runGitAndCapture(["-C", path, "rev-parse", "--is-inside-work-tree"])) != nil }

    public func defaultBranch(path: String) -> String? {
        if let output = try? runGitAndCapture(["-C", path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = trimmed.split(separator: "/").last { return String(slash) }
        }
        if branchExists(path: path, branch: "main") { return "main" }
        if branchExists(path: path, branch: "master") { return "master" }
        return nil
    }

    public func branchExists(path: String, branch: String) -> Bool {
        let status = (try? runGit(["-C", path, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"])) ?? 1
        return status == 0
    }

    public func remoteBranchExists(path: String, branch: String) -> Bool {
        let status = (try? runGit(["-C", path, "ls-remote", "--exit-code", "--heads", "origin", branch])) ?? 1
        return status == 0
    }

    public func branchOptions(path: String) -> [String] {
        var branches = Set<String>()
        if let local = try? runGitAndCapture(["-C", path, "for-each-ref", "--format=%(refname:short)", "refs/heads"]) {
            let values = local.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            branches.formUnion(values.filter { !$0.isEmpty })
        }
        if let remote = try? runGitAndCapture(["-C", path, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"]) {
            for raw in remote.split(separator: "\n") {
                let trimmed = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "origin/HEAD" else { continue }
                if let stripped = trimmed.replacingPrefix("origin/"), !stripped.isEmpty { branches.insert(stripped) }
            }
        }
        // Include live remote heads so newly created remote branches appear even before local fetch.
        if let remoteHeads = try? runGitAndCapture(["-C", path, "ls-remote", "--heads", "origin"]) {
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

    public func trackedFileActivity(path: String) -> GitTrackedFileActivity {
        guard isRepo(path: path) else { return GitTrackedFileActivity(latestTrackedFileModificationDate: nil, modifiedTrackedFileCount: 0) }

        let trackedPaths = trackedFilePaths(path: path)
        let latestModificationDate = latestTrackedFileModificationDate(path: path, trackedPaths: trackedPaths)
        let modifiedTrackedFileCount = modifiedTrackedFileCount(path: path)

        return GitTrackedFileActivity(latestTrackedFileModificationDate: latestModificationDate, modifiedTrackedFileCount: modifiedTrackedFileCount)
    }

    public func createWorktree(path repoPath: String, worktreePath: String, branch: String, targetBranch: String? = nil) throws {
        if branchExists(path: repoPath, branch: branch) {
            try runGitOrThrow(["-C", repoPath, "worktree", "add", worktreePath, branch])
            return
        }
        if remoteBranchExists(path: repoPath, branch: branch) {
            try fetchRemoteBranch(path: repoPath, branch: branch)
            try runGitOrThrow(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath, "origin/\(branch)"])
            return
        }
        if let startPoint = try resolveStartPoint(path: repoPath, targetBranch: targetBranch) {
            try runGitOrThrow(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath, startPoint])
            return
        }
        try runGitOrThrow(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath])
    }

    public func removeWorktree(path repoPath: String, worktreePath: String) throws {
        try runGitOrThrow(["-C", repoPath, "worktree", "remove", "--force", worktreePath])
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
                    worktrees.append(WorktreeInfo(
                        path: path,
                        head: currentWorktree["HEAD"],
                        branch: currentWorktree["branch"]
                    ))
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
            worktrees.append(WorktreeInfo(
                path: path,
                head: currentWorktree["HEAD"],
                branch: currentWorktree["branch"]
            ))
        }
        
        return worktrees
    }

    public func clone(url: String, destination: String) throws { try runGitOrThrow(["clone", url, destination]) }

    public func deleteBranch(path repoPath: String, branch: String) { _ = try? runGit(["-C", repoPath, "branch", "-D", branch]) }

    private func runGit(_ arguments: [String]) throws -> Int32 {
        let process = makeGitProcess(arguments)
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func runGitAndCapture(_ arguments: [String]) throws -> String {
        let process = makeGitProcess(arguments)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw MuxyError.gitCommandFailed(message: message)
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
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw MuxyError.gitCommandFailed(message: message)
        }
    }

    private func resolveStartPoint(path: String, targetBranch: String?) throws -> String? {
        guard let targetBranch = targetBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !targetBranch.isEmpty else { return nil }
        if remoteBranchExists(path: path, branch: targetBranch) {
            try fetchRemoteBranch(path: path, branch: targetBranch)
            return "origin/\(targetBranch)"
        }
        if branchExists(path: path, branch: targetBranch) { return targetBranch }
        throw MuxyError.invalidArgument(message: "Target branch not found: \(targetBranch)")
    }

    private func fetchRemoteBranch(path: String, branch: String) throws {
        try runGitOrThrow(["-C", path, "fetch", "origin", "refs/heads/\(branch):refs/remotes/origin/\(branch)"])
    }

    private func trackedFilePaths(path: String) -> [String] {
        guard let output = try? runGitAndCapture(["-C", path, "ls-files", "-z"]) else { return [] }
        return parseNullSeparatedOutput(output)
    }

    private func latestTrackedFileModificationDate(path: String, trackedPaths: [String]) -> Date? {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        var latestDate: Date?

        for trackedPath in trackedPaths {
            guard !trackedPath.isEmpty else { continue }
            let fileURL = rootURL.appending(path: trackedPath)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                let modificationDate = attributes[.modificationDate] as? Date
            else { continue }
            if let existingLatestDate = latestDate {
                if modificationDate > existingLatestDate { latestDate = modificationDate }
            } else {
                latestDate = modificationDate
            }
        }

        return latestDate
    }

    private func modifiedTrackedFileCount(path: String) -> Int {
        let staged = trackedDiffPaths(path: path, includeStaged: true)
        let unstaged = trackedDiffPaths(path: path, includeStaged: false)
        return staged.union(unstaged).count
    }

    private func trackedDiffPaths(path: String, includeStaged: Bool) -> Set<String> {
        var arguments = ["-C", path, "diff", "--name-only", "-z"]
        if includeStaged { arguments.insert("--cached", at: 3) }
        guard let output = try? runGitAndCapture(arguments) else { return [] }
        return Set(parseNullSeparatedOutput(output))
    }

    private func parseNullSeparatedOutput(_ output: String) -> [String] {
        output.split(separator: "\u{0}", omittingEmptySubsequences: true).map { String($0) }
    }

    private func makeGitProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.environment = gitEnvironment()
        return process
    }

    private func gitEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        return environment
    }
}

extension String {
    fileprivate func replacingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

import Foundation
import appctl

public final class GitClient {
    public init() {}

    public func isRepo(path: String) -> Bool {
        (try? Shell.runAndCapture(["git", "-C", path, "rev-parse", "--is-inside-work-tree"])) != nil
    }

    public func defaultBranch(path: String) -> String? {
        if let output = try? Shell.runAndCapture([
            "git", "-C", path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD",
        ]) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = trimmed.split(separator: "/").last {
                return String(slash)
            }
        }
        if branchExists(path: path, branch: "main") { return "main" }
        if branchExists(path: path, branch: "master") { return "master" }
        return nil
    }

    public func branchExists(path: String, branch: String) -> Bool {
        let status =
            (try? Shell.run(["git", "-C", path, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"])) ?? 1
        return status == 0
    }

    public func remoteBranchExists(path: String, branch: String) -> Bool {
        let status =
            (try? Shell.run(["git", "-C", path, "ls-remote", "--exit-code", "--heads", "origin", branch])) ?? 1
        return status == 0
    }

    public func createWorktree(path repoPath: String, worktreePath: String, branch: String) throws {
        if branchExists(path: repoPath, branch: branch) {
            try runGit(["-C", repoPath, "worktree", "add", worktreePath, branch])
            return
        }
        if remoteBranchExists(path: repoPath, branch: branch) {
            try runGit(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath, "origin/\(branch)"])
            return
        }
        try runGit(["-C", repoPath, "worktree", "add", "-b", branch, worktreePath])
    }

    public func removeWorktree(path repoPath: String, worktreePath: String) throws {
        try runGit(["-C", repoPath, "worktree", "remove", "--force", worktreePath])
    }

    public func clone(url: String, destination: String) throws {
        try runGit(["clone", url, destination])
    }

    public func deleteBranch(path repoPath: String, branch: String) {
        _ = try? Shell.run(["git", "-C", repoPath, "branch", "-D", branch])
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        let out = Pipe()
        let err = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = out
        process.standardError = err

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message =
                String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw AgentmuxError.gitCommandFailed(message: message)
        }
    }
}

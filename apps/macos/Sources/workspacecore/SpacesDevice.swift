import Foundation
import spacesterminalcore

public enum SpacesDeviceRecord { public static let localDeviceID = "local" }

public struct WorkspaceRuntimePortMapping: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let port: Int

    public init(id: String, name: String, port: Int) {
        self.id = id
        self.name = name
        self.port = port
    }
}

public struct WorkspaceRuntimeManifest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let projectID: String
    public let localPath: String
    public let branch: String?
    public let baseBranch: String?
    public let namedPorts: [WorkspaceRuntimePortMapping]
    public let processEnvironment: [String: String]
    public let allowedFileRoots: [String]

    public init(
        workspaceID: String, projectID: String, localPath: String, branch: String?, baseBranch: String?, namedPorts: [WorkspaceRuntimePortMapping],
        processEnvironment: [String: String], allowedFileRoots: [String]
    ) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.localPath = localPath
        self.branch = branch
        self.baseBranch = baseBranch
        self.namedPorts = namedPorts
        self.processEnvironment = processEnvironment
        self.allowedFileRoots = allowedFileRoots
    }
}

public enum SpacesDevicePlanner {
    public static func runtimeManifest(project: ProjectRecord, workspace: WorkspaceRecord, namedPorts: [WorkspaceRuntimePortMapping])
        -> WorkspaceRuntimeManifest
    {
        let workingPath = workspace.dir
        let slug = SpacesProfile.workspaceHostSlug(
            branch: workspace.branch, projectName: project.name, isGitRepo: project.isGitRepo, workspaceID: workspace.id)
        var environment = ["SPACES_WORKSPACE_ID": workspace.id, "SPACES_PROJECT_ID": project.id, "SPACES_WORKSPACE_SLUG": slug]
        for mapping in namedPorts {
            environment[ServiceName.portEnvVar(for: mapping.name)] = String(mapping.port)
            environment[ServiceName.hostEnvVar(for: mapping.name)] = "\(mapping.name).\(slug).localhost"
        }

        return WorkspaceRuntimeManifest(
            workspaceID: workspace.id, projectID: project.id, localPath: workspace.dir, branch: workspace.branch,
            baseBranch: workspace.baseBranch, namedPorts: namedPorts, processEnvironment: environment, allowedFileRoots: [workingPath])
    }
}

public enum RemoteWorktreeRefreshBlockReason: String, Codable, Sendable, Equatable {
    case dirtyWorktree
    case untrackedOverwriteRisk
    case divergentHistory
    case missingBranch
    case fetchFailed
    case checkoutFailed
}

public struct RemoteWorktreeRefreshResult: Codable, Sendable, Equatable {
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

public struct RemoteWorktreeRefreshBlock: LocalizedError, Sendable, Equatable {
    public let hostName: String
    public let path: String
    public let branch: String
    public let reason: RemoteWorktreeRefreshBlockReason
    public let detail: String?

    public init(hostName: String, path: String, branch: String, reason: RemoteWorktreeRefreshBlockReason, detail: String? = nil) {
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

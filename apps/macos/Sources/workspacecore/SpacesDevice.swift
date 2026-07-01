import Foundation
import spacesterminalcore

public enum SpacesDeviceKind: String, Codable, Sendable, Equatable {
    case local
    case remote
}

public struct SpacesDaemonEndpoint: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int
    public let certificateFingerprint: String

    public init(host: String, port: Int, certificateFingerprint: String) {
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
    }
}

public struct SpacesDeviceRecord: Codable, Sendable, Equatable, Identifiable {
    public static let localDeviceID = "local"

    public let id: String
    public var name: String
    public var kind: SpacesDeviceKind
    public var sshHost: String
    public var sshUser: String?
    public var sshPort: Int?
    public var workspaceRoot: String
    public var daemonEndpoint: SpacesDaemonEndpoint
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String, name: String, kind: SpacesDeviceKind = .remote, sshHost: String, sshUser: String? = nil, sshPort: Int? = nil,
        workspaceRoot: String, daemonEndpoint: SpacesDaemonEndpoint, createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.workspaceRoot = workspaceRoot
        self.daemonEndpoint = daemonEndpoint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func local(createdAt: String = "1970-01-01T00:00:00Z", updatedAt: String = "1970-01-01T00:00:00Z") -> SpacesDeviceRecord {
        SpacesDeviceRecord(
            id: localDeviceID, name: "Local Mac", kind: .local, sshHost: "", sshUser: nil, sshPort: nil, workspaceRoot: "",
            daemonEndpoint: SpacesDaemonEndpoint(host: "", port: 0, certificateFingerprint: ""), createdAt: createdAt, updatedAt: updatedAt)
    }

    public var isLocal: Bool { kind == .local }
}

public enum SpacesDeviceSelection: Sendable, Equatable {
    case local(SpacesDeviceRecord)
    case remote(SpacesDeviceRecord)

    public var deviceID: String? {
        switch self {
        case .local(let device): device.id
        case .remote(let device): device.id
        }
    }

    public var isRemote: Bool {
        switch self {
        case .local: false
        case .remote: true
        }
    }

    public var displayName: String {
        switch self {
        case .local(let device): device.name
        case .remote(let device): device.name
        }
    }
}

public struct SpacesDaemonConnectionTarget: Sendable, Equatable {
    public enum Transport: String, Sendable, Equatable {
        case localUnixSocket
        case pinnedTLS
    }

    public let transport: Transport
    public let deviceID: String?
    public let displayName: String
    public let socketPath: String?
    public let endpoint: SpacesDaemonEndpoint?

    public init(transport: Transport, deviceID: String?, displayName: String, socketPath: String? = nil, endpoint: SpacesDaemonEndpoint? = nil) {
        self.transport = transport
        self.deviceID = deviceID
        self.displayName = displayName
        self.socketPath = socketPath
        self.endpoint = endpoint
    }
}

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
    public enum Location: String, Codable, Sendable {
        case local
        case remote
    }

    public let workspaceID: String
    public let projectID: String
    public let deviceID: String?
    public let location: Location
    public let localPath: String
    public let remotePath: String?
    public let branch: String?
    public let baseBranch: String?
    public let gitRemoteURL: String?
    public let namedPorts: [WorkspaceRuntimePortMapping]
    public let processEnvironment: [String: String]
    public let allowedFileRoots: [String]

    public init(
        workspaceID: String, projectID: String, deviceID: String?, location: Location, localPath: String, remotePath: String?, branch: String?,
        baseBranch: String?, gitRemoteURL: String? = nil, namedPorts: [WorkspaceRuntimePortMapping], processEnvironment: [String: String],
        allowedFileRoots: [String]
    ) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.deviceID = deviceID
        self.location = location
        self.localPath = localPath
        self.remotePath = remotePath
        self.branch = branch
        self.baseBranch = baseBranch
        self.gitRemoteURL = gitRemoteURL
        self.namedPorts = namedPorts
        self.processEnvironment = processEnvironment
        self.allowedFileRoots = allowedFileRoots
    }
}

public struct WorkspaceRuntimePlan: Sendable {
    public let project: ProjectRecord
    public let workspace: WorkspaceRecord
    public let selection: SpacesDeviceSelection
    public let manifest: WorkspaceRuntimeManifest
    public let daemonTarget: SpacesDaemonConnectionTarget
    public let remoteSSHURI: String?

    public init(
        project: ProjectRecord, workspace: WorkspaceRecord, selection: SpacesDeviceSelection, manifest: WorkspaceRuntimeManifest,
        daemonTarget: SpacesDaemonConnectionTarget, remoteSSHURI: String?
    ) {
        self.project = project
        self.workspace = workspace
        self.selection = selection
        self.manifest = manifest
        self.daemonTarget = daemonTarget
        self.remoteSSHURI = remoteSSHURI
    }
}

public enum SpacesDevicePlanner {
    public static func selectDevice(project: ProjectRecord, workspace: WorkspaceRecord, devicesByID: [String: SpacesDeviceRecord])
        -> SpacesDeviceSelection
    { .local(devicesByID[SpacesDeviceRecord.localDeviceID] ?? SpacesDeviceRecord.local()) }

    public static func daemonTarget(selection: SpacesDeviceSelection, localSocketPath: String) -> SpacesDaemonConnectionTarget {
        let device = SpacesDeviceRecord.local()
        return SpacesDaemonConnectionTarget(transport: .localUnixSocket, deviceID: device.id, displayName: device.name, socketPath: localSocketPath)
    }

    public static func runtimeManifest(
        project: ProjectRecord, workspace: WorkspaceRecord, selection: SpacesDeviceSelection, namedPorts: [WorkspaceRuntimePortMapping]
    ) -> WorkspaceRuntimeManifest {
        let workingPath = workspace.runtimePath
        let slug = SpacesProfile.workspaceHostSlug(branch: workspace.branch, workspaceID: workspace.id)
        var environment = [
            "SPACES_WORKSPACE_ID": workspace.id, "SPACES_PROJECT_ID": project.id, "SPACES_WORKSPACE_SLUG": slug,
            "SPACES_WORKSPACE_HOST": "\(slug).localhost",
        ]
        for mapping in namedPorts { environment[ServiceName.portEnvVar(for: mapping.name)] = String(mapping.port) }

        return WorkspaceRuntimeManifest(
            workspaceID: workspace.id, projectID: project.id, deviceID: SpacesDeviceRecord.localDeviceID, location: .local,
            localPath: workspace.runtimePath, remotePath: nil, branch: workspace.branch, baseBranch: workspace.baseBranch, gitRemoteURL: nil,
            namedPorts: namedPorts, processEnvironment: environment, allowedFileRoots: [workingPath])
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

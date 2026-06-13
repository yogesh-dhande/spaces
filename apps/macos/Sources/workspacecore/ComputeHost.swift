import Foundation

public enum ComputeHostKind: String, Codable, Sendable, Equatable { case remote }

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

public struct ComputeHostRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var kind: ComputeHostKind
    public var sshHost: String
    public var sshUser: String?
    public var sshPort: Int?
    public var workspaceRoot: String
    public var daemonEndpoint: SpacesDaemonEndpoint
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String, name: String, kind: ComputeHostKind = .remote, sshHost: String, sshUser: String? = nil, sshPort: Int? = nil,
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
}

public struct ComputeHostDraft: Sendable, Equatable {
    public let host: String
    public let sshUser: String?
    public let displayName: String?
    public let sshPort: Int?
    public let workspaceRoot: String?

    public init(host: String, sshUser: String? = nil, displayName: String? = nil, sshPort: Int? = nil, workspaceRoot: String? = nil) {
        self.host = host
        self.sshUser = sshUser
        self.displayName = displayName
        self.sshPort = sshPort
        self.workspaceRoot = workspaceRoot
    }
}

public struct PreparedComputeHostDraft: Sendable, Equatable {
    public let host: ComputeHostRecord
    public let authToken: String

    public init(host: ComputeHostRecord, authToken: String) {
        self.host = host
        self.authToken = authToken
    }
}

public enum ComputeHostDraftBuilder {
    public static let defaultWorkspaceRoot = "$HOME/.spaces/workspaces"
    public static let defaultDaemonPort = 7443

    public static func prepare(
        draft: ComputeHostDraft, resolvedSSH: SSHResolvedConfiguration? = nil, existing: ComputeHostRecord? = nil,
        certificateFingerprint: String = "", daemonPort: Int = defaultDaemonPort, authToken: String = ComputeHostCredentialStore.generateAuthToken(),
        now: Date = Date()
    ) throws -> PreparedComputeHostDraft {
        let enteredHost = try required(draft.host, label: "Host")
        let resolvedHostname = resolvedSSH?.resolvedHostname(fallback: enteredHost) ?? enteredHost
        let enteredDisplayName = normalized(draft.displayName)
        let displayName = enteredDisplayName ?? enteredHost
        let hostID = existing?.id ?? slug(source: enteredDisplayName ?? resolvedHostname, fallback: resolvedHostname)
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: now)
        let workspaceRoot = existing?.workspaceRoot ?? normalized(draft.workspaceRoot) ?? defaultWorkspaceRoot

        let host = ComputeHostRecord(
            id: hostID, name: displayName, sshHost: enteredHost, sshUser: normalized(draft.sshUser) ?? resolvedSSH?.user,
            sshPort: draft.sshPort ?? resolvedSSH?.port, workspaceRoot: workspaceRoot,
            daemonEndpoint: SpacesDaemonEndpoint(host: resolvedHostname, port: daemonPort, certificateFingerprint: certificateFingerprint),
            createdAt: existing?.createdAt ?? timestamp, updatedAt: timestamp)
        return PreparedComputeHostDraft(host: host, authToken: authToken)
    }

    private static func required(_ value: String?, label: String) throws -> String {
        guard let trimmed = normalized(value) else { throw WorkspaceError.invalidArgument(message: "\(label) is required.") }
        return trimmed
    }

    private static func slug(source: String, fallback: String) -> String {
        let candidate = normalized(source) ?? normalized(fallback) ?? "remote-host"
        var scalars: [UnicodeScalar] = []
        var lastWasSeparator = false
        for scalar in candidate.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                scalars.append("-")
                lastWasSeparator = true
            }
        }
        let slug = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "remote-host" : slug
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public struct ComputeHostReachabilityError: LocalizedError, Sendable, Equatable {
    public let host: String
    public let port: Int
    public let underlyingDescription: String

    public init(host: String, port: Int, underlying: Error) {
        self.host = host
        self.port = port
        self.underlyingDescription = (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
    }

    public init(host: String, port: Int, underlyingDescription: String) {
        self.host = host
        self.port = port
        self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? {
        "Remote spacesd started over SSH, but Spaces could not reach \(host):\(port) directly. Make sure the Mac, iPhone, VPN, firewall, or cloud security group allows direct spacesd access. \(underlyingDescription)"
    }
}

public struct WorkspaceComputeBinding: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(workspaceID):\(hostID)" }
    public let workspaceID: String
    public let hostID: String
    public var remotePath: String
    public var branch: String?
    public var createdAt: String
    public var updatedAt: String

    public init(workspaceID: String, hostID: String, remotePath: String, branch: String?, createdAt: String, updatedAt: String) {
        self.workspaceID = workspaceID
        self.hostID = hostID
        self.remotePath = remotePath
        self.branch = branch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ComputeHostDeletionResult: Codable, Sendable, Equatable {
    public let hostID: String
    public let clearedProjectDefaultIDs: [String]
    public let clearedWorkspaceOverrideIDs: [String]
    public let clearedWorkspaceBindingIDs: [String]
    public let credentialTokenDeleted: Bool

    public init(
        hostID: String, clearedProjectDefaultIDs: [String], clearedWorkspaceOverrideIDs: [String], clearedWorkspaceBindingIDs: [String],
        credentialTokenDeleted: Bool
    ) {
        self.hostID = hostID
        self.clearedProjectDefaultIDs = clearedProjectDefaultIDs
        self.clearedWorkspaceOverrideIDs = clearedWorkspaceOverrideIDs
        self.clearedWorkspaceBindingIDs = clearedWorkspaceBindingIDs
        self.credentialTokenDeleted = credentialTokenDeleted
    }
}

public enum ComputeHostSelection: Sendable, Equatable {
    case localMac
    case remote(ComputeHostRecord)

    public var computeHostID: String? {
        switch self {
        case .localMac: nil
        case .remote(let host): host.id
        }
    }

    public var isRemote: Bool {
        switch self {
        case .localMac: false
        case .remote: true
        }
    }

    public var displayName: String {
        switch self {
        case .localMac: "local Mac"
        case .remote(let host): host.name
        }
    }
}

public struct SpacesDaemonConnectionTarget: Sendable, Equatable {
    public enum Transport: String, Sendable, Equatable {
        case localUnixSocket
        case pinnedTLS
    }

    public let transport: Transport
    public let computeHostID: String?
    public let displayName: String
    public let socketPath: String?
    public let endpoint: SpacesDaemonEndpoint?

    public init(transport: Transport, computeHostID: String?, displayName: String, socketPath: String? = nil, endpoint: SpacesDaemonEndpoint? = nil) {
        self.transport = transport
        self.computeHostID = computeHostID
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
    public let computeHostID: String?
    public let location: Location
    public let localPath: String
    public let remotePath: String?
    public let branch: String?
    public let targetBranch: String?
    public let gitRemoteURL: String?
    public let namedPorts: [WorkspaceRuntimePortMapping]
    public let processEnvironment: [String: String]
    public let allowedFileRoots: [String]

    public init(
        workspaceID: String, projectID: String, computeHostID: String?, location: Location, localPath: String, remotePath: String?, branch: String?,
        targetBranch: String?, gitRemoteURL: String? = nil, namedPorts: [WorkspaceRuntimePortMapping], processEnvironment: [String: String],
        allowedFileRoots: [String]
    ) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.computeHostID = computeHostID
        self.location = location
        self.localPath = localPath
        self.remotePath = remotePath
        self.branch = branch
        self.targetBranch = targetBranch
        self.gitRemoteURL = gitRemoteURL
        self.namedPorts = namedPorts
        self.processEnvironment = processEnvironment
        self.allowedFileRoots = allowedFileRoots
    }
}

public struct WorkspaceRuntimePlan: Sendable {
    public let project: ProjectRecord
    public let workspace: WorkspaceRecord
    public let selection: ComputeHostSelection
    public let binding: WorkspaceComputeBinding?
    public let manifest: WorkspaceRuntimeManifest
    public let daemonTarget: SpacesDaemonConnectionTarget
    public let remoteSSHURI: String?

    public init(
        project: ProjectRecord, workspace: WorkspaceRecord, selection: ComputeHostSelection, binding: WorkspaceComputeBinding?,
        manifest: WorkspaceRuntimeManifest, daemonTarget: SpacesDaemonConnectionTarget, remoteSSHURI: String?
    ) {
        self.project = project
        self.workspace = workspace
        self.selection = selection
        self.binding = binding
        self.manifest = manifest
        self.daemonTarget = daemonTarget
        self.remoteSSHURI = remoteSSHURI
    }
}

public enum ComputeHostPlanner {
    public static func selectHost(project: ProjectRecord, workspace: WorkspaceRecord, hostsByID: [String: ComputeHostRecord]) -> ComputeHostSelection
    {
        if let overrideID = normalized(workspace.computeHostOverrideID), let host = hostsByID[overrideID] { return .remote(host) }
        if let defaultID = normalized(project.defaultComputeHostID), let host = hostsByID[defaultID] { return .remote(host) }
        return .localMac
    }

    public static func daemonTarget(selection: ComputeHostSelection, localSocketPath: String) -> SpacesDaemonConnectionTarget {
        switch selection {
        case .localMac:
            return SpacesDaemonConnectionTarget(
                transport: .localUnixSocket, computeHostID: nil, displayName: "local Mac", socketPath: localSocketPath)
        case .remote(let host):
            return SpacesDaemonConnectionTarget(transport: .pinnedTLS, computeHostID: host.id, displayName: host.name, endpoint: host.daemonEndpoint)
        }
    }

    public static func proposedRemoteWorkspacePath(host: ComputeHostRecord, project: ProjectRecord, workspace: WorkspaceRecord) -> String {
        let root = host.workspaceRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let projectComponent = stablePathComponent(name: project.name, id: project.id)
        let workspaceName = workspace.dirname ?? workspace.branch ?? workspace.title
        let workspaceComponent = stablePathComponent(name: workspaceName, id: workspace.id)
        return "/" + [root, projectComponent, workspaceComponent].filter { !$0.isEmpty }.joined(separator: "/")
    }

    public static func runtimeManifest(
        project: ProjectRecord, workspace: WorkspaceRecord, selection: ComputeHostSelection, binding: WorkspaceComputeBinding?,
        namedPorts: [WorkspaceRuntimePortMapping], gitRemoteURL: String? = nil
    ) -> WorkspaceRuntimeManifest {
        let location: WorkspaceRuntimeManifest.Location = selection.isRemote ? .remote : .local
        let remotePath = binding?.remotePath
        let workingPath = remotePath ?? workspace.dir
        var environment = ["SPACES_WORKSPACE_ID": workspace.id, "SPACES_PROJECT_ID": project.id, "SPACES_COMPUTE_LOCATION": location.rawValue]
        if let computeHostID = selection.computeHostID { environment["SPACES_COMPUTE_HOST_ID"] = computeHostID }
        if let remotePath { environment["SPACES_REMOTE_WORKSPACE_PATH"] = remotePath }
        for mapping in namedPorts { environment[mapping.name] = String(mapping.port) }

        return WorkspaceRuntimeManifest(
            workspaceID: workspace.id, projectID: project.id, computeHostID: selection.computeHostID, location: location, localPath: workspace.dir,
            remotePath: remotePath, branch: workspace.branch, targetBranch: workspace.targetBranch, gitRemoteURL: gitRemoteURL,
            namedPorts: namedPorts, processEnvironment: environment, allowedFileRoots: [workingPath])
    }

    public static func remoteSSHURI(host: ComputeHostRecord, path: String) -> String {
        let authority: String
        if let user = normalized(host.sshUser) { authority = "\(user)@\(host.sshHost)" } else { authority = host.sshHost }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let portQuery = host.sshPort.map { "?port=\($0)" } ?? ""
        return "vscode-remote://ssh-remote+\(authority)\(normalizedPath)\(portQuery)"
    }

    private static func stablePathComponent(name: String, id: String) -> String {
        let slug = slugify(name)
        let shortID = id.replacingOccurrences(of: "-", with: "").prefix(8)
        return shortID.isEmpty ? slug : "\(slug)-\(shortID)"
    }

    private static func slugify(_ value: String) -> String {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var scalars: [UnicodeScalar] = []
        var lastWasSeparator = false
        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                scalars.append("-")
                lastWasSeparator = true
            }
        }
        let slug = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "workspace" : slug
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
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
        case .dirtyWorktree: "Commit, discard, or move local changes on the compute host before launching."
        case .untrackedOverwriteRisk: "Move or remove untracked files that would be overwritten before launching."
        case .divergentHistory: "Reconcile the remote worktree branch history so it can fast-forward to the workspace branch tip."
        case .missingBranch: "Push the workspace branch or choose a workspace with a branch reachable from the compute host."
        case .fetchFailed: "Fix remote repository access from the compute host, then retry."
        case .checkoutFailed: "Fix the remote worktree checkout error on the compute host, then retry."
        }
    }
}

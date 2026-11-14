import Foundation

/// A pinned thread: a named, resumable coding-agent conversation that stays under its workspace after
/// the agent stops. Every pin of a workspace is listed on its summary, running or not.
public struct SpacesDeviceWorkspacePinnedThread: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String
    /// The row's name. While a coding-agent row is attached this is also that row's displayed name.
    public let name: String
    /// The `SpacesDeviceWorkspaceCodingAgentRow.id` of the running agent attached to this pin, nil when the
    /// pin is not running.
    public let agentRowID: String?
    /// The agent's brief for this conversation. Carried only while the pin is not running: a running pin's
    /// brief is on its coding-agent row, which is what a client renders.
    public let brief: String?
    public let briefUpdatedAt: String?

    public init(id: String, workspaceID: String, name: String, agentRowID: String?, brief: String? = nil, briefUpdatedAt: String? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.agentRowID = agentRowID
        self.brief = brief
        self.briefUpdatedAt = briefUpdatedAt
    }

    public var isRunning: Bool { agentRowID != nil }
}

/// One entry of a workspace's coding-agent list, in display order.
public enum SpacesDeviceWorkspaceAgentEntry: Sendable, Equatable, Identifiable {
    case agent(SpacesDeviceWorkspaceCodingAgentRow)
    case pinnedThread(SpacesDeviceWorkspacePinnedThread)

    public var id: String {
        switch self {
        case .agent(let row): row.id
        case .pinnedThread(let pin): "pin:\(pin.id)"
        }
    }
}

extension SpacesDeviceWorkspaceSummary {
    /// The coding-agent list every client shows: pins first in pin order (a running pin as its attached
    /// row, a not-running pin as itself), then the unpinned agent rows. One definition so the Mac sidebar
    /// and the iPhone list can never order pins differently.
    public var agentEntries: [SpacesDeviceWorkspaceAgentEntry] { Self.agentEntries(pinnedThreads: pinnedThreads, codingAgentRows: codingAgentRows) }

    public static func agentEntries(pinnedThreads: [SpacesDeviceWorkspacePinnedThread], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow])
        -> [SpacesDeviceWorkspaceAgentEntry]
    {
        let rowsByPinID = Dictionary(codingAgentRows.compactMap { row in row.pinID.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        let pinned = pinnedThreads.map { pin -> SpacesDeviceWorkspaceAgentEntry in
            if let row = rowsByPinID[pin.id] { return .agent(row) }
            return .pinnedThread(pin)
        }
        return pinned + codingAgentRows.filter { $0.pinID == nil }.map { .agent($0) }
    }
}

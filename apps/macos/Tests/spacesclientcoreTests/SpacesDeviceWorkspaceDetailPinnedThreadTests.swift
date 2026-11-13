import XCTest
import spacesdevicecore

@testable import spacesclientcore

final class SpacesDeviceWorkspaceDetailPinnedThreadTests: XCTestCase {
    private func row(_ id: String, pinID: String? = nil) -> SpacesDeviceWorkspaceCodingAgentRow {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: "agent:\(id)", workspaceID: "workspace-1", name: id, command: "claude", agentID: id, sessionID: "session-\(id)", runState: .running,
            activityState: .idle, brief: nil, briefUpdatedAt: nil, canStop: true, pinID: pinID)
    }

    /// Both clients list a workspace's agents from this one ordering: pins first in pin order (a running pin
    /// as its row, a not-running pin as itself), then the unpinned rows in their own order.
    func testAgentEntriesListPinsFirstInPinOrderThenTheUnpinnedRows() {
        let workspace = SpacesDeviceWorkspaceSummary(
            id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/repo", isRunning: true,
            isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: true,
            codingAgentRows: [row("plain-1"), row("pinned", pinID: "pin-2"), row("plain-2")],
            pinnedThreads: [
                SpacesDeviceWorkspacePinnedThread(id: "pin-1", workspaceID: "workspace-1", name: "Not running", agentRowID: nil, brief: "brief"),
                SpacesDeviceWorkspacePinnedThread(id: "pin-2", workspaceID: "workspace-1", name: "pinned", agentRowID: "agent:pinned"),
            ])

        let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: workspace)

        XCTAssertEqual(detail.agentEntries.map(\.id), ["pin:pin-1", "agent:pinned", "agent:plain-1", "agent:plain-2"])
        XCTAssertEqual(detail.pinnedThreads.map(\.id), ["pin-1", "pin-2"])
        XCTAssertEqual(detail.agentEntries, workspace.agentEntries)
    }
}

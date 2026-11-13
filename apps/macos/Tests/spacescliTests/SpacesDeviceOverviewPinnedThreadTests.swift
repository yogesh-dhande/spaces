import XCTest
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacescli
@testable import spacesdeviceapi

/// What the overview tells every client about pinned threads: their order, which rows are pinned, why a
/// row cannot be pinned, and what a not-running pin carries.
final class SpacesDeviceOverviewPinnedThreadTests: XCTestCase {
    private let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main", kind: .standard)
    private let workspace = WorkspaceRecord(
        id: "workspace-1", projectID: "project-1", dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isRunning: true,
        lastLaunchedAt: nil)

    private func agent(_ id: String, label: String, key: String?, command: String? = "claude") -> AgentWindowRecord {
        AgentWindowRecord(
            id: id, workspaceID: workspace.id, provider: .spaces, label: label,
            terminalTarget: TerminalTargetRecord(runtimeTargetID: nil, trackingID: "session-\(id)"), sessionKey: key, status: .idle,
            launchCommand: command, createdAt: "now", updatedAt: "now")
    }

    private func pin(_ id: String, name: String, key: String, agentID: String?, brief: String? = nil) -> PinnedThreadRecord {
        PinnedThreadRecord(
            id: id, workspaceID: workspace.id, sessionKey: key, name: name, launchCommand: "claude", workingDirectory: workspace.dir,
            agentSessionID: agentID, pinnedAt: "2026-06-06T00:00:00Z", brief: brief, briefUpdatedAt: brief == nil ? nil : "2026-06-06T00:00:01Z")
    }

    private func summary(agents: [AgentWindowRecord], pins: [PinnedThreadRecord]) -> SpacesDeviceWorkspaceSummary {
        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project],
            workspaces: [.init(project: project, workspace: workspace, settings: WorkspaceSettings(), agentWindows: agents, pinnedThreads: pins)],
            sessions: [])
        return overview.workspaces[0]
    }

    func testPinnedRowsLeadInPinOrderAndCarryTheirPinID() {
        let rows = summary(
            agents: [agent("a", label: "Alpha", key: "k-a"), agent("b", label: "Bravo", key: "k-b"), agent("c", label: "Charlie", key: "k-c")],
            pins: [pin("pin-c", name: "Charlie", key: "k-c", agentID: "c"), pin("pin-b", name: "Bravo", key: "k-b", agentID: "b")]
        ).codingAgentRows

        XCTAssertEqual(rows.map(\.name), ["Charlie", "Bravo", "Alpha"])
        XCTAssertEqual(rows.map(\.pinID), ["pin-c", "pin-b", nil])
    }

    func testANotRunningPinIsListedWithItsBriefAndARunningPinCarriesNone() {
        let workspaceSummary = summary(
            agents: [agent("a", label: "Alpha", key: "k-a")],
            pins: [
                pin("pin-a", name: "Alpha", key: "k-a", agentID: "a", brief: "on the row instead"),
                pin("pin-gone", name: "Fix checkout", key: "k-gone", agentID: nil, brief: "Where I left off"),
            ])

        let running = workspaceSummary.pinnedThreads[0]
        XCTAssertEqual(running.agentRowID, "agent:a")
        XCTAssertNil(running.brief)
        let notRunning = workspaceSummary.pinnedThreads[1]
        XCTAssertNil(notRunning.agentRowID)
        XCTAssertEqual(notRunning.name, "Fix checkout")
        XCTAssertEqual(notRunning.brief, "Where I left off")
        XCTAssertEqual(notRunning.briefUpdatedAt, "2026-06-06T00:00:01Z")
        XCTAssertEqual(workspaceSummary.agentEntries.map(\.id), ["agent:a", "pin:pin-gone"])
    }

    func testPinUnavailableReasonNamesWhyARowCannotBePinned() {
        let rows = summary(
            agents: [
                agent("ready", label: "Ready", key: "k-ready"), agent("fresh", label: "Fresh", key: nil),
                agent("oneshot", label: "One shot", key: "k-oneshot", command: #"claude -p "summarize""#),
                agent("pinned", label: "Pinned", key: "k-pinned"), agent("dup", label: "Dup", key: "k-pinned"),
            ], pins: [pin("pin-1", name: "Pinned", key: "k-pinned", agentID: "pinned")]
        ).codingAgentRows
        func reason(_ name: String) -> SpacesDeviceAgentPinUnavailableReason? { rows.first { $0.name == name }?.pinUnavailableReason }

        XCTAssertNil(reason("Ready"))
        XCTAssertEqual(reason("Fresh"), .noConversation)
        XCTAssertEqual(reason("One shot"), .oneShotRun)
        XCTAssertEqual(reason("Pinned"), .conversationPinned)
        XCTAssertEqual(reason("Dup"), .conversationPinned, "a second row on a pinned conversation cannot be pinned again")
    }

    func testAgentEntriesPutPinsFirstInPinOrderAndHideTheirRowsFromTheRest() {
        let workspaceSummary = summary(
            agents: [agent("a", label: "Alpha", key: "k-a"), agent("b", label: "Bravo", key: "k-b")],
            pins: [pin("pin-gone", name: "Fix checkout", key: "k-gone", agentID: nil), pin("pin-b", name: "Bravo", key: "k-b", agentID: "b")])

        XCTAssertEqual(workspaceSummary.agentEntries.map(\.id), ["pin:pin-gone", "agent:b", "agent:a"])
    }

    func testTheWorkspaceSummaryRoundTripsItsPins() throws {
        let original = summary(agents: [agent("a", label: "Alpha", key: "k-a")], pins: [pin("pin-a", name: "Alpha", key: "k-a", agentID: "a")])

        let decoded = try JSONDecoder().decode(SpacesDeviceWorkspaceSummary.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.codingAgentRows.first?.pinID, "pin-a")
        XCTAssertEqual(decoded.pinnedThreads.map(\.id), ["pin-a"])
    }
}

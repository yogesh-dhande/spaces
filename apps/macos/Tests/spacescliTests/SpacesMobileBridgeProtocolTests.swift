import XCTest
import spacesmobilecore

final class SpacesMobileBridgeProtocolTests: XCTestCase {
    func testRequestRoundTripsScrollModsThroughCodec() throws {
        let request = SpacesMobileBridgeRequest(
            command: "scroll", authToken: "SECRET", sessionID: "session-1", clientID: "ios-client", ownerEpoch: 3, scrollHorizontal: 1.5,
            scrollVertical: -2.5, scrollMods: 7)

        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeRequest(SpacesMobileBridgeCodec.encodeRequest(request)), request)
    }

    func testLegacyScrollRequestDecodesWithoutScrollMods() throws {
        let payload = #"{"command":"scroll","sessionID":"session-1","clientID":"ios-client","scrollVertical":24}"#.data(using: .utf8)!
        let request = try SpacesMobileBridgeCodec.decodeRequest(payload)

        XCTAssertEqual(request.scrollVertical, 24)
        XCTAssertNil(request.scrollMods)
    }

    func testMutationRequestRoundTripsWorkspaceAndRuntimeFields() throws {
        let request = SpacesMobileBridgeRequest(
            command: "createWorkspace", authToken: "SECRET", projectID: "project-1", workspaceID: "workspace-1", workspaceTitle: "Feature",
            branch: "feature", targetBranch: "main", directoryName: "feature-dir", allowExistingBranchReuse: true, processKey: "api",
            processID: "process-1", processTemplateID: "template-1", agentName: "Codex", agentID: "agent-1", agentLauncherID: "launcher-1")

        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeRequest(SpacesMobileBridgeCodec.encodeRequest(request)), request)
    }

    func testLegacyOverviewDecodesWithProjectAndRowDefaults() throws {
        let payload = """
            {
              "workspaces": [{
                "id": "workspace-1",
                "projectID": "project-1",
                "projectName": "Project",
                "title": "Main",
                "dir": "/repo",
                "isRunning": false,
                "isArchived": false,
                "isHidden": false,
                "isDefault": true,
                "sessionCount": 0
              }],
              "sessions": []
            }
            """.data(using: .utf8)!

        let overview = try JSONDecoder().decode(SpacesMobileOverviewPayload.self, from: payload)

        XCTAssertEqual(overview.projects, [])
        XCTAssertEqual(overview.workspaces.first?.processRows, [])
        XCTAssertEqual(overview.workspaces.first?.codingAgentRows, [])
        XCTAssertEqual(overview.workspaces.first?.terminalRows, [])
    }

    func testResponseRoundTripsMutationOutputsAndCreateOptions() throws {
        let options = SpacesMobileWorkspaceCreateOptions(
            projects: [SpacesMobileProjectSummary(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")],
            selectedProjectID: "project-1", branchOptions: ["main"])
        let response = SpacesMobileBridgeResponse(
            ok: true, message: "ok", workspaceCreateOptions: options, workspaceID: "workspace-1", sessionID: "session-1")

        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeResponse(SpacesMobileBridgeCodec.encodeResponse(response)), response)
    }

    func testWorkspaceTerminalRowRoundTripsStopAvailability() throws {
        let row = SpacesMobileWorkspaceTerminalRow(
            id: "terminal-shell", workspaceID: "workspace-1", title: "shell", workingDirectory: "/repo", sessionID: "session-1", runState: .running,
            canOpenTerminal: true, canStop: true)
        let overview = SpacesMobileOverviewPayload(
            workspaces: [
                SpacesMobileWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", title: "Feature", branch: nil, targetBranch: nil, dir: "/repo",
                    isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 1, terminalRows: [row])
            ], sessions: [])

        let decoded = try SpacesMobileBridgeCodec.decodeResponse(
            SpacesMobileBridgeCodec.encodeResponse(SpacesMobileBridgeResponse(ok: true, message: "ok", overview: overview)))

        XCTAssertEqual(decoded.overview?.workspaces.first?.terminalRows.first?.canStop, true)
    }

}

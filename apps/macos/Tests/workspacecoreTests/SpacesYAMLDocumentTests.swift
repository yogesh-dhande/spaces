import XCTest

@testable import workspacecore

final class SpacesYAMLDocumentTests: XCTestCase {
    func testDecodeDefaultsMissingKeysInAppState() throws {
        let document = try SpacesYAMLService.decode(
            """
            processes:
              - command: npm run api
            """)

        XCTAssertEqual(document.version, 1)
        XCTAssertNil(document.setupScript)
        XCTAssertNil(document.stopScript)
        XCTAssertTrue(document.ports.isEmpty)
        XCTAssertEqual(document.processes.first?.command, "npm run api")
        XCTAssertNil(document.processes.first?.name)
        XCTAssertEqual(document.processes.first?.onExit, ProcessExitAction.none)
        XCTAssertEqual(document.processes.first?.executionMode, .direct)
        XCTAssertTrue(document.browserSessions.isEmpty)
        XCTAssertTrue(document.agentLaunchers.isEmpty)
    }

    func testDecodeTreatsMissingVersionAsVersionOne() throws {
        let document = try SpacesYAMLService.decode(
            """
            ports:
              - name: API_PORT
            """)

        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.ports.map(\.name), ["API_PORT"])
    }

    func testDecodeRejectsFutureVersion() throws {
        XCTAssertThrowsError(try SpacesYAMLService.decode("version: 2\n")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported spaces.yaml version 2"))
        }
    }

    func testEncodeExportsCanonicalFieldsWithoutInternalIDs() throws {
        let project = ProjectRecord(
            id: "project-id", name: "Project", dir: "/tmp/project", isGitRepo: false, defaultBranch: nil, setupScript: "npm install",
            stopScript: "npm stop", ports: [PortDefinition(id: "port-id", name: "API_PORT")],
            processes: [ProcessTemplate(id: "process-id", name: "api", command: "npm run api", onExit: .notify, executionMode: .shell)],
            browserSessions: [BrowserSession(name: "app", url: "http://localhost:3000")],
            agentLaunchers: [AgentLauncher(name: "Codex", command: "codex")])

        let yaml = try SpacesYAMLService.encode(SpacesYAMLDocument(project: project))

        XCTAssertTrue(yaml.contains("version: 1"))
        XCTAssertTrue(yaml.contains("setup_script: npm install"))
        XCTAssertTrue(yaml.contains("stop_script: npm stop"))
        XCTAssertTrue(yaml.contains("name: API_PORT"))
        XCTAssertTrue(yaml.contains("command: npm run api"))
        XCTAssertTrue(yaml.contains("on_exit: notify"))
        XCTAssertTrue(yaml.contains("execution_mode: shell"))
        XCTAssertTrue(yaml.contains("browser_sessions:"))
        XCTAssertTrue(yaml.contains("agent_launchers:"))
        XCTAssertFalse(yaml.contains("project-id"))
        XCTAssertFalse(yaml.contains("port-id"))
        XCTAssertFalse(yaml.contains("process-id"))
    }

    func testRoundTripPreservesSupportedFields() throws {
        let original = SpacesYAMLDocument(
            setupScript: "npm install", stopScript: "npm stop", ports: [.init(name: "API_PORT")],
            processes: [.init(name: "api", command: "npm run api", onExit: .restart, executionMode: .shell)],
            browserSessions: [.init(name: "app", url: "http://localhost:3000")], agentLaunchers: [.init(name: "Codex", command: "codex")])

        let decoded = try SpacesYAMLService.decode(try SpacesYAMLService.encode(original))

        XCTAssertEqual(decoded, original)
    }
}

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
        XCTAssertTrue(document.services.isEmpty)
        XCTAssertEqual(document.processes.first?.command, "npm run api")
        XCTAssertNil(document.processes.first?.name)
        XCTAssertEqual(document.processes.first?.onExit, ProcessExitAction.none)
        XCTAssertTrue(document.browserSessions.isEmpty)
    }

    /// A spaces.yaml written before configured coding agents were removed still carries `agent_launchers:`.
    /// The decoder ignores keys it does not know, so such a file keeps importing with the rest of its
    /// configuration intact rather than failing the whole import.
    func testDecodeIgnoresRetiredAgentLaunchersKey() throws {
        let document = try SpacesYAMLService.decode(
            """
            stop_script: npm stop
            processes:
              - name: api
                command: npm run api
            agent_launchers:
              - name: Codex
                command: codex
            """)

        XCTAssertEqual(document.stopScript, "npm stop")
        XCTAssertEqual(document.processes.first?.command, "npm run api")
    }

    func testDecodeServicesList() throws {
        let document = try SpacesYAMLService.decode(
            """
            services:
              - web
              - backend
            """)

        XCTAssertEqual(document.services, ["web", "backend"])
        XCTAssertEqual(document.serviceDefinitions.map(\.name), ["web", "backend"])
    }

    func testDecodeTreatsMissingVersionAsCurrent() throws {
        let document = try SpacesYAMLService.decode(
            """
            services:
              - api
            """)

        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.services, ["api"])
    }

    func testDecodeRejectsFutureVersion() throws {
        XCTAssertThrowsError(try SpacesYAMLService.decode("version: 2\n")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported spaces.yaml version 2"))
        }
    }

    func testDecodeRejectsInvalidServiceNames() throws {
        for invalid in ["Web", "web_1", "web.api", "-web", "web-", String(repeating: "a", count: 64)] {
            XCTAssertThrowsError(try SpacesYAMLService.decode("services:\n  - \(invalid)\n"), "expected \(invalid) to be rejected") { error in
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("service name"))
            }
        }
    }

    func testEncodeExportsCanonicalFieldsWithoutInternalIDs() throws {
        let project = ProjectRecord(
            id: "project-id", name: "Project", dir: "/tmp/project", isGitRepo: false, defaultBranch: nil, setupScript: "npm install",
            stopScript: "npm stop", ports: [ServiceDefinition(id: "service-id", name: "web")],
            processes: [ProcessTemplate(id: "process-id", name: "api", command: "npm run api", onExit: .notify)],
            browserSessions: [BrowserSession(name: "app", url: "http://localhost:3000")])

        let yaml = try SpacesYAMLService.encode(SpacesYAMLDocument(project: project))

        XCTAssertTrue(yaml.contains("version: 1"))
        XCTAssertTrue(yaml.contains("setup_script: npm install"))
        XCTAssertTrue(yaml.contains("stop_script: npm stop"))
        XCTAssertTrue(yaml.contains("services:"))
        XCTAssertTrue(yaml.contains("- web"))
        XCTAssertTrue(yaml.contains("command: npm run api"))
        XCTAssertTrue(yaml.contains("on_exit: notify"))
        XCTAssertFalse(yaml.contains("execution_mode"))
        XCTAssertTrue(yaml.contains("browser_sessions:"))
        XCTAssertFalse(yaml.contains("agent_launchers"))
        XCTAssertFalse(yaml.contains("project-id"))
        XCTAssertFalse(yaml.contains("service-id"))
        XCTAssertFalse(yaml.contains("process-id"))
    }

    func testRoundTripPreservesSupportedFields() throws {
        let original = SpacesYAMLDocument(
            setupScript: "npm install", stopScript: "npm stop", services: ["web"],
            processes: [.init(name: "api", command: "npm run api", onExit: .restart)],
            browserSessions: [.init(name: "app", url: "http://localhost:3000")])

        let decoded = try SpacesYAMLService.decode(try SpacesYAMLService.encode(original))

        XCTAssertEqual(decoded, original)
    }
}

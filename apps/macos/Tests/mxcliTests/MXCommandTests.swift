import ArgumentParser
import XCTest
@testable import mxcli

final class MXCommandTests: XCTestCase {
    func testWorkspaceUpParsesLeafCommandOptions() throws {
        let command = try WorkspaceUpCommand.parse(["--dir", "/tmp/worktree", "--force-restart", "--focus", "frontend", "--tooltip", "Ready"])

        XCTAssertEqual(command.dir, "/tmp/worktree")
        XCTAssertTrue(command.forceRestart)
        XCTAssertEqual(command.focus, "frontend")
        XCTAssertEqual(command.tooltip, "Ready")
    }

    func testAgentEventParsesTypedEnums() throws {
        let command = try AgentEventCommand.parse(["--type", "waiting", "--provider", "ghostty"])

        XCTAssertEqual(command.type, .waiting)
        XCTAssertEqual(command.provider, .ghostty)
    }

    func testAgentEventRejectsUnknownEnumValue() {
        XCTAssertThrowsError(try AgentEventCommand.parse(["--type", "bogus"])) { error in
            let rendered = String(describing: error)
            XCTAssertTrue(rendered.contains("bogus") || rendered.contains("waiting"))
        }
    }

    func testRootRejectsRemovedJSONFlag() {
        XCTAssertThrowsError(try MXCommand.parseAsRoot(["--json", "workspace", "import"])) { error in
            XCTAssertTrue(String(describing: error).contains("no longer supported"))
        }
    }

    func testRemovedDashboardCommandReportsExplicitError() throws {
        let command = try DashboardRemovedCommand.parse([])

        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertTrue(String(describing: error).contains("removed with the Tauri proof of concept"))
        }
    }
}

import ArgumentParser
import XCTest
@testable import mxcli

final class MXCommandTests: XCTestCase {
    func testWorkspaceUpParsesLeafCommandOptions() throws {
        let command = try WorkspaceUpCommand.parse(["/tmp/worktree", "--restart", "--focus", "frontend"])

        XCTAssertEqual(command.path, "/tmp/worktree")
        XCTAssertTrue(command.restart)
        XCTAssertEqual(command.focus, "frontend")
    }

    func testWorkspaceUpdateRequiresMutationFlag() {
        XCTAssertThrowsError(try WorkspaceUpdateCommand.parse([])) { error in
            XCTAssertTrue(String(describing: error).contains("at least one field"))
        }
    }

    func testWorkspaceUpdateParsesPathAndMetadata() throws {
        let command = try WorkspaceUpdateCommand.parse(["/tmp/worktree", "--title", "Title", "--tooltip", "Summary"])

        XCTAssertEqual(command.path, "/tmp/worktree")
        XCTAssertEqual(command.title, "Title")
        XCTAssertEqual(command.tooltip, "Summary")
    }

    func testAgentEventParsesTypedEnums() throws {
        let command = try AgentEventCommand.parse(["--type", "waiting", "/tmp/worktree"])

        XCTAssertEqual(command.type, .waiting)
        XCTAssertEqual(command.path, "/tmp/worktree")
    }

    func testAgentEventRejectsUnknownEnumValue() {
        XCTAssertThrowsError(try AgentEventCommand.parse(["--type", "bogus"])) { error in
            let rendered = String(describing: error)
            XCTAssertTrue(rendered.contains("bogus") || rendered.contains("waiting"))
        }
    }
}

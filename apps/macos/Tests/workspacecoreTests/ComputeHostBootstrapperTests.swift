import XCTest

@testable import workspacecore

final class ComputeHostBootstrapperTests: XCTestCase {
    func testStartSpacesDaemonRunsSSHWithConfiguredUserAndPort() throws {
        let host = makeHost(sshUser: "runner", sshPort: 2222)
        let capture = CommandCapture()
        let bootstrapper = ComputeHostBootstrapper { command, _ in
            capture.command = command
            return """
                fingerprint=SHA256:abc123
                workspace_root=/Users/runner/.spaces/workspaces
                port=7445
                pid=42
                log=/Users/runner/.spaces/compute-hosts/lab-mac/spacesd-7445.log

                """
        }

        let outcome = try bootstrapper.startSpacesDaemon(host: host, authToken: "secret")
        let capturedCommand = capture.command

        XCTAssertEqual(outcome.certificateFingerprint, "SHA256:abc123")
        XCTAssertEqual(outcome.workspaceRoot, "/Users/runner/.spaces/workspaces")
        XCTAssertEqual(outcome.daemonHost, "lab-mac.local")
        XCTAssertEqual(outcome.daemonPort, 7445)
        XCTAssertEqual(outcome.processID, 42)
        XCTAssertEqual(capturedCommand.first, "ssh")
        XCTAssertTrue(capturedCommand.contains("BatchMode=yes"))
        XCTAssertTrue(capturedCommand.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(capturedCommand.contains("2222"))
        XCTAssertTrue(capturedCommand.contains("runner@lab-mac.local"))
        XCTAssertTrue(capturedCommand.last?.contains("requested_port=7443") == true)
        XCTAssertTrue(capturedCommand.last?.contains("SPACESD_LISTEN_PORT=\"${selected_port}\"") == true)
        XCTAssertTrue(capturedCommand.last?.contains("SPACESD_AUTH_TOKEN='secret'") == true)
    }

    func testStartSpacesDaemonFromDraftSelectsAvailablePortRange() throws {
        let capture = CommandCapture()
        let bootstrapper = ComputeHostBootstrapper { command, _ in
            capture.command = command
            return """
                fingerprint=SHA256:def456
                workspace_root=/Users/runner/workspaces
                port=7446
                pid=84
                log=/Users/runner/.spaces/compute-hosts/lab-mac/spacesd-7446.log

                """
        }

        let result = try bootstrapper.startSpacesDaemon(
            draft: ComputeHostDraft(host: "builder", sshUser: "runner", displayName: "Lab Mac", sshPort: 2222),
            resolvedSSH: SSHResolvedConfiguration(hostname: "10.0.0.42"), authToken: "secret")
        let capturedCommand = capture.command
        let script = capturedCommand.last ?? ""

        XCTAssertEqual(result.authToken, "secret")
        XCTAssertEqual(result.host.id, "lab-mac")
        XCTAssertEqual(result.host.workspaceRoot, "/Users/runner/workspaces")
        XCTAssertEqual(result.host.daemonEndpoint.host, "10.0.0.42")
        XCTAssertEqual(result.host.daemonEndpoint.port, 7446)
        XCTAssertEqual(result.outcome.daemonPort, 7446)
        XCTAssertTrue(capturedCommand.contains("runner@builder"))
        XCTAssertTrue(script.contains("last_port=$((requested_port + 9))"))
        XCTAssertTrue(script.contains("port_candidate=\"${requested_port}\""))
        XCTAssertTrue(script.contains("No available spacesd port found"))
    }

    func testRemoteStartScriptCreatesStablePerHostProfile() {
        let script = ComputeHostBootstrapper.remoteStartScript(host: makeHost(id: "Lab Mac!"), authToken: "a'b")

        XCTAssertTrue(script.contains(".spaces/compute-hosts/lab-mac"))
        XCTAssertTrue(script.contains("workspace_root_input='/tmp/spaces remote'"))
        XCTAssertTrue(script.contains("printf 'workspace_root=%s"))
        XCTAssertTrue(script.contains("printf 'port=%s"))
        XCTAssertTrue(script.contains("SPACESD_AUTH_TOKEN='a'\"'\"'b'"))
        XCTAssertTrue(script.contains("command -v spacesd"))
    }

    func testParseBootstrapOutputIncludesSelectedPortAndWorkspaceRoot() throws {
        let outcome = try ComputeHostBootstrapper.parseBootstrapOutput(
            "fingerprint=SHA256:abc123\nworkspace_root=/Users/runner/.spaces/workspaces\nport=7444\npid=42\nlog=/tmp/spacesd.log\n")

        XCTAssertEqual(outcome.certificateFingerprint, "SHA256:abc123")
        XCTAssertEqual(outcome.workspaceRoot, "/Users/runner/.spaces/workspaces")
        XCTAssertEqual(outcome.daemonPort, 7444)
        XCTAssertEqual(outcome.processID, 42)
        XCTAssertEqual(outcome.logPath, "/tmp/spacesd.log")
    }

    func testParseBootstrapOutputRequiresFingerprint() {
        XCTAssertThrowsError(try ComputeHostBootstrapper.parseBootstrapOutput("pid=42\n")) { error in
            XCTAssertEqual(error as? ComputeHostBootstrapError, .invalidBootstrapOutput("pid=42"))
        }
    }

    func testGeneratedAuthTokenIsURLSafe() {
        let token = ComputeHostCredentialStore.generateAuthToken()

        XCTAssertGreaterThanOrEqual(token.count, 22)
        XCTAssertNil(token.range(of: "[+/=]", options: .regularExpression))
    }

    private func makeHost(id: String = "lab-mac", sshUser: String? = nil, sshPort: Int? = nil) -> ComputeHostRecord {
        ComputeHostRecord(
            id: id, name: "Lab Mac", sshHost: "lab-mac.local", sshUser: sshUser, sshPort: sshPort, workspaceRoot: "/tmp/spaces remote",
            daemonEndpoint: SpacesDaemonEndpoint(host: "lab-mac.local", port: 7443, certificateFingerprint: "SHA256:abc123"),
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    }
}

private final class CommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommand: [String] = []

    var command: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedCommand
        }
        set {
            lock.lock()
            storedCommand = newValue
            lock.unlock()
        }
    }
}

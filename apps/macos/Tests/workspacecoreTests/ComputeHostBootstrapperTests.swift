import XCTest

@testable import workspacecore

final class ComputeHostBootstrapperTests: XCTestCase {
    func testStartSpacesDaemonRunsSSHWithConfiguredUserAndPort() throws {
        let host = makeHost(sshUser: "runner", sshPort: 2222)
        let capture = CommandCapture()
        let bootstrapper = ComputeHostBootstrapper { command, standardInput, _ in
            capture.command = command
            capture.standardInput = standardInput
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
        XCTAssertTrue(capturedCommand.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(capturedCommand.contains("2222"))
        XCTAssertTrue(capturedCommand.contains("runner@lab-mac.local"))
        XCTAssertEqual(capturedCommand.suffix(1), ["sh -c 'IFS= read -r spacesd_auth_token; export spacesd_auth_token; exec bash -s'"])
        XCTAssertFalse(capturedCommand.contains { $0.contains("secret") })
        XCTAssertTrue(capture.standardInput.hasPrefix("secret\n"))
        XCTAssertTrue(capture.standardInput.contains("requested_port=7443"))
        XCTAssertTrue(capture.standardInput.contains("SPACESD_LISTEN_PORT=\"${selected_port}\""))
        XCTAssertTrue(capture.standardInput.contains("SPACESD_AUTH_TOKEN=\"${spacesd_auth_token}\""))
    }

    func testStartSpacesDaemonFromDraftSelectsAvailablePortRange() throws {
        let capture = CommandCapture()
        let bootstrapper = ComputeHostBootstrapper { command, standardInput, _ in
            capture.command = command
            capture.standardInput = standardInput
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

        XCTAssertEqual(result.authToken, "secret")
        XCTAssertEqual(result.host.id, "lab-mac")
        XCTAssertEqual(result.host.workspaceRoot, "/Users/runner/workspaces")
        XCTAssertEqual(result.host.daemonEndpoint.host, "10.0.0.42")
        XCTAssertEqual(result.host.daemonEndpoint.port, 7446)
        XCTAssertEqual(result.outcome.daemonPort, 7446)
        XCTAssertTrue(capturedCommand.contains("runner@builder"))
        XCTAssertEqual(capturedCommand.suffix(1), ["sh -c 'IFS= read -r spacesd_auth_token; export spacesd_auth_token; exec bash -s'"])
        XCTAssertTrue(capture.standardInput.contains("last_port=$((requested_port + 9))"))
        XCTAssertTrue(capture.standardInput.contains("port_candidate=\"${requested_port}\""))
        XCTAssertTrue(capture.standardInput.contains("No available spacesd port found"))
    }

    func testRemoteStartScriptCreatesStablePerHostProfile() {
        let script = ComputeHostBootstrapper.remoteStartScript(host: makeHost(id: "Lab Mac!"))

        XCTAssertTrue(script.contains(".spaces/compute-hosts/lab-mac"))
        XCTAssertTrue(script.contains("workspace_root_input='/tmp/spaces remote'"))
        XCTAssertTrue(script.contains("printf 'workspace_root=%s"))
        XCTAssertTrue(script.contains("printf 'port=%s"))
        XCTAssertTrue(script.contains("SPACESD_AUTH_TOKEN=\"${spacesd_auth_token}\""))
        XCTAssertTrue(script.contains("command -v spacesd"))
        XCTAssertTrue(script.contains("while [ \"${ready_attempt}\" -lt 100 ]"))
        XCTAssertTrue(script.contains("spacesd did not start listening on port"))
    }

    func testRemoteStartScriptCanCleanExistingProfileAndPort() {
        let script = ComputeHostBootstrapper.remoteStartScript(host: makeHost(id: "E2E Remote"), cleanExistingProfile: true)

        XCTAssertTrue(script.contains("port_pids=\"$(\"${lsof_path}\" -tiTCP:${requested_port} -sTCP:LISTEN"))
        XCTAssertTrue(script.contains("remote E2E cleanup could not free spacesd port ${requested_port}."))
        XCTAssertTrue(script.contains("rm -rf \"${profile_root}\""))
        XCTAssertTrue(script.contains(".spaces/compute-hosts/e2e-remote"))
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
    private var storedStandardInput = ""

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

    var standardInput: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedStandardInput
        }
        set {
            lock.lock()
            storedStandardInput = newValue
            lock.unlock()
        }
    }
}

import XCTest

@testable import workspacecore

final class ComputeHostBootstrapperTests: XCTestCase {
    func testStartSpacesDaemonRunsSSHWithConfiguredUserAndPort() throws {
        let host = makeHost(sshUser: "runner", sshPort: 2222)
        let capture = CommandCapture()
        let bootstrapper = ComputeHostBootstrapper { command, standardInput, _ in
            let call = capture.append(command: command, standardInput: standardInput)
            switch call {
            case 1: return Self.macosProbeOutput
            case 2: return "preflight=ok\n"
            default:
                return """
                    fingerprint=SHA256:abc123
                    workspace_root=/Users/runner/.spaces/workspaces
                    port=7445
                    pid=42
                    log=/Users/runner/.spaces/compute-hosts/lab-mac/spacesd-7445.log

                    """
            }
        } artifactManifestProvider: {
            Self.fakeManifest
        }

        let outcome = try bootstrapper.startSpacesDaemon(host: host, authToken: "secret")
        let capturedCommand = try XCTUnwrap(capture.commands.last)
        let capturedInput = try XCTUnwrap(capture.standardInputs.last)

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
        XCTAssertTrue(capturedInput.hasPrefix("secret\n"))
        XCTAssertTrue(capturedInput.contains("requested_port=7443"))
        XCTAssertTrue(capturedInput.contains("archive_url='https://example.com/spacesd-macos-universal.tar.gz'"))
        XCTAssertTrue(capturedInput.contains("spacesd_path=\"${daemon_root}/bin/spacesd\""))
        XCTAssertTrue(capturedInput.contains("pid_path=\"${runtime_root}/spacesd.pid\""))
        XCTAssertTrue(capturedInput.contains("printf '%s\\n' \"${daemon_pid}\" > \"${pid_path}\""))
        XCTAssertTrue(capturedInput.contains("SPACESD_LISTEN_PORT=\"${selected_port}\""))
        XCTAssertTrue(capturedInput.contains("SPACESD_AUTH_TOKEN=\"${spacesd_auth_token}\""))
        XCTAssertTrue(capturedInput.contains("fail portAvailability \"lsof -nPiTCP:${selected_port} -sTCP:LISTEN\""))
        XCTAssertFalse(capturedInput.contains("kill -TERM"))
        XCTAssertFalse(capturedInput.contains("command -v spacesd"))
        XCTAssertFalse(capturedInput.contains("${HOME}/bin/spacesd"))
    }

    func testStartSpacesDaemonUsesLongerTimeoutForArtifactInstall() throws {
        let capture = CommandCapture()
        let bootstrapper = ComputeHostBootstrapper { command, standardInput, timeout in
            let call = capture.append(command: command, standardInput: standardInput, timeout: timeout)
            switch call {
            case 1: return Self.macosProbeOutput
            case 2: return "preflight=ok\n"
            default:
                return """
                    fingerprint=SHA256:abc123
                    workspace_root=/Users/runner/.spaces/workspaces
                    port=7445
                    pid=42
                    log=/Users/runner/.spaces/compute-hosts/lab-mac/spacesd-7445.log

                    """
            }
        } artifactManifestProvider: {
            Self.fakeManifest
        }

        _ = try bootstrapper.startSpacesDaemon(host: makeHost(), authToken: "secret", timeout: 30)

        XCTAssertEqual(capture.timeouts, [30, 30, 300])
    }

    func testStartSpacesDaemonFromDraftSelectsAvailablePortRange() throws {
        let capture = CommandCapture()
        let bootstrapper = ComputeHostBootstrapper { command, standardInput, _ in
            let call = capture.append(command: command, standardInput: standardInput)
            switch call {
            case 1: return Self.macosProbeOutput
            case 2: return "preflight=ok\n"
            default:
                return """
                    fingerprint=SHA256:def456
                    workspace_root=/Users/runner/workspaces
                    port=7446
                    pid=84
                    log=/Users/runner/.spaces/compute-hosts/lab-mac/spacesd-7446.log

                    """
            }
        } artifactManifestProvider: {
            Self.fakeManifest
        }

        let result = try bootstrapper.startSpacesDaemon(
            draft: ComputeHostDraft(host: "builder", sshUser: "runner", displayName: "Lab Mac", sshPort: 2222),
            resolvedSSH: SSHResolvedConfiguration(hostname: "10.0.0.42"), authToken: "secret")
        let capturedCommand = try XCTUnwrap(capture.commands.last)
        let capturedInput = try XCTUnwrap(capture.standardInputs.last)

        XCTAssertEqual(result.authToken, "secret")
        XCTAssertEqual(result.host.id, "lab-mac")
        XCTAssertEqual(result.host.workspaceRoot, "/Users/runner/workspaces")
        XCTAssertEqual(result.host.daemonEndpoint.host, "10.0.0.42")
        XCTAssertEqual(result.host.daemonEndpoint.port, 7446)
        XCTAssertEqual(result.outcome.daemonPort, 7446)
        XCTAssertTrue(capturedCommand.contains("runner@builder"))
        XCTAssertEqual(capturedCommand.suffix(1), ["sh -c 'IFS= read -r spacesd_auth_token; export spacesd_auth_token; exec bash -s'"])
        XCTAssertTrue(capturedInput.contains("last_port=$((requested_port + 9))"))
        XCTAssertTrue(capturedInput.contains("port_candidate=\"${requested_port}\""))
        XCTAssertTrue(capturedInput.contains("No available spacesd port found"))
    }

    func testRemoteStartScriptCreatesStablePerHostProfile() {
        let script = ComputeHostBootstrapper.remoteStartScript(host: makeHost(id: "Lab Mac!"), artifact: Self.fakeManifest.artifacts[0])

        XCTAssertTrue(script.contains(".spaces/compute-hosts/lab-mac"))
        XCTAssertTrue(script.contains("workspace_root_input='/tmp/spaces remote'"))
        XCTAssertTrue(script.contains("printf 'workspace_root=%s"))
        XCTAssertTrue(script.contains("printf 'port=%s"))
        XCTAssertTrue(script.contains("SPACESD_AUTH_TOKEN=\"${spacesd_auth_token}\""))
        XCTAssertTrue(script.contains("archive_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'"))
        XCTAssertTrue(script.contains("release_root=\"${daemon_root}/releases/${artifact_version}\""))
        XCTAssertFalse(script.contains("command -v spacesd"))
        XCTAssertTrue(script.contains("while [ \"${ready_attempt}\" -lt 100 ]"))
        XCTAssertTrue(script.contains("spacesd did not start listening on port"))
    }

    func testRemoteStartScriptRefusesExistingListenerOnSavedPort() {
        let script = ComputeHostBootstrapper.remoteStartScript(host: makeHost(id: "Lab Mac!"), artifact: Self.fakeManifest.artifacts[0])

        XCTAssertTrue(script.contains("fail portAvailability \"lsof -nPiTCP:${selected_port} -sTCP:LISTEN\""))
        XCTAssertTrue(script.contains("Stop the listener on port ${selected_port}, then retry setup."))
        XCTAssertTrue(script.contains("Port ${selected_port} is already in use."))
        XCTAssertFalse(script.contains("kill -TERM"))
        XCTAssertFalse(script.contains("listener_command"))
    }

    func testRemoteStartScriptCanCleanExistingProfileAndPort() {
        let script = ComputeHostBootstrapper.remoteStartScript(
            host: makeHost(id: "E2E Remote"), artifact: Self.fakeManifest.artifacts[0], cleanExistingProfile: true)

        XCTAssertTrue(script.contains("rm -rf \"${profile_root}\""))
        XCTAssertTrue(script.contains(".spaces/compute-hosts/e2e-remote"))
    }

    func testUpgradeManagedSpacesDaemonRequiresSavedPortAvailable() throws {
        let capture = CommandCapture()
        let bootstrapper = ComputeHostBootstrapper { command, standardInput, _ in
            let call = capture.append(command: command, standardInput: standardInput)
            switch call {
            case 1: return Self.macosProbeOutput
            case 2: return "preflight=ok\n"
            default:
                return """
                    fingerprint=SHA256:abc123
                    workspace_root=/tmp/spaces remote
                    port=7443
                    pid=99
                    log=/Users/runner/.spaces/compute-hosts/lab-mac/spacesd-7443.log

                    """
            }
        } artifactManifestProvider: {
            Self.fakeManifest
        }

        let outcome = try bootstrapper.upgradeManagedSpacesDaemon(host: makeHost(), authToken: "secret")
        let capturedInput = try XCTUnwrap(capture.standardInputs.last)

        XCTAssertEqual(outcome.daemonPort, 7443)
        XCTAssertTrue(capturedInput.contains("fail portAvailability \"lsof -nPiTCP:${selected_port} -sTCP:LISTEN\""))
        XCTAssertTrue(capturedInput.contains("Port ${selected_port} is already in use."))
        XCTAssertFalse(capturedInput.contains("kill -TERM"))
    }

    func testRemoteUninstallScriptRemovesManagedDaemonAssetsOnly() {
        let script = ComputeHostBootstrapper.remoteUninstallScript(host: makeHost(id: "Lab Mac!"))

        XCTAssertTrue(script.contains(".spaces/compute-hosts/lab-mac"))
        XCTAssertTrue(script.contains("command -v lsof"))
        XCTAssertTrue(script.contains("lsof -nPiTCP:${daemon_port} -sTCP:LISTEN"))
        XCTAssertTrue(script.contains("rm -rf \"${daemon_root}\" \"${profile_root}/uploads\""))
        XCTAssertTrue(script.contains("rm -f \"${profile_root}/bin/spaces\" \"${pid_path}\""))
        XCTAssertFalse(script.contains("workspace_root"))
        XCTAssertFalse(script.contains(".spaces/workspaces"))
    }

    func testUnsupportedPlatformProducesSetupChecklist() throws {
        let host = makeHost()
        let bootstrapper = ComputeHostBootstrapper { _, standardInput, _ in
            if standardInput.contains("uname -s") { return "os=Linux\narch=riscv64\nlinux_id=ubuntu\nlinux_version_id=24.04\n" }
            return ""
        } artifactManifestProvider: {
            Self.fakeManifest
        }

        XCTAssertThrowsError(try bootstrapper.startSpacesDaemon(host: host, authToken: "secret")) { error in
            guard let setupError = error as? ComputeHostSetupError else {
                XCTFail("Expected ComputeHostSetupError, got \(error)")
                return
            }
            XCTAssertTrue(setupError.checklist.shouldShow)
            let failed = setupError.checklist.rows.first { $0.status == .failed }
            XCTAssertEqual(failed?.checkID, .supportedPlatform)
            XCTAssertTrue(failed?.detail.contains("not supported") == true)
        }
    }

    func testPreflightFailureProducesExactFailedCommandAndFix() throws {
        let host = makeHost()
        let bootstrapper = ComputeHostBootstrapper { _, standardInput, _ in
            if standardInput.contains("uname -s") { return Self.macosProbeOutput }
            if standardInput.contains("preflight=ok") {
                throw ComputeHostBootstrapError.sshCommandFailed(
                    """
                    SPACES_SETUP_FAILED_CHECK=requiredTools
                    SPACES_SETUP_FAILED_COMMAND=command -v curl
                    SPACES_SETUP_FAILED_FIX=Install curl on the remote host.
                    curl is required on the remote host.
                    """)
            }
            return ""
        } artifactManifestProvider: {
            Self.fakeManifest
        }

        XCTAssertThrowsError(try bootstrapper.startSpacesDaemon(host: host, authToken: "secret")) { error in
            guard let setupError = error as? ComputeHostSetupError else {
                XCTFail("Expected ComputeHostSetupError, got \(error)")
                return
            }
            let failed = setupError.checklist.rows.first { $0.status == .failed }
            XCTAssertEqual(failed?.checkID, .requiredTools)
            XCTAssertEqual(failed?.command, "command -v curl")
            XCTAssertEqual(failed?.fixHint, "Install curl on the remote host.")
            XCTAssertTrue(setupError.checklist.diagnosticsText.contains("curl is required"))
        }
    }

    func testManifestFailureLeavesRemotePreflightChecksPending() throws {
        let checklist = ComputeHostSetupChecklistBuilder.failure(
            host: makeHost(), failedCheck: .artifactManifest, command: "Open release", detail: "Manifest unavailable.", fixHint: nil)

        XCTAssertEqual(status(of: .sshAccess, in: checklist), .passed)
        XCTAssertEqual(status(of: .supportedPlatform, in: checklist), .passed)
        XCTAssertEqual(status(of: .artifactManifest, in: checklist), .failed)
        XCTAssertEqual(status(of: .requiredTools, in: checklist), .pending)
        XCTAssertEqual(status(of: .writableInstallRoot, in: checklist), .pending)
        XCTAssertEqual(status(of: .gitAvailable, in: checklist), .pending)
        XCTAssertEqual(status(of: .gitAuthentication, in: checklist), .pending)
    }

    func testCertificateFingerprintFailureLeavesPortAndDaemonLaunchPending() throws {
        let checklist = ComputeHostSetupChecklistBuilder.failure(
            host: makeHost(), failedCheck: .certificateFingerprint, command: "spacesd --print-fingerprint",
            detail: "spacesd did not print a certificate fingerprint.", fixHint: nil)

        XCTAssertEqual(status(of: .internalChecksums, in: checklist), .passed)
        XCTAssertEqual(status(of: .certificateFingerprint, in: checklist), .failed)
        XCTAssertEqual(status(of: .portAvailability, in: checklist), .pending)
        XCTAssertEqual(status(of: .daemonLaunch, in: checklist), .pending)
    }

    func testStartSpacesDaemonParsesSetupFailureFromRemoteStartScript() throws {
        let host = makeHost()
        let bootstrapper = makeBootstrapperThatFailsRemoteStart()

        assertRemoteStartSetupFailure(try bootstrapper.startSpacesDaemon(host: host, authToken: "secret"))
    }

    func testUpgradeManagedSpacesDaemonParsesSetupFailureFromRemoteStartScript() throws {
        let host = makeHost()
        let bootstrapper = makeBootstrapperThatFailsRemoteStart()

        assertRemoteStartSetupFailure(try bootstrapper.upgradeManagedSpacesDaemon(host: host, authToken: "secret"))
    }

    func testDraftStartParsesSetupFailureFromRemoteStartScript() throws {
        let bootstrapper = makeBootstrapperThatFailsRemoteStart()

        assertRemoteStartSetupFailure(
            try bootstrapper.startSpacesDaemon(
                draft: ComputeHostDraft(host: "builder", sshUser: "runner", displayName: "Lab Mac"), authToken: "secret"))
    }

    func testArtifactManifestFailurePointsToReleasePage() throws {
        let host = makeHost()
        let bootstrapper = ComputeHostBootstrapper { _, standardInput, _ in
            if standardInput.contains("uname -s") { return Self.macosProbeOutput }
            return ""
        } artifactManifestProvider: {
            throw RemoteSpacesArtifactError.invalidManifestURL("https://github.com/example")
        }

        XCTAssertThrowsError(try bootstrapper.startSpacesDaemon(host: host, authToken: "secret")) { error in
            guard let setupError = error as? ComputeHostSetupError else {
                XCTFail("Expected ComputeHostSetupError, got \(error)")
                return
            }
            let failed = setupError.checklist.rows.first { $0.status == .failed }
            XCTAssertEqual(failed?.checkID, .artifactManifest)
            XCTAssertEqual(failed?.command, "Open https://github.com/yogesh-dhande/spaces/releases/tag/v\(AppVersion.current)")
            XCTAssertTrue(failed?.detail.contains("https://github.com/yogesh-dhande/spaces/releases/tag/v\(AppVersion.current)") == true)
            XCTAssertTrue(failed?.fixHint?.contains("https://github.com/yogesh-dhande/spaces/releases/tag/v\(AppVersion.current)") == true)
        }
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

    private func makeBootstrapperThatFailsRemoteStart() -> ComputeHostBootstrapper {
        ComputeHostBootstrapper { _, standardInput, _ in
            if standardInput.contains("uname -s") { return Self.macosProbeOutput }
            if standardInput.contains("preflight=ok") { return "preflight=ok\n" }
            throw ComputeHostBootstrapError.sshCommandFailed(Self.remoteStartSetupFailure)
        } artifactManifestProvider: {
            Self.fakeManifest
        }
    }

    private func assertRemoteStartSetupFailure<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let setupError = error as? ComputeHostSetupError else {
                XCTFail("Expected ComputeHostSetupError, got \(error)", file: file, line: line)
                return
            }
            let failed = setupError.checklist.rows.first { $0.status == .failed }
            XCTAssertEqual(failed?.checkID, .archiveChecksum, file: file, line: line)
            XCTAssertEqual(failed?.command, "curl -fL https://example.com/spacesd.tar.gz", file: file, line: line)
            XCTAssertEqual(failed?.fixHint, "Confirm the release asset is reachable from the remote host.", file: file, line: line)
            XCTAssertTrue(setupError.checklist.diagnosticsText.contains("Could not download the selected spacesd archive."), file: file, line: line)
        }
    }

    private func status(of checkID: ComputeHostSetupCheckID, in checklist: ComputeHostSetupChecklist) -> ComputeHostSetupCheckStatus? {
        checklist.rows.first { $0.checkID == checkID }?.status
    }

    private static let macosProbeOutput = "os=Darwin\narch=arm64\nmacos_version=14.5\n"

    private static let remoteStartSetupFailure = """
        SPACES_SETUP_FAILED_CHECK=archiveChecksum
        SPACES_SETUP_FAILED_COMMAND=curl -fL https://example.com/spacesd.tar.gz
        SPACES_SETUP_FAILED_FIX=Confirm the release asset is reachable from the remote host.
        Could not download the selected spacesd archive.
        """

    private static let fakeManifest = RemoteSpacesArtifactManifest(
        appVersion: AppVersion.current, releaseTag: "v\(AppVersion.current)",
        artifacts: [
            RemoteSpacesArtifact(
                id: "spacesd-macos-universal", version: AppVersion.current, platform: "macos", architecture: "universal",
                archiveName: "spacesd-macos-universal.tar.gz", url: "https://example.com/spacesd-macos-universal.tar.gz",
                sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        ])
}

private final class CommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommands: [[String]] = []
    private var storedStandardInputs: [String] = []
    private var storedTimeouts: [TimeInterval] = []

    @discardableResult func append(command: [String], standardInput: String, timeout: TimeInterval? = nil) -> Int {
        lock.lock()
        storedCommands.append(command)
        storedStandardInputs.append(standardInput)
        if let timeout { storedTimeouts.append(timeout) }
        let count = storedCommands.count
        lock.unlock()
        return count
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedCommands
    }

    var standardInputs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedStandardInputs
    }

    var timeouts: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storedTimeouts
    }
}

import XCTest

@testable import workspacecore

final class ComputeHostDraftTests: XCTestCase {
    func testPrepareDraftGeneratesHiddenRecordValues() throws {
        let prepared = try ComputeHostDraftBuilder.prepare(
            draft: ComputeHostDraft(host: "builder", displayName: "Lab Mac"),
            resolvedSSH: SSHResolvedConfiguration(hostname: "10.0.0.42", user: "runner", port: 2222), authToken: "token-123",
            now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(prepared.authToken, "token-123")
        XCTAssertEqual(prepared.host.id, "lab-mac")
        XCTAssertEqual(prepared.host.name, "Lab Mac")
        XCTAssertEqual(prepared.host.sshHost, "builder")
        XCTAssertEqual(prepared.host.sshUser, "runner")
        XCTAssertEqual(prepared.host.sshPort, 2222)
        XCTAssertEqual(prepared.host.workspaceRoot, ComputeHostDraftBuilder.defaultWorkspaceRoot)
        XCTAssertEqual(prepared.host.daemonEndpoint.host, "10.0.0.42")
        XCTAssertEqual(prepared.host.daemonEndpoint.port, ComputeHostDraftBuilder.defaultDaemonPort)
        XCTAssertEqual(prepared.host.daemonEndpoint.certificateFingerprint, "")
    }

    func testPrepareDraftUsesResolvedHostForIDWhenDisplayNameIsBlank() throws {
        let prepared = try ComputeHostDraftBuilder.prepare(
            draft: ComputeHostDraft(host: "builder"), resolvedSSH: SSHResolvedConfiguration(hostname: "builder.internal"), authToken: "token-123",
            now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(prepared.host.id, "builder-internal")
        XCTAssertEqual(prepared.host.name, "builder")
    }

    func testReachabilityErrorExplainsDirectNetworkRequirement() {
        let error = ComputeHostReachabilityError(host: "10.0.0.42", port: 7443, underlyingDescription: "connection refused")
        let message = error.errorDescription ?? ""

        XCTAssertTrue(message.contains("started over SSH"))
        XCTAssertTrue(message.contains("could not reach 10.0.0.42:7443 directly"))
        XCTAssertTrue(message.contains("VPN"))
        XCTAssertTrue(message.contains("firewall"))
        XCTAssertTrue(message.contains("cloud security group"))
    }
}

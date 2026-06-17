import Testing
import workspacecore

@testable import spacesui

@MainActor @Suite struct ComputeHostUITests {
    @Test func computeHostIDCandidateUsesNameBeforeEndpointFields() {
        #expect(AppKitController.computeHostIDCandidate(name: "Lab Mac", sshHost: "ssh.local", daemonHost: "daemon.local") == "lab-mac")
    }

    @Test func computeHostIDCandidateFallsBackToDaemonHost() {
        #expect(AppKitController.computeHostIDCandidate(name: "  ", sshHost: nil, daemonHost: "Remote Host.local") == "remote-host-local")
    }

    @Test func setupChecklistIsHiddenWhenNoChecksFail() {
        let checklist = ComputeHostSetupChecklistBuilder.success(host: makeHost())

        #expect(checklist.shouldShow == false)
        #expect(checklist.rows.isEmpty)
    }

    @Test func setupChecklistIncludesFailedCommandAndFixHint() throws {
        let host = makeHost()
        let checklist = ComputeHostSetupChecklistBuilder.failure(
            host: host, failedCheck: .requiredTools, command: "command -v curl", detail: "curl is required on builder.local.",
            fixHint: "Install curl on builder.local.")

        let failed = try #require(checklist.rows.first { $0.status == .failed })
        #expect(checklist.shouldShow)
        #expect(failed.checkID == .requiredTools)
        #expect(failed.command == "command -v curl")
        #expect(failed.fixHint == "Install curl on builder.local.")
        #expect(checklist.diagnosticsText.contains("builder.local"))
        #expect(checklist.diagnosticsText.contains("command -v curl"))
    }

    @Test func savedRemoteHostsExcludesLocalHost() {
        let hosts = [ComputeHostRecord.local(), makeHost()]

        #expect(AppKitController.savedRemoteHosts(hosts).map(\.id) == ["builder"])
    }

    private func makeHost() -> ComputeHostRecord {
        ComputeHostRecord(
            id: "builder", name: "Builder", sshHost: "builder.local", sshUser: "runner", sshPort: 2222, workspaceRoot: "$HOME/.spaces/workspaces",
            daemonEndpoint: SpacesDaemonEndpoint(host: "builder.local", port: 7443, certificateFingerprint: "SHA256:abc"),
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    }
}

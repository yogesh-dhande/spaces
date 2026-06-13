import Testing

@testable import spacesui

@MainActor @Suite struct ComputeHostUITests {
    @Test func computeHostIDCandidateUsesNameBeforeEndpointFields() {
        #expect(AppKitController.computeHostIDCandidate(name: "Lab Mac", sshHost: "ssh.local", daemonHost: "daemon.local") == "lab-mac")
    }

    @Test func computeHostIDCandidateFallsBackToDaemonHost() {
        #expect(AppKitController.computeHostIDCandidate(name: "  ", sshHost: nil, daemonHost: "Remote Host.local") == "remote-host-local")
    }
}

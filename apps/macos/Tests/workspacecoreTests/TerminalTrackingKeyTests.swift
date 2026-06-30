import Testing
import systembridge

@testable import workspacecore

@Suite struct TerminalTrackingKeyTests {
    @Test func runningProcessFocusIdentityPrefersNativeSessionID() {
        let record = RunningProcessRecord(
            id: "process-1", workspaceID: "workspace-1", templateName: "frontend", command: "npm run dev", terminalApp: TerminalHost.spaces.appName,
            terminalTrackingID: nil, terminalNativeID: "native-session-1", pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "now", exitedAt: nil)

        #expect(record.terminalFocusIdentity == .session("native-session-1"))
        #expect(record.terminalTrackingIdentity == .session("native-session-1"))
    }

    @Test func windowFocusIdentityPrefersNativeSessionID() {
        let record = WindowRecord(
            id: "window-1", workspaceID: "workspace-1", app: TerminalHost.spaces.appName, name: "frontend", detail: "npm run dev", targetURL: nil,
            windowID: 101, terminalTrackingID: nil, terminalNativeID: "native-session-2", role: "terminal", orderIndex: 0, lastSeenAt: "now")

        #expect(record.terminalFocusIdentity == .session("native-session-2"))
        #expect(record.terminalTrackingIdentity == .session("native-session-2"))
    }

    @Test func agentFocusIdentityPrefersNativeSessionID() {
        let record = AgentWindowRecord(
            id: "agent-1", workspaceID: "workspace-1", provider: .spaces, label: "Claude", terminalTrackingID: nil,
            terminalNativeID: "native-session-3", codexThreadID: nil, status: .waiting, createdAt: "now",
            updatedAt: "now")

        #expect(record.terminalFocusIdentity == TerminalTrackingIdentity.session("native-session-3"))
        #expect(record.terminalTrackingIdentity == TerminalTrackingIdentity.session("native-session-3"))
    }
}

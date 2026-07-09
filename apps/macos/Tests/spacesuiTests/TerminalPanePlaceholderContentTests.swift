import Testing
import spacesterminalcore

@testable import spacesui

@MainActor @Suite struct TerminalPanePlaceholderContentTests {
    @Test func placeholderRecordsOwnerRequestWhileTerminalContentIsPreparing() {
        let request = AppKitController.DeviceTerminalOpenRequest(
            workspaceID: "workspace-1", deviceID: "device-1", sessionID: "session-1", title: "shell", workingDirectory: "/tmp/work", kind: .shell)
        let placeholder = TerminalPanePlaceholderContentController(request: request, deviceID: "device-1")

        #expect(!placeholder.debugStateDump().takeoverPending)

        placeholder.requestOwnershipIfNeeded()

        #expect(placeholder.debugStateDump().takeoverPending)
    }
}

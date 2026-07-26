import Foundation
import Testing

@testable import spacesui

@Suite struct PanelWindowRestoreTests {
    private func pane(_ id: String, deviceID: String = "device") -> Pane {
        Pane(id: id, content: .terminalSession(deviceID: deviceID, sessionID: "sess-\(id)"))
    }

    private func layoutJSON(_ layout: PanelLayout) throws -> String { String(decoding: try JSONEncoder().encode(layout), as: UTF8.self) }

    @Test func waitsUntilEveryReferencedDeviceIsLoaded() throws {
        var layout = PanelLayoutEngine.appendTab(tabID: "tab-1", pane: pane("a", deviceID: "local"), to: PanelLayout())
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b", deviceID: "remote"), to: layout)
        let json = try layoutJSON(layout)
        #expect(
            AppKitController.panelWindowRestoreDecision(layoutJSON: json, loadedDeviceIDs: ["local"], retainedSessionIDs: ["sess-a", "sess-b"])
                == .waitForDevices)
        #expect(
            AppKitController.panelWindowRestoreDecision(
                layoutJSON: json, loadedDeviceIDs: ["local", "remote"], retainedSessionIDs: ["sess-a", "sess-b"]) == .open(layout))
    }

    @Test func skipsUnreadableAndFutureVersionRows() {
        #expect(AppKitController.panelWindowRestoreDecision(layoutJSON: "not json", loadedDeviceIDs: ["local"], retainedSessionIDs: []) == .skip)
        #expect(
            AppKitController.panelWindowRestoreDecision(layoutJSON: #"{"version":999,"tabs":[]}"#, loadedDeviceIDs: ["local"], retainedSessionIDs: [])
                == .skip)
    }

    @Test func discardsWhenNoSessionSurvivesPruning() throws {
        let layout = PanelLayoutEngine.appendTab(tabID: "tab-1", pane: pane("a"), to: PanelLayout())
        #expect(
            AppKitController.panelWindowRestoreDecision(layoutJSON: try layoutJSON(layout), loadedDeviceIDs: ["device"], retainedSessionIDs: [])
                == .discard)
    }

    @Test func opensWithDeadSessionsPruned() throws {
        var layout = PanelLayoutEngine.appendTab(tabID: "tab-1", pane: pane("a"), to: PanelLayout())
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b"), to: layout)
        let decision = AppKitController.panelWindowRestoreDecision(
            layoutJSON: try layoutJSON(layout), loadedDeviceIDs: ["device"], retainedSessionIDs: ["sess-b"])
        guard case .open(let restored) = decision else {
            Issue.record("expected open, got \(decision)")
            return
        }
        #expect(restored.tabs.map(\.id) == ["tab-2"])
        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: restored) == ["sess-b"])
    }
}

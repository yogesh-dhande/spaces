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
            AppKitController.panelWindowRestoreDecision(
                layoutJSON: json, loadedDeviceIDs: ["local"], retainedSessionIDs: ["sess-a", "sess-b"], retainedWorkspaceKeys: [],
                editorAlreadyOpen: false)
                == .waitForDevices)
        #expect(
            AppKitController.panelWindowRestoreDecision(
                layoutJSON: json, loadedDeviceIDs: ["local", "remote"], retainedSessionIDs: ["sess-a", "sess-b"], retainedWorkspaceKeys: [],
                editorAlreadyOpen: false)
                == .open(layout))
    }

    @Test func skipsUnreadableAndFutureVersionRows() {
        #expect(
            AppKitController.panelWindowRestoreDecision(
                layoutJSON: "not json", loadedDeviceIDs: ["local"], retainedSessionIDs: [], retainedWorkspaceKeys: [], editorAlreadyOpen: false)
                == .skip)
        #expect(
            AppKitController.panelWindowRestoreDecision(
                layoutJSON: #"{"version":999,"tabs":[]}"#, loadedDeviceIDs: ["local"], retainedSessionIDs: [], retainedWorkspaceKeys: [],
                editorAlreadyOpen: false) == .skip)
    }

    @Test func discardsWhenNoSessionSurvivesPruning() throws {
        let layout = PanelLayoutEngine.appendTab(tabID: "tab-1", pane: pane("a"), to: PanelLayout())
        #expect(
            AppKitController.panelWindowRestoreDecision(
                layoutJSON: try layoutJSON(layout), loadedDeviceIDs: ["device"], retainedSessionIDs: [], retainedWorkspaceKeys: [],
                editorAlreadyOpen: false) == .discard)
    }

    @Test func opensWithDeadSessionsPruned() throws {
        var layout = PanelLayoutEngine.appendTab(tabID: "tab-1", pane: pane("a"), to: PanelLayout())
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: pane("b"), to: layout)
        let decision = AppKitController.panelWindowRestoreDecision(
            layoutJSON: try layoutJSON(layout), loadedDeviceIDs: ["device"], retainedSessionIDs: ["sess-b"], retainedWorkspaceKeys: [],
            editorAlreadyOpen: false)
        guard case .open(let restored) = decision else {
            Issue.record("expected open, got \(decision)")
            return
        }
        #expect(restored.tabs.map(\.id) == ["tab-2"])
        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: restored) == ["sess-b"])
    }

    @Test func discardsCodePaneWhoseWorkspaceIsGone() throws {
        let codePane = Pane(id: "a", content: .codePane(deviceID: "device", workspaceID: "ws-gone"))
        let layout = PanelLayoutEngine.appendTab(tabID: "tab-1", pane: codePane, to: PanelLayout())
        #expect(
            AppKitController.panelWindowRestoreDecision(
                layoutJSON: try layoutJSON(layout), loadedDeviceIDs: ["device"], retainedSessionIDs: [], retainedWorkspaceKeys: [],
                editorAlreadyOpen: false) == .discard)
    }

    @Test func opensCodePaneWhoseWorkspaceSurvives() throws {
        let codePane = Pane(id: "a", content: .codePane(deviceID: "device", workspaceID: "ws-live"))
        let layout = PanelLayoutEngine.appendTab(tabID: "tab-1", pane: codePane, to: PanelLayout())
        let decision = AppKitController.panelWindowRestoreDecision(
            layoutJSON: try layoutJSON(layout), loadedDeviceIDs: ["device"], retainedSessionIDs: [],
            retainedWorkspaceKeys: [PanelLayoutEngine.WorkspaceKey(deviceID: "device", workspaceID: "ws-live")], editorAlreadyOpen: false)
        #expect(decision == .open(layout))
    }

    /// Regression for the offline-device race: a persisted global window carrying a code pane whose
    /// workspace is still live must still be dropped (and the whole window discarded, since it holds
    /// nothing else) when the Editor singleton is already open elsewhere — otherwise the device
    /// reconnecting after a fresh ⌘⌥E would restore a second Editor.
    @Test func discardsCodePaneWhenEditorAlreadyOpenElsewhere() throws {
        let codePane = Pane(id: "a", content: .codePane(deviceID: "device", workspaceID: "ws-live"))
        let layout = PanelLayoutEngine.appendTab(tabID: "tab-1", pane: codePane, to: PanelLayout())
        let decision = AppKitController.panelWindowRestoreDecision(
            layoutJSON: try layoutJSON(layout), loadedDeviceIDs: ["device"], retainedSessionIDs: [],
            retainedWorkspaceKeys: [PanelLayoutEngine.WorkspaceKey(deviceID: "device", workspaceID: "ws-live")], editorAlreadyOpen: true)
        #expect(decision == .discard)
    }

    /// A persisted global window mixing a terminal pane with a code pane keeps the terminal pane and
    /// drops only the code pane when the Editor is already open elsewhere, rather than discarding the
    /// whole window.
    @Test func dropsOnlyCodePaneWhenEditorAlreadyOpenAlongsideOtherPanes() throws {
        var layout = PanelLayoutEngine.appendTab(tabID: "tab-1", pane: pane("a"), to: PanelLayout())
        let codePane = Pane(id: "b", content: .codePane(deviceID: "device", workspaceID: "ws-live"))
        layout = PanelLayoutEngine.appendTab(tabID: "tab-2", pane: codePane, to: layout)
        let decision = AppKitController.panelWindowRestoreDecision(
            layoutJSON: try layoutJSON(layout), loadedDeviceIDs: ["device"], retainedSessionIDs: ["sess-a"],
            retainedWorkspaceKeys: [PanelLayoutEngine.WorkspaceKey(deviceID: "device", workspaceID: "ws-live")], editorAlreadyOpen: true)
        guard case .open(let restored) = decision else {
            Issue.record("expected open, got \(decision)")
            return
        }
        #expect(restored.tabs.map(\.id) == ["tab-1"])
        #expect(PanelLayoutEngine.allPanes(in: restored).map(\.id) == ["a"])
    }
}

import Foundation
import Testing

@testable import spacesui

/// Covers what the sidebar's cycling row and the mode-change HUD say: the count slot, the
/// accessibility label the window-cycle E2E reads, and the HUD's one summary line per mode.
@Suite struct CycleModeRowModelTests {
    @Test func countSlotCarriesTheNumberOfTargets() {
        let model = CycleModeRowModel(mode: .openSessions, count: 6, deviceCount: 2, workspaceName: nil)
        #expect(model.countText == "6")
        #expect(!model.isEmpty)
    }

    @Test func emptyAlertsSetReadsAsNoAlertsRatherThanZero() {
        let model = CycleModeRowModel(mode: .alerts, count: 0, deviceCount: 0, workspaceName: nil)
        #expect(model.isEmpty)
        #expect(model.countText == "no alerts")
        #expect(model.accessibilityLabel == "Cycling Alerts, no alerts")
    }

    @Test func everyOtherEmptyModeStillCountsInNumbers() {
        #expect(CycleModeRowModel(mode: .openSessions, count: 0, deviceCount: 0, workspaceName: nil).countText == "0")
        #expect(CycleModeRowModel(mode: .allAgents, count: 0, deviceCount: 0, workspaceName: nil).countText == "0")
        #expect(CycleModeRowModel(mode: .workspace, count: 0, deviceCount: 0, workspaceName: "harbor-web").countText == "0")
    }

    @Test func accessibilityLabelNamesTheModeAndTheCount() {
        let model = CycleModeRowModel(mode: .allAgents, count: 3, deviceCount: 2, workspaceName: nil)
        #expect(model.accessibilityLabel == "Cycling All agents, 3")
    }

    @Test func alertsSummaryCountsAlertsAndDevices() {
        #expect(CycleModeRowModel(mode: .alerts, count: 3, deviceCount: 2, workspaceName: nil).hudSummary == "3 alerts across 2 devices")
        #expect(CycleModeRowModel(mode: .alerts, count: 1, deviceCount: 1, workspaceName: nil).hudSummary == "1 alert across 1 device")
        #expect(CycleModeRowModel(mode: .alerts, count: 0, deviceCount: 0, workspaceName: nil).hudSummary == "no alerts")
    }

    @Test func allAgentsSummaryCountsAgentsAndDevices() {
        #expect(CycleModeRowModel(mode: .allAgents, count: 4, deviceCount: 2, workspaceName: nil).hudSummary == "4 agents across 2 devices")
        #expect(CycleModeRowModel(mode: .allAgents, count: 0, deviceCount: 0, workspaceName: nil).hudSummary == "no agents")
    }

    @Test func openSessionsSummaryCountsSessions() {
        #expect(CycleModeRowModel(mode: .openSessions, count: 6, deviceCount: 2, workspaceName: nil).hudSummary == "6 open sessions")
        #expect(CycleModeRowModel(mode: .openSessions, count: 1, deviceCount: 1, workspaceName: nil).hudSummary == "1 open session")
        #expect(CycleModeRowModel(mode: .openSessions, count: 0, deviceCount: 0, workspaceName: nil).hudSummary == "no open sessions")
    }

    @Test func workspaceSummaryNamesTheWorkspace() {
        #expect(CycleModeRowModel(mode: .workspace, count: 4, deviceCount: 1, workspaceName: "harbor-web").hudSummary == "4 windows in harbor-web")
        #expect(CycleModeRowModel(mode: .workspace, count: 1, deviceCount: 1, workspaceName: "harbor-web").hudSummary == "1 window in harbor-web")
        #expect(CycleModeRowModel(mode: .workspace, count: 0, deviceCount: 1, workspaceName: "harbor-web").hudSummary == "no windows in harbor-web")
    }

    @Test func workspaceSummaryWithNoWorkspaceSelectedSaysSo() {
        let model = CycleModeRowModel(mode: .workspace, count: 0, deviceCount: 0, workspaceName: nil)
        #expect(model.hudSummary == "no workspace selected")
        #expect(model.accessibilityLabel == "Cycling Workspace, 0")
    }

    @Test func everyModeHasAMenuDescription() {
        for mode in WindowCycleMode.allCases { #expect(!CycleModeRowModel.menuItemDescription(for: mode).isEmpty) }
    }
}

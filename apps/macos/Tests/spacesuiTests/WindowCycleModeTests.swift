import Foundation
import Testing
import spacesclientcore

@testable import spacesui

/// Covers the cycling mode itself: the order the shortcut steps through, and the setting it is
/// remembered in between launches.
@Suite struct WindowCycleModeTests {
    @Test func steppingWalksEveryModeAndWrapsBackToWorkspace() {
        #expect(WindowCycleMode.workspace.next == .alerts)
        #expect(WindowCycleMode.alerts.next == .allAgents)
        #expect(WindowCycleMode.allAgents.next == .openSessions)
        #expect(WindowCycleMode.openSessions.next == .workspace)
    }

    @Test func everyModeHasAName() { #expect(WindowCycleMode.allCases.map(\.displayName) == ["Workspace", "Alerts", "All agents", "Open sessions"]) }

    @Test func anUnsetOrUnreadableSettingResolvesToWorkspace() {
        #expect(WindowCycleMode.resolved(persistedRawValue: nil) == .workspace)
        #expect(WindowCycleMode.resolved(persistedRawValue: "") == .workspace)
        // A value written by some other build is not a preference this one can honor, including the
        // raw value the Alerts mode was stored under before it was renamed.
        #expect(WindowCycleMode.resolved(persistedRawValue: "everythingEverywhere") == .workspace)
        #expect(WindowCycleMode.resolved(persistedRawValue: "attention") == .workspace)
    }

    /// The mode survives a launch: it is stored under its own client setting and read back as itself.
    @Test func theSelectedModeRoundTripsThroughTheClientSetting() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-client.db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try SpacesClientDatabase(path: path)

        #expect(WindowCycleMode.resolved(persistedRawValue: try database.setting(key: ClientSettingsKey.windowCycleMode)) == .workspace)

        try database.setSetting(key: ClientSettingsKey.windowCycleMode, value: WindowCycleMode.allAgents.rawValue)
        #expect(WindowCycleMode.resolved(persistedRawValue: try database.setting(key: ClientSettingsKey.windowCycleMode)) == .allAgents)

        try database.setSetting(key: ClientSettingsKey.windowCycleMode, value: "not-a-mode")
        #expect(WindowCycleMode.resolved(persistedRawValue: try database.setting(key: ClientSettingsKey.windowCycleMode)) == .workspace)
    }

    @Test func aScopeNamesTheModeItRotatesFor() {
        #expect(WindowCycleScope.workspace("w1").mode == .workspace)
        #expect(WindowCycleScope.workspace("w1").workspaceID == "w1")
        #expect(WindowCycleScope.mode(.alerts).mode == .alerts)
        #expect(WindowCycleScope.mode(.alerts).workspaceID == nil)
        // Two workspaces, and a workspace and a mode, never share cycle state.
        #expect(WindowCycleScope.workspace("w1").key != WindowCycleScope.workspace("w2").key)
        #expect(WindowCycleScope.workspace("alerts").key != WindowCycleScope.mode(.alerts).key)
    }
}

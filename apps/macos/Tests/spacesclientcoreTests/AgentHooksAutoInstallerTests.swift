import Foundation
import Testing

@testable import spacesclientcore
import spacesterminalcore

@Suite struct AgentHooksAutoInstallerTests {
    private func status(_ kind: SupportedCodingAgentHook, available: Bool, installed: Bool) -> AgentHookStatus {
        AgentHookStatus(kind: kind, displayName: kind.displayName, available: available, hooksInstalled: installed)
    }

    @Test func installsAvailableAgentsThatAreNotYetRecorded() {
        let decision = AgentHooksAutoInstaller.plan(
            status: [
                status(.claudeCode, available: true, installed: false),
                status(.codex, available: true, installed: false),
                status(.opencode, available: false, installed: false),
            ],
            alreadyRecorded: [])
        #expect(Set(decision.install) == [.claudeCode, .codex])
        // opencode is unavailable, so it is neither installed nor recorded.
        #expect(decision.recorded == [.claudeCode, .codex])
    }

    @Test func respectsRemovalOnceRecorded() {
        // Recorded before but hook now missing (user removed it): do not reinstall.
        let decision = AgentHooksAutoInstaller.plan(
            status: [status(.claudeCode, available: true, installed: false)], alreadyRecorded: [.claudeCode])
        #expect(decision.install.isEmpty)
        #expect(decision.recorded == [.claudeCode])
    }

    @Test func recordsAlreadyInstalledAgentWithoutRedundantInstall() {
        let decision = AgentHooksAutoInstaller.plan(
            status: [status(.claudeCode, available: true, installed: true)], alreadyRecorded: [])
        #expect(decision.install.isEmpty)
        #expect(decision.recorded == [.claudeCode])
    }

    @Test func picksUpNewlyAvailableAgent() {
        // opencode was installed by the user after Spaces; it is available now and not yet recorded.
        let decision = AgentHooksAutoInstaller.plan(
            status: [
                status(.claudeCode, available: true, installed: true),
                status(.opencode, available: true, installed: false),
            ],
            alreadyRecorded: [.claudeCode])
        #expect(decision.install == [.opencode])
        #expect(decision.recorded == [.claudeCode, .opencode])
    }

    @Test func unavailableAgentIsNeverRecorded() {
        let decision = AgentHooksAutoInstaller.plan(
            status: [status(.codex, available: false, installed: false)], alreadyRecorded: [])
        #expect(decision.install.isEmpty)
        #expect(decision.recorded.isEmpty)
    }

    @Test func staleMarkerSnapshotSavePreservesMarkersRecordedByAnotherDevice() throws {
        let database = try makeTemporaryClientDatabase()
        var firstTriggerSnapshot = AgentHooksAutoInstaller.loadRecorded(database: database)
        var secondTriggerSnapshot = AgentHooksAutoInstaller.loadRecorded(database: database)

        firstTriggerSnapshot["local"] = [SupportedCodingAgentHook.claudeCode.rawValue]
        try AgentHooksAutoInstaller.saveRecorded(firstTriggerSnapshot, database: database)

        secondTriggerSnapshot["remote-linux"] = [SupportedCodingAgentHook.codex.rawValue]
        try AgentHooksAutoInstaller.saveRecorded(secondTriggerSnapshot, database: database)

        let stored = AgentHooksAutoInstaller.loadRecorded(database: database)
        #expect(stored["local"] == [SupportedCodingAgentHook.claudeCode.rawValue])
        #expect(stored["remote-linux"] == [SupportedCodingAgentHook.codex.rawValue])
    }

    private func makeTemporaryClientDatabase() throws -> SpacesClientDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
    }
}

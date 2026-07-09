import Foundation
import Testing

@testable import spacesclientcore
import spacesterminalcore

@Suite struct AgentHooksAutoInstallerTests {
    private func status(_ kind: SupportedCodingAgentHook, available: Bool, installed: Bool) -> AgentHookStatus {
        AgentHookStatus(kind: kind, displayName: kind.displayName, available: available, hooksInstalled: installed)
    }

    private func kinds(_ candidates: [AgentHookStatus]) -> Set<SupportedCodingAgentHook> { Set(candidates.map(\.kind)) }

    // MARK: - Which agents a pass acts on

    @Test func installsAvailableAgentsThatAreNotYetRecorded() {
        let candidates = AgentHooksAutoInstaller.candidates(
            status: [
                status(.claudeCode, available: true, installed: false),
                status(.codex, available: true, installed: false),
                status(.opencode, available: false, installed: false),
            ],
            alreadyRecorded: [])

        // opencode is unavailable, so it is neither a candidate nor an install target.
        #expect(kinds(candidates) == [.claudeCode, .codex])
        #expect(Set(AgentHooksAutoInstaller.installTargets(candidates: candidates)) == [.claudeCode, .codex])
    }

    @Test func respectsRemovalOnceRecorded() {
        // Recorded before but hook now missing (user removed it): do not reinstall.
        let candidates = AgentHooksAutoInstaller.candidates(
            status: [status(.claudeCode, available: true, installed: false)], alreadyRecorded: [.claudeCode])

        #expect(candidates.isEmpty)
    }

    @Test func recordsAlreadyInstalledAgentWithoutRedundantInstall() {
        let status = [status(.claudeCode, available: true, installed: true)]
        let candidates = AgentHooksAutoInstaller.candidates(status: status, alreadyRecorded: [])

        #expect(AgentHooksAutoInstaller.installTargets(candidates: candidates).isEmpty)
        #expect(AgentHooksAutoInstaller.recordedAfterInstall(candidates: candidates, finalStatus: status, alreadyRecorded: []) == [.claudeCode])
    }

    @Test func picksUpNewlyAvailableAgent() {
        // opencode was installed by the user after Spaces; it is available now and not yet recorded.
        let candidates = AgentHooksAutoInstaller.candidates(
            status: [
                status(.claudeCode, available: true, installed: true),
                status(.opencode, available: true, installed: false),
            ],
            alreadyRecorded: [.claudeCode])

        #expect(AgentHooksAutoInstaller.installTargets(candidates: candidates) == [.opencode])
    }

    @Test func unavailableAgentIsNeverRecorded() {
        let status = [status(.codex, available: false, installed: false)]
        let candidates = AgentHooksAutoInstaller.candidates(status: status, alreadyRecorded: [])

        #expect(candidates.isEmpty)
        #expect(AgentHooksAutoInstaller.recordedAfterInstall(candidates: candidates, finalStatus: status, alreadyRecorded: []).isEmpty)
    }

    // MARK: - Recording reflects what actually landed

    /// A batch where one agent installs and another fails must record only the one that landed.
    /// Recording neither would let the next connect reinstall Claude Code's hooks after the user
    /// deliberately removed them; recording both would give up on Codex forever.
    @Test func recordsOnlyAgentsWhoseHooksAreInstalledAfterAPartialFailure() {
        let candidates = AgentHooksAutoInstaller.candidates(
            status: [
                status(.claudeCode, available: true, installed: false),
                status(.codex, available: true, installed: false),
            ],
            alreadyRecorded: [])
        // Claude Code installed; Codex failed on a config.toml only the user can untangle.
        let finalStatus = [
            status(.claudeCode, available: true, installed: true),
            status(.codex, available: true, installed: false),
        ]

        let recorded = AgentHooksAutoInstaller.recordedAfterInstall(candidates: candidates, finalStatus: finalStatus, alreadyRecorded: [])

        #expect(recorded == [.claudeCode])
    }

    @Test func recordingMergesIntoWhatWasAlreadyRecorded() {
        let candidates = AgentHooksAutoInstaller.candidates(
            status: [status(.opencode, available: true, installed: false)], alreadyRecorded: [.claudeCode])
        let finalStatus = [status(.opencode, available: true, installed: true)]

        let recorded = AgentHooksAutoInstaller.recordedAfterInstall(
            candidates: candidates, finalStatus: finalStatus, alreadyRecorded: [.claudeCode])

        #expect(recorded == [.claudeCode, .opencode])
    }

    // MARK: - Persistence

    @Test func staleMarkerSnapshotSavePreservesMarkersRecordedByAnotherDevice() throws {
        let database = try makeTemporaryClientDatabase()

        try AgentHooksAutoInstaller.persist(deviceID: "local", recorded: [.claudeCode], attempted: [.claudeCode], failures: [], database: database)
        try AgentHooksAutoInstaller.persist(deviceID: "remote-linux", recorded: [.codex], attempted: [.codex], failures: [], database: database)

        let stored = AgentHooksAutoInstaller.loadRecorded(database: database)
        #expect(stored["local"] == [SupportedCodingAgentHook.claudeCode.rawValue])
        #expect(stored["remote-linux"] == [SupportedCodingAgentHook.codex.rawValue])
    }

    /// The message Settings shows must not outlive the problem it describes.
    @Test func installFailureIsRecordedThenClearedOnTheNextSuccess() throws {
        let database = try makeTemporaryClientDatabase()
        let failure = AgentHookInstallFailure(kind: .codex, message: "config.toml already defines `features`.")

        try AgentHooksAutoInstaller.persist(deviceID: "local", recorded: [], attempted: [.codex], failures: [failure], database: database)
        #expect(AgentHooksAutoInstaller.installFailures(deviceID: "local", database: database) == [.codex: failure.message])

        try AgentHooksAutoInstaller.recordInstallFailures(deviceID: "local", attempted: [.codex], failures: [], database: database)
        #expect(AgentHooksAutoInstaller.installFailures(deviceID: "local", database: database).isEmpty)
    }

    @Test func installFailuresAreScopedToTheirDevice() throws {
        let database = try makeTemporaryClientDatabase()
        let failure = AgentHookInstallFailure(kind: .codex, message: "unreadable config")

        try AgentHooksAutoInstaller.persist(deviceID: "remote-linux", recorded: [], attempted: [.codex], failures: [failure], database: database)

        #expect(AgentHooksAutoInstaller.installFailures(deviceID: "remote-linux", database: database) == [.codex: failure.message])
        #expect(AgentHooksAutoInstaller.installFailures(deviceID: "local", database: database).isEmpty)
    }

    private func makeTemporaryClientDatabase() throws -> SpacesClientDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
    }
}

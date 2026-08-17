import Foundation
import Testing

@testable import spacesterminalcore

/// The registry is process-wide and keyed by session id alone, but the same session id can get a second
/// core while the first core's launch write is still queued on its own persistence queue (a handoff resume
/// re-enqueues the launch write under the same id, and the daemon can build a fresh core for an id it has
/// seen before). Without a generation check, the older write's later commit or failure callback would clear
/// the newer core's entry out from under it and reopen the visibility gap the registry exists to cover.
/// This suite builds its own registry instance rather than mutating `.shared`, so it runs isolated from
/// every other suite that touches the process-wide singleton.
@Suite struct TerminalSessionPendingLaunchRegistryTests {
    private func makeConfiguration(sessionID: String, createdAt: String) -> TerminalSessionLaunchConfiguration {
        TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, title: "cmd", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
            createdAt: createdAt, workspaceID: "workspace-1", kind: .automation)
    }

    @Test func anOlderLaunchWritesClearCannotEraseANewerLaunchsPendingEntry() {
        let registry = TerminalSessionPendingLaunchRegistry()
        let sessionID = UUID().uuidString
        let olderConfiguration = makeConfiguration(sessionID: sessionID, createdAt: "2026-07-21T00:00:00Z")
        let newerConfiguration = makeConfiguration(sessionID: sessionID, createdAt: "2026-07-21T00:00:01Z")

        let olderGeneration = registry.recordPending(olderConfiguration)
        let newerGeneration = registry.recordPending(newerConfiguration)

        // The older write's commit (or failure) callback fires after the newer core has already recorded
        // its own entry. Clearing with the older generation must be a no-op: the newer entry is what a
        // launch-pending reader needs to see.
        registry.clear(sessionID: sessionID, generation: olderGeneration)
        #expect(
            registry.pendingLaunchConfiguration(sessionID: sessionID) == newerConfiguration,
            "an older launch write's clear must not erase a newer same-session-id launch's pending entry")

        // The newer write's own clear, generation-matched, does remove it.
        registry.clear(sessionID: sessionID, generation: newerGeneration)
        #expect(
            registry.pendingLaunchConfiguration(sessionID: sessionID) == nil,
            "a clear with the matching generation removes the entry it recorded")
    }
}

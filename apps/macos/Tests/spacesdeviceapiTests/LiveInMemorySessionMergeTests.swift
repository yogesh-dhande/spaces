import Foundation
import XCTest
import spacesterminalcore

/// Coverage for `TerminalSessionCatalog.mergingLiveInMemorySessions`, the pure function that covers the
/// write-behind window between a session core advancing in memory and its lifecycle rows committing to
/// SQLite. `SpacesDeviceAPIServer` (and `SpacesdMain`'s automation-run listing) call it to fold live
/// in-memory core entries into a DB-derived catalog listing; this suite exercises the merge itself with no
/// running server, store, or filesystem.
final class LiveInMemorySessionMergeTests: XCTestCase {
    private func makeEntry(id: String, state: TerminalSessionState, servicePID: Int32) -> TerminalSessionCatalogEntry {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: id, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-01-01T00:00:00Z",
            workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: id, servicePID: servicePID, childPID: nil, state: state, updatedAt: "2026-01-01T00:00:05Z",
            exitedAt: state == .exited ? "2026-01-01T00:00:05Z" : nil)
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            paths: TerminalSessionPaths(rootDirectory: "/tmp/spaces-test/\(id)"), isControlAvailable: false, isSubscriptionAvailable: false)
    }

    func testInteractiveInMemoryOnlyEntryIsAppendedAfterDBEntries() {
        let dbEntry = makeEntry(id: "db-only", state: .running, servicePID: getpid())
        let inMemoryEntry = makeEntry(id: "in-memory-only", state: .running, servicePID: getpid())

        let merged = TerminalSessionCatalog.mergingLiveInMemorySessions([dbEntry], inMemory: [inMemoryEntry])

        XCTAssertEqual(merged.map(\.sessionID), ["db-only", "in-memory-only"], "DB-derived entries stay first, in-memory entries append after")
    }

    func testInMemoryEntryAlreadyInDBListingIsNotDuplicated() {
        // Same session ID in both, but with divergent runtime state, so the assertion can also confirm the
        // DB entry wins rather than the in-memory one silently overwriting it.
        let dbEntry = makeEntry(id: "both", state: .running, servicePID: getpid())
        let inMemoryEntry = makeEntry(id: "both", state: .exited, servicePID: getpid())

        let merged = TerminalSessionCatalog.mergingLiveInMemorySessions([dbEntry], inMemory: [inMemoryEntry])

        XCTAssertEqual(merged.map(\.sessionID), ["both"], "no duplicate row for a session already present in the DB listing")
        XCTAssertEqual(merged.first?.runtimeState.state, .running, "the DB entry wins over the in-memory one")
    }

    func testNonInteractiveInMemoryEntryIsNotMerged() {
        let exitedInMemoryEntry = makeEntry(id: "exited-in-memory", state: .exited, servicePID: getpid())

        let merged = TerminalSessionCatalog.mergingLiveInMemorySessions([], inMemory: [exitedInMemoryEntry])

        XCTAssertTrue(merged.isEmpty, "a non-interactive in-memory entry is never merged into the listing")
    }
}

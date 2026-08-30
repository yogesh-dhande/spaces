import Foundation
import XCTest
import spacesterminalcore

/// Coverage for `TerminalSessionCatalog.mergingLiveInMemorySessions`, the pure function that covers the
/// write-behind window between a session core advancing in memory and its lifecycle rows committing to
/// SQLite. `SpacesDeviceAPIServer` (and `SpacesdMain`'s automation-run listing) call it to fold live
/// in-memory core entries into a DB-derived catalog listing; this suite exercises the merge itself with no
/// running server, store, or filesystem.
final class LiveInMemorySessionMergeTests: XCTestCase {
    private func makeEntry(id: String, state: TerminalSessionState, servicePID: Int32, title: String? = nil) -> TerminalSessionCatalogEntry {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: id, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-01-01T00:00:00Z",
            workspaceID: "workspace-1", kind: .shell)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: id, servicePID: servicePID, childPID: nil, state: state, updatedAt: "2026-01-01T00:00:05Z",
            exitedAt: state == .exited ? "2026-01-01T00:00:05Z" : nil, title: title)
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

    /// The stored row no longer tracks title changes (an agent TUI animating a spinner in its title would
    /// otherwise commit a SQLite transaction per frame), so the live core is the authority for what a
    /// running session is currently reporting and the merge has to take the title from it.
    func testLiveTitleComesFromTheInMemoryCoreForASessionInBoth() {
        let dbEntry = makeEntry(id: "both", state: .running, servicePID: getpid(), title: "stale title")
        let inMemoryEntry = makeEntry(id: "both", state: .running, servicePID: getpid(), title: "\u{2839} spider")

        let merged = TerminalSessionCatalog.mergingLiveInMemorySessions([dbEntry], inMemory: [inMemoryEntry])

        XCTAssertEqual(merged.map(\.sessionID), ["both"])
        XCTAssertEqual(merged.first?.liveTitle, "\u{2839} spider", "the live core's title overrides the stored one")
    }

    /// Only the title is taken from the core. The DB entry's other fields are derived alongside filesystem
    /// state the in-memory entry does not recompute, so overlaying them would regress the listing.
    func testOverlayReplacesOnlyTheTitle() {
        let dbEntry = TerminalSessionCatalogEntry(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "both", title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-01-01T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell),
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "both", servicePID: getpid(), childPID: 4242, state: .running, updatedAt: "2026-01-01T00:00:05Z", title: "stale",
                workingDirectory: "/tmp/db-cwd", columns: 120, rows: 40), attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            paths: TerminalSessionPaths(rootDirectory: "/tmp/spaces-test/both"), isControlAvailable: true, isSubscriptionAvailable: true)
        let inMemoryEntry = makeEntry(id: "both", state: .running, servicePID: getpid(), title: "fresh")

        let merged = TerminalSessionCatalog.mergingLiveInMemorySessions([dbEntry], inMemory: [inMemoryEntry])

        let entry = try? XCTUnwrap(merged.first)
        XCTAssertEqual(entry?.liveTitle, "fresh")
        XCTAssertEqual(entry?.runtimeState.workingDirectory, "/tmp/db-cwd", "cwd still comes from the stored row")
        XCTAssertEqual(entry?.runtimeState.columns, 120)
        XCTAssertEqual(entry?.runtimeState.childPID, 4242)
        XCTAssertEqual(entry?.isControlAvailable, true, "socket-presence flags are not overlaid")
        XCTAssertEqual(entry?.isSubscriptionAvailable, true)
    }

    /// A session the core has no entry for keeps whatever the row says, so an ended pane still renders
    /// under the final title the exited-state write recorded.
    func testStoredTitleSurvivesWhenNoLiveCoreEntryExists() {
        let dbEntry = makeEntry(id: "db-only", state: .running, servicePID: getpid(), title: "recorded title")

        let merged = TerminalSessionCatalog.mergingLiveInMemorySessions([dbEntry], inMemory: [])

        XCTAssertEqual(merged.first?.liveTitle, "recorded title")
    }

    /// The daemon's RPC listing (the CLI's `spaces terminal list` and the MCP terminal-list response) is
    /// built from rows too, so it needs the same title overlay the overview merge applies.
    func testSummaryOverlayTakesTheTitleFromTheLiveCore() {
        let stored = makeSummary(id: "both", title: "stale title")
        let live = makeSummary(id: "both", title: "\u{2839} spider")
        let unrelated = makeSummary(id: "other", title: "untouched")

        let overlaid = TerminalSessionCatalog.overlayingLiveTitles([stored, unrelated], liveInMemory: [live])

        XCTAssertEqual(overlaid.map(\.title), ["\u{2839} spider", "untouched"])
        XCTAssertEqual(overlaid.map(\.id), ["both", "other"], "the overlay never reorders or drops a row")
    }

    /// A session no core in this process hosts keeps the row's title, which is what an ended session and a
    /// session hosted by another daemon are listed under.
    func testSummaryOverlayLeavesRowsWithNoLiveCoreAlone() {
        let stored = makeSummary(id: "db-only", title: "recorded title")

        XCTAssertEqual(TerminalSessionCatalog.overlayingLiveTitles([stored], liveInMemory: []).map(\.title), ["recorded title"])
    }

    /// `title` is the effective one a client displays; `reportedTitle` is what the program itself set, which
    /// the summary also carries nested in its runtime state. They differ whenever the program set no title.
    private func makeSummary(id: String, title: String, reportedTitle: String? = nil) -> TerminalServiceSessionSummary {
        TerminalServiceSessionSummary(
            id: id, title: title, workingDirectory: "/tmp", backend: .ghosttyEmbedded, lifetimePolicy: .persistent, state: .running,
            servicePID: getpid(), childPID: 456, controlSocketPath: "/tmp/control-\(id)", outputPath: "/tmp/output-\(id)", launchConfiguration: nil,
            runtimeState: TerminalSessionRuntimeState(
                sessionID: id, servicePID: getpid(), childPID: 456, state: .running, updatedAt: "2026-01-01T00:00:05Z", title: reportedTitle))
    }

    /// A consumer may read the title from the summary or from the runtime state nested inside it, so the
    /// overlay has to move both or the wire response contradicts itself.
    func testSummaryOverlayMovesTheNestedRuntimeTitleToo() {
        let stored = makeSummary(id: "both", title: "stale", reportedTitle: "stale")
        let live = makeSummary(id: "both", title: "\u{2839} spider", reportedTitle: "\u{2839} spider")

        let overlaid = TerminalSessionCatalog.overlayingLiveTitles([stored], liveInMemory: [live])

        XCTAssertEqual(overlaid.first?.title, "\u{2839} spider")
        XCTAssertEqual(overlaid.first?.runtimeState?.title, "\u{2839} spider", "the nested runtime title moves with the outer one")
    }

    /// The two titles are not interchangeable: a session whose program never set one has an effective title
    /// derived from its launch configuration and a nil raw report. Copying the effective title into the raw
    /// field would make an untitled session look like one that named itself.
    func testSummaryOverlayKeepsAnUnreportedTitleNil() {
        let stored = makeSummary(id: "both", title: "shell", reportedTitle: nil)
        let live = makeSummary(id: "both", title: "shell", reportedTitle: nil)

        let overlaid = TerminalSessionCatalog.overlayingLiveTitles([stored], liveInMemory: [live])

        XCTAssertEqual(overlaid.first?.title, "shell")
        XCTAssertNil(overlaid.first?.runtimeState?.title, "an unreported title stays nil rather than picking up the launch title")
    }

    func testNonInteractiveInMemoryEntryIsNotMerged() {
        let exitedInMemoryEntry = makeEntry(id: "exited-in-memory", state: .exited, servicePID: getpid())

        let merged = TerminalSessionCatalog.mergingLiveInMemorySessions([], inMemory: [exitedInMemoryEntry])

        XCTAssertTrue(merged.isEmpty, "a non-interactive in-memory entry is never merged into the listing")
    }
}

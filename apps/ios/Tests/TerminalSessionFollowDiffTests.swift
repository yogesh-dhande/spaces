#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// Tests for the pure pairing function behind iOS's follow-on-restart (issue #799): a terminal
    /// viewer open on a configured process's session must move onto whatever session replaces it after a
    /// restart run from any client, in place, with no navigation and no focus change. `TerminalDetailView`
    /// wires this into the view lifecycle; these tests cover only `TerminalSessionFollowDiff` itself.
    final class TerminalSessionFollowDiffTests: XCTestCase {
        private func processRow(id: String, workspaceID: String = "workspace-feature", sessionID: String?, runState: SpacesDeviceRunState = .running)
            -> SpacesDeviceWorkspaceProcessRow
        {
            SpacesDeviceWorkspaceProcessRow(
                id: id, workspaceID: workspaceID, name: id, command: "echo \(id)", processID: "process-\(id)", sessionID: sessionID,
                runState: runState, canRun: runState != .running, canStop: runState == .running, canRestart: runState == .running)
        }

        private func session(id: String, createdAt: String) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: id, title: "api", workingDirectory: "/repo/feature", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
                lifetimePolicy: .persistent, servicePID: 100, childPID: 101, workspaceID: "workspace-feature", workspaceTitle: "Feature",
                projectID: "project-1", projectName: "Project", createdAt: createdAt, updatedAt: createdAt, isControlAvailable: true,
                isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot())
        }

        private let row = TerminalSessionFollowDiff.ProcessRowIdentity(workspaceID: "workspace-feature", rowID: "api")

        // MARK: - replacementSession

        func testFollowsANewerReplacementOnTheSameRow() {
            let overview = makeOverview(
                processRows: [processRow(id: "api", sessionID: "replacement")],
                sessions: [session(id: "replacement", createdAt: "2026-01-01T00:01:00Z")])

            let replacement = TerminalSessionFollowDiff.replacementSession(
                for: row, displayedSessionID: "ended", displayedCreatedAt: "2026-01-01T00:00:00Z", overview: overview)

            XCTAssertEqual(replacement?.id, "replacement")
        }

        func testIgnoresAReplacementNoNewerThanWhatIsDisplayed() {
            let equalOverview = makeOverview(
                processRows: [processRow(id: "api", sessionID: "same-instant")],
                sessions: [session(id: "same-instant", createdAt: "2026-01-01T00:00:00Z")])
            XCTAssertNil(
                TerminalSessionFollowDiff.replacementSession(
                    for: row, displayedSessionID: "displayed", displayedCreatedAt: "2026-01-01T00:00:00Z", overview: equalOverview))

            let olderOverview = makeOverview(
                processRows: [processRow(id: "api", sessionID: "older")], sessions: [session(id: "older", createdAt: "2025-12-31T23:59:00Z")])
            XCTAssertNil(
                TerminalSessionFollowDiff.replacementSession(
                    for: row, displayedSessionID: "displayed", displayedCreatedAt: "2026-01-01T00:00:00Z", overview: olderOverview))
        }

        func testIgnoresAnotherRowAndANonProcessRow() {
            let otherWorkspace = makeOverview(
                workspaces: [
                    makeWorkspace(id: "workspace-feature", branch: "feature", processRows: [processRow(id: "api", sessionID: "displayed")]),
                    makeWorkspace(
                        id: "workspace-other", branch: "other",
                        processRows: [processRow(id: "api", workspaceID: "workspace-other", sessionID: "other-new")]),
                ], sessions: [session(id: "other-new", createdAt: "2026-01-01T00:01:00Z")])
            // The candidate row lives in "workspace-other"; `row` (this test's fixed identity) names
            // "workspace-feature", so the same-id row in the other workspace must never pair (mirrors the
            // Mac diff's `rowsWithTheSameIDInDifferentWorkspacesAreNeverPaired`).
            XCTAssertNil(
                TerminalSessionFollowDiff.replacementSession(
                    for: row, displayedSessionID: "displayed", displayedCreatedAt: "2026-01-01T00:00:00Z", overview: otherWorkspace))

            let agentRowOnly = makeOverview(codingAgentRows: [makeAgentRow(id: "api", activityState: .idle)])
            XCTAssertNil(
                TerminalSessionFollowDiff.replacementSession(
                    for: row, displayedSessionID: "displayed", displayedCreatedAt: "2026-01-01T00:00:00Z", overview: agentRowOnly))
        }

        func testNoOpWhenAlreadyOnTheRowsSession() {
            let overview = makeOverview(
                processRows: [processRow(id: "api", sessionID: "displayed")], sessions: [session(id: "displayed", createdAt: "2026-01-01T00:00:00Z")])

            XCTAssertNil(
                TerminalSessionFollowDiff.replacementSession(
                    for: row, displayedSessionID: "displayed", displayedCreatedAt: "2026-01-01T00:00:00Z", overview: overview))
        }

        func testNilWhenTheReplacementsSummaryIsMissing() {
            // The row already names a different session, but that session has dropped out of `sessions`
            // (an instant crash within one refresh, or a stale overview): nothing to follow onto yet.
            let overview = makeOverview(processRows: [processRow(id: "api", sessionID: "not-yet-listed")], sessions: [])

            XCTAssertNil(
                TerminalSessionFollowDiff.replacementSession(
                    for: row, displayedSessionID: "displayed", displayedCreatedAt: "2026-01-01T00:00:00Z", overview: overview))
        }

        func testNilWhenTheRowItselfIsGone() {
            let overview = makeOverview(processRows: [])

            XCTAssertNil(
                TerminalSessionFollowDiff.replacementSession(
                    for: row, displayedSessionID: "displayed", displayedCreatedAt: "2026-01-01T00:00:00Z", overview: overview))
        }

        // MARK: - processRowIdentity(for:)

        func testProcessRowIdentityIsCapturedOnlyForAProcessRow() {
            let processRuntimeRow = SpacesMobileWorkspaceRuntimeRow(source: .process(processRow(id: "api", sessionID: "live")))
            XCTAssertEqual(
                TerminalSessionFollowDiff.processRowIdentity(for: processRuntimeRow),
                TerminalSessionFollowDiff.ProcessRowIdentity(workspaceID: "workspace-feature", rowID: "api"))

            let agentRuntimeRow = SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(makeAgentRow(id: "agent-1", activityState: .idle)))
            XCTAssertNil(TerminalSessionFollowDiff.processRowIdentity(for: agentRuntimeRow))
        }
    }
#endif

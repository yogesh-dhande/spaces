#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor final class SpacesMobileAlertsTests: XCTestCase {
        func testDerivesWaitingFinishedAndExitedEvents() {
            let overview = makeOverview(
                codingAgentRows: [
                    makeAgentRow(id: "agent-waiting", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z"),
                    makeAgentRow(id: "agent-done", name: "codex", activityState: .done, updatedAt: "2026-01-01T00:20:00Z"),
                    makeAgentRow(id: "agent-busy", name: "busy", runState: .running, activityState: .spinning, updatedAt: "2026-01-01T00:30:00Z"),
                ],
                processRows: [
                    makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: "2026-01-01T00:05:00Z"),
                    makeProcessRow(id: "process-live", name: "live", runState: .running, exitedAt: nil),
                ], sessions: [makeSession(id: "session-loose", title: "zsh", state: .exited, updatedAt: "2026-01-01T00:01:00Z")])

            let events = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(events.count, 4)
            let bySource = Dictionary(uniqueKeysWithValues: events.map { ($0.sourceID, $0) })
            XCTAssertEqual(bySource["agent:agent-waiting"]?.kind, .waitingForInput)
            XCTAssertEqual(bySource["agent:agent-done"]?.kind, .finished)
            XCTAssertEqual(bySource["process:process-web"]?.kind, .exited)
            XCTAssertEqual(bySource["session:session-loose"]?.kind, .exited)
            XCTAssertEqual(bySource["agent:agent-waiting"]?.date, SpacesMobileAttention.date(fromISO8601: "2026-01-01T00:10:00Z"))
        }

        func testSkipsSourcesWithoutUsableTimestamps() {
            let overview = makeOverview(
                codingAgentRows: [makeAgentRow(id: "agent-waiting", name: "claude", activityState: .waiting, updatedAt: nil)],
                processRows: [makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: nil)],
                sessions: [makeSession(id: "session-loose", title: "zsh", state: .exited, updatedAt: "not-a-timestamp")])

            XCTAssertTrue(SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:]).isEmpty)
        }

        func testAcceptsFractionalLinuxDaemonTimestamps() {
            let overview = makeOverview(
                processRows: [makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: "2026-07-12T12:34:56.123Z")],
                sessions: [makeSession(id: "session-loose", title: "zsh", state: .failed, updatedAt: "2026-07-12T12:34:57.456Z")])

            let events = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(Set(events.map(\.sourceID)), ["process:process-web", "session:session-loose"])
            XCTAssertTrue(events.allSatisfy { $0.date.timeIntervalSince1970 > 0 })
        }

        func testSessionRepresentedByProcessRowProducesOneEvent() {
            let overview = makeOverview(
                processRows: [
                    makeProcessRow(id: "process-web", name: "web", sessionID: "session-web", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")
                ], sessions: [makeSession(id: "session-web", title: "web", state: .exited, updatedAt: "2026-01-01T00:05:30Z")])

            let events = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(events.map(\.sourceID), ["process:process-web"])
        }

        func testExitedTerminalRowUsesLinkedSessionTimestamp() {
            let overview = makeOverview(
                terminalRows: [
                    makeTerminalRow(id: "terminal-shell", title: "zsh", sessionID: "session-shell", runState: .exited),
                    makeTerminalRow(id: "terminal-untracked", title: "lost", sessionID: nil, runState: .exited),
                ], sessions: [makeSession(id: "session-shell", title: "zsh", state: .failed, updatedAt: "2026-01-01T00:07:00Z")])

            let events = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(events.map(\.sourceID), ["terminal:terminal-shell"])
            XCTAssertEqual(events.first?.kind, .failed)
            XCTAssertEqual(events.first?.date, SpacesMobileAttention.date(fromISO8601: "2026-01-01T00:07:00Z"))
        }

        func testSkipsEventsAndLooseSessionsFromHiddenWorkspaces() {
            let workspace = makeWorkspace(
                id: "workspace-feature", branch: "feature", isHidden: true,
                codingAgentRows: [makeAgentRow(id: "agent-hidden", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:01:00Z")],
                processRows: [
                    makeProcessRow(
                        id: "process-hidden", name: "web", sessionID: "session-process", runState: .exited, exitedAt: "2026-01-01T00:02:00Z")
                ], terminalRows: [makeTerminalRow(id: "terminal-hidden", title: "zsh", sessionID: "session-terminal", runState: .exited)])
            let overview = makeOverview(
                workspaces: [workspace],
                sessions: [
                    makeSession(id: "session-process", title: "web", state: .exited, updatedAt: "2026-01-01T00:02:00Z"),
                    makeSession(id: "session-terminal", title: "zsh", state: .failed, updatedAt: "2026-01-01T00:03:00Z"),
                    makeSession(id: "session-loose", title: "shell", state: .exited, updatedAt: "2026-01-01T00:04:00Z"),
                ])

            XCTAssertTrue(SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:]).isEmpty)
        }

        /// A workspace whose own `isHidden` flag is false but whose project is hidden is just as invisible
        /// as one hidden directly — the same rule the Spaces tab's browse list applies via
        /// `SpacesDeviceOverviewPayload.isWorkspaceVisible`.
        func testSkipsEventsAndLooseSessionsFromWorkspacesWithAHiddenProject() {
            let workspace = makeWorkspace(
                id: "workspace-feature", branch: "feature", isHidden: false,
                codingAgentRows: [makeAgentRow(id: "agent-hidden", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:01:00Z")],
                processRows: [
                    makeProcessRow(
                        id: "process-hidden", name: "web", sessionID: "session-process", runState: .exited, exitedAt: "2026-01-01T00:02:00Z")
                ], terminalRows: [makeTerminalRow(id: "terminal-hidden", title: "zsh", sessionID: "session-terminal", runState: .exited)])
            let overview = makeOverview(
                workspaces: [workspace], projectIsHidden: true,
                sessions: [
                    makeSession(id: "session-process", title: "web", state: .exited, updatedAt: "2026-01-01T00:02:00Z"),
                    makeSession(id: "session-terminal", title: "zsh", state: .failed, updatedAt: "2026-01-01T00:03:00Z"),
                    makeSession(id: "session-loose", title: "shell", state: .exited, updatedAt: "2026-01-01T00:04:00Z"),
                ])

            XCTAssertTrue(SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:]).isEmpty)
        }

        /// A deleted workspace's sessions outlive its record by a refresh or two. An event grouped under a
        /// workspace the overview no longer describes would band under an id nothing else on screen carries,
        /// so those sessions raise no loose-session and no bell event.
        func testSkipsLooseSessionsAndBellsOfAWorkspaceMissingFromTheOverview() {
            let overview = makeOverview(
                workspaces: [makeWorkspace(id: "workspace-docs", branch: "docs")],
                sessions: [
                    makeSession(id: "session-loose", title: "shell", state: .exited, updatedAt: "2026-01-01T00:04:00Z"),
                    makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:05:00Z", bellAt: "2026-01-01T00:05:00Z"),
                ])

            XCTAssertTrue(SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:]).isEmpty)
            XCTAssertTrue(
                SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:], includingHiddenWorkspaces: true)
                    .isEmpty)
        }

        func testGroupsSortNewestFirstAndEventsWithinGroupNewestFirst() {
            let overview = makeOverview(workspaces: [
                makeWorkspace(
                    id: "workspace-old", branch: "old",
                    codingAgentRows: [
                        makeAgentRow(
                            id: "agent-old", workspaceID: "workspace-old", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:01:00Z")
                    ]),
                makeWorkspace(
                    id: "workspace-new", branch: "new",
                    codingAgentRows: [
                        makeAgentRow(
                            id: "agent-new-early", workspaceID: "workspace-new", name: "claude", activityState: .waiting,
                            updatedAt: "2026-01-01T00:02:00Z"),
                        makeAgentRow(
                            id: "agent-new-late", workspaceID: "workspace-new", name: "codex", activityState: .done, updatedAt: "2026-01-01T00:09:00Z"
                        ),
                    ]),
            ])

            let groups = SpacesMobileAttention.groups(in: overview, dismissedEventIDs: [], focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(groups.map(\.workspaceID), ["workspace-new", "workspace-old"])
            XCTAssertEqual(groups.first?.events.map(\.sourceID), ["agent:agent-new-late", "agent:agent-new-early"])
            XCTAssertEqual(groups.first?.workspaceDisplayName, "new")
            XCTAssertEqual(groups.first?.projectName, "Project")
            XCTAssertEqual(groups.first?.isGitWorkspace, true)
        }

        func testClearDismissesCurrentEventsAndNewStateChangeReappears() {
            let model = makeModel()
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-waiting", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])

            XCTAssertEqual(model.undismissedAlertCount, 1)

            model.clearAlerts()

            XCTAssertEqual(model.undismissedAlertCount, 0)
            XCTAssertTrue(model.attentionGroups.isEmpty)

            // The same source in a new state (later timestamp) mints a new identity and reappears.
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-waiting", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:15:00Z")
            ])

            XCTAssertEqual(model.undismissedAlertCount, 1)
        }

        func testDismissAlertRemovesOnlyThatEvent() {
            let model = makeModel()
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z"),
                makeAgentRow(id: "agent-b", name: "codex", activityState: .done, updatedAt: "2026-01-01T00:20:00Z"),
            ])
            guard let dismissed = model.attentionGroups.first?.events.first(where: { $0.sourceID == "agent:agent-a" }) else {
                XCTFail("Expected a derived event for agent-a.")
                return
            }

            model.dismissAlert(dismissed)

            XCTAssertEqual(model.undismissedAlertCount, 1)
            XCTAssertEqual(model.attentionGroups.first?.events.map(\.sourceID), ["agent:agent-b"])

            // The same source in a new state mints a new identity, so it alerts again.
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:30:00Z")
            ])

            XCTAssertEqual(model.undismissedAlertCount, 1)
        }

        // MARK: - Row acknowledgment (dismissed-exit-alert-inactive)

        /// An exited process row reads failed red until its exited event is dismissed, then reads the
        /// unstarted stroke; a later exit mints a new event identity, so a fresh failure reddens it again.
        func testIsExitAcknowledgedFollowsDismissalAndResetsOnNewExit() {
            let model = makeModel()
            model.overview = makeOverview(
                processRows: [makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")])
            let row = SpacesMobileWorkspaceRuntimeRow(source: .process(model.overview!.workspaces[0].processRows[0]))

            XCTAssertFalse(model.isExitAcknowledged(row))
            XCTAssertEqual(row.statusDotKind(exitAcknowledged: model.isExitAcknowledged(row)), .exited)

            guard let exitEvent = model.undismissedAlerts(for: row).first(where: { $0.kind == .exited }) else {
                XCTFail("Expected an exited event for the process row.")
                return
            }
            model.dismissAlert(exitEvent)

            XCTAssertTrue(model.isExitAcknowledged(row))
            XCTAssertEqual(row.statusDotKind(exitAcknowledged: model.isExitAcknowledged(row)), .idle)

            // A later exit mints a new event identity (a later `exitedAt`), so the row reddens again even
            // though the earlier exit's dismissal is still on file.
            model.overview = makeOverview(
                processRows: [makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: "2026-01-01T00:10:00Z")])
            let reExitedRow = SpacesMobileWorkspaceRuntimeRow(source: .process(model.overview!.workspaces[0].processRows[0]))

            XCTAssertFalse(model.isExitAcknowledged(reExitedRow))
            XCTAssertEqual(reExitedRow.statusDotKind(exitAcknowledged: model.isExitAcknowledged(reExitedRow)), .exited)
        }

        /// A configured process row's id comes from its project template, not its workspace
        /// (`SpacesDeviceOverviewBuilder` mints it as `template.id`), so two sibling workspaces of the same
        /// project can carry rows with the identical id. `isExitAcknowledged` must key off the row's own
        /// workspace, not just that shared id, or dismissing one workspace's exit would silently
        /// acknowledge the sibling's still-undismissed one.
        func testIsExitAcknowledgedDoesNotBleedAcrossWorkspacesSharingATemplateRowID() {
            let model = makeModel()
            let processA = SpacesDeviceWorkspaceProcessRow(
                id: "process-web", workspaceID: "workspace-a", name: "web", command: "npm run web", processID: "runtime-a", sessionID: nil,
                runState: .exited, exitedAt: "2026-01-01T00:05:00Z", canRun: true, canStop: false, canRestart: false)
            let processB = SpacesDeviceWorkspaceProcessRow(
                id: "process-web", workspaceID: "workspace-b", name: "web", command: "npm run web", processID: "runtime-b", sessionID: nil,
                runState: .exited, exitedAt: "2026-01-01T00:06:00Z", canRun: true, canStop: false, canRestart: false)
            model.overview = makeOverview(workspaces: [
                makeWorkspace(id: "workspace-a", branch: "a", processRows: [processA]),
                makeWorkspace(id: "workspace-b", branch: "b", processRows: [processB]),
            ])
            let rowA = SpacesMobileWorkspaceRuntimeRow(source: .process(processA))
            let rowB = SpacesMobileWorkspaceRuntimeRow(source: .process(processB))
            XCTAssertEqual(rowA.id, rowB.id, "both rows share the project template's id")

            guard let exitEventA = model.undismissedAlerts(for: rowA).first(where: { $0.kind == .exited }) else {
                XCTFail("Expected an exited event for workspace A's row.")
                return
            }
            model.dismissAlert(exitEventA)

            XCTAssertTrue(model.isExitAcknowledged(rowA))
            XCTAssertFalse(model.isExitAcknowledged(rowB), "dismissing A's exit must not acknowledge B's identically-id'd row")

            guard let exitEventB = model.undismissedAlerts(for: rowB).first(where: { $0.kind == .exited }) else {
                XCTFail("Expected an exited event for workspace B's row.")
                return
            }
            model.dismissAlert(exitEventB)

            XCTAssertTrue(model.isExitAcknowledged(rowB))
        }

        /// Dismissing a process's exit turns its own dot from failed red to the unstarted stroke, but
        /// leaves a separate, still-undismissed bell on the same row's session alone: acknowledgment and
        /// menu visibility answer different questions about the same row.
        func testDismissingExitDoesNotClearASeparateBellOnTheSameRow() {
            let model = makeModel()
            model.overview = makeOverview(
                processRows: [
                    makeProcessRow(id: "process-web", name: "web", sessionID: "session-a", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")
                ],
                sessions: [
                    makeSession(id: "session-a", title: "web", state: .exited, updatedAt: "2026-01-01T00:05:00Z", bellAt: "2026-01-01T00:07:00Z")
                ])
            let row = SpacesMobileWorkspaceRuntimeRow(source: .process(model.overview!.workspaces[0].processRows[0]))
            guard let exitEvent = model.undismissedAlerts(for: row).first(where: { $0.kind == .exited }) else {
                XCTFail("Expected an exited event for the process row.")
                return
            }

            model.dismissAlert(exitEvent)

            XCTAssertTrue(model.isExitAcknowledged(row))
            XCTAssertEqual(row.statusDotKind(exitAcknowledged: model.isExitAcknowledged(row)), .idle)
            XCTAssertTrue(model.hasUndismissedAlerts(for: row), "the bell on the same session is still undismissed")
        }

        /// Agent activity and terminal exits never read `exitAcknowledged`: only a `.process` row's dot
        /// changes with dismissal (an agent keeps tracking live activity; a terminal exit stays red).
        func testOnlyProcessRowDotsReadAcknowledgement() {
            let agentRow = SpacesMobileWorkspaceRuntimeRow(
                source: .codingAgent(makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")))
            let terminalRow = SpacesMobileWorkspaceRuntimeRow(
                source: .terminal(makeTerminalRow(id: "terminal-a", title: "zsh", sessionID: nil, runState: .exited)))

            XCTAssertEqual(agentRow.statusDotKind(exitAcknowledged: false), agentRow.statusDotKind(exitAcknowledged: true))
            XCTAssertEqual(agentRow.statusDotKind(exitAcknowledged: true), .waiting)
            XCTAssertEqual(terminalRow.statusDotKind(exitAcknowledged: false), terminalRow.statusDotKind(exitAcknowledged: true))
            XCTAssertEqual(terminalRow.statusDotKind(exitAcknowledged: true), .exited, "a terminal exit stays red regardless of dismissal")
        }

        /// A row's own events are matched by the exact `sourceID`/`workspaceID` the row and
        /// `SpacesMobileAttention.events` both derive from the same underlying record, plus a bell keyed by
        /// session id — never another row's events, another workspace's same-shaped id, or a bell on
        /// another session.
        func testRowMatchesOnlyItsOwnEventsAndBellOnItsSession() {
            let row = SpacesMobileWorkspaceRuntimeRow(
                source: .process(
                    makeProcessRow(id: "process-web", name: "web", sessionID: "session-a", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")))
            let now = Date()
            let ownExit = SpacesMobileAttentionEvent(
                sourceID: "process:process-web", kind: .exited, date: now, title: "web", rowType: .processes, sessionID: "session-a",
                workspaceID: "workspace-feature")
            let ownBell = SpacesMobileAttentionEvent(
                sourceID: "session:session-a", kind: .bell, date: now, title: "web", rowType: .processes, sessionID: "session-a",
                workspaceID: "workspace-feature")
            let otherProcessSameWorkspace = SpacesMobileAttentionEvent(
                sourceID: "process:process-other", kind: .exited, date: now, title: "other", rowType: .processes, sessionID: "session-b",
                workspaceID: "workspace-feature")
            let sameSourceIDOtherWorkspace = SpacesMobileAttentionEvent(
                sourceID: "process:process-web", kind: .exited, date: now, title: "web", rowType: .processes, sessionID: "session-a",
                workspaceID: "workspace-other")
            let bellOnAnotherSession = SpacesMobileAttentionEvent(
                sourceID: "session:session-b", kind: .bell, date: now, title: "other", rowType: .processes, sessionID: "session-b",
                workspaceID: "workspace-feature")

            XCTAssertTrue(row.matches(ownExit))
            XCTAssertTrue(row.matches(ownBell))
            XCTAssertFalse(row.matches(otherProcessSameWorkspace))
            XCTAssertFalse(row.matches(sameSourceIDOtherWorkspace))
            XCTAssertFalse(row.matches(bellOnAnotherSession))
        }

        /// Each row family's undismissed events are its own: a process picks up its exit and any bell on
        /// its session, an agent picks up only its own activity event, a terminal only its own exit — never
        /// a sibling row's events in the same workspace.
        func testUndismissedAlertsIsolatedPerRow() {
            let model = makeModel()
            let processRow = makeProcessRow(id: "process-web", name: "web", sessionID: "session-a", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")
            let agentRow = makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:06:00Z")
            let terminalRow = makeTerminalRow(id: "terminal-a", title: "zsh", sessionID: "session-b", runState: .exited)
            model.overview = makeOverview(
                codingAgentRows: [agentRow], processRows: [processRow], terminalRows: [terminalRow],
                sessions: [
                    makeSession(id: "session-a", title: "web", state: .exited, updatedAt: "2026-01-01T00:05:00Z", bellAt: "2026-01-01T00:07:00Z"),
                    makeSession(id: "session-b", title: "zsh", state: .failed, updatedAt: "2026-01-01T00:07:30Z"),
                ])
            let workspace = model.overview!.workspaces[0]
            let processRuntimeRow = SpacesMobileWorkspaceRuntimeRow(source: .process(workspace.processRows[0]))
            let agentRuntimeRow = SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(workspace.codingAgentRows[0]))
            let terminalRuntimeRow = SpacesMobileWorkspaceRuntimeRow(source: .terminal(workspace.terminalRows[0]))

            XCTAssertEqual(Set(model.undismissedAlerts(for: processRuntimeRow).map(\.sourceID)), ["process:process-web", "session:session-a"])
            XCTAssertEqual(model.undismissedAlerts(for: agentRuntimeRow).map(\.sourceID), ["agent:agent-a"])
            XCTAssertEqual(model.undismissedAlerts(for: terminalRuntimeRow).map(\.sourceID), ["terminal:terminal-a"])
            XCTAssertTrue(model.hasUndismissedAlerts(for: processRuntimeRow))
            XCTAssertTrue(model.hasUndismissedAlerts(for: agentRuntimeRow))
            XCTAssertTrue(model.hasUndismissedAlerts(for: terminalRuntimeRow))
        }

        /// `undismissedAlerts` must apply the same focus/watch-window bell suppression the Alerts tab
        /// does: a bell rung while the row's session was being watched offers nothing to dismiss, but the
        /// identical bell rung outside any watch window does.
        func testUndismissedAlertsSuppressesABellRungInsideAWatchWindowButNotOutsideIt() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            let processRow = makeProcessRow(id: "process-web", name: "web", sessionID: "session-bell", runState: .running, exitedAt: nil)
            let row = SpacesMobileWorkspaceRuntimeRow(source: .process(processRow))
            model.setActiveTerminalSession("session-bell")
            let bellRungWhileWatching = clock.advance(60)
            clock.advance(60)
            model.setActiveTerminalSession(nil)

            model.overview = makeOverview(
                processRows: [processRow],
                sessions: [
                    makeSession(
                        id: "session-bell", title: "web", state: .running, updatedAt: "2026-01-01T00:00:00Z",
                        bellAt: iso8601(bellRungWhileWatching))
                ])

            XCTAssertTrue(model.undismissedAlerts(for: row).isEmpty)
            XCTAssertFalse(model.hasUndismissedAlerts(for: row))

            // The same bell, rung outside any watch window, is one the user has not seen yet.
            let bellOutsideAnyWatch = clock.advance(60)
            model.overview = makeOverview(
                processRows: [processRow],
                sessions: [
                    makeSession(
                        id: "session-bell", title: "web", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: iso8601(bellOutsideAnyWatch))
                ])

            XCTAssertFalse(model.undismissedAlerts(for: row).isEmpty)
            XCTAssertTrue(model.hasUndismissedAlerts(for: row))
        }

        /// The row-level "Dismiss Alert" action dismisses every one of the row's own undismissed events at
        /// once (its exit plus a bell on the same session here), identical in effect to dismissing each
        /// individually from the Alerts tab: same dismissed set, badge follows.
        func testDismissAlertsForRowDismissesAllOfItsEventsAndUpdatesTheBadge() {
            let model = makeModel()
            model.overview = makeOverview(
                processRows: [
                    makeProcessRow(id: "process-web", name: "web", sessionID: "session-a", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")
                ],
                sessions: [
                    makeSession(id: "session-a", title: "web", state: .exited, updatedAt: "2026-01-01T00:05:00Z", bellAt: "2026-01-01T00:07:00Z")
                ])
            let row = SpacesMobileWorkspaceRuntimeRow(source: .process(model.overview!.workspaces[0].processRows[0]))

            XCTAssertTrue(model.hasUndismissedAlerts(for: row))
            XCTAssertEqual(model.undismissedAlertCount, 2)

            model.dismissAlerts(for: row)

            XCTAssertFalse(model.hasUndismissedAlerts(for: row))
            XCTAssertEqual(model.undismissedAlertCount, 0)
            XCTAssertTrue(model.isExitAcknowledged(row))
        }

        func testDismissedAlertIDsRoundTripThroughStorage() {
            let defaults = UserDefaults(suiteName: "spaces.mobile.tests.dismissed-alerts")!
            defaults.removePersistentDomain(forName: "spaces.mobile.tests.dismissed-alerts")
            defer { defaults.removePersistentDomain(forName: "spaces.mobile.tests.dismissed-alerts") }

            XCTAssertTrue(SpacesMobileDismissedAlertsStore.load(deviceID: "device-a", defaults: defaults).isEmpty)

            SpacesMobileDismissedAlertsStore.save(["agent:a|waitingForInput|1", "agent:b|finished|2"], deviceID: "device-a", defaults: defaults)

            XCTAssertEqual(
                SpacesMobileDismissedAlertsStore.load(deviceID: "device-a", defaults: defaults), ["agent:a|waitingForInput|1", "agent:b|finished|2"])
        }

        /// Each device's dismissals live in their own bucket: saving under one device id must not leak
        /// into, or be visible from, another. Without this a global set gets pruned against whichever
        /// device's overview last published, resurfacing another device's dismissed alerts the moment the
        /// active device changes back.
        func testDismissedAlertIDsAreScopedPerDevice() {
            let defaults = UserDefaults(suiteName: "spaces.mobile.tests.dismissed-alerts-scoped")!
            defaults.removePersistentDomain(forName: "spaces.mobile.tests.dismissed-alerts-scoped")
            defer { defaults.removePersistentDomain(forName: "spaces.mobile.tests.dismissed-alerts-scoped") }

            SpacesMobileDismissedAlertsStore.save(["agent:a|waitingForInput|1"], deviceID: "device-a", defaults: defaults)
            SpacesMobileDismissedAlertsStore.save(["agent:b|finished|2"], deviceID: "device-b", defaults: defaults)

            XCTAssertEqual(SpacesMobileDismissedAlertsStore.load(deviceID: "device-a", defaults: defaults), ["agent:a|waitingForInput|1"])
            XCTAssertEqual(SpacesMobileDismissedAlertsStore.load(deviceID: "device-b", defaults: defaults), ["agent:b|finished|2"])

            // Saving an empty set for one device clears only its own bucket.
            SpacesMobileDismissedAlertsStore.save([], deviceID: "device-a", defaults: defaults)
            XCTAssertTrue(SpacesMobileDismissedAlertsStore.load(deviceID: "device-a", defaults: defaults).isEmpty)
            XCTAssertEqual(SpacesMobileDismissedAlertsStore.load(deviceID: "device-b", defaults: defaults), ["agent:b|finished|2"])
        }

        /// `retainDevices` bounds the store to devices the app still knows about, dropping the rest —
        /// otherwise every unpaired device's bucket would sit in `UserDefaults` for the life of the install.
        func testRetainDevicesDropsBucketsForUnknownDevices() {
            let defaults = UserDefaults(suiteName: "spaces.mobile.tests.dismissed-alerts-retain")!
            defaults.removePersistentDomain(forName: "spaces.mobile.tests.dismissed-alerts-retain")
            defer { defaults.removePersistentDomain(forName: "spaces.mobile.tests.dismissed-alerts-retain") }

            SpacesMobileDismissedAlertsStore.save(["agent:a|waitingForInput|1"], deviceID: "device-a", defaults: defaults)
            SpacesMobileDismissedAlertsStore.save(["agent:b|finished|2"], deviceID: "device-b", defaults: defaults)

            SpacesMobileDismissedAlertsStore.retainDevices(["device-a"], defaults: defaults)

            XCTAssertEqual(SpacesMobileDismissedAlertsStore.load(deviceID: "device-a", defaults: defaults), ["agent:a|waitingForInput|1"])
            XCTAssertTrue(SpacesMobileDismissedAlertsStore.load(deviceID: "device-b", defaults: defaults).isEmpty)
        }

        /// Dismissals only mean something while their event is still derivable, so a refreshed overview
        /// that no longer produces an event drops its dismissal instead of storing it forever.
        func testRetainedDismissalsDropIdentitiesTheOverviewNoLongerProduces() {
            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            let events = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])
            guard let liveID = events.first?.id else {
                XCTFail("Expected a derived event.")
                return
            }

            let retained = SpacesMobileAttention.retainedDismissedEventIDs([liveID, "agent:agent-gone|finished|1"], in: overview)

            XCTAssertEqual(retained, [liveID])
        }

        /// Hiding a workspace is a reversible suppression, the same as a focused session or a watch
        /// window: `retainedDismissedEventIDs` must keep deriving a hidden workspace's events (it opts
        /// into `includingHiddenWorkspaces`), or hiding it would prune the dismissal and unhiding it would
        /// resurface an alert the user already dismissed even though nothing about the source changed.
        /// This covers an agent-derived event.
        func testRetainedDismissalsSurviveWhenAnAgentsWorkspaceIsHidden() {
            let visibleOverview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            guard let liveID = SpacesMobileAttention.events(in: visibleOverview, focusedSessionID: nil, watchWindowsBySessionID: [:]).first?.id else {
                XCTFail("Expected a derived event.")
                return
            }
            let hiddenOverview = makeOverview(workspaces: [
                makeWorkspace(
                    id: "workspace-feature", branch: "feature", isHidden: true,
                    codingAgentRows: [makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")])
            ])

            let retained = SpacesMobileAttention.retainedDismissedEventIDs([liveID], in: hiddenOverview)

            XCTAssertEqual(retained, [liveID])
        }

        /// The same guarantee when the suppression is project-level rather than the workspace's own flag:
        /// hiding the project must not resurface an alert the user already dismissed once it is unhidden.
        func testRetainedDismissalsSurviveWhenAnAgentsWorkspaceProjectIsHidden() {
            let visibleOverview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            guard let liveID = SpacesMobileAttention.events(in: visibleOverview, focusedSessionID: nil, watchWindowsBySessionID: [:]).first?.id else {
                XCTFail("Expected a derived event.")
                return
            }
            let hiddenOverview = makeOverview(
                workspaces: [
                    makeWorkspace(
                        id: "workspace-feature", branch: "feature",
                        codingAgentRows: [makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")])
                ], projectIsHidden: true)

            let retained = SpacesMobileAttention.retainedDismissedEventIDs([liveID], in: hiddenOverview)

            XCTAssertEqual(retained, [liveID])
        }

        /// The same guarantee for a session-derived event: an exited loose terminal whose identity comes
        /// from the loose-session branch of `events(...)`, not a workspace row.
        func testRetainedDismissalsSurviveWhenASessionsWorkspaceIsHidden() {
            let session = makeSession(id: "session-loose", title: "zsh", state: .exited, updatedAt: "2026-01-01T00:04:00Z")
            let visibleOverview = makeOverview(sessions: [session])
            guard let liveID = SpacesMobileAttention.events(in: visibleOverview, focusedSessionID: nil, watchWindowsBySessionID: [:]).first?.id else {
                XCTFail("Expected a derived event.")
                return
            }
            let hiddenOverview = makeOverview(
                workspaces: [makeWorkspace(id: "workspace-feature", branch: "feature", isHidden: true)], sessions: [session])

            let retained = SpacesMobileAttention.retainedDismissedEventIDs([liveID], in: hiddenOverview)

            XCTAssertEqual(retained, [liveID])
        }

        /// A dismissal for an event the overview still produces survives a refresh, and one for an event
        /// the device stopped reporting is pruned out of the model's set.
        func testRefreshPrunesStaleDismissalsAndKeepsLiveOnes() async {
            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let liveID = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:]).first?.id
            model.dismissedAlertIDs = [liveID ?? "", "agent:agent-gone|finished|1"]

            await model.refresh()

            XCTAssertEqual(model.dismissedAlertIDs, [liveID ?? ""])
            XCTAssertEqual(model.undismissedAlertCount, 0)
        }

        /// End-to-end through the model: a dismissal must survive a refresh that reports its workspace
        /// hidden and a later refresh that reports it visible again. Only a genuinely new state change (a
        /// later timestamp, minting a new event identity) may bring the alert back.
        func testDismissalSurvivesHidingAndUnhidingItsWorkspaceAcrossRefreshes() async {
            let overviewBox = OverviewBox(
                makeOverview(codingAgentRows: [
                    makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
                ]))
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewBox.get()))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let liveID = SpacesMobileAttention.events(in: overviewBox.get(), focusedSessionID: nil, watchWindowsBySessionID: [:]).first?.id
            model.dismissedAlertIDs = [liveID ?? ""]

            overviewBox.set(
                makeOverview(workspaces: [
                    makeWorkspace(
                        id: "workspace-feature", branch: "feature", isHidden: true,
                        codingAgentRows: [makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")])
                ]))
            await model.refresh()

            XCTAssertEqual(model.dismissedAlertIDs, [liveID ?? ""])
            XCTAssertEqual(model.undismissedAlertCount, 0)

            overviewBox.set(
                makeOverview(codingAgentRows: [
                    makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
                ]))
            await model.refresh()

            XCTAssertEqual(model.dismissedAlertIDs, [liveID ?? ""])
            XCTAssertEqual(model.undismissedAlertCount, 0)
        }

        // MARK: - Per-device dismissal persistence (device switches, Demo Mode, unpairing)

        /// These exercise the real `SpacesMobileDeviceStore`/`SpacesMobileDismissedAlertsStore`
        /// persistence — `UserDefaults.standard` and the Keychain — so each test resets that state before
        /// and after running, matching `SpacesMobileDemoModeTests`.

        /// Dismissing an event while device A is active must not leak into device B: switching to B starts
        /// from an empty bucket, its own overview is undisturbed by A's dismissal, and switching back to A
        /// restores exactly the dismissal it had.
        func testDismissalsAreScopedPerActiveDeviceAcrossASwitch() {
            resetDeviceScopedAlertsState()
            defer { resetDeviceScopedAlertsState() }
            let (deviceA, deviceB) = seedTwoRealDevices()

            let model = SpacesMobileAppModel()
            model.selectDevice(id: deviceA)
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            guard let eventA = model.attentionGroups.first?.events.first else {
                XCTFail("Expected a derived event for device A.")
                return
            }
            model.dismissAlert(eventA)
            XCTAssertEqual(model.undismissedAlertCount, 0)
            XCTAssertEqual(SpacesMobileDismissedAlertsStore.load(deviceID: deviceA), [eventA.id])

            // Device B's own overview derives none of A's events; switching to it starts from an empty
            // bucket rather than inheriting A's dismissal.
            model.selectDevice(id: deviceB)
            XCTAssertTrue(model.dismissedAlertIDs.isEmpty)
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-b", name: "codex", activityState: .waiting, updatedAt: "2026-01-01T00:20:00Z")
            ])
            XCTAssertEqual(model.undismissedAlertCount, 1)

            // A's persisted bucket is untouched by the time spent on B.
            XCTAssertEqual(SpacesMobileDismissedAlertsStore.load(deviceID: deviceA), [eventA.id])

            // Switching back to A reloads its dismissal from storage.
            model.selectDevice(id: deviceA)
            XCTAssertEqual(model.dismissedAlertIDs, [eventA.id])
        }

        /// Turning Demo Mode on swaps the active device to the synthetic Demo Mac, which gets its own,
        /// initially empty bucket; turning it off restores the real device's dismissal exactly as it was,
        /// since the round trip parks (and never rewrites) the real device-store state.
        func testDemoModeSwapKeepsRealDeviceDismissalsIntact() {
            resetDeviceScopedAlertsState()
            defer { resetDeviceScopedAlertsState() }
            let (deviceA, _) = seedTwoRealDevices()

            let model = SpacesMobileAppModel()
            model.selectDevice(id: deviceA)
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            guard let eventA = model.attentionGroups.first?.events.first else {
                XCTFail("Expected a derived event for device A.")
                return
            }
            model.dismissAlert(eventA)
            XCTAssertEqual(SpacesMobileDismissedAlertsStore.load(deviceID: deviceA), [eventA.id])

            model.setDemoMode(true)
            XCTAssertTrue(model.dismissedAlertIDs.isEmpty, "the demo device starts with its own, empty bucket")

            model.setDemoMode(false)

            XCTAssertEqual(model.activeDeviceID, deviceA)
            XCTAssertEqual(model.dismissedAlertIDs, [eventA.id], "the real device's dismissal survives a Demo Mode round trip")
            XCTAssertEqual(SpacesMobileDismissedAlertsStore.load(deviceID: deviceA), [eventA.id])
        }

        /// Unpairing a device drops its persisted dismissal bucket along with it, so the store stays
        /// bounded to devices the app can still show instead of accumulating forever.
        func testRemovingADeviceDropsItsDismissedAlertsBucket() {
            resetDeviceScopedAlertsState()
            defer { resetDeviceScopedAlertsState() }
            let (deviceA, deviceB) = seedTwoRealDevices()

            let model = SpacesMobileAppModel()
            model.selectDevice(id: deviceA)
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            guard let eventA = model.attentionGroups.first?.events.first else {
                XCTFail("Expected a derived event for device A.")
                return
            }
            model.dismissAlert(eventA)
            model.selectDevice(id: deviceB)
            XCTAssertEqual(SpacesMobileDismissedAlertsStore.load(deviceID: deviceA), [eventA.id])

            model.removeDevice(id: deviceA)

            XCTAssertTrue(SpacesMobileDismissedAlertsStore.load(deviceID: deviceA).isEmpty, "an unpaired device's bucket is dropped")
        }

        func testDismissedEventFilteringLeavesOtherEvents() {
            let model = makeModel()
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z"),
                makeAgentRow(id: "agent-b", name: "codex", activityState: .done, updatedAt: "2026-01-01T00:20:00Z"),
            ])
            guard let dismissed = model.attentionGroups.first?.events.last else {
                XCTFail("Expected derived events.")
                return
            }

            model.dismissedAlertIDs.insert(dismissed.id)

            XCTAssertEqual(model.undismissedAlertCount, 1)
            XCTAssertEqual(model.attentionGroups.first?.events.map(\.sourceID), ["agent:agent-b"])
        }

        func testAbbreviatedAge() {
            let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
            XCTAssertEqual(SpacesMobileAttention.abbreviatedAge(of: now.addingTimeInterval(-30), relativeTo: now), "now")
            XCTAssertEqual(SpacesMobileAttention.abbreviatedAge(of: now.addingTimeInterval(-5 * 60), relativeTo: now), "5m")
            XCTAssertEqual(SpacesMobileAttention.abbreviatedAge(of: now.addingTimeInterval(-3 * 3600), relativeTo: now), "3h")
            XCTAssertEqual(SpacesMobileAttention.abbreviatedAge(of: now.addingTimeInterval(-2 * 86400), relativeTo: now), "2d")
        }

        // MARK: - Bell events

        func testSessionWithBellYieldsBellEvent() {
            let overview = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])

            let events = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(events.map(\.sourceID), ["session:session-bell"])
            XCTAssertEqual(events.first?.kind, .bell)
            XCTAssertEqual(events.first?.date, SpacesMobileAttention.date(fromISO8601: "2026-01-01T00:10:00Z"))
        }

        /// A bell row reads exactly as the session's own row does — its name, then what its program is
        /// doing — because its presence under Alerts is what says the bell rang. A state change the row
        /// cannot otherwise show still says so ("Exited").
        func testBellEventIsNamedAndDescribedLikeItsSessionRow() {
            let overview = makeOverview(sessions: [
                makeSession(
                    id: "session-bell", title: "build box", liveTitle: "vim main.swift", state: .running, updatedAt: "2026-01-01T00:00:00Z",
                    bellAt: "2026-01-01T00:10:00Z"),
                makeSession(id: "session-quiet", title: "shell-1", state: .exited, updatedAt: "2026-01-01T00:00:00Z"),
            ])

            let events = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            let bell = events.first { $0.kind == .bell }
            XCTAssertEqual(bell?.title, "build box")
            XCTAssertEqual(bell?.detail, "vim main.swift")
            XCTAssertEqual(events.first { $0.kind == .exited }?.detail, "Exited")
        }

        /// A shell that has reported no title spends no words on the bell itself.
        func testBellEventForASilentShellCarriesNoDetail() {
            let overview = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "shell-1", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])

            let events = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(events.first?.detail, "")
        }

        func testSessionWithoutBellYieldsNoBellEvent() {
            let overview = makeOverview(sessions: [makeSession(id: "session-quiet", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z")]
            )

            XCTAssertTrue(SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:]).isEmpty)
        }

        func testUnchangedBellAtProducesStableEventID() {
            let overview = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])

            let first = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])
            let second = SpacesMobileAttention.events(in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(first.first?.id, second.first?.id)
        }

        func testChangedBellAtProducesNewEventID() {
            let before = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])
            let after = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:20:00Z")
            ])

            let beforeID = SpacesMobileAttention.events(in: before, focusedSessionID: nil, watchWindowsBySessionID: [:]).first?.id
            let afterID = SpacesMobileAttention.events(in: after, focusedSessionID: nil, watchWindowsBySessionID: [:]).first?.id

            XCTAssertNotEqual(beforeID, afterID)
        }

        func testFocusedSessionSuppressesItsBellEvent() {
            let overview = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])

            XCTAssertTrue(SpacesMobileAttention.events(in: overview, focusedSessionID: "session-bell", watchWindowsBySessionID: [:]).isEmpty)
        }

        /// Overview polling is paused while a terminal detail is open, so the bell rung while the user was
        /// watching only arrives after they back out — by which time the session is no longer focused.
        func testBellRungWhileWatchingIsSuppressedAfterBackingOut() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            let bellRungWhileWatching = clock.advance(60)
            clock.advance(60)
            model.setActiveTerminalSession(nil)

            model.overview = bellOverview(at: bellRungWhileWatching)

            XCTAssertEqual(model.undismissedAlertCount, 0)
        }

        func testBellRungAfterBackingOutStillAlerts() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            model.setActiveTerminalSession(nil)

            model.overview = bellOverview(at: clock.advance(60))

            XCTAssertEqual(model.attentionGroups.first?.events.map(\.kind), [.bell])
        }

        /// A bell that rang before the user ever opened the session is not something they watched, so
        /// opening and leaving the detail afterwards does not swallow its alert.
        func testBellRungBeforeTheWatchStartedStillAlerts() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            let bellRungBeforeOpening = clock.now
            clock.advance(60)
            model.setActiveTerminalSession("session-bell")
            model.setActiveTerminalSession(nil)

            model.overview = bellOverview(at: bellRungBeforeOpening)

            XCTAssertEqual(model.attentionGroups.first?.events.map(\.kind), [.bell])
        }

        func testBellAfterASuppressedOneStillAlerts() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            let bellRungWhileWatching = clock.advance(60)
            clock.advance(60)
            model.setActiveTerminalSession(nil)

            model.overview = bellOverview(at: bellRungWhileWatching)
            XCTAssertEqual(model.undismissedAlertCount, 0)

            model.overview = bellOverview(at: clock.advance(60))
            XCTAssertEqual(model.attentionGroups.first?.events.map(\.kind), [.bell])
        }

        /// Switching straight from one session's detail to another ends the watch on the one left behind.
        func testSwitchingSessionsEndsTheWatchOnTheOneLeftBehind() {
            let model = makeModel()
            model.setActiveTerminalSession("session-bell")
            model.setActiveTerminalSession("session-other")

            XCTAssertEqual(model.activeTerminalSessionID, "session-other")
            XCTAssertNotNil(model.terminalWatchWindowsBySessionID["session-bell"])
            XCTAssertNil(model.terminalWatchWindowsBySessionID["session-other"])
        }

        // MARK: - Terminal detail torn down without a route change

        /// Switching devices re-identifies the tab and destroys the navigation stack, so the detail leaves
        /// the screen without `selectedSession` ever going nil. The watch has to end there: a bell rung
        /// afterwards, with no terminal on screen, is one the user could not have seen.
        func testTerminalTeardownEndsTheWatchSoLaterBellsAlert() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            clock.advance(60)
            model.endTerminalWatch(forSessionID: "session-bell")
            let bellRungWithNoTerminalOnScreen = clock.advance(60)
            // Some later visit to another session ends its own watch; the torn-down session's window must
            // already be closed rather than stretching to here.
            clock.advance(60)
            model.setActiveTerminalSession("session-other")
            clock.advance(60)
            model.setActiveTerminalSession(nil)

            model.overview = bellOverview(at: bellRungWithNoTerminalOnScreen)

            XCTAssertNil(model.watchedTerminalSessionID)
            XCTAssertEqual(model.attentionGroups.first?.events.map(\.kind), [.bell])
        }

        /// The ordinary back-out drives both the route change and the detail's teardown, so the second one
        /// must be a no-op — two windows would be a second, empty watch recorded after the user left.
        func testNormalBackOutRecordsExactlyOneWatchWindow() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            clock.advance(60)
            model.setActiveTerminalSession(nil)
            model.endTerminalWatch(forSessionID: "session-bell")

            XCTAssertEqual(model.terminalWatchWindowsBySessionID["session-bell"]?.count, 1)
        }

        /// A teardown that lands after the user has already moved to another session's detail belongs to
        /// the view that is going away, not to the one on screen.
        func testTeardownOfAPreviousSessionLeavesTheCurrentWatchRunning() {
            let model = makeModel()
            model.setActiveTerminalSession("session-bell")
            model.setActiveTerminalSession("session-other")

            model.endTerminalWatch(forSessionID: "session-bell")

            XCTAssertEqual(model.watchedTerminalSessionID, "session-other")
        }

        // MARK: - Bells while the app is in the background

        /// Backgrounding does not close the detail route, so nothing about the route says the user stopped
        /// watching — but they did, and a bell rung while the app was away is exactly what the Alerts tab
        /// exists for.
        func testBellRungWhileBackgroundedAlertsEvenThoughTheRouteStayedOpen() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            clock.advance(60)
            model.suspendTerminalWatch()

            model.overview = bellOverview(at: clock.advance(60))

            XCTAssertNil(model.watchedTerminalSessionID, "a backgrounded app is watching nothing")
            XCTAssertEqual(model.attentionGroups.first?.events.map(\.kind), [.bell])
        }

        /// The realistic sequence: overview polling is paused the whole time, so the bell only arrives on
        /// the refresh after the user comes back and leaves the detail. The watch recorded on the way out
        /// must not cover the stretch the app spent in the background.
        func testBellRungWhileBackgroundedStillAlertsAfterForegroundingAndBackingOut() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            clock.advance(60)
            model.suspendTerminalWatch()
            let bellRungWhileAway = clock.advance(60)
            clock.advance(60)
            model.resumeTerminalWatch()
            clock.advance(60)
            model.setActiveTerminalSession(nil)

            model.overview = bellOverview(at: bellRungWhileAway)

            XCTAssertEqual(model.attentionGroups.first?.events.map(\.kind), [.bell])
        }

        /// The whole visit, in order: the user watches the terminal and hears the bell, backgrounds the
        /// app, comes back to the still-open detail, then leaves it — and only then does polling resume and
        /// deliver that bell. Every watch of the session has to be remembered for it to stay suppressed;
        /// keeping only the latest would raise an alert for a bell the user watched ring.
        func testBellRungBeforeBackgroundingStaysSuppressedAfterForegroundingAndBackingOut() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            let bellRungWhileWatching = clock.advance(60)
            clock.advance(60)
            model.suspendTerminalWatch()
            clock.advance(60)
            model.resumeTerminalWatch()
            clock.advance(60)
            model.setActiveTerminalSession(nil)

            model.overview = bellOverview(at: bellRungWhileWatching)

            XCTAssertEqual(model.undismissedAlertCount, 0)
        }

        /// The counterpart of the sequence above: the windows either side of the background stretch are
        /// never merged, so a bell rung in the gap between them still alerts.
        func testBellRungInTheGapBetweenTwoWatchesAlerts() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            clock.advance(60)
            model.suspendTerminalWatch()
            let bellRungInTheGap = clock.advance(60)
            clock.advance(60)
            model.resumeTerminalWatch()
            clock.advance(60)
            model.setActiveTerminalSession(nil)

            model.overview = bellOverview(at: bellRungInTheGap)

            XCTAssertEqual(model.terminalWatchWindowsBySessionID["session-bell"]?.count, 2)
            XCTAssertEqual(model.attentionGroups.first?.events.map(\.kind), [.bell])
        }

        /// A visit that backgrounds and returns many times cannot grow without bound; the windows that
        /// survive are the newest, which are the ones an arriving bell can still fall inside.
        func testWatchWindowsArePrunedOldestFirst() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            let bellRungInTheFirstWatch = clock.advance(1)
            for _ in 0..<12 {
                clock.advance(60)
                model.suspendTerminalWatch()
                clock.advance(60)
                model.resumeTerminalWatch()
            }
            clock.advance(60)
            model.setActiveTerminalSession(nil)

            let windows = model.terminalWatchWindowsBySessionID["session-bell"] ?? []
            XCTAssertEqual(windows.count, 8)
            XCTAssertEqual(windows, windows.sorted { $0.endedAt < $1.endedAt }, "windows are kept oldest first")
            // The dropped windows really are gone: a bell from the first, evicted watch no longer matches.
            model.overview = bellOverview(at: bellRungInTheFirstWatch)
            XCTAssertEqual(model.attentionGroups.first?.events.map(\.kind), [.bell])
        }

        /// The bell the user did watch — rung before the app went away — stays suppressed.
        func testBellRungBeforeBackgroundingIsSuppressed() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            let bellRungWhileWatching = clock.advance(60)
            clock.advance(60)
            model.suspendTerminalWatch()

            model.overview = bellOverview(at: bellRungWhileWatching)

            XCTAssertEqual(model.undismissedAlertCount, 0)
        }

        /// Coming back to the foreground with the detail still open resumes the watch, so a bell rung then
        /// is happening in front of the user and is suppressed as focused.
        func testForegroundingWithTheRouteOpenResumesTheWatch() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.setActiveTerminalSession("session-bell")
            model.suspendTerminalWatch()
            clock.advance(60)
            model.resumeTerminalWatch()

            model.overview = bellOverview(at: clock.advance(60))

            XCTAssertEqual(model.watchedTerminalSessionID, "session-bell")
            XCTAssertEqual(model.undismissedAlertCount, 0)
        }

        /// Foregrounding with no detail open starts nothing: the next session the user opens should be
        /// watched from the moment they open it, not from the moment the app came back.
        func testForegroundingWithNoRouteOpenWatchesNothing() {
            let model = makeModel()
            model.resumeTerminalWatch()

            XCTAssertNil(model.watchedTerminalSessionID)
        }

        // MARK: - Fixtures

        /// An overview whose one session rang its bell at `date`, stamped the way a daemon stamps it.
        private func bellOverview(at date: Date) -> SpacesDeviceOverviewPayload {
            makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: iso8601(date))
            ])
        }

        /// Formats `date` the way the daemon stamps `bellAt`, for tests that need a session fixture beyond
        /// `bellOverview`'s fixed shape (e.g. one paired with a process row on the same session).
        private func iso8601(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }

        /// Wall clock the watch-window tests step by hand. Watch windows are compared against bell
        /// timestamps with a couple of seconds of skew tolerance, so the real clock's sub-millisecond gaps
        /// between two calls would put every timestamp inside every window.
        private final class TestWallClock: @unchecked Sendable {
            private(set) var now = Date(timeIntervalSinceReferenceDate: 1_000_000)

            @discardableResult func advance(_ seconds: TimeInterval) -> Date {
                now = now.addingTimeInterval(seconds)
                return now
            }
        }

        /// Lock-guarded overview box so a fake bridge client's `@Sendable` closure can hand back whatever
        /// overview the test most recently set, letting successive `model.refresh()` calls see different
        /// payloads (e.g. a workspace going hidden, then visible again).
        private final class OverviewBox: @unchecked Sendable {
            private let lock = NSLock()
            private var overview: SpacesDeviceOverviewPayload

            init(_ overview: SpacesDeviceOverviewPayload) { self.overview = overview }

            func set(_ overview: SpacesDeviceOverviewPayload) {
                lock.lock()
                self.overview = overview
                lock.unlock()
            }

            func get() -> SpacesDeviceOverviewPayload {
                lock.lock()
                defer { lock.unlock() }
                return overview
            }
        }

        private func makeModel(clock: TestWallClock? = nil) -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            guard let clock else { return SpacesMobileAppModel(settings: settings, bridgeClient: client) }
            return SpacesMobileAppModel(settings: settings, bridgeClient: client, wallClock: { clock.now })
        }

        /// Clears the real, on-disk paired-device and dismissed-alerts state the per-device persistence
        /// tests exercise, matching `SpacesMobileDemoModeTests`'s reset of the same `UserDefaults.standard`
        /// keys plus the Keychain-backed device store.
        private func resetDeviceScopedAlertsState() {
            for device in SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings()).devices {
                _ = SpacesMobileDeviceStore.remove(deviceID: device.id, fallbackSettings: SpacesMobileConnectionSettings())
            }
            let defaults = UserDefaults.standard
            for key in [
                "spaces.mobile.paired-devices", "spaces.mobile.active-device-id", "spaces.mobile.connection-settings",
                "spaces.mobile.demo-mode-enabled", SpacesMobileDismissedAlertsStore.dismissedIDsKey,
            ] { defaults.removeObject(forKey: key) }
        }

        /// Pairs two real devices in the on-disk store and returns their assigned ids.
        private func seedTwoRealDevices() -> (deviceA: String, deviceB: String) {
            let stateA = SpacesMobileDeviceStore.upsert(
                settings: realDeviceSettings(host: "10.0.0.10", fingerprint: "SHA256:device-a", token: "token-a"), name: "Device A")
            let stateB = SpacesMobileDeviceStore.upsert(
                settings: realDeviceSettings(host: "10.0.0.11", fingerprint: "SHA256:device-b", token: "token-b"), name: "Device B")
            guard let deviceA = stateA.devices.first(where: { $0.name == "Device A" })?.id,
                let deviceB = stateB.devices.first(where: { $0.name == "Device B" })?.id
            else { fatalError("Expected both seeded devices to be present in the store.") }
            return (deviceA, deviceB)
        }

        private func realDeviceSettings(host: String, fingerprint: String, token: String) -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = [host]
            settings.port = 47_900
            settings.certificateFingerprint = fingerprint
            settings.authToken = token
            return settings
        }

        // `makeOverview`/`makeWorkspace`/`makeAgentRow` live in `SpacesMobileOverviewFixtures.swift`,
        // shared with `SpacesMobileAgentsTests`.

        private func makeProcessRow(id: String, name: String, sessionID: String? = nil, runState: SpacesDeviceRunState, exitedAt: String?)
            -> SpacesDeviceWorkspaceProcessRow
        {
            SpacesDeviceWorkspaceProcessRow(
                id: id, workspaceID: "workspace-feature", name: name, command: "npm run \(name)", processID: "runtime-\(id)", sessionID: sessionID,
                runState: runState, exitedAt: exitedAt, canRun: runState != .running, canStop: runState == .running, canRestart: runState == .running)
        }

        private func makeTerminalRow(id: String, title: String, sessionID: String?, runState: SpacesDeviceRunState)
            -> SpacesDeviceWorkspaceTerminalRow
        {
            SpacesDeviceWorkspaceTerminalRow(
                id: id, workspaceID: "workspace-feature", title: title, workingDirectory: "/repo/workspace-feature", sessionID: sessionID,
                runState: runState, canOpenTerminal: runState == .running)
        }

        private func makeSession(
            id: String, title: String, liveTitle: String? = nil, state: TerminalSessionState, updatedAt: String, bellAt: String? = nil
        ) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: id, title: title, liveTitle: liveTitle, workingDirectory: "/repo/workspace-feature", shell: "/bin/zsh", command: nil,
                state: state, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: nil,
                workspaceID: "workspace-feature", workspaceTitle: "feature", projectID: "project-1", projectName: "Project",
                createdAt: "2026-01-01T00:00:00Z", updatedAt: updatedAt, isControlAvailable: state == .running,
                isSubscriptionAvailable: state == .running, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), bellAt: bellAt)
        }
    }
#endif

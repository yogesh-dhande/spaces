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

            let events = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

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

            XCTAssertTrue(
                SpacesMobileAttention.events(deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])
                    .isEmpty)
        }

        func testAcceptsFractionalLinuxDaemonTimestamps() {
            let overview = makeOverview(
                processRows: [makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: "2026-07-12T12:34:56.123Z")],
                sessions: [makeSession(id: "session-loose", title: "zsh", state: .failed, updatedAt: "2026-07-12T12:34:57.456Z")])

            let events = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(Set(events.map(\.sourceID)), ["process:process-web", "session:session-loose"])
            XCTAssertTrue(events.allSatisfy { $0.date.timeIntervalSince1970 > 0 })
        }

        func testSessionRepresentedByProcessRowProducesOneEvent() {
            let overview = makeOverview(
                processRows: [
                    makeProcessRow(id: "process-web", name: "web", sessionID: "session-web", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")
                ], sessions: [makeSession(id: "session-web", title: "web", state: .exited, updatedAt: "2026-01-01T00:05:30Z")])

            let events = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(events.map(\.sourceID), ["process:process-web"])
        }

        func testExitedTerminalRowUsesLinkedSessionTimestamp() {
            let overview = makeOverview(
                terminalRows: [
                    makeTerminalRow(id: "terminal-shell", title: "zsh", sessionID: "session-shell", runState: .exited),
                    makeTerminalRow(id: "terminal-untracked", title: "lost", sessionID: nil, runState: .exited),
                ], sessions: [makeSession(id: "session-shell", title: "zsh", state: .failed, updatedAt: "2026-01-01T00:07:00Z")])

            let events = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

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

            XCTAssertTrue(
                SpacesMobileAttention.events(deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])
                    .isEmpty)
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

            XCTAssertTrue(
                SpacesMobileAttention.events(deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])
                    .isEmpty)
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

            XCTAssertTrue(
                SpacesMobileAttention.events(deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])
                    .isEmpty)
            XCTAssertTrue(
                SpacesMobileAttention.events(
                    deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:],
                    includingHiddenWorkspaces: true
                ).isEmpty)
        }

        /// The Alerts tab shows one flat, newest-first list, not workspace bands: `model.attentionEvents`
        /// sorts across every workspace by date alone, and each event's own `detail` carries the
        /// project/workspace identity that a band header would otherwise be the only place showing.
        func testAttentionEventsSortNewestFirstAcrossWorkspacesAndCarryProjectWorkspaceInDetail() {
            let model = makeModel()
            model.overview = makeOverview(workspaces: [
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

            let events = model.attentionEvents

            XCTAssertEqual(events.map(\.sourceID), ["agent:agent-new-late", "agent:agent-new-early", "agent:agent-old"])
            XCTAssertEqual(events.first?.detail, "Project / new")
        }

        // MARK: - Row acknowledgment (dismissed-exit-alert-inactive)

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
                key: "k", sourceID: "process:process-web", kind: .exited, date: now, title: "web", rowType: .processes, sessionID: "session-a",
                workspaceID: "workspace-feature", deviceID: "device-a", projectName: "Project", workspaceDisplayName: "feature", deviceText: nil,
                isDeviceOffline: false)
            let ownBell = SpacesMobileAttentionEvent(
                key: "k", sourceID: "session:session-a", kind: .bell, date: now, title: "web", rowType: .processes, sessionID: "session-a",
                workspaceID: "workspace-feature", deviceID: "device-a", projectName: "Project", workspaceDisplayName: "feature", deviceText: nil,
                isDeviceOffline: false)
            let otherProcessSameWorkspace = SpacesMobileAttentionEvent(
                key: "k", sourceID: "process:process-other", kind: .exited, date: now, title: "other", rowType: .processes, sessionID: "session-b",
                workspaceID: "workspace-feature", deviceID: "device-a", projectName: "Project", workspaceDisplayName: "feature", deviceText: nil,
                isDeviceOffline: false)
            let sameSourceIDOtherWorkspace = SpacesMobileAttentionEvent(
                key: "k", sourceID: "process:process-web", kind: .exited, date: now, title: "web", rowType: .processes, sessionID: "session-a",
                workspaceID: "workspace-other", deviceID: "device-a", projectName: "Project", workspaceDisplayName: "other", deviceText: nil,
                isDeviceOffline: false)
            let bellOnAnotherSession = SpacesMobileAttentionEvent(
                key: "k", sourceID: "session:session-b", kind: .bell, date: now, title: "other", rowType: .processes, sessionID: "session-b",
                workspaceID: "workspace-feature", deviceID: "device-a", projectName: "Project", workspaceDisplayName: "feature", deviceText: nil,
                isDeviceOffline: false)

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
            let processRow = makeProcessRow(
                id: "process-web", name: "web", sessionID: "session-a", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")
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

            XCTAssertEqual(
                Set(model.undismissedAlerts(for: processRuntimeRow, deviceID: "device-a").map(\.sourceID)),
                ["process:process-web", "session:session-a"])
            XCTAssertEqual(model.undismissedAlerts(for: agentRuntimeRow, deviceID: "device-a").map(\.sourceID), ["agent:agent-a"])
            XCTAssertEqual(model.undismissedAlerts(for: terminalRuntimeRow, deviceID: "device-a").map(\.sourceID), ["terminal:terminal-a"])
            XCTAssertTrue(model.hasDismissableAlerts(for: processRuntimeRow, deviceID: "device-a"))
            XCTAssertTrue(model.hasDismissableAlerts(for: agentRuntimeRow, deviceID: "device-a"))
            XCTAssertTrue(model.hasDismissableAlerts(for: terminalRuntimeRow, deviceID: "device-a"))
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
                        id: "session-bell", title: "web", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: iso8601(bellRungWhileWatching))
                ])

            XCTAssertTrue(model.undismissedAlerts(for: row, deviceID: "device-a").isEmpty)
            XCTAssertFalse(model.hasDismissableAlerts(for: row, deviceID: "device-a"))

            // The same bell, rung outside any watch window, is one the user has not seen yet.
            let bellOutsideAnyWatch = clock.advance(60)
            model.overview = makeOverview(
                processRows: [processRow],
                sessions: [
                    makeSession(
                        id: "session-bell", title: "web", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: iso8601(bellOutsideAnyWatch))
                ])

            XCTAssertFalse(model.undismissedAlerts(for: row, deviceID: "device-a").isEmpty)
            XCTAssertTrue(model.hasDismissableAlerts(for: row, deviceID: "device-a"))
        }

        /// The same suppression has to hold for a non-selected device's row too: `watchedTerminalSessionID`
        /// and the watch-window store are shared app state, not scoped to the selected device, since a
        /// terminal opened from an Agents/Alerts row can belong to any paired device.
        func testUndismissedAlertsSuppressesAWatchedBellOnANonSelectedDeviceToo() {
            let clock = TestWallClock()
            let model = makeModel(clock: clock)
            model.pairedDevices = [makeDeviceRecord(id: Self.testDeviceID), makeDeviceRecord(id: "device-b")]
            let processRow = makeProcessRow(id: "process-web", name: "web", sessionID: "session-bell", runState: .running, exitedAt: nil)
            let row = SpacesMobileWorkspaceRuntimeRow(source: .process(processRow))
            model.setActiveTerminalSession("session-bell")
            let bellRungWhileWatching = clock.advance(60)
            clock.advance(60)
            model.setActiveTerminalSession(nil)

            model.setDeviceOverviewForTesting(
                makeOverview(
                    processRows: [processRow],
                    sessions: [
                        makeSession(
                            id: "session-bell", title: "web", state: .running, updatedAt: "2026-01-01T00:00:00Z",
                            bellAt: iso8601(bellRungWhileWatching))
                    ]), deviceID: "device-b")

            XCTAssertTrue(model.undismissedAlerts(for: row, deviceID: "device-b").isEmpty, "a watch window applies to a non-selected device too")
        }

        // MARK: - Cross-device Alerts (Agents and Alerts tabs list every paired device)

        /// A second paired device's alerts join the flat list, sorted by date across both devices rather
        /// than grouped by device, and an automation-run alert merges into the same list alongside
        /// attention events (`SpacesMobileAppModel.alertItems`).
        func testAlertItemsMergeAcrossDevicesNewestFirstIncludingAnAutomationAlert() {
            let model = makeModel()
            model.pairedDevices = [makeDeviceRecord(id: Self.testDeviceID), makeDeviceRecord(id: "device-b")]
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-old", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:01:00Z")
            ])
            model.setDeviceOverviewForTesting(
                makeOverview(codingAgentRows: [
                    makeAgentRow(id: "agent-new", name: "codex", activityState: .waiting, updatedAt: "2026-01-01T00:30:00Z")
                ]), deviceID: "device-b")

            let items = model.alertItems

            XCTAssertEqual(items.count, 2)
            // Newest first regardless of which device it came from: device B's later event leads.
            guard case .event(let first) = items[0], case .event(let second) = items[1] else {
                XCTFail("Expected two attention events.")
                return
            }
            XCTAssertEqual(first.sourceID, "agent:agent-new")
            XCTAssertEqual(second.sourceID, "agent:agent-old")
            // Two paired devices widens the device segment on every row, including device A's.
            XCTAssertEqual(second.deviceText, Self.testDeviceID)
            XCTAssertEqual(first.deviceText, "device-b")
        }

        /// The device segment is hidden only with exactly one paired device, online; a second paired
        /// device (even one with no cached overview yet) widens it on every row, matching the Mac
        /// sidebar's own rule.
        func testDeviceSegmentHiddenOnlyWithExactlyOnePairedOnlineDevice() {
            let model = makeModel()
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            XCTAssertNil(model.attentionEvents.first?.deviceText, "one online paired device shows no device text")

            model.pairedDevices = [makeDeviceRecord(id: Self.testDeviceID), makeDeviceRecord(id: "device-b")]
            XCTAssertEqual(model.attentionEvents.first?.deviceText, Self.testDeviceID, "a second paired device widens the segment")
        }

        /// An offline device's alerts stay listed (not dropped), carry "(offline)" in their device text,
        /// and their `isDeviceOffline` flag is what the Alerts/Agents tabs dim the row on.
        func testOfflineDevicesAlertsStayListedAndMarkedOffline() {
            let model = makeModel()
            model.pairedDevices = [makeDeviceRecord(id: Self.testDeviceID)]
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            model.setOfflineForTesting(true, deviceID: Self.testDeviceID)

            guard let event = model.attentionEvents.first else {
                XCTFail("Expected an offline device's event to stay listed.")
                return
            }
            XCTAssertTrue(event.isDeviceOffline)
            XCTAssertEqual(event.deviceText, "\(Self.testDeviceID) (offline)")

            // Recovering (the stream delivers again) clears both the offline marking and the "(offline)"
            // text on the next derivation.
            model.setOfflineForTesting(false, deviceID: Self.testDeviceID)
            XCTAssertFalse(model.attentionEvents.first?.isDeviceOffline ?? true)
        }

        /// The Alerts tab badge counts an offline device's own undismissed alerts the same as any other
        /// paired device's, so it always equals the number of rows the tab actually shows.
        func testBadgeCountsAnOfflineDevicesAlertsToo() {
            let model = makeModel()
            model.pairedDevices = [makeDeviceRecord(id: Self.testDeviceID), makeDeviceRecord(id: "device-b")]
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            model.setDeviceOverviewForTesting(
                makeOverview(codingAgentRows: [makeAgentRow(id: "agent-b", name: "codex", activityState: .waiting, updatedAt: "2026-01-01T00:20:00Z")]
                ), deviceID: "device-b")
            model.setOfflineForTesting(true, deviceID: "device-b")

            XCTAssertEqual(model.undismissedAlertCount, 2, "device B's alert still counts toward the badge while offline")
        }

        /// An auth rejection on the selected device nils `model.overview` (`handleAuthenticationFailure`),
        /// but the same delivery is still sitting in `deviceOverviews[activeDeviceID]` (every stream push
        /// writes there before publishing to `overview`, including for the selected device). Agents/Alerts
        /// read through `overview(forDeviceID:)`, which falls back to that cache, so the selected device's
        /// rows and badge count survive the rejection instead of vanishing until the next successful
        /// refresh republishes `overview`.
        func testSelectedDeviceKeepsItsRowsAfterAuthFailureClearsOverview() {
            let model = makeModel()
            model.pairedDevices = [makeDeviceRecord(id: Self.testDeviceID)]
            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
            ])
            model.overview = overview
            model.setDeviceOverviewForTesting(overview, deviceID: Self.testDeviceID)

            model.handleAuthenticationFailure(message: "Device rejected this iPhone.")

            XCTAssertNil(model.overview, "handleAuthenticationFailure should still clear the published overview")
            XCTAssertEqual(model.attentionEvents.count, 1, "the selected device's row should survive via the stream cache fallback")
            XCTAssertEqual(model.undismissedAlertCount, 1, "the badge count should still reflect the surviving row")
            XCTAssertFalse(model.attentionEvents.first?.isDeviceOffline ?? true, "an auth failure alone does not mark the device offline")

            // An auth failure that also leaves the device offline (the stream drops with it) keeps
            // showing the row, now dimmed, rather than dropping it.
            model.setOfflineForTesting(true, deviceID: Self.testDeviceID)
            XCTAssertEqual(model.attentionEvents.count, 1, "the row should still show while offline")
            XCTAssertTrue(model.attentionEvents.first?.isDeviceOffline ?? false, "the surviving row should be marked offline for dimming")
        }

        // MARK: - Bell events

        func testSessionWithBellYieldsBellEvent() {
            let overview = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])

            let events = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(events.map(\.sourceID), ["session:session-bell"])
            XCTAssertEqual(events.first?.kind, .bell)
            XCTAssertEqual(events.first?.date, SpacesMobileAttention.date(fromISO8601: "2026-01-01T00:10:00Z"))
        }

        /// A bell row is named for its session, like every other row, but its detail line is the flat
        /// cross-device list's project/workspace text, not the session's live title or exit status (see
        /// `SpacesMobileAttentionEvent.detail`).
        func testBellEventIsNamedForItsSessionAndCarriesProjectWorkspaceDetail() {
            let overview = makeOverview(sessions: [
                makeSession(
                    id: "session-bell", title: "build box", liveTitle: "vim main.swift", state: .running, updatedAt: "2026-01-01T00:00:00Z",
                    bellAt: "2026-01-01T00:10:00Z"),
                makeSession(id: "session-quiet", title: "shell-1", state: .exited, updatedAt: "2026-01-01T00:00:00Z"),
            ])

            let events = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            let bell = events.first { $0.kind == .bell }
            XCTAssertEqual(bell?.title, "build box")
            XCTAssertEqual(bell?.detail, "Project / feature")
            XCTAssertEqual(events.first { $0.kind == .exited }?.detail, "Project / feature")
        }

        /// The detail line never depends on the session's live title: a bell on a silent shell (nothing
        /// running to report) still carries the same project/workspace text as any other row.
        func testBellEventDetailIsProjectAndWorkspaceRegardlessOfLiveTitle() {
            let overview = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "shell-1", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])

            let events = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(events.first?.detail, "Project / feature")
        }

        func testSessionWithoutBellYieldsNoBellEvent() {
            let overview = makeOverview(sessions: [makeSession(id: "session-quiet", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z")]
            )

            XCTAssertTrue(
                SpacesMobileAttention.events(deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])
                    .isEmpty)
        }

        func testUnchangedBellAtProducesStableEventID() {
            let overview = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])

            let first = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])
            let second = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:])

            XCTAssertEqual(first.first?.id, second.first?.id)
        }

        func testChangedBellAtProducesNewEventID() {
            let before = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])
            let after = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:20:00Z")
            ])

            let beforeID = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: before, focusedSessionID: nil, watchWindowsBySessionID: [:]
            ).first?.id
            let afterID = SpacesMobileAttention.events(
                deviceID: "device-a", deviceText: nil, in: after, focusedSessionID: nil, watchWindowsBySessionID: [:]
            ).first?.id

            XCTAssertNotEqual(beforeID, afterID)
        }

        func testFocusedSessionSuppressesItsBellEvent() {
            let overview = makeOverview(sessions: [
                makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z", bellAt: "2026-01-01T00:10:00Z")
            ])

            XCTAssertTrue(
                SpacesMobileAttention.events(
                    deviceID: "device-a", deviceText: nil, in: overview, focusedSessionID: "session-bell", watchWindowsBySessionID: [:]
                ).isEmpty)
        }

        /// A bell for the focused session is excluded live; once the user backs out the session is no
        /// longer focused, so the bell that rang while they were watching surfaces then.
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

            XCTAssertEqual(model.attentionEvents.map(\.kind), [.bell])
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

            XCTAssertEqual(model.attentionEvents.map(\.kind), [.bell])
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
            XCTAssertEqual(model.attentionEvents.map(\.kind), [.bell])
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
            XCTAssertEqual(model.attentionEvents.map(\.kind), [.bell])
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
            XCTAssertEqual(model.attentionEvents.map(\.kind), [.bell])
        }

        /// The realistic sequence: no stream is open while backgrounded, so the bell only arrives on the
        /// overview fetched after the user comes back and leaves the detail. The watch recorded on the way
        /// out must not cover the stretch the app spent in the background.
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

            XCTAssertEqual(model.attentionEvents.map(\.kind), [.bell])
        }

        /// The whole visit, in order: the user watches the terminal and hears the bell, backgrounds the
        /// app, comes back to the still-open detail, then leaves it, and only then does the next overview
        /// delivery report that bell. Every watch of the session has to be remembered for it to stay
        /// suppressed; keeping only the latest would raise an alert for a bell the user watched ring.
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
            XCTAssertEqual(model.attentionEvents.map(\.kind), [.bell])
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
            XCTAssertEqual(model.attentionEvents.map(\.kind), [.bell])
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

        // MARK: - Dismissal is the device's call

        /// A model whose selected device is `device`: every request goes to it and its answers become the
        /// model's overview, the way a real device's mutation responses do.
        private func makeDeviceModel(_ device: FakeAlertDevice, clock: ManualVisitClock? = nil) -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let client = device.client(settings: settings)
            let model =
                clock.map { clock in
                    SpacesMobileAppModel(settings: settings, bridgeClient: client, wallClock: { clock.now }, visitSchedule: clock.schedule)
                } ?? SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.pairedDevices = [makeDeviceRecord(id: Self.testDeviceID)]
            model.activeDeviceID = Self.testDeviceID
            model.overview = device.currentOverview
            return model
        }

        /// Adds `device` to `model` as a second, non-selected paired device.
        private func addSecondDevice(_ device: FakeAlertDevice, to model: SpacesMobileAppModel, id: String = "device-b") {
            let record = makeDeviceRecord(id: id)
            // The model reuses a cached client only while its settings equal the paired record's.
            let settings = SpacesMobileDeviceStore.settings(from: record, installationID: model.settings.installationID)
            model.pairedDevices.append(record)
            model.setNonActiveDeviceStreamClientForTesting(device.client(settings: settings), settings: settings, deviceID: id)
            model.setDeviceOverviewForTesting(device.currentOverview, deviceID: id)
        }

        private func waitingAgentOverview(updatedAt: String = "2026-01-01T00:10:00Z") -> SpacesDeviceOverviewPayload {
            makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: updatedAt),
                makeAgentRow(id: "agent-b", name: "codex", activityState: .done, updatedAt: "2026-01-01T00:20:00Z"),
            ])
        }

        func testDismissAlertAsksItsDeviceAndTheListChangesWhenTheOverviewReturns() async throws {
            let device = FakeAlertDevice(overview: waitingAgentOverview())
            let model = makeDeviceModel(device)
            let event = try XCTUnwrap(model.attentionEvents.first { $0.sourceID == "agent:agent-a" })

            await model.dismissAlert(event)

            XCTAssertEqual(device.commands, [.dismissAlerts([event.key])])
            XCTAssertEqual(model.attentionEvents.map(\.sourceID), ["agent:agent-b"])
            XCTAssertEqual(model.undismissedAlertCount, 1)
        }

        func testNothingIsHiddenBeforeTheDeviceConfirms() async throws {
            let device = FakeAlertDevice(overview: waitingAgentOverview())
            device.appliesRequests = false
            let model = makeDeviceModel(device)
            let event = try XCTUnwrap(model.attentionEvents.first)

            await model.dismissAlert(event)

            XCTAssertEqual(device.commands.count, 1)
            XCTAssertEqual(model.undismissedAlertCount, 2, "the list changes when the device's overview says so, not on the tap")
        }

        func testANewStateChangeOfADismissedSourceAlertsAgain() async throws {
            let device = FakeAlertDevice(overview: waitingAgentOverview())
            let model = makeDeviceModel(device)
            let event = try XCTUnwrap(model.attentionEvents.first { $0.sourceID == "agent:agent-a" })
            await model.dismissAlert(event)
            let dismissedKeys = device.currentOverview.dismissedAlertKeys

            model.overview = waitingAgentOverview(updatedAt: "2026-01-01T00:30:00Z").replacingAlertState(
                dismissedAlertKeys: dismissedKeys, comeBackLaterFlags: [])

            XCTAssertEqual(Set(model.attentionEvents.map(\.sourceID)), ["agent:agent-a", "agent:agent-b"])
        }

        func testWhatIsDismissedIsEachDevicesOwn() {
            let overview = waitingAgentOverview()
            let dismissingDevice = FakeAlertDevice(
                overview: overview.replacingAlertState(
                    dismissedAlertKeys: overview.alertCandidates().filter { $0.subjectID == "agent-a" }.map(\.key), comeBackLaterFlags: []))
            let model = makeDeviceModel(dismissingDevice)
            addSecondDevice(FakeAlertDevice(overview: overview), to: model)

            let remaining = model.attentionEvents.filter { $0.sourceID == "agent:agent-a" }

            XCTAssertEqual(remaining.map(\.deviceID), ["device-b"], "the same alert, dismissed on one device, still shows for the other")
        }

        func testDismissalGoesToTheDeviceThatOwnsTheAlert() async throws {
            let deviceA = FakeAlertDevice(overview: waitingAgentOverview())
            let deviceB = FakeAlertDevice(overview: waitingAgentOverview())
            let model = makeDeviceModel(deviceA)
            addSecondDevice(deviceB, to: model)
            let eventOnB = try XCTUnwrap(model.attentionEvents.first { $0.deviceID == "device-b" && $0.sourceID == "agent:agent-a" })

            await model.dismissAlert(eventOnB)

            XCTAssertTrue(deviceA.commands.isEmpty)
            XCTAssertEqual(deviceB.commands, [.dismissAlerts([eventOnB.key])])
            XCTAssertEqual(model.attentionEvents.filter { $0.deviceID == "device-b" }.map(\.sourceID), ["agent:agent-b"])
        }

        func testClearDismissesOnlyOnlineDevicesAndLeavesAnOfflineDevicesItemsListed() async {
            let deviceA = FakeAlertDevice(overview: waitingAgentOverview())
            let deviceB = FakeAlertDevice(overview: waitingAgentOverview())
            let model = makeDeviceModel(deviceA)
            addSecondDevice(deviceB, to: model)
            model.setOfflineForTesting(true, deviceID: "device-b")
            XCTAssertTrue(model.canClearAlerts)

            await model.clearAlerts()

            XCTAssertEqual(deviceA.commands.count, 1)
            XCTAssertTrue(deviceB.commands.isEmpty, "an offline device cannot confirm, so it is not asked")
            XCTAssertEqual(model.attentionEvents.map(\.deviceID), ["device-b", "device-b"], "its items stay listed")
            XCTAssertFalse(model.canClearAlerts, "only an offline device's items are left, so Clear has nothing to do")
        }

        func testDismissingForAnOfflineDeviceSendsNothing() async throws {
            let device = FakeAlertDevice(overview: waitingAgentOverview())
            let model = makeDeviceModel(device)
            let event = try XCTUnwrap(model.attentionEvents.first)
            model.setOfflineForTesting(true, deviceID: Self.testDeviceID)

            XCTAssertFalse(model.canChangeAlerts(onDeviceID: Self.testDeviceID))
            await model.dismissAlert(event)

            XCTAssertTrue(device.commands.isEmpty)
        }

        func testRowDismissSendsEveryAlertOfTheRowInOneRequest() async throws {
            let overview = makeOverview(
                processRows: [
                    makeProcessRow(id: "process-web", name: "web", sessionID: "session-a", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")
                ],
                sessions: [
                    makeSession(id: "session-a", title: "web", state: .exited, updatedAt: "2026-01-01T00:05:00Z", bellAt: "2026-01-01T00:07:00Z")
                ]
            ).replacingAlertState(
                dismissedAlertKeys: [],
                comeBackLaterFlags: [SpacesDeviceComeBackLaterFlag(rowKind: .process, rowID: "process-web", flaggedAt: "2026-01-01T00:08:00Z")])
            let device = FakeAlertDevice(overview: overview)
            let model = makeDeviceModel(device)
            let row = SpacesMobileWorkspaceRuntimeRow(source: .process(overview.workspaces[0].processRows[0]))
            XCTAssertEqual(model.undismissedAlerts(for: row, deviceID: Self.testDeviceID).count, 3)
            XCTAssertTrue(model.hasDismissableAlerts(for: row, deviceID: Self.testDeviceID))

            await model.dismissAlerts(for: row, deviceID: Self.testDeviceID)

            XCTAssertEqual(device.commands.count, 1)
            XCTAssertEqual(model.undismissedAlertCount, 0)
            XCTAssertFalse(model.hasDismissableAlerts(for: row, deviceID: Self.testDeviceID))
            XCTAssertTrue(device.currentOverview.comeBackLaterFlags.isEmpty, "Dismiss Alert clears the row's Come Back Later mark too")
        }

        func testARowWhoseOnlyAlertIsItsFlagOffersNoDismissAlert() {
            let overview = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-a", name: "claude", activityState: .idle)]).replacingAlertState(
                dismissedAlertKeys: [],
                comeBackLaterFlags: [SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "agent-a", flaggedAt: "2026-01-01T00:08:00Z")])
            let model = makeDeviceModel(FakeAlertDevice(overview: overview))
            let row = SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(overview.workspaces[0].codingAgentRows[0]))

            XCTAssertFalse(model.hasDismissableAlerts(for: row, deviceID: Self.testDeviceID), "the flag has its own Remove from Alerts item")
            XCTAssertEqual(model.undismissedAlerts(for: row, deviceID: Self.testDeviceID).count, 1)
        }

        // MARK: - Exited process acknowledgement from synced dismissals

        func testIsExitAcknowledgedReadsTheDevicesDismissedKeys() {
            let overview = makeOverview(processRows: [
                makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")
            ])
            let exitKey = overview.alertCandidates().first { $0.kind == .processExited }?.key ?? ""
            let row = SpacesMobileWorkspaceRuntimeRow(source: .process(overview.workspaces[0].processRows[0]))

            let undismissed = makeDeviceModel(FakeAlertDevice(overview: overview))
            XCTAssertFalse(undismissed.isExitAcknowledged(row))
            XCTAssertEqual(row.statusDotKind(exitAcknowledged: undismissed.isExitAcknowledged(row)), .exited)

            let dismissedOnDevice = makeDeviceModel(
                FakeAlertDevice(overview: overview.replacingAlertState(dismissedAlertKeys: [exitKey], comeBackLaterFlags: [])))
            XCTAssertTrue(dismissedOnDevice.isExitAcknowledged(row), "a dismissal made on another client reads as not started here")
            XCTAssertEqual(row.statusDotKind(exitAcknowledged: dismissedOnDevice.isExitAcknowledged(row)), .idle)

            let reExited = makeOverview(processRows: [
                makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: "2026-01-01T00:10:00Z")
            ]).replacingAlertState(dismissedAlertKeys: [exitKey], comeBackLaterFlags: [])
            dismissedOnDevice.overview = reExited
            XCTAssertFalse(dismissedOnDevice.isExitAcknowledged(row), "a later exit alerts again")
        }

        /// A configured process row's id comes from its project template, so two sibling workspaces can
        /// carry rows with the identical id; dismissing one workspace's exit must not acknowledge the other's.
        func testIsExitAcknowledgedDoesNotBleedAcrossWorkspacesSharingATemplateRowID() {
            func process(in workspaceID: String, exitedAt: String) -> SpacesDeviceWorkspaceProcessRow {
                SpacesDeviceWorkspaceProcessRow(
                    id: "process-web", workspaceID: workspaceID, name: "web", command: "npm run web", processID: "runtime-\(workspaceID)",
                    sessionID: nil, runState: .exited, exitedAt: exitedAt, canRun: true, canStop: false, canRestart: false)
            }
            let processA = process(in: "workspace-a", exitedAt: "2026-01-01T00:05:00Z")
            let processB = process(in: "workspace-b", exitedAt: "2026-01-01T00:06:00Z")
            let overview = makeOverview(workspaces: [
                makeWorkspace(id: "workspace-a", branch: "a", processRows: [processA]),
                makeWorkspace(id: "workspace-b", branch: "b", processRows: [processB]),
            ])
            let keyA = overview.alertCandidates().first { $0.workspaceID == "workspace-a" }?.key ?? ""
            let model = makeDeviceModel(FakeAlertDevice(overview: overview.replacingAlertState(dismissedAlertKeys: [keyA], comeBackLaterFlags: [])))

            XCTAssertTrue(model.isExitAcknowledged(SpacesMobileWorkspaceRuntimeRow(source: .process(processA))))
            XCTAssertFalse(model.isExitAcknowledged(SpacesMobileWorkspaceRuntimeRow(source: .process(processB))))
        }

        // MARK: - Come Back Later

        private func comeBackLaterOverview(flag: SpacesDeviceComeBackLaterFlag? = nil) -> SpacesDeviceOverviewPayload {
            makeOverview(
                codingAgentRows: [makeAgentRow(id: "agent-a", name: "claude", activityState: .idle)],
                processRows: [makeProcessRow(id: "process-web", name: "web", sessionID: "session-web", runState: .running, exitedAt: nil)]
            ).replacingAlertState(dismissedAlertKeys: [], comeBackLaterFlags: flag.map { [$0] } ?? [])
        }

        func testAComeBackLaterRowIsAnAlertDatedByWhenItWasFlagged() throws {
            let flag = SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "agent-a", flaggedAt: "2026-01-01T00:08:00Z")
            let model = makeDeviceModel(FakeAlertDevice(overview: comeBackLaterOverview(flag: flag)))

            let event = try XCTUnwrap(model.attentionEvents.first)

            XCTAssertEqual(model.attentionEvents.count, 1)
            XCTAssertEqual(event.kind, .comeBackLater)
            XCTAssertEqual(event.title, "claude")
            XCTAssertEqual(event.key, flag.alertKey)
            XCTAssertEqual(event.date, SpacesMobileAttention.date(fromISO8601: "2026-01-01T00:08:00Z"))
            XCTAssertEqual(event.detail, "Project / feature")
            XCTAssertEqual(model.undismissedAlertCount, 1, "it counts in the Alerts badge")
            XCTAssertEqual(StatusDot.Kind(attentionKind: event.kind), .comeBackLater)
        }

        func testAComeBackLaterRowSortsAmongOtherAlertsByItsFlagTime() {
            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", name: "claude", activityState: .idle),
                makeAgentRow(id: "agent-b", name: "codex", activityState: .waiting, updatedAt: "2026-01-01T00:20:00Z"),
            ]).replacingAlertState(
                dismissedAlertKeys: [],
                comeBackLaterFlags: [SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "agent-a", flaggedAt: "2026-01-01T00:30:00Z")])
            let model = makeDeviceModel(FakeAlertDevice(overview: overview))

            XCTAssertEqual(model.attentionEvents.map(\.kind), [.comeBackLater, .waitingForInput])
        }

        func testDismissingAComeBackLaterEventSendsItsFlagKey() async throws {
            let flag = SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "agent-a", flaggedAt: "2026-01-01T00:08:00Z")
            let device = FakeAlertDevice(overview: comeBackLaterOverview(flag: flag))
            let model = makeDeviceModel(device)

            await model.dismissAlert(try XCTUnwrap(model.attentionEvents.first))

            XCTAssertEqual(device.commands, [.dismissAlerts(["comebacklater:agent:agent-a"])])
            XCTAssertTrue(model.attentionEvents.isEmpty)
        }

        func testAFlagOnAHiddenWorkspaceIsNotListed() {
            let workspace = makeWorkspace(
                id: "workspace-feature", branch: "feature", isHidden: true,
                codingAgentRows: [makeAgentRow(id: "agent-a", name: "claude", activityState: .idle)])
            let overview = makeOverview(workspaces: [workspace]).replacingAlertState(
                dismissedAlertKeys: [],
                comeBackLaterFlags: [SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "agent-a", flaggedAt: "2026-01-01T00:08:00Z")])

            XCTAssertTrue(makeDeviceModel(FakeAlertDevice(overview: overview)).attentionEvents.isEmpty)
        }

        func testTheMenuItemFlipsBetweenComeBackLaterAndRemoveFromAlerts() async {
            let device = FakeAlertDevice(overview: comeBackLaterOverview())
            let model = makeDeviceModel(device)
            let row = SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(device.currentOverview.workspaces[0].codingAgentRows[0]))
            XCTAssertEqual(model.comeBackLaterMenuTitle(for: row, deviceID: Self.testDeviceID), "Come Back Later")

            await model.toggleComeBackLater(for: row, deviceID: Self.testDeviceID)

            XCTAssertEqual(device.commands, [.setComeBackLater(rowKind: .agent, rowID: "agent-a", isOn: true)])
            XCTAssertEqual(model.comeBackLaterMenuTitle(for: row, deviceID: Self.testDeviceID), "Remove from Alerts")
            XCTAssertEqual(model.attentionEvents.map(\.kind), [.comeBackLater])

            await model.toggleComeBackLater(for: row, deviceID: Self.testDeviceID)

            XCTAssertEqual(device.commands.last, .setComeBackLater(rowKind: .agent, rowID: "agent-a", isOn: false))
            XCTAssertEqual(model.comeBackLaterMenuTitle(for: row, deviceID: Self.testDeviceID), "Come Back Later")
            XCTAssertTrue(model.attentionEvents.isEmpty)
        }

        func testTheFlagStateComesBackFromTheDeviceNotTheTap() async {
            let device = FakeAlertDevice(overview: comeBackLaterOverview())
            device.appliesRequests = false
            let model = makeDeviceModel(device)
            let row = SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(device.currentOverview.workspaces[0].codingAgentRows[0]))

            await model.toggleComeBackLater(for: row, deviceID: Self.testDeviceID)

            XCTAssertEqual(model.comeBackLaterMenuTitle(for: row, deviceID: Self.testDeviceID), "Come Back Later")
            XCTAssertTrue(model.attentionEvents.isEmpty)
        }

        func testComeBackLaterIsNotOfferedOnARowThatNeverStarted() {
            let model = makeModel()
            let neverStarted = SpacesMobileWorkspaceRuntimeRow(
                source: .process(makeProcessRow(id: "process-web", name: "web", runState: .notStarted, exitedAt: nil)))
            let exitedWithoutSession = SpacesMobileWorkspaceRuntimeRow(
                source: .process(makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")))
            let running = SpacesMobileWorkspaceRuntimeRow(
                source: .process(makeProcessRow(id: "process-web", name: "web", sessionID: "session-web", runState: .running, exitedAt: nil)))
            let agent = SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(makeAgentRow(id: "agent-a", activityState: .idle)))
            let terminal = SpacesMobileWorkspaceRuntimeRow(
                source: .terminal(makeTerminalRow(id: "terminal-a", title: "zsh", sessionID: "session-t", runState: .running)))

            XCTAssertNil(model.comeBackLaterTarget(for: neverStarted))
            XCTAssertNotNil(model.comeBackLaterTarget(for: exitedWithoutSession), "a process that ran and exited has something to come back to")
            XCTAssertEqual(model.comeBackLaterTarget(for: running)?.rowKind, .process)
            XCTAssertEqual(model.comeBackLaterTarget(for: agent)?.rowKind, .agent)
            XCTAssertEqual(model.comeBackLaterTarget(for: terminal)?.rowKind, .terminal)
        }

        func testComeBackLaterNeedsTheDeviceOnlineAndSendsToTheRowsOwnDevice() async {
            let deviceA = FakeAlertDevice(overview: comeBackLaterOverview())
            let deviceB = FakeAlertDevice(overview: comeBackLaterOverview())
            let model = makeDeviceModel(deviceA)
            addSecondDevice(deviceB, to: model)
            let row = SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(deviceB.currentOverview.workspaces[0].codingAgentRows[0]))

            model.setOfflineForTesting(true, deviceID: "device-b")
            XCTAssertFalse(model.canChangeAlerts(onDeviceID: "device-b"))
            await model.toggleComeBackLater(for: row, deviceID: "device-b")
            XCTAssertTrue(deviceB.commands.isEmpty)

            model.setOfflineForTesting(false, deviceID: "device-b")
            await model.toggleComeBackLater(for: row, deviceID: "device-b")
            XCTAssertTrue(deviceA.commands.isEmpty)
            XCTAssertEqual(deviceB.commands, [.setComeBackLater(rowKind: .agent, rowID: "agent-a", isOn: true)])
        }

        // MARK: - Bells rung while watched are consumed through the device

        private func bellKey(in overview: SpacesDeviceOverviewPayload) -> String? { overview.alertCandidates().first { $0.kind == .bell }?.key }

        func testABellRungWhileWatchedIsDismissedOnTheDevice() async {
            let clock = ManualVisitClock()
            let device = FakeAlertDevice(
                overview: makeOverview(sessions: [makeSession(id: "session-bell", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z")]))
            let model = makeDeviceModel(device, clock: clock)
            model.setActiveTerminalSession("session-bell")
            clock.advance(60)
            device.setOverview(bellOverview(at: clock.now))

            await model.refresh()

            let key = bellKey(in: device.currentOverview) ?? ""
            await waitUntilAsync("the watched bell's dismissal reaches the device") { device.commands.contains(.dismissAlerts([key])) }
            XCTAssertEqual(model.undismissedAlertCount, 0)
        }

        func testABellRungBeforeTheWatchBeganIsLeftAlone() async {
            let clock = ManualVisitClock()
            let device = FakeAlertDevice(overview: bellOverview(at: clock.now))
            let model = makeDeviceModel(device, clock: clock)
            let bellRungEarlier = clock.now
            clock.advance(60)
            model.setActiveTerminalSession("session-bell")
            device.setOverview(bellOverview(at: bellRungEarlier))

            await model.refresh()
            for _ in 0..<50 { await Task.yield() }

            XCTAssertTrue(device.commands.isEmpty, "focusing a session does not clear an alert from a bell it rang earlier")
        }

        func testABellRungAfterLeavingTheTerminalStillAlerts() async {
            let clock = ManualVisitClock()
            let device = FakeAlertDevice(overview: bellOverview(at: clock.now))
            let model = makeDeviceModel(device, clock: clock)
            model.setActiveTerminalSession("session-bell")
            clock.advance(60)
            model.setActiveTerminalSession(nil)
            clock.advance(60)
            device.setOverview(bellOverview(at: clock.now))

            await model.refresh()
            for _ in 0..<50 { await Task.yield() }

            XCTAssertTrue(device.commands.isEmpty)
            XCTAssertEqual(model.attentionEvents.map(\.kind), [.bell])
        }

        // MARK: - Visits reach the session's device

        private func visitOverview() -> SpacesDeviceOverviewPayload {
            makeOverview(
                codingAgentRows: [makeAgentRow(id: "agent-a", name: "claude", activityState: .done, updatedAt: "2026-01-01T00:10:00Z")],
                sessions: [makeSession(id: "session-agent-a", title: "claude", state: .running, updatedAt: "2026-01-01T00:10:00Z")])
        }

        func testVisitingATerminalWithAFinishedAgentReportsTheVisitToItsDevice() async {
            let clock = ManualVisitClock()
            let device = FakeAlertDevice(overview: visitOverview())
            let model = makeDeviceModel(device, clock: clock)

            model.setActiveTerminalSession("session-agent-a")
            model.noteTerminalContentShown(sessionID: "session-agent-a")
            clock.advance(2)

            await waitUntilAsync("the visit reaches the device") { !device.commands.isEmpty }
            guard case .visit(let sessionID, let seconds, _)? = device.commands.first else { return XCTFail("Expected a visit, got \(device.commands)") }
            XCTAssertEqual(sessionID, "session-agent-a")
            XCTAssertEqual(seconds, 2, accuracy: 0.01)
        }

        func testVisitingATerminalWithNothingToClearSendsNothing() async {
            let clock = ManualVisitClock()
            let device = FakeAlertDevice(overview: makeOverview(sessions: [makeSession(id: "session-quiet", title: "zsh", state: .running, updatedAt: "2026-01-01T00:00:00Z")]))
            let model = makeDeviceModel(device, clock: clock)

            model.setActiveTerminalSession("session-quiet")
            model.noteTerminalContentShown(sessionID: "session-quiet")
            clock.advance(30)
            for _ in 0..<50 { await Task.yield() }

            XCTAssertTrue(device.commands.isEmpty)
        }

        func testVisitingATerminalOnAnOfflineDeviceSendsNothing() async {
            let clock = ManualVisitClock()
            let device = FakeAlertDevice(overview: visitOverview())
            let model = makeDeviceModel(device, clock: clock)
            model.setOfflineForTesting(true, deviceID: Self.testDeviceID)

            model.setActiveTerminalSession("session-agent-a")
            model.noteTerminalContentShown(sessionID: "session-agent-a")
            clock.advance(30)
            for _ in 0..<50 { await Task.yield() }

            XCTAssertTrue(device.commands.isEmpty)
        }

        func testABlockedAgentsAlertDoesNotStartAVisit() async {
            let clock = ManualVisitClock()
            let device = FakeAlertDevice(
                overview: makeOverview(
                    codingAgentRows: [makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")]))
            let model = makeDeviceModel(device, clock: clock)

            model.setActiveTerminalSession("session-agent-a")
            model.noteTerminalContentShown(sessionID: "session-agent-a")
            clock.advance(30)
            for _ in 0..<50 { await Task.yield() }

            XCTAssertTrue(device.commands.isEmpty, "a visit does not answer a waiting agent")
        }

        // MARK: - Upgrading from per-phone dismissals

        func testStartupRemovesThePerPhoneDismissalStore() {
            let suite = "spaces.mobile.tests.legacy-dismissed-alerts"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(["device-a": ["agent:a|waitingForInput|1"]], forKey: SpacesMobileAppModel.legacyDismissedAlertsDefaultsKey)
            defaults.set(true, forKey: "unrelated")

            SpacesMobileAppModel.discardLegacyDismissedAlerts(defaults: defaults)

            XCTAssertNil(defaults.object(forKey: SpacesMobileAppModel.legacyDismissedAlertsDefaultsKey))
            XCTAssertTrue(defaults.bool(forKey: "unrelated"))
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

        /// The fixture device id every `makeModel()` test below runs as the selected device.
        private static let testDeviceID = "device-a"

        private func makeDeviceRecord(id: String) -> SpacesMobilePairedDeviceRecord {
            SpacesMobilePairedDeviceRecord(
                id: id, name: id, hosts: ["127.0.0.1"], port: 47_847, certificateFingerprint: "fp-\(id)", createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil)
        }

        /// Every attention/automation derivation reads through `pairedDevices`/`activeDeviceID`
        /// (Agents/Alerts span every paired device), so a lightweight model under test needs one paired,
        /// selected device even when the test only cares about a single overview.
        private func makeModel(clock: TestWallClock? = nil) -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            let model =
                clock.map { clock in SpacesMobileAppModel(settings: settings, bridgeClient: client, wallClock: { clock.now }) }
                ?? SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.pairedDevices = [makeDeviceRecord(id: Self.testDeviceID)]
            model.activeDeviceID = Self.testDeviceID
            return model
        }

        // `makeOverview`/`makeWorkspace`/`makeAgentRow` live in `SpacesMobileOverviewFixtures.swift`.

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

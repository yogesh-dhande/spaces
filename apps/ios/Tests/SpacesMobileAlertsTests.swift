#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor
    final class SpacesMobileAlertsTests: XCTestCase {
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
                ],
                sessions: [
                    makeSession(id: "session-loose", title: "zsh", state: .exited, updatedAt: "2026-01-01T00:01:00Z")
                ]
            )

            let events = SpacesMobileAttention.events(in: overview)

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
                codingAgentRows: [
                    makeAgentRow(id: "agent-waiting", name: "claude", activityState: .waiting, updatedAt: nil)
                ],
                processRows: [
                    makeProcessRow(id: "process-web", name: "web", runState: .exited, exitedAt: nil)
                ],
                sessions: [
                    makeSession(id: "session-loose", title: "zsh", state: .exited, updatedAt: "not-a-timestamp")
                ]
            )

            XCTAssertTrue(SpacesMobileAttention.events(in: overview).isEmpty)
        }

        func testAcceptsFractionalLinuxDaemonTimestamps() {
            let overview = makeOverview(
                processRows: [
                    makeProcessRow(
                        id: "process-web", name: "web", runState: .exited,
                        exitedAt: "2026-07-12T12:34:56.123Z")
                ],
                sessions: [
                    makeSession(
                        id: "session-loose", title: "zsh", state: .failed,
                        updatedAt: "2026-07-12T12:34:57.456Z")
                ]
            )

            let events = SpacesMobileAttention.events(in: overview)

            XCTAssertEqual(Set(events.map(\.sourceID)), ["process:process-web", "session:session-loose"])
            XCTAssertTrue(events.allSatisfy { $0.date.timeIntervalSince1970 > 0 })
        }

        func testSessionRepresentedByProcessRowProducesOneEvent() {
            let overview = makeOverview(
                processRows: [
                    makeProcessRow(
                        id: "process-web", name: "web", sessionID: "session-web", runState: .exited, exitedAt: "2026-01-01T00:05:00Z")
                ],
                sessions: [
                    makeSession(id: "session-web", title: "web", state: .exited, updatedAt: "2026-01-01T00:05:30Z")
                ]
            )

            let events = SpacesMobileAttention.events(in: overview)

            XCTAssertEqual(events.map(\.sourceID), ["process:process-web"])
        }

        func testExitedTerminalRowUsesLinkedSessionTimestamp() {
            let overview = makeOverview(
                terminalRows: [
                    makeTerminalRow(id: "terminal-shell", title: "zsh", sessionID: "session-shell", runState: .exited),
                    makeTerminalRow(id: "terminal-untracked", title: "lost", sessionID: nil, runState: .exited),
                ],
                sessions: [
                    makeSession(id: "session-shell", title: "zsh", state: .failed, updatedAt: "2026-01-01T00:07:00Z")
                ]
            )

            let events = SpacesMobileAttention.events(in: overview)

            XCTAssertEqual(events.map(\.sourceID), ["terminal:terminal-shell"])
            XCTAssertEqual(events.first?.kind, .failed)
            XCTAssertEqual(events.first?.date, SpacesMobileAttention.date(fromISO8601: "2026-01-01T00:07:00Z"))
        }

        func testGroupsSortNewestFirstAndEventsWithinGroupNewestFirst() {
            let overview = makeOverview(
                workspaces: [
                    makeWorkspace(
                        id: "workspace-old", branch: "old",
                        codingAgentRows: [
                            makeAgentRow(
                                id: "agent-old", workspaceID: "workspace-old", name: "claude", activityState: .waiting,
                                updatedAt: "2026-01-01T00:01:00Z")
                        ]),
                    makeWorkspace(
                        id: "workspace-new", branch: "new",
                        codingAgentRows: [
                            makeAgentRow(
                                id: "agent-new-early", workspaceID: "workspace-new", name: "claude", activityState: .waiting,
                                updatedAt: "2026-01-01T00:02:00Z"),
                            makeAgentRow(
                                id: "agent-new-late", workspaceID: "workspace-new", name: "codex", activityState: .done,
                                updatedAt: "2026-01-01T00:09:00Z"),
                        ]),
                ]
            )

            let groups = SpacesMobileAttention.groups(in: overview, dismissedEventIDs: [])

            XCTAssertEqual(groups.map(\.workspaceID), ["workspace-new", "workspace-old"])
            XCTAssertEqual(groups.first?.events.map(\.sourceID), ["agent:agent-new-late", "agent:agent-new-early"])
            XCTAssertEqual(groups.first?.workspaceDisplayName, "new")
            XCTAssertEqual(groups.first?.projectName, "Project")
            XCTAssertEqual(groups.first?.isGitWorkspace, true)
        }

        func testClearDismissesCurrentEventsAndNewStateChangeReappears() {
            let model = makeModel()
            model.overview = makeOverview(
                codingAgentRows: [
                    makeAgentRow(id: "agent-waiting", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z")
                ]
            )

            XCTAssertEqual(model.undismissedAlertCount, 1)

            model.clearAlerts()

            XCTAssertEqual(model.undismissedAlertCount, 0)
            XCTAssertTrue(model.attentionGroups.isEmpty)

            // The same source in a new state (later timestamp) mints a new identity and reappears.
            model.overview = makeOverview(
                codingAgentRows: [
                    makeAgentRow(id: "agent-waiting", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:15:00Z")
                ]
            )

            XCTAssertEqual(model.undismissedAlertCount, 1)
        }

        func testDismissedEventFilteringLeavesOtherEvents() {
            let model = makeModel()
            model.overview = makeOverview(
                codingAgentRows: [
                    makeAgentRow(id: "agent-a", name: "claude", activityState: .waiting, updatedAt: "2026-01-01T00:10:00Z"),
                    makeAgentRow(id: "agent-b", name: "codex", activityState: .done, updatedAt: "2026-01-01T00:20:00Z"),
                ]
            )
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

        // MARK: - Fixtures

        private func makeModel() -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            return SpacesMobileAppModel(settings: settings, bridgeClient: client)
        }

        private func makeOverview(
            workspaces: [SpacesDeviceWorkspaceSummary]? = nil,
            codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [],
            processRows: [SpacesDeviceWorkspaceProcessRow] = [],
            terminalRows: [SpacesDeviceWorkspaceTerminalRow] = [],
            sessions: [SpacesDeviceTerminalSessionSummary] = []
        ) -> SpacesDeviceOverviewPayload {
            let project = SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
            let resolvedWorkspaces =
                workspaces ?? [
                    makeWorkspace(
                        id: "workspace-feature", branch: "feature", codingAgentRows: codingAgentRows, processRows: processRows,
                        terminalRows: terminalRows)
                ]
            return SpacesDeviceOverviewPayload(
                projects: [project], workspaces: resolvedWorkspaces, sessions: sessions,
                daemonStatus: TerminalServiceDaemonStatus(
                    version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                    protocolVersion: SpacesWireProtocol.version))
        }

        private func makeWorkspace(
            id: String,
            branch: String?,
            codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [],
            processRows: [SpacesDeviceWorkspaceProcessRow] = [],
            terminalRows: [SpacesDeviceWorkspaceTerminalRow] = []
        ) -> SpacesDeviceWorkspaceSummary {
            SpacesDeviceWorkspaceSummary(
                id: id, projectID: "project-1", projectName: "Project", branch: branch, baseBranch: "main", dir: "/repo/\(id)",
                isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 0, processRows: processRows,
                codingAgentRows: codingAgentRows, terminalRows: terminalRows)
        }

        private func makeAgentRow(
            id: String,
            workspaceID: String = "workspace-feature",
            name: String,
            runState: SpacesDeviceRunState = .running,
            activityState: SpacesDeviceCodingAgentActivityState,
            updatedAt: String?
        ) -> SpacesDeviceWorkspaceCodingAgentRow {
            SpacesDeviceWorkspaceCodingAgentRow(
                id: id, workspaceID: workspaceID, name: name, command: name, agentID: "runtime-\(id)", sessionID: "session-\(id)",
                isConfigured: true, runState: runState, activityState: activityState, updatedAt: updatedAt, canRun: false,
                canStop: true, canRestart: true)
        }

        private func makeProcessRow(
            id: String,
            name: String,
            sessionID: String? = nil,
            runState: SpacesDeviceRunState,
            exitedAt: String?
        ) -> SpacesDeviceWorkspaceProcessRow {
            SpacesDeviceWorkspaceProcessRow(
                id: id, workspaceID: "workspace-feature", name: name, command: "npm run \(name)", processID: "runtime-\(id)",
                sessionID: sessionID, runState: runState, exitedAt: exitedAt, canRun: runState != .running,
                canStop: runState == .running, canRestart: runState == .running)
        }

        private func makeTerminalRow(
            id: String,
            title: String,
            sessionID: String?,
            runState: SpacesDeviceRunState
        ) -> SpacesDeviceWorkspaceTerminalRow {
            SpacesDeviceWorkspaceTerminalRow(
                id: id, workspaceID: "workspace-feature", title: title, workingDirectory: "/repo/workspace-feature",
                sessionID: sessionID, runState: runState, canOpenTerminal: runState == .running)
        }

        private func makeSession(
            id: String,
            title: String,
            state: TerminalSessionState,
            updatedAt: String
        ) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: id,
                title: title,
                workingDirectory: "/repo/workspace-feature",
                shell: "/bin/zsh",
                command: nil,
                state: state,
                backend: .ghosttyEmbedded,
                lifetimePolicy: .persistent,
                servicePID: 100,
                childPID: nil,
                workspaceID: "workspace-feature",
                workspaceTitle: "feature",
                projectID: "project-1",
                projectName: "Project",
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: updatedAt,
                isControlAvailable: state == .running,
                isSubscriptionAvailable: state == .running,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot()
            )
        }
    }
#endif

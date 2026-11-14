#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor final class SpacesMobileAgentsTests: XCTestCase {
        /// Every single-overview test below shares one device with the device segment hidden, matching the
        /// single-paired-device default: `SpacesMobileAgentGrouping.groups` itself is what changed for
        /// #837's multi-device Agents tab, and these cases exercise everything about it *except* that.
        func makeGroups(
            _ overview: SpacesDeviceOverviewPayload, deviceID: String = "device-a", isOffline: Bool = false, showsDeviceSegment: Bool = false
        ) -> [SpacesMobileAgentGroup] {
            SpacesMobileAgentGrouping.groups(
                devices: [SpacesMobileDeviceOverviewContext(deviceID: deviceID, deviceName: "Device", overview: overview, isOffline: isOffline)],
                showsDeviceSegment: showsDeviceSegment)
        }

        func testGroupsMembershipOrderingAndCounts() {
            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-idle-exited", runState: .exited, activityState: .idle),
                makeAgentRow(id: "agent-waiting", runState: .running, activityState: .waiting),
                makeAgentRow(id: "agent-spinning", runState: .running, activityState: .spinning),
                makeAgentRow(id: "agent-running-idle", runState: .running, activityState: .idle),
                makeAgentRow(id: "agent-done", runState: .running, activityState: .done),
            ])

            let groups = makeGroups(overview)

            XCTAssertEqual(groups.map(\.kind), [.blocked, .done, .working])
            XCTAssertEqual(groups.map(\.kind.label), ["Blocked", "Done", "Working"])
            XCTAssertEqual(groups.map { $0.entries.count }, [1, 1, 2])
            XCTAssertEqual(groups[0].entries.map { $0.runtimeRow.id }, ["agent:agent-waiting"])
            XCTAssertEqual(groups[1].entries.map { $0.runtimeRow.id }, ["agent:agent-done"])
            XCTAssertEqual(groups[2].entries.map { $0.runtimeRow.id }, ["agent:agent-spinning", "agent:agent-running-idle"])
        }

        /// Stopped agents are deliberately absent from the Agents tab: it surfaces agents with a state
        /// worth acting on, and stopped agents stay reachable from their workspace on the Spaces tab.
        func testNotRunningAgentsAreNeverListed() {
            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-idle-exited", runState: .exited, activityState: .idle),
                makeAgentRow(id: "agent-exited", runState: .running, activityState: .exited),
            ])

            XCTAssertEqual(makeGroups(overview), [])
        }

        /// A finished agent has a result the user has not read yet, so it bands ahead of the agents still
        /// working — regardless of whether its terminal is still alive.
        func testDoneAgentBandsBeforeWorkingRegardlessOfRunState() {
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-a", runState: .running, activityState: .done)), .done)
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-b", runState: .exited, activityState: .done)), .done)

            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-spinning", runState: .running, activityState: .spinning),
                makeAgentRow(id: "agent-done", runState: .exited, activityState: .done),
            ])

            XCTAssertEqual(makeGroups(overview).map(\.kind), [.done, .working])
        }

        /// An agent waiting for input is the one thing on this tab that needs the user, so it bands first.
        func testBlockedAgentBandsFirst() {
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-a", runState: .running, activityState: .waiting)), .blocked)

            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-spinning", runState: .running, activityState: .spinning),
                makeAgentRow(id: "agent-done", runState: .running, activityState: .done),
                makeAgentRow(id: "agent-waiting", runState: .running, activityState: .waiting),
            ])

            XCTAssertEqual(makeGroups(overview).first?.kind, .blocked)
        }

        /// An idle agent says nothing about itself, so its terminal decides which band it lands in.
        func testIdleAgentBandsOnItsTerminalRunState() {
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-a", runState: .running, activityState: .idle)), .working)
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-c", runState: .exited, activityState: .idle)), .notRunning)
        }

        /// An exited agent still owns an interactive terminal (`runState == .running`), but the agent
        /// process is gone. It must group under "Not running" rather than "Working", and its status dot
        /// must read as exited rather than inheriting the terminal's still-running state.
        func testExitedAgentGroupsAsNotRunningDespiteRunningTerminal() {
            let row = makeAgentRow(id: "agent-exited-running-terminal", runState: .running, activityState: .exited)

            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: row), .notRunning)
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .exited), .exited)
        }

        func testOmitsEmptyGroups() {
            let overview = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-spinning", runState: .running, activityState: .spinning)])

            let groups = makeGroups(overview)

            XCTAssertEqual(groups.map(\.kind), [.working])
        }

        func testSkipsHiddenWorkspaces() {
            let workspace = makeWorkspace(
                id: "workspace-hidden", branch: "feature", isHidden: true,
                codingAgentRows: [makeAgentRow(id: "agent-a", runState: .running, activityState: .spinning)])
            let overview = makeOverview(workspaces: [workspace])

            XCTAssertTrue(makeGroups(overview).isEmpty)
        }

        /// A workspace whose own `isHidden` flag is false but whose project is hidden must drop out of the
        /// Agents tab exactly as an individually hidden workspace does — see
        /// `SpacesDeviceOverviewPayload.isWorkspaceVisible`, the rule `SpacesMobileAgentGrouping` applies.
        func testSkipsWorkspacesWithAHiddenProject() {
            let workspace = makeWorkspace(
                id: "workspace-feature", branch: "feature", isHidden: false,
                codingAgentRows: [makeAgentRow(id: "agent-a", runState: .running, activityState: .spinning)])
            let overview = makeOverview(workspaces: [workspace], projectIsHidden: true)

            XCTAssertTrue(makeGroups(overview).isEmpty)
        }

        /// The detail line always shows project and workspace together, mirroring the Mac's Alerts table,
        /// and appends the device only when the caller passed a `deviceText` (the Agents tab's own
        /// `showsDeviceSegment` rule decides that upstream, not this type).
        func testDetailAlwaysShowsProjectAndWorkspacePlusOptionalDevice() {
            let entry = SpacesMobileAgentEntry(
                runtimeRow: .init(source: .codingAgent(makeAgentRow(id: "agent-a", runState: .running, activityState: .spinning))),
                deviceID: "device-a", projectName: "spaces", workspaceDisplayName: "ios-redesign", deviceText: nil, isDeviceOffline: false,
                isInPinnedGroup: false)
            XCTAssertEqual(entry.detail, "spaces / ios-redesign")

            let withDevice = SpacesMobileAgentEntry(
                runtimeRow: .init(source: .codingAgent(makeAgentRow(id: "agent-b", runState: .running, activityState: .idle))), deviceID: "device-b",
                projectName: "Notes-App", workspaceDisplayName: "notes-app", deviceText: "MacBook Pro", isDeviceOffline: false, isInPinnedGroup: false
            )
            XCTAssertEqual(withDevice.detail, "Notes-App / notes-app · MacBook Pro")
        }

        /// Pinned lists every pin of every paired device, running or not, after all the activity bands.
        func testPinnedGroupSpansDevicesAndComesLast() {
            let workspaceA = makeWorkspace(
                id: "workspace-feature", branch: "feature",
                codingAgentRows: [makeAgentRow(id: "agent-a", runState: .running, activityState: .waiting)],
                pinnedThreads: [makePin(id: "pin-a", name: "Stopped A")])
            let workspaceB = makeWorkspace(id: "workspace-feature", branch: "feature", pinnedThreads: [makePin(id: "pin-b", name: "Stopped B")])
            let devices = [
                SpacesMobileDeviceOverviewContext(
                    deviceID: "device-a", deviceName: "MacBook Pro", overview: makeOverview(workspaces: [workspaceA]), isOffline: false),
                SpacesMobileDeviceOverviewContext(
                    deviceID: "device-b", deviceName: "Mac Studio", overview: makeOverview(workspaces: [workspaceB]), isOffline: false),
            ]

            let groups = SpacesMobileAgentGrouping.groups(devices: devices, showsDeviceSegment: true)

            XCTAssertEqual(groups.map(\.kind), [.blocked, .pinned])
            XCTAssertEqual(groups.last?.kind.label, "Pinned")
            XCTAssertEqual(groups.last?.entries.map(\.runtimeRow.title), ["Stopped A", "Stopped B"])
            XCTAssertEqual(groups.last?.entries.map(\.deviceID), ["device-a", "device-b"])
        }

        /// A running pin is still an agent in its activity band, so it is listed there and in Pinned, as two
        /// entries that never share an identity.
        func testRunningPinIsListedInItsBandAndInPinned() {
            let workspace = makeWorkspace(
                id: "workspace-feature", branch: "feature",
                codingAgentRows: [makeAgentRow(id: "agent-a", name: "Review", runState: .running, activityState: .spinning, pinID: "pin-a")],
                pinnedThreads: [makePin(id: "pin-a", name: "Review", agentRowID: "agent-a")])

            let groups = makeGroups(makeOverview(workspaces: [workspace]))

            XCTAssertEqual(groups.map(\.kind), [.working, .pinned])
            let working = groups[0].entries[0]
            let pinned = groups[1].entries[0]
            XCTAssertEqual(working.runtimeRow.id, pinned.runtimeRow.id)
            XCTAssertNotEqual(working.id, pinned.id)
            XCTAssertNotNil(pinned.runtimeRow.sessionID)
        }

        /// A not-running pin has no session but is a launchable row: tapping it resumes it.
        func testNotRunningPinRowIsLaunchableWithoutASession() {
            let workspace = makeWorkspace(id: "workspace-feature", branch: "feature", pinnedThreads: [makePin(id: "pin-a", brief: "notes")])

            let row = makeGroups(makeOverview(workspaces: [workspace]))[0].entries[0].runtimeRow

            XCTAssertNil(row.sessionID)
            XCTAssertTrue(row.canRun)
            XCTAssertEqual(row.brief, "notes")
            XCTAssertEqual(row.statusDotKind(exitAcknowledged: false), .idle)
        }

        func testPinsInHiddenWorkspacesAreExcluded() {
            let workspace = makeWorkspace(id: "workspace-hidden", branch: "feature", isHidden: true, pinnedThreads: [makePin(id: "pin-a")])
            XCTAssertTrue(makeGroups(makeOverview(workspaces: [workspace])).isEmpty)

            let projectHidden = makeWorkspace(id: "workspace-feature", branch: "feature", pinnedThreads: [makePin(id: "pin-a")])
            XCTAssertTrue(makeGroups(makeOverview(workspaces: [projectHidden], projectIsHidden: true)).isEmpty)
        }

        /// Two paired devices' agents land in the same band, each device's own agents keeping the
        /// overview's own order, and neither device's rows interleave with the other's.
        func testGroupsMergeAcrossDevicesWithDeviceNamesWhenSegmentShown() {
            let overviewA = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a1", runState: .running, activityState: .waiting),
                makeAgentRow(id: "agent-a2", runState: .running, activityState: .waiting),
            ])
            let overviewB = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-b1", runState: .running, activityState: .waiting)])
            let devices = [
                SpacesMobileDeviceOverviewContext(deviceID: "device-a", deviceName: "MacBook Pro", overview: overviewA, isOffline: false),
                SpacesMobileDeviceOverviewContext(deviceID: "device-b", deviceName: "Mac Studio", overview: overviewB, isOffline: false),
            ]

            let groups = SpacesMobileAgentGrouping.groups(devices: devices, showsDeviceSegment: true)

            XCTAssertEqual(groups.map(\.kind), [.blocked])
            XCTAssertEqual(groups[0].entries.map(\.runtimeRow.id), ["agent:agent-a1", "agent:agent-a2", "agent:agent-b1"])
            XCTAssertEqual(groups[0].entries.map(\.deviceText), ["MacBook Pro", "MacBook Pro", "Mac Studio"])
            // Two devices' rows share a workspace id ("workspace-feature") from the shared fixture, so
            // only the device-qualified `id` keeps them apart in SwiftUI's `ForEach`.
            XCTAssertEqual(Set(groups[0].entries.map(\.id)).count, 3)
        }

        /// An offline device's agents stay listed and carry "(offline)" in their device text, rather than
        /// dropping out of the tab the moment its stream fails.
        func testOfflineDeviceAgentsStayListedAndMarkedOffline() {
            let overview = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-a", runState: .running, activityState: .waiting)])

            let groups = makeGroups(overview, isOffline: true, showsDeviceSegment: true)

            XCTAssertEqual(groups[0].entries.map(\.deviceText), ["Device (offline)"])
            XCTAssertEqual(groups[0].entries.map(\.isDeviceOffline), [true])
        }

        func testAgentStatusDotReflectsActivityState() {
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .waiting), .waiting)
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .done), .done)
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .spinning), .running)
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .idle), .running)
            XCTAssertEqual(StatusDot.Kind(runState: .exited, activityState: .idle), .exited)
            XCTAssertEqual(StatusDot.Kind(runState: .notStarted, activityState: .idle), .idle)

            let agentRow = SpacesMobileWorkspaceRuntimeRow(
                source: .codingAgent(makeAgentRow(id: "agent-a", runState: .running, activityState: .done)))
            XCTAssertEqual(agentRow.statusDotKind(exitAcknowledged: false), .done)

            let processRow = SpacesMobileWorkspaceRuntimeRow(
                source: .process(
                    SpacesDeviceWorkspaceProcessRow(
                        id: "process-a", workspaceID: "workspace-feature", name: "web", command: "npm run dev", processID: nil, sessionID: nil,
                        runState: .exited, canRun: true, canStop: false, canRestart: false)))
            XCTAssertEqual(processRow.statusDotKind(exitAcknowledged: false), .exited)
        }

        func testWorkspaceCollapseToggle() {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            XCTAssertFalse(model.collapsedWorkspaceIDs.contains("workspace-feature"))

            model.toggleWorkspaceCollapsed("workspace-feature")
            XCTAssertTrue(model.collapsedWorkspaceIDs.contains("workspace-feature"))

            model.toggleWorkspaceCollapsed("workspace-feature")
            XCTAssertFalse(model.collapsedWorkspaceIDs.contains("workspace-feature"))
        }

        // MARK: - Pin actions

        private func makePinModel(workspace: SpacesDeviceWorkspaceSummary) -> (SpacesMobileAppModel, DeviceAPIRequestRecorder) {
            let recorder = DeviceAPIRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.overview = makeOverview(workspaces: [workspace])
            return (model, recorder)
        }

        func testRunningPinnedRowKeepsItsPositionAheadOfUnpinnedRows() throws {
            let workspace = makeWorkspace(
                id: "workspace-feature", branch: "feature",
                codingAgentRows: [
                    makeAgentRow(id: "agent-plain", name: "Plain", activityState: .idle),
                    makeAgentRow(id: "agent-pinned", name: "Mine", activityState: .idle, pinID: "pin-b"),
                ], pinnedThreads: [makePin(id: "pin-a", name: "Stopped"), makePin(id: "pin-b", name: "Mine", agentRowID: "agent-pinned")])
            let (model, _) = makePinModel(workspace: workspace)

            let titles = model.workspaceGroups.flatMap(\.rows).filter { $0.type == .codingAgents }.map(\.title)

            XCTAssertEqual(titles, ["Stopped", "Mine", "Plain"])
        }

        func testTappingANotRunningPinResumesItOnItsDevice() async throws {
            let workspace = makeWorkspace(id: "workspace-feature", branch: "feature", pinnedThreads: [makePin(id: "pin-a")])
            let (model, recorder) = makePinModel(workspace: workspace)
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.pinID == "pin-a" })

            _ = await model.performPrimaryAction(for: row, deviceID: "device-1")

            guard case .resumePinnedThread(let request)? = await recorder.snapshot().first?.command else {
                return XCTFail("Expected a resumePinnedThread command.")
            }
            XCTAssertEqual(request.workspaceID, "workspace-feature")
            XCTAssertEqual(request.pinID, "pin-a")
        }

        /// A resumed agent whose conversation is gone exits at once, so the refreshed overview can already
        /// lack its session; the launched session in the response still opens so its error is visible.
        func testResumingAPinOpensTheLaunchedSessionEvenWhenTheOverviewLacksIt() async throws {
            let workspace = makeWorkspace(id: "workspace-feature", branch: "feature", pinnedThreads: [makePin(id: "pin-a")])
            let launched = SpacesDeviceTerminalSessionSummary(
                id: "session-resumed", title: "Pinned", workingDirectory: "/repo/feature", shell: "/bin/zsh", command: "claude --resume abc",
                state: .running, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: 101,
                workspaceID: "workspace-feature", workspaceTitle: "Feature", projectID: "project-1", projectName: "Project",
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z", isControlAvailable: true, isSubscriptionAvailable: true,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot())
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview(workspaces: [workspace], sessions: [])
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(
                    ok: true, message: "Resumed pinned thread.",
                    result: .mutation(.init(overview: overview, sessionID: "session-resumed", launchedTerminalSession: launched)))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            model.overview = overview
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.pinID == "pin-a" })

            let session = await model.performPrimaryAction(for: row, deviceID: "device-1")

            XCTAssertEqual(session?.id, "session-resumed")
        }

        func testRenamingPinnedRowsRenamesThePinAndDiscardsAnEmptyName() async throws {
            let workspace = makeWorkspace(
                id: "workspace-feature", branch: "feature",
                codingAgentRows: [makeAgentRow(id: "agent-pinned", name: "Mine", activityState: .idle, pinID: "pin-b")],
                pinnedThreads: [makePin(id: "pin-a", name: "Stopped"), makePin(id: "pin-b", name: "Mine", agentRowID: "agent-pinned")])
            let (model, recorder) = makePinModel(workspace: workspace)
            let rows = model.workspaceGroups.flatMap(\.rows)
            let stopped = try XCTUnwrap(rows.first { $0.pinID == "pin-a" })
            let running = try XCTUnwrap(rows.first { $0.pinID == "pin-b" })

            await model.rename(row: stopped, to: "Archived")
            await model.rename(row: running, to: "Renamed")
            await model.rename(row: running, to: "  ")

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["renamePinnedThread", "renamePinnedThread"])
            guard case .renamePinnedThread(let first)? = requests.first?.command, case .renamePinnedThread(let second)? = requests.last?.command
            else { return XCTFail("Expected renamePinnedThread commands.") }
            XCTAssertEqual([first.pinID, first.name], ["pin-a", "Archived"])
            XCTAssertEqual([second.pinID, second.name], ["pin-b", "Renamed"])
        }

        func testPinAndUnpinSendTheirCommandsAndPinHonorsTheUnavailableReason() async throws {
            let workspace = makeWorkspace(
                id: "workspace-feature", branch: "feature",
                codingAgentRows: [
                    makeAgentRow(id: "agent-ok", name: "Ok", activityState: .idle),
                    makeAgentRow(id: "agent-oneshot", name: "Job", activityState: .idle, pinUnavailableReason: .oneShotRun),
                ], pinnedThreads: [makePin(id: "pin-a")])
            let (model, recorder) = makePinModel(workspace: workspace)
            let rows = model.workspaceGroups.flatMap(\.rows)
            let ok = try XCTUnwrap(rows.first { $0.title == "Ok" })
            let oneShot = try XCTUnwrap(rows.first { $0.title == "Job" })
            let pinned = try XCTUnwrap(rows.first { $0.pinID == "pin-a" })

            XCTAssertTrue(model.canPin(row: ok))
            XCTAssertEqual(oneShot.pinUnavailableReason, .oneShotRun)
            await model.pin(row: oneShot, name: "Job", deviceID: "device-1")
            await model.pin(row: ok, name: "  ", deviceID: "device-1")
            await model.pin(row: ok, name: "Kept", deviceID: "device-1")
            XCTAssertFalse(model.canPin(row: pinned))
            await model.unpin(row: pinned, deviceID: "device-1")

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["pinAgentSession", "unpinThread"])
            guard case .pinAgentSession(let pin)? = requests.first?.command, case .unpinThread(let unpin)? = requests.last?.command else {
                return XCTFail("Expected pin and unpin commands.")
            }
            XCTAssertEqual([pin.agentID, pin.name], ["runtime-agent-ok", "Kept"])
            XCTAssertEqual(unpin.pinID, "pin-a")
        }

        // MARK: - Fixtures
        //
        // `makeOverview`/`makeWorkspace`/`makeAgentRow` live in `SpacesMobileOverviewFixtures.swift`.
    }
#endif

import Foundation
import Testing
import spacesdevicecore
import workspacecore

@testable import spacesui

/// Covers what the Resources pane lists, how it orders and sums it, and what a device that has not
/// answered shows.
struct ResourcesViewModelTests {
    private static let megabyte: UInt64 = 1_048_576

    private func label(
        _ sessionID: String, workspaceID: String = "ws-1", project: String = "Proj", workspace: String = "main", terminal: String? = nil,
        agent: Bool = false, hidden: Bool = false
    ) -> ResourcesSessionLabel {
        ResourcesSessionLabel(
            sessionID: sessionID, workspaceID: workspaceID, projectName: project, workspaceName: workspace, terminalName: terminal ?? sessionID,
            runsAgent: agent, isHidden: hidden)
    }

    private func frame(daemon: (cpu: Double, mb: UInt64) = (1, 40), terminals: [(id: String, cpu: Double, mb: UInt64)]) -> SpacesDeviceResourcesFrame
    {
        SpacesDeviceResourcesFrame(
            sampledAt: Date(timeIntervalSince1970: 0), processorCount: 10, physicalMemoryBytes: 32 * 1_073_741_824,
            daemon: SpacesDeviceResourceUsage(cpuPercent: daemon.cpu, memoryBytes: daemon.mb * Self.megabyte),
            terminals: terminals.map {
                SpacesDeviceTerminalResourceUsage(
                    sessionID: $0.id, usage: SpacesDeviceResourceUsage(cpuPercent: $0.cpu, memoryBytes: $0.mb * Self.megabyte), processCount: 1)
            })
    }

    private func makeModel(labels: [ResourcesSessionLabel], devices: [(id: String, name: String)] = [("local", "This Mac")]) -> ResourcesViewModel {
        var model = ResourcesViewModel()
        model.setDevices(devices)
        for device in devices { model.setLabels(Dictionary(uniqueKeysWithValues: labels.map { ($0.sessionID, $0) }), deviceID: device.id) }
        return model
    }

    // MARK: - Jumping

    @Test func hiddenWorkspacesListedButCannotBeJumpedTo() {
        var model = makeModel(labels: [
            label("a", workspaceID: "shown"), label("b", workspaceID: "hidden", hidden: true), label("c", workspaceID: "hidden", hidden: true),
        ])
        model.ingest(frame(terminals: [("a", 1, 1), ("b", 1, 1), ("c", 1, 1)]), deviceID: "local")

        let workspaces = model.rows(mode: .workspaces, sort: .cpu)
        #expect(workspaces.count == 2)
        #expect(workspaces.first { $0.workspaceID == "shown" }?.canJump == true)
        #expect(workspaces.first { $0.workspaceID == "hidden" }?.canJump == false)
        let terminalRows = model.rows(mode: .terminals, sort: .cpu)
        #expect(terminalRows.allSatisfy { $0.canJump }, "a terminal opens through its deep link, hidden or not")
    }

    // MARK: - Table ordering

    @Test func rowsAreOrderedByCPUThenMemoryDescending() {
        var model = makeModel(labels: [label("a"), label("b"), label("c")])
        model.ingest(frame(terminals: [("a", 10, 100), ("b", 50, 10), ("c", 10, 300)]), deviceID: "local")

        #expect(model.rows(mode: .terminals, sort: .cpu).map(\.sessionID) == ["b", "c", "a"])
    }

    @Test func sortingByMemoryOrdersByMemoryWithCPUBreakingTies() {
        var model = makeModel(labels: [label("a"), label("b"), label("c")])
        model.ingest(frame(terminals: [("a", 5, 100), ("b", 50, 10), ("c", 20, 100)]), deviceID: "local")

        #expect(model.rows(mode: .terminals, sort: .memory).map(\.sessionID) == ["c", "a", "b"])
    }

    @Test func idleTerminalsAreListed() {
        var model = makeModel(labels: [label("busy"), label("idle")])
        model.ingest(frame(terminals: [("idle", 0, 5), ("busy", 30, 80)]), deviceID: "local")

        let rows = model.rows(mode: .terminals, sort: .cpu)

        #expect(rows.map(\.sessionID) == ["busy", "idle"])
        #expect(rows.last?.cpuPercent == 0)
    }

    @Test func rowsSpanDevicesAndNameTheirDevice() {
        var model = makeModel(labels: [label("a")], devices: [("local", "This Mac"), ("linux", "Build box")])
        model.ingest(frame(terminals: [("a", 10, 10)]), deviceID: "local")
        model.ingest(frame(terminals: [("a", 40, 10)]), deviceID: "linux")

        let rows = model.rows(mode: .terminals, sort: .cpu)

        #expect(rows.map(\.deviceName) == ["Build box", "This Mac"])
        #expect(Set(rows.map(\.id)).count == 2)
    }

    // MARK: - Rollup and separation

    @Test func workspacesModeSumsEachWorkspacesTerminals() {
        var model = makeModel(labels: [
            label("a", workspaceID: "ws-1", workspace: "main"), label("b", workspaceID: "ws-1", workspace: "main", agent: true),
            label("c", workspaceID: "ws-2", workspace: "feature"),
        ])
        model.ingest(frame(terminals: [("a", 10, 100), ("b", 20, 50), ("c", 25, 10)]), deviceID: "local")

        let rows = model.rows(mode: .workspaces, sort: .cpu)

        #expect(rows.map(\.workspaceName) == ["main", "feature"])
        #expect(rows[0].cpuPercent == 30)
        #expect(rows[0].memoryBytes == 150 * Self.megabyte)
        #expect(rows[0].runsAgent)
        #expect(rows[0].sessionID == nil)
        #expect(rows[0].terminalName == nil)
    }

    @Test func spacesItselfNeverAppearsAsARow() {
        var model = makeModel(labels: [label("a")])
        model.ingest(frame(daemon: (cpu: 400, mb: 900), terminals: [("a", 1, 1)]), deviceID: "local")
        model.ingestApp(SpacesDeviceResourceUsage(cpuPercent: 80, memoryBytes: 500 * Self.megabyte))

        #expect(model.rows(mode: .terminals, sort: .cpu).map(\.sessionID) == ["a"])
        #expect(model.rows(mode: .workspaces, sort: .cpu).count == 1)
    }

    @Test func cardsKeepSpacesAndTerminalsSeparate() {
        var model = makeModel(labels: [label("a"), label("b")])
        model.ingest(frame(daemon: (cpu: 3, mb: 40), terminals: [("a", 10, 100), ("b", 20, 50)]), deviceID: "local")
        model.ingestApp(SpacesDeviceResourceUsage(cpuPercent: 7, memoryBytes: 200 * Self.megabyte))

        let spaces = model.spacesCardLines(localDeviceName: "This Mac")

        #expect(model.terminalsCardLines().first?.content == .usage(cpuPercent: 30, memoryBytes: 150 * Self.megabyte))
        #expect(
            spaces.map(\.content) == [
                .usage(cpuPercent: 7, memoryBytes: 200 * Self.megabyte), .usage(cpuPercent: 3, memoryBytes: 40 * Self.megabyte),
            ])
    }

    @Test func spacesCardListsTheAppThenADaemonPerDevice() {
        let model = makeModel(labels: [], devices: [("local", "This Mac"), ("linux", "Build box")])

        let spaces = model.spacesCardLines(localDeviceName: "This Mac")

        #expect(spaces.map(\.name) == ["App", "Daemon", "Daemon"])
        #expect(spaces.map(\.detail) == ["· This Mac", "· This Mac", "· Build box"])
        #expect(model.terminalsCardLines().map(\.name) == ["This Mac", "Build box"])
    }

    @Test func aTerminalWithoutALabelIsNotListedUntilTheOverviewNamesIt() {
        var model = makeModel(labels: [label("a")])
        model.ingest(frame(terminals: [("a", 10, 10), ("new", 99, 10)]), deviceID: "local")
        #expect(model.rows(mode: .terminals, sort: .cpu).map(\.sessionID) == ["a"])

        model.setLabels(["a": label("a"), "new": label("new")], deviceID: "local")
        #expect(model.rows(mode: .terminals, sort: .cpu).map(\.sessionID) == ["new", "a"])
    }

    // MARK: - Before and after measurement

    @Test func aDeviceWithNoFrameShowsMeasuringNotZero() {
        let model = makeModel(labels: [])

        #expect(model.hasMeasurement == false)
        #expect(model.terminalsCardLines().first?.summary == "Measuring…")
        #expect(model.spacesCardLines(localDeviceName: "This Mac").map(\.summary) == ["Measuring…", "Measuring…"])
        #expect(model.rows(mode: .terminals, sort: .cpu).isEmpty)
    }

    @Test func anOfflineDeviceIsNamedAndContributesNoRows() {
        var model = makeModel(labels: [label("a")], devices: [("local", "This Mac"), ("linux", "Build box")])
        model.ingest(frame(terminals: [("a", 10, 10)]), deviceID: "linux")
        model.setStatus(.offline, deviceID: "linux")

        let daemon = model.spacesCardLines(localDeviceName: "This Mac").last
        #expect(daemon?.detail == "· Build box")
        #expect(daemon?.summary == "Offline")
        #expect(model.terminalsCardLines().last?.name == "Build box")
        #expect(model.terminalsCardLines().last?.summary == "Offline")
        #expect(model.rows(mode: .terminals, sort: .cpu).isEmpty)
    }

    @Test func terminalsCardCarriesTheMachineCapacity() {
        var model = makeModel(labels: [])
        model.ingest(frame(terminals: []), deviceID: "local")

        #expect(model.terminalsCardLines().first?.detail == "10 cores · 32 GB")
    }

    // MARK: - History

    @Test func historyIsCappedAtTenMinutesOfSamples() {
        var model = makeModel(labels: [label("a")])
        for index in 0..<(ResourcesUsageHistory.capacity + 5) { model.ingest(frame(terminals: [("a", Double(index), 10)]), deviceID: "local") }

        let history = model.rows(mode: .terminals, sort: .cpu).first?.history ?? []

        #expect(ResourcesUsageHistory.capacity == 300)
        #expect(history.count == 300)
        #expect(history.first == 5)
        #expect(history.last == 304)
    }

    @Test func resetForgetsEverythingMeasured() {
        var model = makeModel(labels: [label("a")])
        model.ingest(frame(terminals: [("a", 10, 10)]), deviceID: "local")
        model.ingestApp(SpacesDeviceResourceUsage(cpuPercent: 7, memoryBytes: 1))

        model.reset()

        #expect(model.hasMeasurement == false)
        #expect(model.spacesCardLines(localDeviceName: "This Mac").first?.history.isEmpty == true)
        #expect(model.terminalsCardLines().isEmpty)
    }

    @Test func historyOfATerminalThatWentAwayIsDropped() {
        var model = makeModel(labels: [label("a"), label("b")])
        model.ingest(frame(terminals: [("a", 10, 10), ("b", 20, 10)]), deviceID: "local")
        model.ingest(frame(terminals: [("b", 30, 10)]), deviceID: "local")
        model.ingest(frame(terminals: [("a", 40, 10), ("b", 30, 10)]), deviceID: "local")

        let rows = model.rows(mode: .terminals, sort: .cpu)

        #expect(rows.first { $0.sessionID == "a" }?.history == [40])
        #expect(rows.first { $0.sessionID == "b" }?.history == [20, 30, 30])
    }

    @Test func historySurvivesADeviceGoingOfflineAndReturning() {
        var model = makeModel(labels: [label("a")])
        model.ingest(frame(terminals: [("a", 10, 10)]), deviceID: "local")
        model.setStatus(.offline, deviceID: "local")
        model.ingest(frame(terminals: [("a", 20, 10)]), deviceID: "local")

        #expect(model.rows(mode: .terminals, sort: .cpu).first?.history == [10, 20])
    }

    @Test func aDeviceThatDropsOutLosesItsState() {
        var model = makeModel(labels: [label("a")], devices: [("local", "This Mac"), ("linux", "Build box")])
        model.ingest(frame(terminals: [("a", 10, 10)]), deviceID: "linux")

        model.setDevices([("local", "This Mac")])

        #expect(model.spacesCardLines(localDeviceName: "This Mac").map(\.detail) == ["· This Mac", "· This Mac"])
        #expect(model.rows(mode: .terminals, sort: .cpu).isEmpty)
    }

    // MARK: - Formatting

    @Test func cpuIsAWholePercentThatCanPassOneHundred() {
        #expect(ResourcesFormatting.cpu(0) == "0%")
        #expect(ResourcesFormatting.cpu(0.4) == "0%")
        #expect(ResourcesFormatting.cpu(303.6) == "304%")
    }

    @Test func memoryIsMegabytesBelowAGigabyteThenOneDecimalGigabytes() {
        #expect(ResourcesFormatting.memory(8 * Self.megabyte) == "8 MB")
        #expect(ResourcesFormatting.memory(1_825_361_101) == "1.7 GB")
        #expect(ResourcesFormatting.capacity(processorCount: 1, physicalMemoryBytes: 8 * 1_073_741_824) == "1 core · 8 GB")
    }

    // MARK: - Session labels

    @Test func labelsNameSessionsByTheirProjectWorkspaceAndTerminalRow() {
        let agentRow = SpacesDeviceWorkspaceCodingAgentRow(
            id: "agent-row", workspaceID: "ws-1", name: "claude", command: "claude", agentID: "agent-1", sessionID: "s-agent", runState: .running,
            activityState: .idle, brief: nil, briefUpdatedAt: nil, canStop: true)
        let terminalRow = SpacesDeviceWorkspaceTerminalRow(
            id: "terminal-row", workspaceID: "ws-1", title: "shell-2", workingDirectory: "/tmp", sessionID: "s-shell", runState: .running,
            canOpenTerminal: true)
        let workspace = SpacesDeviceWorkspaceSummary(
            id: "ws-1", projectID: "home", projectName: ProjectKind.homeProjectName, projectKind: .home, branch: nil, baseBranch: nil,
            dir: "/Users/me", isRunning: true, isHidden: false, isDefault: true, hasTrackedRuntimeIndicators: true, codingAgentRows: [agentRow],
            terminalRows: [terminalRow])
        func session(_ id: String) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: id, title: "raw-\(id)", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
                lifetimePolicy: .persistent, servicePID: 1, childPID: 2, workspaceID: id == "s-orphan" ? "gone" : "ws-1", workspaceTitle: nil,
                projectID: nil, projectName: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", isControlAvailable: true,
                isSubscriptionAvailable: true, attachmentSnapshot: .init())
        }
        let overview = SpacesDeviceOverviewPayload(workspaces: [workspace], sessions: [session("s-agent"), session("s-shell"), session("s-orphan")])

        let labels = ResourcesSessionLabel.labels(from: overview)

        #expect(labels["s-agent"]?.terminalName == "claude")
        #expect(labels["s-agent"]?.runsAgent == true)
        #expect(labels["s-agent"]?.projectName == "~")
        #expect(labels["s-agent"]?.workspaceName == "~")
        #expect(labels["s-shell"]?.terminalName == "shell-2")
        #expect(labels["s-shell"]?.runsAgent == false)
        #expect(labels["s-orphan"] == nil)
    }
}

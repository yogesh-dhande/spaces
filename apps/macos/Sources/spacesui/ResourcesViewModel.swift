import Foundation
import spacesdevicecore

/// What the table's rows stand for.
enum ResourcesMode: Int {
    case terminals
    case workspaces
}

/// The table column the rows are ordered by. Always descending: the pane answers "what is using the
/// most", never "what is using the least".
enum ResourcesSortColumn {
    case cpu
    case memory
}

enum ResourcesDeviceStatus: Equatable {
    /// Subscribed or connecting, with no frame yet.
    case measuring
    case live
    case offline
}

/// One line of a summary card.
struct ResourcesCardLine: Equatable, Identifiable {
    enum Content: Equatable {
        case measuring
        case offline
        case usage(cpuPercent: Double, memoryBytes: UInt64)
    }

    let id: String
    /// What the line measures: a device's name on the terminals card, "App" or "Daemon" on Spaces' own.
    let name: String
    /// Muted text that follows the name: "10 cores · 32 GB" (known once the device's first frame
    /// arrives), or "· This Mac" on Spaces' own lines. Nil when there is nothing to add yet.
    let detail: String?
    let content: Content
    let history: [Double]

    /// The line's figures, or what stands in for them while the device has none.
    var summary: String {
        switch content {
        case .measuring: "Measuring…"
        case .offline: "Offline"
        case .usage(let cpuPercent, let memoryBytes): "\(ResourcesFormatting.cpu(cpuPercent)) · \(ResourcesFormatting.memory(memoryBytes))"
        }
    }
}

/// One row of the table: a terminal, or in Workspaces mode the sum of a workspace's terminals on one
/// device.
struct ResourcesRow: Equatable, Identifiable {
    let id: String
    let deviceID: String
    let deviceName: String
    let projectName: String
    let workspaceID: String
    let workspaceName: String
    /// Nil for a workspace row.
    let sessionID: String?
    let terminalName: String?
    let runsAgent: Bool
    let cpuPercent: Double
    let memoryBytes: UInt64
    /// CPU since the pane opened, oldest first.
    let history: [Double]
    /// Whether the row has somewhere to go. A terminal always does (its deep link); a workspace row does
    /// only while the sidebar shows the workspace, since selecting it needs a sidebar row.
    let canJump: Bool
}

/// The Resources pane's data: the latest frame per device, the names that label its terminals, and the
/// CPU history since the pane opened. Pure state with no timers or I/O, so the pane's rules (what is
/// listed, how it is ordered, what a device that has not answered shows) are directly testable.
///
/// Spaces' own cost (the app and each daemon) and the work users run in terminals are separate figures
/// throughout. Nothing here adds them together, so a heavy build or agent never reads as Spaces' usage.
struct ResourcesViewModel {
    private struct Device {
        var name: String
        var status: ResourcesDeviceStatus = .measuring
        var frame: SpacesDeviceResourcesFrame?
        var labels: [String: ResourcesSessionLabel] = [:]
        /// Series keys: "daemon", "terminals", "t:<sessionID>", "w:<workspaceID>".
        var histories: [String: ResourcesUsageHistory] = [:]
    }

    private var devices: [String: Device] = [:]
    private var deviceOrder: [String] = []
    private var appHistory = ResourcesUsageHistory()
    private var latestApp: SpacesDeviceResourceUsage?

    /// Whether any device has reported a frame yet.
    var hasMeasurement: Bool { devices.values.contains { $0.frame != nil } }

    // MARK: - Input

    /// Sets the devices the pane shows, in display order. A device that drops out loses its state and
    /// history; one that stays keeps both.
    mutating func setDevices(_ entries: [(id: String, name: String)]) {
        let ids = Set(entries.map(\.id))
        devices = devices.filter { ids.contains($0.key) }
        for entry in entries {
            if devices[entry.id] == nil { devices[entry.id] = Device(name: entry.name) } else { devices[entry.id]?.name = entry.name }
        }
        deviceOrder = entries.map(\.id)
    }

    mutating func setLabels(_ labels: [String: ResourcesSessionLabel], deviceID: String) { devices[deviceID]?.labels = labels }

    mutating func setStatus(_ status: ResourcesDeviceStatus, deviceID: String) {
        guard devices[deviceID] != nil else { return }
        devices[deviceID]?.status = status
        // A device that stopped answering has no current figures. Its history stays, so the sparklines
        // resume where they left off if it comes back.
        if status != .live { devices[deviceID]?.frame = nil }
    }

    /// Records a frame and appends one sample to each series it measures. Terminals with no label yet
    /// are neither listed nor charted until the overview names them.
    mutating func ingest(_ frame: SpacesDeviceResourcesFrame, deviceID: String) {
        guard var device = devices[deviceID] else { return }
        device.status = .live
        device.frame = frame

        var samples: [String: Double] = ["daemon": frame.daemon.cpuPercent]
        samples["terminals"] = frame.terminals.reduce(0) { $0 + $1.usage.cpuPercent }
        for terminal in frame.terminals {
            guard let label = device.labels[terminal.sessionID] else { continue }
            samples["t:\(terminal.sessionID)"] = terminal.usage.cpuPercent
            samples["w:\(label.workspaceID)", default: 0] += terminal.usage.cpuPercent
        }
        // Series for terminals and workspaces that are gone are dropped, which bounds the history to
        // what is currently running.
        var histories: [String: ResourcesUsageHistory] = [:]
        for (key, value) in samples {
            var history = device.histories[key] ?? ResourcesUsageHistory()
            history.append(value)
            histories[key] = history
        }
        device.histories = histories
        devices[deviceID] = device
    }

    mutating func ingestApp(_ usage: SpacesDeviceResourceUsage) {
        latestApp = usage
        appHistory.append(usage.cpuPercent)
    }

    /// Forgets every frame, label, and history. The pane calls this when it closes, so a reopened pane
    /// starts its history fresh.
    mutating func reset() {
        devices = [:]
        deviceOrder = []
        appHistory = ResourcesUsageHistory()
        latestApp = nil
    }

    // MARK: - Cards

    /// "Your terminals": per device, the sum of its terminals, named with the device's capacity.
    func terminalsCardLines() -> [ResourcesCardLine] {
        deviceOrder.compactMap { id in
            guard let device = devices[id] else { return nil }
            let capacity = device.frame.map {
                ResourcesFormatting.capacity(processorCount: $0.processorCount, physicalMemoryBytes: $0.physicalMemoryBytes)
            }
            let content: ResourcesCardLine.Content =
                if let frame = device.frame {
                    .usage(
                        cpuPercent: frame.terminals.reduce(0) { $0 + $1.usage.cpuPercent },
                        memoryBytes: frame.terminals.reduce(0) { $0 + $1.usage.memoryBytes })
                } else { Self.unmeasuredContent(device.status) }
            return ResourcesCardLine(
                id: id, name: device.name, detail: capacity, content: content, history: device.histories["terminals"]?.values ?? [])
        }
    }

    /// "Spaces itself": the app (this Mac's process, measured locally, so named for `localDeviceName`)
    /// first, then each device's daemon in device order.
    func spacesCardLines(localDeviceName: String) -> [ResourcesCardLine] {
        var appContent = ResourcesCardLine.Content.measuring
        if let latestApp { appContent = .usage(cpuPercent: latestApp.cpuPercent, memoryBytes: latestApp.memoryBytes) }
        let app = ResourcesCardLine(id: "app", name: "App", detail: "· \(localDeviceName)", content: appContent, history: appHistory.values)
        let daemons: [ResourcesCardLine] = deviceOrder.compactMap { id in
            guard let device = devices[id] else { return nil }
            let content: ResourcesCardLine.Content =
                if let frame = device.frame { .usage(cpuPercent: frame.daemon.cpuPercent, memoryBytes: frame.daemon.memoryBytes) } else {
                    Self.unmeasuredContent(device.status)
                }
            return ResourcesCardLine(
                id: "daemon:\(id)", name: "Daemon", detail: "· \(device.name)", content: content, history: device.histories["daemon"]?.values ?? [])
        }
        return [app] + daemons
    }

    private static func unmeasuredContent(_ status: ResourcesDeviceStatus) -> ResourcesCardLine.Content { status == .offline ? .offline : .measuring }

    // MARK: - Table

    /// Rows for `mode`, largest first by `sort`'s column with the other column breaking ties. Idle rows
    /// are listed like any other. Only devices currently reporting contribute rows.
    func rows(mode: ResourcesMode, sort: ResourcesSortColumn) -> [ResourcesRow] {
        var rows: [ResourcesRow] = []
        for id in deviceOrder {
            guard let device = devices[id], let frame = device.frame else { continue }
            switch mode {
            case .terminals: rows += terminalRows(deviceID: id, device: device, frame: frame)
            case .workspaces: rows += workspaceRows(deviceID: id, device: device, frame: frame)
            }
        }
        return rows.sorted { Self.isOrdered($0, before: $1, by: sort) }
    }

    private func terminalRows(deviceID: String, device: Device, frame: SpacesDeviceResourcesFrame) -> [ResourcesRow] {
        frame.terminals.compactMap { terminal in
            guard let label = device.labels[terminal.sessionID] else { return nil }
            return ResourcesRow(
                id: "\(deviceID)|\(terminal.sessionID)", deviceID: deviceID, deviceName: device.name, projectName: label.projectName,
                workspaceID: label.workspaceID, workspaceName: label.workspaceName, sessionID: terminal.sessionID, terminalName: label.terminalName,
                runsAgent: label.runsAgent, cpuPercent: terminal.usage.cpuPercent, memoryBytes: terminal.usage.memoryBytes,
                history: device.histories["t:\(terminal.sessionID)"]?.values ?? [], canJump: true)
        }
    }

    private func workspaceRows(deviceID: String, device: Device, frame: SpacesDeviceResourcesFrame) -> [ResourcesRow] {
        var totals: [String: (label: ResourcesSessionLabel, cpuPercent: Double, memoryBytes: UInt64, runsAgent: Bool)] = [:]
        for terminal in frame.terminals {
            guard let label = device.labels[terminal.sessionID] else { continue }
            var total = totals[label.workspaceID] ?? (label, 0, 0, false)
            total.cpuPercent += terminal.usage.cpuPercent
            total.memoryBytes += terminal.usage.memoryBytes
            total.runsAgent = total.runsAgent || label.runsAgent
            totals[label.workspaceID] = total
        }
        return totals.map { workspaceID, total in
            ResourcesRow(
                id: "\(deviceID)|ws|\(workspaceID)", deviceID: deviceID, deviceName: device.name, projectName: total.label.projectName,
                workspaceID: workspaceID, workspaceName: total.label.workspaceName, sessionID: nil, terminalName: nil, runsAgent: total.runsAgent,
                cpuPercent: total.cpuPercent, memoryBytes: total.memoryBytes, history: device.histories["w:\(workspaceID)"]?.values ?? [],
                canJump: !total.label.isHidden)
        }
    }

    private static func isOrdered(_ lhs: ResourcesRow, before rhs: ResourcesRow, by sort: ResourcesSortColumn) -> Bool {
        let primary: (Double, Double)
        let secondary: (Double, Double)
        switch sort {
        case .cpu:
            primary = (lhs.cpuPercent, rhs.cpuPercent)
            secondary = (Double(lhs.memoryBytes), Double(rhs.memoryBytes))
        case .memory:
            primary = (Double(lhs.memoryBytes), Double(rhs.memoryBytes))
            secondary = (lhs.cpuPercent, rhs.cpuPercent)
        }
        if primary.0 != primary.1 { return primary.0 > primary.1 }
        if secondary.0 != secondary.1 { return secondary.0 > secondary.1 }
        // A total order keeps equal rows from swapping places between ticks.
        return lhs.id < rhs.id
    }
}

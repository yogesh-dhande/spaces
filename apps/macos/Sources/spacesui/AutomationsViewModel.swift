import Foundation
import spacesterminalcore

/// One paired device's automation slice, read from its loaded overview (or marked unreachable). The
/// Automations detail pane and the sidebar row fan out over these and merge them, so every merge/filter/
/// derivation rule lives here as pure value logic that is unit-testable without an AppKitController or a
/// live device.
struct AutomationDeviceInput: Sendable, Equatable {
    let deviceID: String
    let deviceName: String
    let isLocal: Bool
    /// Whether this device's overview loaded. An unreachable paired device still appears (as a marker row),
    /// so it is never silently dropped.
    let isReachable: Bool
    /// The reason an unreachable device could not be reached, for its marker row.
    let offlineMessage: String?
    let automations: [TerminalServiceAutomationSummary]
    let runs: [TerminalServiceAutomationRunSummary]

    init(
        deviceID: String, deviceName: String, isLocal: Bool, isReachable: Bool, offlineMessage: String? = nil,
        automations: [TerminalServiceAutomationSummary] = [], runs: [TerminalServiceAutomationRunSummary] = []
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.isLocal = isLocal
        self.isReachable = isReachable
        self.offlineMessage = offlineMessage
        self.automations = automations
        self.runs = runs
    }
}

/// One merged automations-table row: an automation plus the device it lives on and its most recent run's
/// status (for the last-run status icon).
struct AutomationTableRow: Sendable, Equatable, Identifiable {
    let deviceID: String
    let deviceName: String
    let isLocal: Bool
    let automation: TerminalServiceAutomationSummary
    /// The raw `AutomationRunStatus` value of this automation's most recent run on its device, or nil if it
    /// has never run.
    let lastRunStatus: String?

    var id: String { "\(deviceID)::\(automation.id)" }
}

/// One merged runs-table row: a run plus the device it ran on.
struct AutomationRunTableRow: Sendable, Equatable, Identifiable {
    let deviceID: String
    let deviceName: String
    let isLocal: Bool
    let run: TerminalServiceAutomationRunSummary

    var id: String { "\(deviceID)::\(run.id)" }
}

/// A device that could not be reached, surfaced as a visible marker rather than an omission.
struct AutomationUnreachableDevice: Sendable, Equatable, Identifiable {
    let deviceID: String
    let deviceName: String
    let message: String?

    var id: String { deviceID }
}

/// A derived attention entry for a failed or timed-out run, fed into the alerts pipeline.
struct AutomationAlertEntry: Sendable, Equatable {
    let attentionID: String
    let text: String
    let deviceID: String
    let runID: String
    /// The run's status raw value (`failed` or `timed_out`).
    let status: String
    let eventDate: Date?
}

/// Pure merge/filter/derivation logic for the Automations pane and sidebar row. Every function is a static
/// pure function of its inputs so the cross-device merge, the device filter, the running-run extraction, and
/// the alert derivation are directly unit-testable.
enum AutomationsViewModel {
    /// Reused for parsing the ISO8601 run timestamps the wire summaries carry. `ISO8601DateFormatter` is
    /// documented thread-safe, so one shared instance is safe from these nonisolated helpers.
    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    /// The merged automations table across every reachable device, sorted by automation name (locale-aware)
    /// then device name so the same automation name on two devices stays adjacent and stable.
    static func mergedAutomations(from inputs: [AutomationDeviceInput]) -> [AutomationTableRow] {
        var rows: [AutomationTableRow] = []
        for input in inputs where input.isReachable {
            for automation in input.automations {
                rows.append(
                    AutomationTableRow(
                        deviceID: input.deviceID, deviceName: input.deviceName, isLocal: input.isLocal, automation: automation,
                        lastRunStatus: lastRunStatus(automationID: automation.id, in: input.runs)))
            }
        }
        return rows.sorted { lhs, rhs in
            let byName = lhs.automation.name.localizedStandardCompare(rhs.automation.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            let byDevice = lhs.deviceName.localizedStandardCompare(rhs.deviceName)
            if byDevice != .orderedSame { return byDevice == .orderedAscending }
            return lhs.automation.id < rhs.automation.id
        }
    }

    /// The merged runs table across every reachable device, newest first. Ordered by the run's start time
    /// when present, else its creation time (a queued/skipped run never started), so a just-started run sorts
    /// above an older queued one; ties break on id for stable ordering.
    static func mergedRuns(from inputs: [AutomationDeviceInput]) -> [AutomationRunTableRow] {
        var rows: [AutomationRunTableRow] = []
        for input in inputs where input.isReachable {
            for run in input.runs {
                rows.append(AutomationRunTableRow(deviceID: input.deviceID, deviceName: input.deviceName, isLocal: input.isLocal, run: run))
            }
        }
        return rows.sorted { lhs, rhs in
            let lhsKey = lhs.run.startedAt ?? lhs.run.createdAt
            let rhsKey = rhs.run.startedAt ?? rhs.run.createdAt
            if lhsKey != rhsKey { return lhsKey > rhsKey }
            return lhs.run.id > rhs.run.id
        }
    }

    /// The currently-running runs across every reachable device, newest first — the sidebar row's children.
    static func runningRuns(from inputs: [AutomationDeviceInput]) -> [AutomationRunTableRow] {
        mergedRuns(from: inputs).filter { $0.run.status == "running" }
    }

    /// Filters merged automation rows to a single device id, or returns them unchanged for nil (All devices).
    static func filterAutomations(_ rows: [AutomationTableRow], deviceID: String?) -> [AutomationTableRow] {
        guard let deviceID else { return rows }
        return rows.filter { $0.deviceID == deviceID }
    }

    /// Filters merged run rows to a single device id, or returns them unchanged for nil (All devices).
    static func filterRuns(_ rows: [AutomationRunTableRow], deviceID: String?) -> [AutomationRunTableRow] {
        guard let deviceID else { return rows }
        return rows.filter { $0.deviceID == deviceID }
    }

    /// The unreachable paired devices, in input order, so the pane can render a marker for each.
    static func unreachableDevices(from inputs: [AutomationDeviceInput]) -> [AutomationUnreachableDevice] {
        inputs.filter { !$0.isReachable }.map { AutomationUnreachableDevice(deviceID: $0.deviceID, deviceName: $0.deviceName, message: $0.offlineMessage) }
    }

    /// The raw status of an automation's most recent run (by start-or-create time), or nil if it has none.
    static func lastRunStatus(automationID: String, in runs: [TerminalServiceAutomationRunSummary]) -> String? {
        runs.filter { $0.automationID == automationID }
            .max { lhs, rhs in (lhs.startedAt ?? lhs.createdAt) < (rhs.startedAt ?? rhs.createdAt) }?
            .status
    }

    /// The failed/timed-out runs for one device, derived into dismissible attention entries newest first.
    /// Only these two statuses draw attention: a succeeded/canceled/skipped run needs none, and a
    /// queued/running one is not yet an outcome. The entry text names the automation, the failure, and the
    /// device (e.g. "Nightly audit failed (exit 3) on This Mac").
    static func alertEntries(deviceID: String, deviceName: String, runs: [TerminalServiceAutomationRunSummary]) -> [AutomationAlertEntry] {
        runs.filter { $0.status == "failed" || $0.status == "timed_out" }
            .map { run in
                AutomationAlertEntry(
                    attentionID: "alert:\(deviceID):automationrun:\(run.id):\(run.status)", text: alertText(run: run, deviceName: deviceName),
                    deviceID: deviceID, runID: run.id, status: run.status,
                    eventDate: (run.endedAt ?? run.createdAt).flatMap { iso8601Formatter.date(from: $0) })
            }
            .sorted { lhs, rhs in
                switch (lhs.eventDate, rhs.eventDate) {
                case (let a?, let b?): return a > b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
    }

    /// The human-readable attention text for a failed/timed-out run.
    private static func alertText(run: TerminalServiceAutomationRunSummary, deviceName: String) -> String {
        let name = run.automationName ?? "Automation"
        let outcome: String
        switch run.status {
        case "timed_out": outcome = "timed out"
        case "failed": outcome = run.exitCode.map { "failed (exit \($0))" } ?? "failed"
        default: outcome = run.status
        }
        return "\(name) \(outcome) on \(deviceName)"
    }
}

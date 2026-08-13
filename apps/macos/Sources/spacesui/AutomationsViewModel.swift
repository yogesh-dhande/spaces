import Foundation
import spacesterminalcore
import workspacecore

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
    /// The device's daemon-reported time-zone identifier, used by the editor to preview cron next-run times
    /// in the zone the device actually evaluates the schedule in. Nil for the local device (which uses the
    /// Mac's current zone) or when the device's daemon didn't report one.
    let timeZoneIdentifier: String?

    init(
        deviceID: String, deviceName: String, isLocal: Bool, isReachable: Bool, offlineMessage: String? = nil,
        automations: [TerminalServiceAutomationSummary] = [], runs: [TerminalServiceAutomationRunSummary] = [], timeZoneIdentifier: String? = nil
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.isLocal = isLocal
        self.isReachable = isReachable
        self.offlineMessage = offlineMessage
        self.automations = automations
        self.runs = runs
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// One merged automations-table row: an automation plus the device it lives on and the two runs the table
/// reads, its most recent one (which decides whether the status dot reports a failure) and its in-flight one
/// (the status dot's running state and the row's Open terminal action).
struct AutomationTableRow: Sendable, Equatable, Identifiable {
    let deviceID: String
    let deviceName: String
    let isLocal: Bool
    let automation: TerminalServiceAutomationSummary
    /// This automation's most recent run on its device, or nil if it has never run.
    let latestRun: TerminalServiceAutomationRunSummary?
    /// This automation's currently-running run, when it has one.
    let runningRun: TerminalServiceAutomationRunSummary?

    var id: String { "\(deviceID)::\(automation.id)" }

    /// The raw `AutomationRunStatus` value of the most recent run, or nil if it has never run.
    var lastRunStatus: String? { latestRun?.status }
}

/// What the automations table's leading status dot reports for one row.
enum AutomationRowStatus: Sendable, Equatable {
    /// A run is in flight, whether the schedule or a person started it.
    case running
    /// The most recent run failed or timed out.
    case failed
    /// Enabled with nothing in flight and nothing wrong.
    case ready
    /// Switched off, so the schedule will not fire it.
    case disabled
}

/// The schedule column's two parts: a humanized summary and the raw cron string it was derived from.
struct AutomationScheduleDescription: Sendable, Equatable {
    let summary: String
    /// The stored cron string, shown as quiet monospaced detail beside the summary. Nil for a manual
    /// automation, which has no expression.
    let cronDetail: String?
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

    /// Augments the bounded overview run slice with the full retained history loaded for each reachable
    /// device. The overview wins for duplicate ids because it keeps live status current between history
    /// loads. Offline inputs keep their last overview snapshot so a failed request never looks authoritative.
    static func mergingRetainedRuns(
        in inputs: [AutomationDeviceInput], with retainedRunsByDeviceID: [String: [TerminalServiceAutomationRunSummary]]
    ) -> [AutomationDeviceInput] {
        inputs.map { input in
            guard input.isReachable, let retainedRuns = retainedRunsByDeviceID[input.deviceID] else { return input }
            var runsByID = Dictionary(uniqueKeysWithValues: retainedRuns.map { ($0.id, $0) })
            for run in input.runs { runsByID[run.id] = run }
            return AutomationDeviceInput(
                deviceID: input.deviceID, deviceName: input.deviceName, isLocal: input.isLocal, isReachable: true,
                offlineMessage: input.offlineMessage, automations: input.automations, runs: Array(runsByID.values),
                timeZoneIdentifier: input.timeZoneIdentifier)
        }
    }

    /// The merged automations table across every reachable device, sorted by automation name (locale-aware)
    /// then device name so the same automation name on two devices stays adjacent and stable.
    static func mergedAutomations(from inputs: [AutomationDeviceInput]) -> [AutomationTableRow] {
        var rows: [AutomationTableRow] = []
        for input in inputs where input.isReachable {
            for automation in input.automations {
                rows.append(
                    AutomationTableRow(
                        deviceID: input.deviceID, deviceName: input.deviceName, isLocal: input.isLocal, automation: automation,
                        latestRun: latestRun(automationID: automation.id, in: input.runs),
                        runningRun: runningRun(automationID: automation.id, in: input.runs)))
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

    /// The live-run badge shown beside Automations. Unreachable devices remain visible in the pane as
    /// markers, but their stale overview snapshots never contribute live activity to the sidebar.
    static func runningRunCount(from inputs: [AutomationDeviceInput]) -> Int {
        inputs.reduce(0) { count, input in
            count + (input.isReachable ? input.runs.count(where: { $0.status == AutomationRunStatus.running.rawValue }) : 0)
        }
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
        inputs.filter { !$0.isReachable }.map {
            AutomationUnreachableDevice(deviceID: $0.deviceID, deviceName: $0.deviceName, message: $0.offlineMessage)
        }
    }

    /// An automation's most recent run (by start-or-create time), or nil if it has none.
    static func latestRun(automationID: String, in runs: [TerminalServiceAutomationRunSummary]) -> TerminalServiceAutomationRunSummary? {
        runs.filter { $0.automationID == automationID }.max { lhs, rhs in (lhs.startedAt ?? lhs.createdAt) < (rhs.startedAt ?? rhs.createdAt) }
    }

    /// An automation's currently-running run, newest first when a concurrency policy allowed more than one.
    static func runningRun(automationID: String, in runs: [TerminalServiceAutomationRunSummary]) -> TerminalServiceAutomationRunSummary? {
        runs.filter { $0.automationID == automationID && $0.status == AutomationRunStatus.running.rawValue }.max { lhs, rhs in
            (lhs.startedAt ?? lhs.createdAt) < (rhs.startedAt ?? rhs.createdAt)
        }
    }

    /// The raw status of an automation's most recent run (by start-or-create time), or nil if it has none.
    static func lastRunStatus(automationID: String, in runs: [TerminalServiceAutomationRunSummary]) -> String? {
        latestRun(automationID: automationID, in: runs)?.status
    }

    /// The failed/timed-out runs for one device, derived into dismissible attention entries newest first.
    /// Only these two statuses draw attention: a succeeded/canceled/skipped run needs none, and a
    /// queued/running one is not yet an outcome. The entry text names the automation, the failure, and the
    /// device (e.g. "Nightly audit failed (exit 3) on This Mac").
    static func alertEntries(deviceID: String, deviceName: String, runs: [TerminalServiceAutomationRunSummary]) -> [AutomationAlertEntry] {
        runs.filter { $0.status == "failed" || $0.status == "timed_out" }.map { run in
            AutomationAlertEntry(
                attentionID: "alert:\(deviceID):automationrun:\(run.id):\(run.status)", text: alertText(run: run, deviceName: deviceName),
                deviceID: deviceID, runID: run.id, status: run.status,
                eventDate: (run.endedAt ?? run.createdAt).flatMap { iso8601Formatter.date(from: $0) })
        }.sorted { lhs, rhs in
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

    // MARK: - Automations table columns (pure, unit-testable)

    /// What the row's leading status dot reports. A run in flight outranks everything else, including a
    /// disabled automation: disabling stops the schedule from firing but never touches a run already going.
    static func rowStatus(for row: AutomationTableRow) -> AutomationRowStatus {
        if row.runningRun != nil { return .running }
        guard row.automation.enabled else { return .disabled }
        switch row.latestRun.flatMap({ AutomationRunStatus(rawValue: $0.status) }) {
        case .failed, .timedOut: return .failed
        default: return .ready
        }
    }

    /// The schedule column: a humanized summary plus the raw cron string it came from.
    static func scheduleDescription(for automation: TerminalServiceAutomationSummary) -> AutomationScheduleDescription {
        guard AutomationTriggerKind(rawValue: automation.triggerKind) == .cron else {
            return AutomationScheduleDescription(summary: "Manual", cronDetail: nil)
        }
        let expression = automation.cronExpression?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !expression.isEmpty else { return AutomationScheduleDescription(summary: "Cron", cronDetail: nil) }
        return AutomationScheduleDescription(summary: scheduleSummary(cronExpression: expression), cronDetail: expression)
    }

    /// The humanized form of a stored cron string, read through the same preset shapes the editor's schedule
    /// builder recognizes so the table and the builder describe one schedule the same way. An expression
    /// that fits no preset reads as "Custom" and leans on the raw string shown beside it.
    static func scheduleSummary(cronExpression: String) -> String {
        switch AutomationSchedulePreset.from(cronExpression: cronExpression) {
        case .everyNMinutes(let minutes): "Every \(minutes) min"
        case .hourlyAtMinute(let minute): "Hourly at :\(paddedTwoDigits(minute))"
        case .dailyAtTime(let hour, let minute): "Daily at \(clockText(hour: hour, minute: minute))"
        case .weeklyOnDaysAtTime(let days, let hour, let minute):
            "Weekly \(days.sorted().map { weekdayAbbreviations[$0] }.joined(separator: ", ")) \(clockText(hour: hour, minute: minute))"
        case .advanced: "Custom"
        }
    }

    /// The next-run column: a countdown while the fire is near, a short absolute time beyond that, and a
    /// placeholder for an automation that has no scheduled fire (manual, disabled, or never scheduled).
    static func nextRunDescription(for automation: TerminalServiceAutomationSummary, now: Date, timeZone: TimeZone = .current) -> String {
        guard automation.enabled, let iso = automation.nextFireTime, let date = iso8601Formatter.date(from: iso) else { return placeholderText }
        let interval = date.timeIntervalSince(now)
        // A fire time already in the past means the daemon has not caught up to it yet; say so rather than
        // counting up from it, which would read like the run had been going for that long.
        guard interval > 0 else { return "due" }
        guard interval >= nearFireHorizon else { return "in \(compactDuration(interval))" }
        return futureAbsolute(date, now: now, timeZone: timeZone)
    }

    /// A compact duration for the table's time columns: seconds under a minute, then minutes, then hours and
    /// minutes, then days and hours. Two units at most so the columns stay narrow.
    static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval.rounded()))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days) d" : "\(days) d \(hours % 24) h"
    }

    /// The placeholder for a column with no value to report.
    private static let placeholderText = "—"

    /// Under twelve hours a next run reads better as a countdown; past that the wall-clock time is the more
    /// useful fact, so the column switches to an absolute time.
    private static let nearFireHorizon: TimeInterval = 12 * 3600

    private static let weekdayAbbreviations = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// A future fire's short absolute time. Unlike a past event it keeps the clock time on another day too:
    /// knowing an automation fires on Aug 8 is not much use without knowing it fires at 04:30.
    private static func futureAbsolute(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let calendar = gregorianCalendar(timeZone)
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        if calendar.isDate(date, inSameDayAs: now) { return clockText(parts) }
        return "\(monthDayText(parts)) \(clockText(parts))"
    }

    /// The table's dates are assembled from calendar components rather than a `DateFormatter` so the columns
    /// render one fixed shape (`14:05`, `Aug 8`) that matches the app's other English chrome, independent of
    /// the host's locale, and so the formatting stays a deterministic pure function under test.
    private static func gregorianCalendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func clockText(_ parts: DateComponents) -> String { clockText(hour: parts.hour ?? 0, minute: parts.minute ?? 0) }

    private static func clockText(hour: Int, minute: Int) -> String { "\(paddedTwoDigits(hour)):\(paddedTwoDigits(minute))" }

    private static func monthDayText(_ parts: DateComponents) -> String {
        let month = monthAbbreviations[min(max(parts.month ?? 1, 1), 12) - 1]
        return "\(month) \(parts.day ?? 1)"
    }

    private static func paddedTwoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    // MARK: - Schedule preview zone (pure, unit-testable)

    /// The time zone to preview a cron schedule in for the automation's target device: the Mac's own current
    /// zone for the local device, else the remote device's daemon-reported zone (so the preview matches the
    /// absolute times the remote daemon will actually fire at). Falls back to the Mac's current zone when the
    /// device reported no zone or an unparseable identifier.
    static func schedulePreviewTimeZone(isLocalDevice: Bool, reportedTimeZoneIdentifier: String?) -> TimeZone {
        guard !isLocalDevice, let identifier = reportedTimeZoneIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty,
            let zone = TimeZone(identifier: identifier)
        else { return .current }
        return zone
    }

    /// The zone-identifier suffix to append to the schedule preview text, shown only when the preview zone
    /// differs from the Mac's own so local authoring stays uncluttered; nil when they match.
    static func schedulePreviewZoneSuffix(previewTimeZone: TimeZone, localTimeZone: TimeZone = .current) -> String? {
        previewTimeZone.identifier == localTimeZone.identifier ? nil : previewTimeZone.identifier
    }

    // MARK: - Editor form logic (pure, unit-testable)

    /// One workspace choice offered by the editor's Agent form: the workspace id and its display label. A
    /// plain value (no AppKit dependency) so the choice-merging logic stays unit-testable.
    struct WorkspaceChoice: Sendable, Equatable {
        let workspaceID: String
        let label: String
    }

    /// Merges the editor's visible workspace choices with the automation's stored target so editing an
    /// automation whose workspace has since been hidden (or archived) never silently retargets it: the stored
    /// workspace is appended when it is not already visible, labeled with its real "<project> / <workspace>"
    /// name plus a " (hidden)" suffix when it still resolves, or a plain raw-id fallback when its row is gone
    /// entirely. A nil stored id (a new automation, or a script automation) leaves the visible list unchanged.
    static func workspaceChoices(visible: [WorkspaceChoice], preservingWorkspaceID: String?, resolveLabel: (String) -> String?) -> [WorkspaceChoice] {
        guard let preservingWorkspaceID, !preservingWorkspaceID.isEmpty else { return visible }
        guard !visible.contains(where: { $0.workspaceID == preservingWorkspaceID }) else { return visible }
        let label = resolveLabel(preservingWorkspaceID).map { "\($0) (hidden)" } ?? preservingWorkspaceID
        return visible + [WorkspaceChoice(workspaceID: preservingWorkspaceID, label: label)]
    }

    /// A fail-fast validation problem from `buildAutomationFields`, carrying the message shown inline in the
    /// editor.
    struct ValidationError: Error, Equatable { let message: String }

    /// The one-line excerpt shown for an automation in the table: an `agent`-kind automation's prompt (first
    /// non-empty line), a `script`-kind automation's script (first non-empty line). Empty when nothing to show.
    static func excerpt(for automation: TerminalServiceAutomationSummary) -> String {
        let source: String
        switch AutomationKind(rawValue: automation.kind) {
        case .agent: source = automation.agentPrompt ?? ""
        default: source = automation.script
        }
        return firstNonEmptyLine(source)
    }

    private static func firstNonEmptyLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Whether the "End agents" action applies to a run: it does only when the run has reached a terminal
    /// status (so its own execution is done) yet still has at least one live attributed coding agent lingering.
    /// A running run is never eligible — it keeps its Cancel affordance instead.
    static func endAgentsAvailable(for run: TerminalServiceAutomationRunSummary) -> Bool {
        guard let status = AutomationRunStatus(rawValue: run.status), status.isTerminal else { return false }
        return run.attributedAgents.contains { $0.live }
    }

    /// The shell-script equivalent of an `agent`-kind automation, generated to prefill the script editor when
    /// the user switches an agent automation to a script one. It spawns the coding agent in the chosen
    /// workspace, captures the child session id from the spawn result's first (tab-separated) column, then
    /// delivers the prompt with `--submit`. Command and prompt are single-quoted (embedded quotes escaped) so
    /// arbitrary text survives as one shell argument; the workspace id is a plain identifier and needs none.
    static func agentEquivalentScript(workspaceID: String, command: String, prompt: String) -> String {
        """
        SESSION=$(spaces agent spawn --command \(shellSingleQuoted(command)) --workspace \(workspaceID) | cut -f1)
        spaces terminal send text "$SESSION" \(shellSingleQuoted(prompt)) --submit
        """
    }

    /// Wraps a value in single quotes for a POSIX shell, escaping embedded single quotes as `'\''`.
    static func shellSingleQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Validates the editor's collected values for the chosen kind and assembles the wire fields, or returns
    /// the first problem's message. The daemon re-validates; this fails fast inline. `cronExpression` and
    /// `timeoutSeconds` are pre-resolved by the caller (they are shared across both kinds); this owns the
    /// name check and the kind-specific required-field checks.
    static func buildAutomationFields(
        name: String, kind: AutomationKind, enabled: Bool, triggerKind: AutomationTriggerKind, cronExpression: String?, workspaceID: String?,
        agentCommand: String, agentPrompt: String, script: String, timeoutSeconds: Int?, concurrencyPolicy: String, missedRunPolicy: String
    ) -> Result<TerminalServiceAutomationFields, ValidationError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(ValidationError(message: "Enter a name.")) }

        let workspace = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !workspace.isEmpty else { return .failure(ValidationError(message: "Choose a workspace.")) }
        switch kind {
        case .agent:
            let command = agentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return .failure(ValidationError(message: "Enter an agent command.")) }
            let prompt = agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return .failure(ValidationError(message: "Enter a prompt.")) }
            return .success(
                TerminalServiceAutomationFields(
                    name: trimmedName, enabled: enabled, triggerKind: triggerKind.rawValue, cronExpression: cronExpression,
                    kind: AutomationKind.agent.rawValue, script: "", agentCommand: command, agentPrompt: prompt, workspaceID: workspace,
                    timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrencyPolicy, missedRunPolicy: missedRunPolicy))
        case .script:
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(ValidationError(message: "Enter a script."))
            }
            return .success(
                TerminalServiceAutomationFields(
                    name: trimmedName, enabled: enabled, triggerKind: triggerKind.rawValue, cronExpression: cronExpression,
                    kind: AutomationKind.script.rawValue, script: script, agentCommand: nil, agentPrompt: nil, workspaceID: workspace,
                    timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrencyPolicy, missedRunPolicy: missedRunPolicy))
        }
    }
}

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

    // MARK: - Editor form logic (pure, unit-testable)

    /// A fail-fast validation problem from `buildAutomationFields`, carrying the message shown inline in the
    /// editor.
    struct ValidationError: Error, Equatable {
        let message: String
    }

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
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Validates the editor's collected values for the chosen kind and assembles the wire fields, or returns
    /// the first problem's message. The daemon re-validates; this fails fast inline. `cronExpression` and
    /// `timeoutSeconds` are pre-resolved by the caller (they are shared across both kinds); this owns the
    /// name check and the kind-specific required-field checks.
    static func buildAutomationFields(
        name: String, kind: AutomationKind, enabled: Bool, triggerKind: AutomationTriggerKind, cronExpression: String?, workspaceID: String?,
        agentCommand: String, agentPrompt: String, script: String, workingDirectory: String, timeoutSeconds: Int?, concurrencyPolicy: String,
        missedRunPolicy: String
    ) -> Result<TerminalServiceAutomationFields, ValidationError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(ValidationError(message: "Enter a name.")) }

        switch kind {
        case .agent:
            let workspace = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !workspace.isEmpty else { return .failure(ValidationError(message: "Choose a workspace.")) }
            let command = agentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return .failure(ValidationError(message: "Enter an agent command.")) }
            let prompt = agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return .failure(ValidationError(message: "Enter a prompt.")) }
            return .success(
                TerminalServiceAutomationFields(
                    name: trimmedName, enabled: enabled, triggerKind: triggerKind.rawValue, cronExpression: cronExpression,
                    kind: AutomationKind.agent.rawValue, script: "", agentCommand: command, agentPrompt: prompt, workspaceID: workspace,
                    workingDirectory: "", timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrencyPolicy, missedRunPolicy: missedRunPolicy))
        case .script:
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(ValidationError(message: "Enter a script.")) }
            let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !directory.isEmpty else { return .failure(ValidationError(message: "Enter a working directory.")) }
            return .success(
                TerminalServiceAutomationFields(
                    name: trimmedName, enabled: enabled, triggerKind: triggerKind.rawValue, cronExpression: cronExpression,
                    kind: AutomationKind.script.rawValue, script: script, agentCommand: nil, agentPrompt: nil, workspaceID: nil,
                    workingDirectory: directory, timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrencyPolicy, missedRunPolicy: missedRunPolicy))
        }
    }
}

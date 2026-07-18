import Foundation
import spacesterminalcore

/// One row for the iOS Automations list: an automation plus its most recent run's status (for the
/// leading status dot).
struct SpacesMobileAutomationRow: Identifiable, Equatable, Sendable {
    let automation: TerminalServiceAutomationSummary
    /// The raw `AutomationRunStatus` value of this automation's most recent run, or nil if it has
    /// never run.
    let lastRunStatus: String?

    var id: String { automation.id }
}

/// One row for the iOS Automation Runs list.
struct SpacesMobileAutomationRunRow: Identifiable, Equatable, Sendable {
    let run: TerminalServiceAutomationRunSummary

    var id: String { run.id }
    var isRunning: Bool { run.status == "running" }
}

/// A derived alert entry for a failed or timed-out automation run. Automation runs are workspace-less
/// (they run in their own terminal sessions, never inside a workspace), so they cannot join the
/// per-workspace groups `SpacesMobileAttention` derives; this is their own flat list, mirroring the
/// Mac's synthetic "Automations" alerts group (`AutomationsViewModel.alertEntries` /
/// `AppKitController.alertsGroups`). Unlike the Mac, which polls every paired device at once and so
/// names the device in the entry text, the iOS app shows one active device at a time (see
/// `SpacesMobileAppModel`), so there is no ambiguity to resolve and no device name to carry.
struct SpacesMobileAutomationAlertEntry: Identifiable, Equatable, Sendable {
    let id: String
    let automationName: String
    /// Human-readable outcome, e.g. "Failed (exit 3)" or "Timed out".
    let outcome: String
    let runID: String
    let status: String
}

/// Pure merge/derivation logic for the iOS Automations feature, mirroring the Mac's
/// `AutomationsViewModel`. The iOS app connects to one paired device at a time and refreshes that
/// device's whole overview as a unit (see `SpacesMobileAppModel`), unlike the Mac sidebar, which polls
/// every paired device simultaneously and merges their automations/runs into one cross-device table.
/// There is therefore no cross-device merge to do here: switching the active device on iOS discards the
/// previous overview and loads the new device's own automations from scratch.
enum SpacesMobileAutomations {
    static func rows(automations: [TerminalServiceAutomationSummary], runs: [TerminalServiceAutomationRunSummary]) -> [SpacesMobileAutomationRow] {
        automations.map { automation in
            SpacesMobileAutomationRow(automation: automation, lastRunStatus: lastRunStatus(automationID: automation.id, in: runs))
        }.sorted { $0.automation.name.localizedStandardCompare($1.automation.name) == .orderedAscending }
    }

    /// The raw status of an automation's most recent run (by start-or-create time), or nil if it has
    /// never run — mirrors `AutomationsViewModel.lastRunStatus` on the Mac.
    static func lastRunStatus(automationID: String, in runs: [TerminalServiceAutomationRunSummary]) -> String? {
        runs.filter { $0.automationID == automationID }
            .max { lhs, rhs in (lhs.startedAt ?? lhs.createdAt) < (rhs.startedAt ?? rhs.createdAt) }?
            .status
    }

    /// Runs newest first (by start-or-create time; a queued/skipped run never started), optionally
    /// narrowed to one automation — nil lists every run, the "Recent Runs" view.
    static func runRows(_ runs: [TerminalServiceAutomationRunSummary], automationID: String? = nil) -> [SpacesMobileAutomationRunRow] {
        let filtered = automationID.map { id in runs.filter { $0.automationID == id } } ?? runs
        return filtered.sorted { lhs, rhs in
            let lhsKey = lhs.startedAt ?? lhs.createdAt
            let rhsKey = rhs.startedAt ?? rhs.createdAt
            if lhsKey != rhsKey { return lhsKey > rhsKey }
            return lhs.id > rhs.id
        }.map(SpacesMobileAutomationRunRow.init)
    }

    static func triggerSummary(_ automation: TerminalServiceAutomationSummary) -> String {
        guard automation.triggerKind == "cron" else { return "Manual" }
        return automation.cronExpression.map { "Cron: \($0)" } ?? "Cron"
    }

    /// "next in 5 min" for an enabled cron automation with a next fire time, else nil — a manual or
    /// disabled automation never fires on its own.
    static func nextFireDescription(_ automation: TerminalServiceAutomationSummary, relativeTo now: Date = Date()) -> String? {
        guard automation.enabled, let fireDate = date(automation.nextFireTime) else { return nil }
        return "next \(relativeFormatter().localizedString(for: fireDate, relativeTo: now))"
    }

    static func runTriggerLabel(_ run: TerminalServiceAutomationRunSummary) -> String {
        switch run.trigger {
        case "manual": "Manual"
        case "cron": "Cron"
        case "missed_catch_up": "Missed catch-up"
        default: run.trigger
        }
    }

    /// "started 5 min ago" for a run that has started, else nil (a queued/skipped run never started).
    static func startedDescription(_ run: TerminalServiceAutomationRunSummary, relativeTo now: Date = Date()) -> String? {
        guard let started = date(run.startedAt) else { return nil }
        return "started \(relativeFormatter().localizedString(for: started, relativeTo: now))"
    }

    /// Wall-clock duration for a run that has started: its end time if ended, else `now` for a still-
    /// running run, so a caller re-rendering on a timer sees the duration keep advancing.
    static func durationDescription(_ run: TerminalServiceAutomationRunSummary, relativeTo now: Date = Date()) -> String? {
        guard let started = date(run.startedAt) else { return nil }
        let end = date(run.endedAt) ?? now
        let interval = max(0, end.timeIntervalSince(started))
        return durationFormatter().string(from: interval)
    }

    /// Human-readable reason for a skipped run, from `AutomationRunSkipReason`'s raw value.
    static func skipReasonLabel(_ reason: String) -> String {
        switch reason {
        case "concurrency": "already running"
        case "missed": "missed occurrence"
        default: reason
        }
    }

    /// Parses the ISO8601 timestamps the wire summaries carry. `TerminalSessionTimestamp` is the same
    /// plain (non-fractional) formatter the daemon uses to produce them (see `AutomationWireSummary`).
    private static func date(_ iso: String?) -> Date? { iso.flatMap(TerminalSessionTimestamp.date(from:)) }

    private static func relativeFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }

    private static func durationFormatter() -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }
}

/// Pure derivation of automation-run alert entries, mirroring `AutomationsViewModel.alertEntries` on
/// the Mac.
enum SpacesMobileAutomationAlerts {
    static func entries(runs: [TerminalServiceAutomationRunSummary]) -> [SpacesMobileAutomationAlertEntry] {
        runs.filter { $0.status == "failed" || $0.status == "timed_out" }
            .map { run -> (entry: SpacesMobileAutomationAlertEntry, date: Date?) in
                let entry = SpacesMobileAutomationAlertEntry(
                    id: "alert:automationrun:\(run.id):\(run.status)", automationName: run.automationName ?? "Automation",
                    outcome: outcome(for: run), runID: run.id, status: run.status)
                return (entry, TerminalSessionTimestamp.date(from: run.endedAt ?? run.createdAt))
            }
            .sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case (let a?, let b?): return a > b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            .map(\.entry)
    }

    private static func outcome(for run: TerminalServiceAutomationRunSummary) -> String {
        switch run.status {
        case "timed_out": "Timed out"
        case "failed": run.exitCode.map { "Failed (exit \($0))" } ?? "Failed"
        default: run.status
        }
    }
}

import Foundation
import spacesdevicecore
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
    var isRunning: Bool { AutomationRunStatus(rawValue: run.status) == .running }
}

/// A derived alert entry for a failed or timed-out automation run. Automation failures keep their own
/// flat list, separate from coding-agent attention grouped by workspace, mirroring the
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
        runs.filter { $0.automationID == automationID }.max { lhs, rhs in (lhs.startedAt ?? lhs.createdAt) < (rhs.startedAt ?? rhs.createdAt) }?
            .status
    }

    /// Count of runs currently in flight across every automation on the device — the Automations
    /// tab's badge count. Unlike `lastRunStatus`, which is scoped to one automation's most recent run,
    /// this counts every running run regardless of which automation started it.
    static func runningCount(_ runs: [TerminalServiceAutomationRunSummary]) -> Int {
        runs.count(where: { AutomationRunStatus(rawValue: $0.status) == .running })
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

    /// Runs for the per-automation runs screen: the live overview window (refreshed by `.overviewPolling`
    /// every 2 seconds while the screen is open) reconciled with the retained fetch history (a one-shot
    /// fetch of older runs the overview window doesn't carry). Overview wins for any run ID present in
    /// both — that keeps status, duration, and the Cancel/End Agents actions live for a run that completes
    /// or times out while the screen is open, instead of freezing at whatever the one-shot fetch saw.
    /// History fills in the older tail, and a run that only just appeared in the overview (fired after the
    /// fetch completed) is included too, since it is simply a run ID the history dictionary doesn't have
    /// yet. Ordering is newest-first, same as `runRows`.
    static func mergedRunRows(
        overviewRuns: [TerminalServiceAutomationRunSummary], historyRuns: [TerminalServiceAutomationRunSummary], automationID: String
    ) -> [SpacesMobileAutomationRunRow] {
        var byID: [String: TerminalServiceAutomationRunSummary] = [:]
        for run in historyRuns where run.automationID == automationID { byID[run.id] = run }
        for run in overviewRuns where run.automationID == automationID { byID[run.id] = run }
        return runRows(Array(byID.values), automationID: automationID)
    }

    static func triggerSummary(_ automation: TerminalServiceAutomationSummary) -> String {
        guard AutomationTriggerKind(rawValue: automation.triggerKind) == .cron else { return "Manual" }
        return automation.cronExpression.map { "Cron: \($0)" } ?? "Cron"
    }

    /// The one-line excerpt shown under an automation's name: an `agent`-kind automation's prompt (first
    /// non-empty line), a `script`-kind automation's script (first non-empty line). Empty when there is
    /// nothing to show. Mirrors `AutomationsViewModel.excerpt` on the Mac — the row shows no type icon or
    /// label, so this excerpt (plus the name) is how a user tells an agent automation from a script one.
    static func excerpt(_ automation: TerminalServiceAutomationSummary) -> String {
        let source = AutomationKind(rawValue: automation.kind) == .agent ? (automation.agentPrompt ?? "") : automation.script
        return firstNonEmptyLine(source)
    }

    private static func firstNonEmptyLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// The display name of an automation's target workspace, resolved from the overview already on hand.
    /// A workspace absent from the current overview (for example, hidden and filtered out upstream) is
    /// simply omitted; this never triggers a separate fetch.
    static func workspaceName(for automation: TerminalServiceAutomationSummary, in workspaces: [SpacesDeviceWorkspaceSummary]) -> String? {
        workspaces.first(where: { $0.id == automation.workspaceID })?.displayName
    }

    /// Whether a run's still-live attributed coding agents should offer "End agents": only once the run
    /// itself has reached a terminal status (`running`/`queued` keep their Cancel affordance instead), and
    /// only if at least one attributed agent's terminal session is still live. Mirrors
    /// `AutomationsViewModel.endAgentsAvailable` on the Mac.
    static func endAgentsAvailable(_ run: TerminalServiceAutomationRunSummary) -> Bool {
        let status = AutomationRunStatus(rawValue: run.status)
        guard status != .running, status != .queued else { return false }
        return run.attributedAgents.contains { $0.live }
    }

    /// "next in 5 min" for an enabled cron automation with a next fire time, else nil — a manual or
    /// disabled automation never fires on its own. `now` is meant to be
    /// `SpacesMobileAppModel.relativeTimeReference` at every call site on the poll (a 30-second-cadence
    /// clock, not `Date()` directly — see that property's doc comment for why).
    ///
    /// A published `nextFireTime` is not guaranteed to stay future-dated relative to `now`: a refresh that
    /// failed retains the last-known overview while the reference keeps advancing, and even a fresh
    /// overview can be read moments after the daemon's own scheduler tick was due to fire it. Rather than
    /// assume the common case and hand a non-positive interval to the formatter — which renders it as
    /// "ago" ("next 5s ago") — this matches the Mac's `AutomationsViewModel.nextRunDescription`, which
    /// treats the same interval as "due".
    static func nextFireDescription(_ automation: TerminalServiceAutomationSummary, relativeTo now: Date = Date()) -> String? {
        guard automation.enabled, let fireDate = date(automation.nextFireTime) else { return nil }
        guard fireDate > now else { return "next due" }
        return "next \(relativeFormatter.localizedString(for: fireDate, relativeTo: now))"
    }

    /// The "Next run" fact row's value on the detail screen. The row is a chip that opens the next-run
    /// sheet for every automation, including the ones that never fire on their own, so it needs a value
    /// even where `nextFireDescription` has nothing to say.
    static func nextRunChipValue(_ automation: TerminalServiceAutomationSummary, relativeTo now: Date = Date()) -> String {
        nextFireDescription(automation, relativeTo: now) ?? "Not scheduled"
    }

    /// The next-run sheet's secondary line: the absolute instant the automation fires next, else why it
    /// has none. A one-time next-run override arrives as `nextFireTime` like any cron occurrence does, so
    /// a manual automation holding an override reads as scheduled rather than as manual.
    static func nextRunSummary(_ automation: TerminalServiceAutomationSummary) -> String {
        if let fireDate = date(automation.nextFireTime) { return "Scheduled: \(absoluteFormatter.string(from: fireDate))" }
        return AutomationTriggerKind(rawValue: automation.triggerKind) == .cron ? "Not scheduled" : "Manual"
    }

    /// Rejects a next-run instant that is not in the future, so the sheet says so inline instead of making
    /// a round trip the daemon refuses on the same grounds.
    static func nextRunValidationMessage(for nextRun: Date, relativeTo now: Date = Date()) -> String? {
        nextRun > now ? nil : "Pick a time in the future."
    }

    /// Human-readable outcome label for a run, used as the row title on the per-automation detail screen
    /// (`AutomationDetailView`) where the automation name is already the screen's own title, so repeating
    /// it on every row would be redundant — the outcome is the thing that differs row to row.
    static func statusTitle(_ run: TerminalServiceAutomationRunSummary) -> String {
        switch AutomationRunStatus(rawValue: run.status) {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .timedOut: "Timed out"
        case .canceled: "Canceled"
        case .skipped: "Skipped"
        case nil: run.status.capitalized
        }
    }

    static func runTriggerLabel(_ run: TerminalServiceAutomationRunSummary) -> String {
        switch run.trigger {
        case "manual": "Manual"
        case "cron": "Cron"
        // A run fired from a one-time next-run override: no cron occurrence to attribute it to, and not
        // a manual trigger either, so the daemon records it under its own trigger kind.
        case "scheduled": "Scheduled"
        case "missed_catch_up": "Missed catch-up"
        default: run.trigger
        }
    }

    /// "started 5 min ago" for a run that has started, else nil (a queued/skipped run never started).
    /// `now` is meant to be `SpacesMobileAppModel.relativeTimeReference`, which advances in 30-second jumps
    /// off the poll cadence and can still trail a run that started only moments before the jump caught up.
    /// Handed to the formatter unguarded, that reads in the future tense ("started in 5s") until the
    /// reference's next jump (#540); clamping `now` up to `started` avoids the wrong tense but then compares
    /// `started` against itself, which the formatter's numeric abbreviated style renders as "in 0 sec"
    /// rather than as the present. Neither reads right, so the boundary — `now` at or before `started` — is
    /// worded directly instead of routing through the formatter at all.
    static func startedDescription(_ run: TerminalServiceAutomationRunSummary, relativeTo now: Date = Date()) -> String? {
        guard let started = AutomationRunFormatting.date(run.startedAt) else { return nil }
        guard now > started else { return "started now" }
        return "started \(AutomationRunFormatting.relativePhrase(for: started, relativeTo: now))"
    }

    /// Wall-clock duration for a run that has started: its end time if ended, else `now` for a still-
    /// running run, so a caller re-rendering on `SpacesMobileAppModel.relativeTimeReference`'s 30-second
    /// cadence sees the duration keep advancing between real overview changes. The `max(0, ...)` below
    /// already keeps this safe against a `now` that trails `started` — the same skew `startedDescription`
    /// guards against — since a negative interval floors to zero rather than rendering a negative time.
    static func durationDescription(_ run: TerminalServiceAutomationRunSummary, relativeTo now: Date = Date()) -> String? {
        guard let started = AutomationRunFormatting.date(run.startedAt) else { return nil }
        let end = AutomationRunFormatting.date(run.endedAt) ?? now
        return AutomationRunFormatting.durationPhrase(from: started, to: end)
    }

    /// Human-readable reason for a skipped run, from `AutomationRunSkipReason`'s raw value.
    static func skipReasonLabel(_ reason: String) -> String {
        switch reason {
        case "concurrency": "already running"
        case "missed": "missed occurrence"
        default: reason
        }
    }

    /// Whether a run row opens a terminal on tap, mirroring the Mac's `AutomationsController.makeRunCard`
    /// rule: a run with no terminal session was never observable (still queued, or skipped before it
    /// ever ran), so it stays inert. Every other status opens something, live while running or its
    /// read-only ended transcript once finished.
    static func runIsNavigable(_ run: TerminalServiceAutomationRunSummary) -> Bool {
        let status = AutomationRunStatus(rawValue: run.status)
        return run.terminalSessionID != nil && status != .skipped && status != .queued
    }

    /// The terminal session a run row opens on tap, or nil when the row is not navigable (see
    /// `runIsNavigable`). The overview's own session wins when present, since it carries the daemon's
    /// live, polled state; otherwise a summary is synthesized from the run itself — mirroring
    /// `SpacesMobileAppModel.terminalSession(from:in:)` — so a retained historical run still opens its
    /// (by-then read-only) transcript after its session has aged out of the overview window.
    static func runSession(for run: TerminalServiceAutomationRunSummary, overview: SpacesDeviceOverviewPayload?)
        -> SpacesDeviceTerminalSessionSummary?
    {
        guard runIsNavigable(run), let sessionID = run.terminalSessionID else { return nil }
        if let session = overview?.sessions.first(where: { $0.id == sessionID }) { return session }
        let workspace = run.workspaceID.flatMap { id in overview?.workspaces.first { $0.id == id } }
        let timestamp = TerminalSessionTimestamp.string(from: Date())
        let isRunning = AutomationRunStatus(rawValue: run.status) == .running
        return SpacesDeviceTerminalSessionSummary(
            id: sessionID, title: run.automationName ?? "Automation", liveTitle: nil, workingDirectory: "", shell: "", command: nil,
            state: isRunning ? .running : .exited, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 0, childPID: nil,
            workspaceID: run.workspaceID ?? "", workspaceTitle: workspace?.displayName, projectID: workspace?.projectID,
            projectName: workspace?.projectName, createdAt: timestamp, updatedAt: timestamp, isControlAvailable: isRunning,
            isSubscriptionAvailable: isRunning, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            rowKind: AutomationKind(rawValue: run.kind) == .agent ? .agent : .liveSession, rowSourceID: run.id, hasFinalRender: false)
    }

    /// The terminal session an attributed-agent chip opens on tap: overview-first, else synthesized, the
    /// same shape as `runSession(for:overview:)`.
    static func agentSession(for agent: TerminalServiceAutomationAgentSummary, overview: SpacesDeviceOverviewPayload?)
        -> SpacesDeviceTerminalSessionSummary?
    {
        if let session = overview?.sessions.first(where: { $0.id == agent.terminalSessionID }) { return session }
        let workspace = agent.workspaceID.flatMap { id in overview?.workspaces.first { $0.id == id } }
        let timestamp = TerminalSessionTimestamp.string(from: Date())
        return SpacesDeviceTerminalSessionSummary(
            id: agent.terminalSessionID, title: agent.title ?? "Agent", liveTitle: nil, workingDirectory: "", shell: "", command: nil,
            state: agent.live ? .running : .exited, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 0, childPID: nil,
            workspaceID: agent.workspaceID ?? "", workspaceTitle: workspace?.displayName, projectID: workspace?.projectID,
            projectName: workspace?.projectName, createdAt: timestamp, updatedAt: timestamp, isControlAvailable: agent.live,
            isSubscriptionAvailable: agent.live, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .agent, rowSourceID: nil,
            hasFinalRender: false)
    }

    /// Parses the ISO8601 timestamps the wire summaries carry. `TerminalSessionTimestamp` is the same
    /// plain (non-fractional) formatter the daemon uses to produce them (see `AutomationWireSummary`).
    private static func date(_ iso: String?) -> Date? { iso.flatMap(TerminalSessionTimestamp.date(from:)) }

    /// Formatter construction is expensive and these derivations are re-evaluated on every SwiftUI render,
    /// so the formatters are built once and reused rather than per call. Not `Sendable`, but every call
    /// site is a SwiftUI view derivation on the main actor, and the formatters are never mutated after
    /// init, matching the `nonisolated(unsafe)` formatter-caching idiom used elsewhere in the codebase
    /// (e.g. `TerminalSessionTimestamp`).
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    nonisolated(unsafe) private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Pure derivation of automation-run alert entries, mirroring `AutomationsViewModel.alertEntries` on
/// the Mac.
enum SpacesMobileAutomationAlerts {
    static func entries(runs: [TerminalServiceAutomationRunSummary]) -> [SpacesMobileAutomationAlertEntry] {
        runs.filter { run in
            let status = AutomationRunStatus(rawValue: run.status)
            return status == .failed || status == .timedOut
        }.map { run -> (entry: SpacesMobileAutomationAlertEntry, date: Date?) in
            let entry = SpacesMobileAutomationAlertEntry(
                id: "alert:automationrun:\(run.id):\(run.status)", automationName: run.automationName ?? "Automation", outcome: outcome(for: run),
                runID: run.id, status: run.status)
            return (entry, TerminalSessionTimestamp.date(from: run.endedAt ?? run.createdAt))
        }.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case (let a?, let b?): return a > b
            case (nil, _): return false
            case (_, nil): return true
            }
        }.map(\.entry)
    }

    private static func outcome(for run: TerminalServiceAutomationRunSummary) -> String {
        switch AutomationRunStatus(rawValue: run.status) {
        case .timedOut: "Timed out"
        case .failed: run.exitCode.map { "Failed (exit \($0))" } ?? "Failed"
        default: run.status
        }
    }
}

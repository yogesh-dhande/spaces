import Foundation

/// How a scheduled automation is triggered. A `manual` automation only runs when explicitly triggered;
/// a `cron` automation carries a `cronExpression` and fires on the schedule the daemon maintains.
public enum AutomationTriggerKind: String, Codable, Sendable, CaseIterable {
    case manual
    case cron
}

/// What a scheduled automation runs. Both kinds target a workspace: a `script` runs verbatim at its root;
/// an `agent` spawns a coding agent (`agentCommand`) seeded with `agentPrompt` there.
public enum AutomationKind: String, Codable, Sendable, CaseIterable {
    case script
    case agent
}

/// What happens when a fire lands while an earlier run of the same automation is still queued or running.
/// `allow` always starts a new run; `skip` records a lightweight skipped row instead; `queue` coalesces to
/// at most one pending queued run that executes when the current one finishes.
public enum AutomationConcurrencyPolicy: String, Codable, Sendable, CaseIterable {
    case allow
    case skip
    case queue
}

/// What a restarted daemon does with a cron automation whose `nextFireTime` elapsed while it was down.
/// `runOnce` fires exactly one catch-up run regardless of how many occurrences were missed; `skip` records
/// one lightweight skipped row. Either way the automation's next fire time is recomputed from now.
public enum AutomationMissedRunPolicy: String, Codable, Sendable, CaseIterable {
    case runOnce = "run_once"
    case skip
}

// spacesdevicecore also compiles into the Linux daemon, which never renders these phrases and
// whose corelibs Foundation lacks RelativeDateTimeFormatter, so this client-only helper is
// compiled out there.
#if !os(Linux)

import Foundation
import spacesterminalcore

/// Shared date parsing and formatter configuration behind an automation run's "started"/duration
/// descriptions, deduped between the Mac's `AutomationsController` (`spacesui`) and iOS's
/// `SpacesMobileAutomations` (`Automations`). The two clients wrap these parts differently — the Mac
/// renders `"started …"`/`"took …"` with `""` fallbacks and only reports a duration once a run has ended,
/// while iOS returns optionals and keeps a live-running run's duration ticking against `now` — so this
/// owns only what must format identically on both: date parsing and the two formatter configurations.
/// Each client keeps its own wrapping and fallback semantics.
public enum AutomationRunFormatting {
    /// Parses one of a run's ISO8601 timestamps (`startedAt`/`endedAt`), or nil if absent/unparseable.
    /// `TerminalSessionTimestamp` is the same plain (non-fractional) formatter the daemon uses to produce
    /// them.
    public static func date(_ iso: String?) -> Date? { iso.flatMap(TerminalSessionTimestamp.date(from:)) }

    /// The relative-time phrase for an instant relative to `now` (e.g. "5 min ago"), unprefixed — each
    /// client decides its own wording and how to handle `now` at or before the instant.
    public static func relativePhrase(for date: Date, relativeTo now: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    /// The formatted wall-clock duration between two instants (e.g. "5 min"), floored at zero so a `now`
    /// that trails `start` never renders a negative duration.
    public static func durationPhrase(from start: Date, to end: Date) -> String? {
        durationFormatter.string(from: max(0, end.timeIntervalSince(start)))
    }

    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    nonisolated(unsafe) private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}

#endif

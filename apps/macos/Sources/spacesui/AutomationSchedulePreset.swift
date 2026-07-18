import Foundation
import workspacecore

/// The cron-schedule builder's editable state, decoupled from the raw 5-field cron string that is the
/// only stored form. The editor renders a friendly builder for the common shapes (`everyNMinutes`,
/// `hourlyAtMinute`, `dailyAtTime`, `weeklyOnDaysAtTime`) and falls back to a raw field for anything else
/// (`advanced`). `cronExpression` serializes builder state to the canonical string; `from(cronExpression:)`
/// re-derives builder state when the string matches a preset shape, else opens in `advanced`.
///
/// Round-trip contract: every non-advanced case serializes to a string that `from(cronExpression:)` maps
/// back to the same case, and any string that does not match a recognized preset shape derives to
/// `.advanced` carrying that string verbatim. Kept a pure value type (no AppKit) so the round-trips,
/// serialization, and next-run previews are directly unit-testable.
enum AutomationSchedulePreset: Equatable, Sendable {
    /// Fires every `minutes` minutes (`*/N * * * *`); `N` in 2...59. Every-minute (`*`) is not a preset and
    /// derives to `.advanced` so the round-trip stays deterministic.
    case everyNMinutes(minutes: Int)
    /// Fires once an hour at minute `minute` (`M * * * *`); `minute` in 0...59.
    case hourlyAtMinute(minute: Int)
    /// Fires once a day at `hour`:`minute` (`M H * * *`).
    case dailyAtTime(hour: Int, minute: Int)
    /// Fires at `hour`:`minute` on the given weekdays (`M H * * D,...`), 0 = Sunday ... 6 = Saturday.
    case weeklyOnDaysAtTime(days: Set<Int>, hour: Int, minute: Int)
    /// Any expression that does not match a builder preset; the raw 5-field string is edited directly.
    case advanced(expression: String)

    /// The friendly cases offered as the builder's picker options, in display order. `advanced` is not a
    /// picker option (it is a separate mode), so it is excluded here.
    enum Kind: String, CaseIterable, Sendable {
        case everyNMinutes
        case hourlyAtMinute
        case dailyAtTime
        case weeklyOnDaysAtTime

        var title: String {
            switch self {
            case .everyNMinutes: "Every N minutes"
            case .hourlyAtMinute: "Hourly at minute"
            case .dailyAtTime: "Daily at time"
            case .weeklyOnDaysAtTime: "Weekly on days at time"
            }
        }
    }

    var kind: Kind? {
        switch self {
        case .everyNMinutes: .everyNMinutes
        case .hourlyAtMinute: .hourlyAtMinute
        case .dailyAtTime: .dailyAtTime
        case .weeklyOnDaysAtTime: .weeklyOnDaysAtTime
        case .advanced: nil
        }
    }

    /// The canonical 5-field cron string for this builder state. This is the single stored form.
    var cronExpression: String {
        switch self {
        case .everyNMinutes(let minutes): "*/\(minutes) * * * *"
        case .hourlyAtMinute(let minute): "\(minute) * * * *"
        case .dailyAtTime(let hour, let minute): "\(minute) \(hour) * * *"
        case .weeklyOnDaysAtTime(let days, let hour, let minute): "\(minute) \(hour) * * \(days.sorted().map(String.init).joined(separator: ","))"
        case .advanced(let expression): expression
        }
    }

    /// Re-derives builder state from a stored cron string. Returns a friendly preset when the string
    /// matches exactly one recognized shape, otherwise `.advanced` carrying the string unchanged (trimmed).
    /// A malformed string that cannot even be split into 5 fields still derives to `.advanced` so the
    /// editor can open on it and surface the parse error inline rather than refusing to load.
    static func from(cronExpression rawExpression: String) -> AutomationSchedulePreset {
        let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else { return .advanced(expression: expression) }
        let (minuteField, hourField, domField, monthField, dowField) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        // Every recognized preset leaves day-of-month and month unrestricted.
        guard domField == "*", monthField == "*" else { return .advanced(expression: expression) }

        // Every N minutes: `*/N * * * *` with the rest unrestricted.
        if hourField == "*", dowField == "*", let step = stepValue(minuteField), (2...59).contains(step) {
            return .everyNMinutes(minutes: step)
        }
        // The remaining presets pin a single minute (0...59).
        guard let minute = singleValue(minuteField, range: 0...59) else { return .advanced(expression: expression) }
        // Hourly at minute: `M * * * *`.
        if hourField == "*", dowField == "*" { return .hourlyAtMinute(minute: minute) }
        // The day/week presets pin a single hour (0...23).
        guard let hour = singleValue(hourField, range: 0...23) else { return .advanced(expression: expression) }
        // Daily at time: `M H * * *`.
        if dowField == "*" { return .dailyAtTime(hour: hour, minute: minute) }
        // Weekly on days at time: `M H * * D,...` with a non-empty comma list of single weekdays (0...6).
        if let days = weekdayList(dowField), !days.isEmpty { return .weeklyOnDaysAtTime(days: days, hour: hour, minute: minute) }
        return .advanced(expression: expression)
    }

    /// Parses `*/N` into `N`, or nil for any other form (including a bare `*` or a plain value).
    private static func stepValue(_ field: String) -> Int? {
        guard field.hasPrefix("*/") else { return nil }
        return Int(field.dropFirst(2))
    }

    /// Parses a bare integer field constrained to `range`, or nil for `*`, lists, ranges, or steps.
    private static func singleValue(_ field: String, range: ClosedRange<Int>) -> Int? {
        guard let value = Int(field), range.contains(value) else { return nil }
        return value
    }

    /// Parses a comma list of single weekday integers (0...6) into a set, or nil if any item is not a bare
    /// in-range integer (so ranges/steps/`*` fall through to `.advanced`).
    private static func weekdayList(_ field: String) -> Set<Int>? {
        var days = Set<Int>()
        for item in field.split(separator: ",", omittingEmptySubsequences: false) {
            guard let value = Int(item), (0...6).contains(value) else { return nil }
            days.insert(value)
        }
        return days
    }
}

/// Pure helpers for the editor's live schedule preview and validation, kept off AppKit so they are unit
/// testable with a fixed clock and time zone.
enum AutomationSchedulePreview {
    /// The next `count` fire dates for a cron expression strictly after `date`, in `timeZone`. Throws the
    /// `AutomationCronSchedule` parse error for a malformed expression so the editor can show it inline.
    /// Returns fewer than `count` dates only when the schedule stops matching within the search horizon.
    static func nextRuns(cronExpression: String, after date: Date, timeZone: TimeZone, count: Int = 3) throws -> [Date] {
        let schedule = try AutomationCronSchedule.parse(cronExpression)
        var runs: [Date] = []
        var cursor = date
        for _ in 0..<max(0, count) {
            guard let next = schedule.nextFireDate(after: cursor, timeZone: timeZone) else { break }
            runs.append(next)
            cursor = next
        }
        return runs
    }
}

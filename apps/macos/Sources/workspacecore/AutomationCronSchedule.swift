import Foundation

/// Describes a malformed cron expression. `errorDescription` carries a human-readable
/// explanation of exactly which field and rule was violated, since cron syntax mistakes
/// are otherwise hard for a user to diagnose from a bare parse failure.
public struct AutomationCronScheduleError: LocalizedError, Equatable {
    private let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

/// A parsed standard 5-field cron schedule (`minute hour day-of-month month day-of-week`).
///
/// Each field is expanded eagerly at parse time into the concrete set of integer values it
/// matches (e.g. `*/15` for minutes becomes `{0, 15, 30, 45}`). This keeps `nextFireDate`
/// simple set-membership checks instead of re-interpreting syntax on every candidate minute,
/// and makes the type trivially `Equatable` and `Sendable` since it stores only value types.
public struct AutomationCronSchedule: Equatable, Sendable {
    /// Minutes 0-59 that this schedule fires on.
    let minutes: Set<Int>
    /// Hours 0-23 that this schedule fires on.
    let hours: Set<Int>
    /// Days of month 1-31 that this schedule fires on.
    let daysOfMonth: Set<Int>
    /// Months 1-12 that this schedule fires on.
    let months: Set<Int>
    /// Days of week 0-6 (Sunday = 0) that this schedule fires on. Parsed 7s are folded into 0
    /// before storage so `dayOfWeekRestricted` and matching never need to special-case 7.
    let daysOfWeek: Set<Int>
    /// Whether the day-of-month field was written as something other than `*`. Standard cron
    /// treats "both dom and dow restricted" as an OR match; this flag (together with
    /// `dayOfWeekRestricted`) is what `matches(components:)` uses to pick AND vs OR.
    let dayOfMonthRestricted: Bool
    /// Whether the day-of-week field was written as something other than `*`.
    let dayOfWeekRestricted: Bool

    /// How far into the future to search for a fire date before giving up. Bounds the search
    /// so schedules that can never match again (e.g. `0 0 30 2 *`, Feb 30 never exists) or that
    /// are simply far away terminate instead of scanning forever.
    private static let searchLimit: TimeInterval = 5 * 365 * 24 * 60 * 60

    private static let monthNames: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    private static let dayOfWeekNames: [String: Int] = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]

    private init(
        minutes: Set<Int>, hours: Set<Int>, daysOfMonth: Set<Int>, months: Set<Int>, daysOfWeek: Set<Int>, dayOfMonthRestricted: Bool,
        dayOfWeekRestricted: Bool
    ) {
        self.minutes = minutes
        self.hours = hours
        self.daysOfMonth = daysOfMonth
        self.months = months
        self.daysOfWeek = daysOfWeek
        self.dayOfMonthRestricted = dayOfMonthRestricted
        self.dayOfWeekRestricted = dayOfWeekRestricted
    }

    /// Parses a standard 5-field cron expression (`minute hour day-of-month month day-of-week`).
    ///
    /// Supported syntax per field: `*`, single values, comma lists (`a,b,c`), ranges (`a-b`),
    /// and steps (`*/n` or `a-b/n`). Month and day-of-week accept case-insensitive 3-letter
    /// names (`jan`..`dec`, `sun`..`sat`) anywhere a numeric value is accepted, including in
    /// ranges (`mon-fri`).
    public static func parse(_ expression: String) throws -> AutomationCronSchedule {
        let fields = expression.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else {
            throw AutomationCronScheduleError(
                "Cron expression must have 5 fields (minute hour day-of-month month day-of-week), found \(fields.count)")
        }

        let minutes = try parseField(fields[0], name: "minute", range: 0...59, names: nil)
        let hours = try parseField(fields[1], name: "hour", range: 0...23, names: nil)
        let daysOfMonth = try parseField(fields[2], name: "day-of-month", range: 1...31, names: nil)
        let months = try parseField(fields[3], name: "month", range: 1...12, names: monthNames)
        var daysOfWeek = try parseField(fields[4], name: "day-of-week", range: 0...7, names: dayOfWeekNames)
        // 7 is an alias for Sunday (0) in the dow field; normalize so downstream matching
        // only ever deals with 0-6.
        if daysOfWeek.remove(7) != nil { daysOfWeek.insert(0) }

        return AutomationCronSchedule(
            minutes: minutes, hours: hours, daysOfMonth: daysOfMonth, months: months, daysOfWeek: daysOfWeek,
            // Standard (Vixie) cron treats a day field that STARTS with `*` — bare `*` or a step like
            // `*/2` — as unrestricted for the day-of-month/day-of-week interaction: the fire-on-EITHER
            // rule applies only when both fields are written as explicit values or ranges. Marking `*/n`
            // restricted would make `0 0 */2 * MON` fire on every second day PLUS every Monday instead of
            // only Mondays that fall on a matching day.
            dayOfMonthRestricted: !fields[2].hasPrefix("*"), dayOfWeekRestricted: !fields[4].hasPrefix("*"))
    }

    /// Parses one cron field (e.g. `"1,15"`, `"mon-fri"`, `"*/15"`) into the set of concrete
    /// integer values it matches, validating every value against `range` and every step/range
    /// against cron's syntax rules.
    private static func parseField(_ field: String, name: String, range: ClosedRange<Int>, names: [String: Int]?) throws -> Set<Int> {
        guard !field.isEmpty else { throw AutomationCronScheduleError("Cron \(name) field cannot be empty") }

        var values = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { throw AutomationCronScheduleError("Cron \(name) field has an empty list item in \"\(field)\"") }
            values.formUnion(try parsePart(String(part), name: name, range: range, names: names))
        }
        return values
    }

    /// Parses a single comma-separated part of a field: a step expression (`*/n`, `a-b/n`), a
    /// range (`a-b`), or a bare value/name.
    private static func parsePart(_ part: String, name: String, range: ClosedRange<Int>, names: [String: Int]?) throws -> Set<Int> {
        let base: String
        let step: Int
        if let slashIndex = part.firstIndex(of: "/") {
            base = String(part[part.startIndex..<slashIndex])
            let stepText = String(part[part.index(after: slashIndex)...])
            guard let parsedStep = Int(stepText), parsedStep > 0 else {
                throw AutomationCronScheduleError("Cron \(name) field has an invalid step in \"\(part)\"")
            }
            step = parsedStep
        } else {
            base = part
            step = 1
        }

        let bounds: ClosedRange<Int>
        if base == "*" {
            bounds = range
        } else if let dashIndex = base.firstIndex(of: "-") {
            let lowerText = String(base[base.startIndex..<dashIndex])
            let upperText = String(base[base.index(after: dashIndex)...])
            let lower = try parseValue(lowerText, name: name, range: range, names: names)
            let upper = try parseValue(upperText, name: name, range: range, names: names)
            guard lower <= upper else { throw AutomationCronScheduleError("Cron \(name) field has an inverted range in \"\(part)\"") }
            bounds = lower...upper
        } else {
            guard step == 1 else { throw AutomationCronScheduleError("Cron \(name) field has a step without a range or \"*\" in \"\(part)\"") }
            let value = try parseValue(base, name: name, range: range, names: names)
            return [value]
        }

        var values = Set<Int>()
        var current = bounds.lowerBound
        while current <= bounds.upperBound {
            values.insert(current)
            // Advance with overflow reporting rather than `current += step`: a step is only validated as
            // `> 0`, so a huge step (e.g. `*/9223372036854775807`) would trap on the addition. A step
            // wider than the field's span already yields just the lower bound, so an overflow means there
            // is no further value to add and the loop is done.
            let (next, overflowed) = current.addingReportingOverflow(step)
            if overflowed { break }
            current = next
        }
        return values
    }

    /// Parses one bare token in a field to an integer, accepting either a numeric value or (for
    /// month/day-of-week) a case-insensitive 3-letter name, and validates it against `range`.
    private static func parseValue(_ text: String, name: String, range: ClosedRange<Int>, names: [String: Int]?) throws -> Int {
        guard !text.isEmpty else { throw AutomationCronScheduleError("Cron \(name) field has a missing value") }
        let value: Int
        if let numeric = Int(text) {
            value = numeric
        } else if let names, let named = names[text.lowercased()] {
            value = named
        } else {
            throw AutomationCronScheduleError("Cron \(name) field has an unrecognized value \"\(text)\"")
        }
        guard range.contains(value) else {
            throw AutomationCronScheduleError("Cron \(name) field value \(value) is out of range \(range.lowerBound)-\(range.upperBound)")
        }
        return value
    }

    /// Returns whether a calendar day identified by `dayOfMonth`/`month`/`weekday0Sunday`
    /// (Sunday = 0) can fire this schedule at all, ignoring hour/minute. Used both by the full
    /// match check and to skip an entire non-matching day in one step, applying the standard
    /// cron OR rule when both day-of-month and day-of-week are restricted (neither is `*`).
    private func dayMatches(dayOfMonth: Int, month: Int, weekday0Sunday: Int) -> Bool {
        guard months.contains(month) else { return false }
        let domMatches = daysOfMonth.contains(dayOfMonth)
        let dowMatches = daysOfWeek.contains(weekday0Sunday)
        if dayOfMonthRestricted && dayOfWeekRestricted { return domMatches || dowMatches }
        return domMatches && dowMatches
    }

    /// Returns the next minute boundary strictly after `date`, in `timeZone`, that matches this
    /// schedule, or `nil` if none is found within the search horizon.
    ///
    /// The search walks forward day by day, skipping an entire day in one step whenever
    /// `dayMatches` is false for it (e.g. every day for a schedule that names an impossible
    /// date such as Feb 30). Only within a day that can match does it step minute by minute to
    /// find the first matching hour/minute. This keeps the worst case (a schedule that never
    /// fires again) to roughly one iteration per calendar day across the search horizon rather
    /// than one per minute, while still handling dom/dow interaction and DST by walking real
    /// wall-clock dates instead of doing field arithmetic. The walk is bounded by
    /// `searchLimit` so schedules that can never match, or that are pathologically sparse,
    /// terminate instead of looping forever.
    ///
    /// DST handling: this walks real elapsed time one calendar minute at a time (via
    /// `Calendar.date(byAdding:)` in `timeZone`) and reads the resulting wall-clock date/time at
    /// each step. During a spring-forward transition, the wall-clock minutes that are skipped
    /// (e.g. 02:00-02:59 in `America/New_York` on its transition day) never occur as calendar
    /// times in that zone, so a schedule targeting a skipped time simply does not match on that
    /// day; the scan continues into the next day and fires there instead once clocks are past
    /// the gap. During a fall-back transition, the repeated wall-clock hour corresponds to two
    /// distinct absolute instants (once at each UTC offset), and this walk advances through both
    /// of them as real elapsed time, so a schedule matching a wall-clock time inside that hour
    /// fires once for each instant - matching the behavior of a daemon that ticks every real
    /// minute rather than de-duplicating on wall-clock display time.
    public func nextFireDate(after date: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Start from the top of the next minute so a date exactly on a fire time is never
        // returned again ("strictly after"). Truncate seconds by subtracting them as a plain
        // Date offset rather than rebuilding the date from year/month/day/hour/minute
        // components: a wall-clock minute is always exactly 60 real seconds (time zone offsets
        // are whole minutes), so this subtraction is unambiguous, whereas reconstructing a date
        // from broken-down components is ambiguous during a DST fall-back's repeated local hour
        // (Calendar could resolve it to either of the two real instants that share the same
        // wall-clock reading) and could make the search regress instead of advance.
        let secondsIntoMinute = calendar.component(.second, from: date)
        let nanosecondsIntoSecond = calendar.component(.nanosecond, from: date)
        let secondsToTrim = Double(secondsIntoMinute) + Double(nanosecondsIntoSecond) / 1_000_000_000
        let startOfCurrentMinute = date.addingTimeInterval(-secondsToTrim)
        guard var candidate = calendar.date(byAdding: .minute, value: 1, to: startOfCurrentMinute) else { return nil }

        let deadline = date.addingTimeInterval(Self.searchLimit)
        while candidate <= deadline {
            let dayComponents = calendar.dateComponents([.day, .month, .weekday], from: candidate)
            guard let day = dayComponents.day, let month = dayComponents.month, let weekday = dayComponents.weekday else { return nil }
            // Foundation's Calendar.weekday is 1-based with Sunday = 1; this schedule stores
            // day-of-week as 0-based with Sunday = 0.
            let weekday0Sunday = weekday - 1

            guard dayMatches(dayOfMonth: day, month: month, weekday0Sunday: weekday0Sunday) else {
                let startOfDay = calendar.startOfDay(for: candidate)
                guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }
                candidate = nextDayStart
                continue
            }

            let timeComponents = calendar.dateComponents([.hour, .minute], from: candidate)
            guard let hour = timeComponents.hour, let minute = timeComponents.minute else { return nil }
            if hours.contains(hour) && minutes.contains(minute) { return candidate }

            guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else { return nil }
            candidate = next
        }
        return nil
    }
}

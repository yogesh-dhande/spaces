import Foundation
import Testing
import workspacecore

@testable import spacesui

/// Covers the cron-schedule builder's serialization/derivation round-trips and the next-runs preview, the
/// pure logic behind the automation editor's schedule builder.
struct AutomationSchedulePresetTests {
    // MARK: - Preset ↔ cron-string round-trips

    @Test func everyNMinutesRoundTrips() {
        // Only uniform divisors of 60 are preset choices, so those are the values that round-trip.
        for n in AutomationSchedulePreset.everyNMinutesChoices {
            let preset = AutomationSchedulePreset.everyNMinutes(minutes: n)
            #expect(preset.cronExpression == "*/\(n) * * * *")
            #expect(AutomationSchedulePreset.from(cronExpression: preset.cronExpression) == preset)
        }
    }

    @Test func everyNMinutesChoicesAreDivisorsOfSixtyUpTo30() {
        // A `*/N` cron only keeps a uniform gap when N divides 60; the preset offers exactly those steps
        // (2 through 30) so it can never open on a lying non-uniform cadence. 1 is excluded like
        // every-minute (`*`) always was.
        #expect(AutomationSchedulePreset.everyNMinutesChoices == [2, 3, 4, 5, 6, 10, 12, 15, 20, 30])
    }

    @Test func everyMinuteStepIsAdvanced() {
        // `*/1` is the same schedule as every-minute (`*`), which is deliberately not a preset; both open
        // in Advanced so the round-trip stays deterministic.
        #expect(AutomationSchedulePreset.from(cronExpression: "*/1 * * * *") == .advanced(expression: "*/1 * * * *"))
    }

    @Test func hourlyAtMinuteRoundTrips() {
        for m in [0, 5, 30, 59] {
            let preset = AutomationSchedulePreset.hourlyAtMinute(minute: m)
            #expect(preset.cronExpression == "\(m) * * * *")
            #expect(AutomationSchedulePreset.from(cronExpression: preset.cronExpression) == preset)
        }
    }

    @Test func dailyAtTimeRoundTrips() {
        let preset = AutomationSchedulePreset.dailyAtTime(hour: 9, minute: 30)
        #expect(preset.cronExpression == "30 9 * * *")
        #expect(AutomationSchedulePreset.from(cronExpression: preset.cronExpression) == preset)
    }

    @Test func weeklyOnDaysAtTimeRoundTripsAndSortsDays() {
        let preset = AutomationSchedulePreset.weeklyOnDaysAtTime(days: [5, 1, 3], hour: 8, minute: 15)
        // Days serialize sorted for a canonical string regardless of set order.
        #expect(preset.cronExpression == "15 8 * * 1,3,5")
        #expect(AutomationSchedulePreset.from(cronExpression: preset.cronExpression) == preset)
    }

    @Test func singleWeekdayRoundTrips() {
        let preset = AutomationSchedulePreset.weeklyOnDaysAtTime(days: [0], hour: 0, minute: 0)
        #expect(preset.cronExpression == "0 0 * * 0")
        #expect(AutomationSchedulePreset.from(cronExpression: preset.cronExpression) == preset)
    }

    // MARK: - Non-preset strings fall to Advanced

    @Test func everyMinuteIsAdvancedNotEveryNMinutes() {
        // A bare `*` minute is not the `*/N` shape, so it is not a preset; it opens in Advanced verbatim.
        #expect(AutomationSchedulePreset.from(cronExpression: "* * * * *") == .advanced(expression: "* * * * *"))
    }

    @Test func restrictedDayOfMonthIsAdvanced() {
        #expect(AutomationSchedulePreset.from(cronExpression: "0 0 1 * *") == .advanced(expression: "0 0 1 * *"))
    }

    @Test func restrictedMonthIsAdvanced() {
        #expect(AutomationSchedulePreset.from(cronExpression: "0 9 * 6 *") == .advanced(expression: "0 9 * 6 *"))
    }

    @Test func stepMinutesWithRestrictedWeekdayIsAdvanced() {
        // `*/15` in the minute field only forms the every-N-minutes preset when the rest is unrestricted.
        #expect(AutomationSchedulePreset.from(cronExpression: "*/15 * * * 1") == .advanced(expression: "*/15 * * * 1"))
    }

    @Test func minuteRangeInWeekdayIsAdvanced() {
        // A weekday range (not a comma list of bare values) is beyond the weekly preset.
        #expect(AutomationSchedulePreset.from(cronExpression: "0 9 * * 1-5") == .advanced(expression: "0 9 * * 1-5"))
    }

    @Test func malformedExpressionIsAdvancedTrimmed() {
        #expect(AutomationSchedulePreset.from(cronExpression: "  not a cron  ") == .advanced(expression: "not a cron"))
    }

    @Test func nonDivisorStepMinutesIsAdvanced() {
        // `*/40` is valid cron but does NOT space evenly (fires at :00 and :40 each hour), so it is not an
        // every-N-minutes preset — it opens in Advanced verbatim rather than as a lying preset. `*/59` (fires
        // at :59 then :00) is the same case.
        #expect(AutomationSchedulePreset.from(cronExpression: "*/40 * * * *") == .advanced(expression: "*/40 * * * *"))
        #expect(AutomationSchedulePreset.from(cronExpression: "*/59 * * * *") == .advanced(expression: "*/59 * * * *"))
    }

    @Test func divisorStepMinutesRoundTripsToPreset() {
        // A divisor step opens honestly as the preset.
        #expect(AutomationSchedulePreset.from(cronExpression: "*/15 * * * *") == .everyNMinutes(minutes: 15))
    }

    // MARK: - Next-3-runs preview

    private func utc() -> TimeZone { TimeZone(identifier: "UTC") ?? .gmt }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else {
            Issue.record("bad fixture date \(iso)")
            return Date()
        }
        return date
    }

    @Test func nextRunsComputesThreeDailyFires() throws {
        let runs = try AutomationSchedulePreview.nextRuns(cronExpression: "0 9 * * *", after: date("2026-01-01T00:00:00Z"), timeZone: utc(), count: 3)
        #expect(runs == [date("2026-01-01T09:00:00Z"), date("2026-01-02T09:00:00Z"), date("2026-01-03T09:00:00Z")])
    }

    @Test func nextRunsSkipsAPassedFireTimeToday() throws {
        // Already past 09:00 today, so the first fire is tomorrow.
        let runs = try AutomationSchedulePreview.nextRuns(cronExpression: "0 9 * * *", after: date("2026-01-01T10:00:00Z"), timeZone: utc(), count: 2)
        #expect(runs == [date("2026-01-02T09:00:00Z"), date("2026-01-03T09:00:00Z")])
    }

    @Test func nextRunsHonorsWeekdayPreset() throws {
        // Mondays only. 2026-01-01 is a Thursday; the next three Mondays are Jan 5, 12, 19.
        let runs = try AutomationSchedulePreview.nextRuns(
            cronExpression: AutomationSchedulePreset.weeklyOnDaysAtTime(days: [1], hour: 0, minute: 0).cronExpression,
            after: date("2026-01-01T00:00:00Z"), timeZone: utc(), count: 3)
        #expect(runs == [date("2026-01-05T00:00:00Z"), date("2026-01-12T00:00:00Z"), date("2026-01-19T00:00:00Z")])
    }

    @Test func nextRunsThrowsOnMalformedExpression() {
        #expect(throws: AutomationCronScheduleError.self) {
            _ = try AutomationSchedulePreview.nextRuns(cronExpression: "not a cron", after: Date(), timeZone: utc(), count: 3)
        }
    }
}

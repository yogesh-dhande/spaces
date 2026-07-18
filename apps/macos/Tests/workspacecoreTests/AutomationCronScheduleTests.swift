import XCTest

@testable import workspacecore

final class AutomationCronScheduleTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    /// Builds a `Date` for an exact wall-clock instant in `timeZone` (defaults to UTC), so
    /// tests can express fixtures as readable calendar dates instead of raw epoch offsets.
    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone: TimeZone? = nil
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? utc
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }

    // MARK: - Basic matching

    // Tests every-minute schedules fire on the next minute boundary by arranging a fixed start
    // and asserting the immediate next minute is returned.
    func testEveryMinuteFiresOnNextMinuteBoundary() throws {
        let schedule = try AutomationCronSchedule.parse("* * * * *")
        let start = date(2024, 1, 15, 10, 30)
        let next = schedule.nextFireDate(after: start, timeZone: utc)
        XCTAssertEqual(next, date(2024, 1, 15, 10, 31))
    }

    // Tests every-minute schedules also fire from a sub-minute offset by truncating seconds
    // before advancing, so 10:30:45 still lands on 10:31:00 rather than 10:32:00.
    func testEveryMinuteTruncatesSecondsBeforeAdvancing() throws {
        let schedule = try AutomationCronSchedule.parse("* * * * *")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let start = calendar.date(byAdding: .second, value: 45, to: date(2024, 1, 15, 10, 30))!
        let next = schedule.nextFireDate(after: start, timeZone: utc)
        XCTAssertEqual(next, date(2024, 1, 15, 10, 31))
    }

    // Tests a specific weekday time schedule skips the weekend and lands on the following
    // Monday, by arranging a start just after Friday's occurrence and asserting the result.
    func testSpecificWeekdayTimeSkipsWeekendAcrossWeekBoundary() throws {
        // Jan 1 2024 is a Monday, so Jan 5 2024 is a Friday and Jan 8 2024 is the next Monday.
        let schedule = try AutomationCronSchedule.parse("30 6 * * 1-5")
        let afterFridayFiring = date(2024, 1, 5, 7, 0)
        let next = schedule.nextFireDate(after: afterFridayFiring, timeZone: utc)
        XCTAssertEqual(next, date(2024, 1, 8, 6, 30))
    }

    // Tests every-15-minutes steps produce exactly the expected minute set by walking four
    // consecutive fires from a start that is not itself on a step boundary.
    func testStepSyntaxProducesQuarterHourBoundaries() throws {
        let schedule = try AutomationCronSchedule.parse("*/15 * * * *")
        var cursor = date(2024, 1, 15, 10, 5)
        let expectedMinutes = [15, 30, 45, 0]
        for expectedMinute in expectedMinutes {
            let next = try XCTUnwrap(schedule.nextFireDate(after: cursor, timeZone: utc))
            XCTAssertEqual(Calendar(identifier: .gregorian).component(.minute, from: next), expectedMinute)
            cursor = next
        }
    }

    // Tests a stepped range (`a-b/n`) restricts to the given hour range at the given cadence.
    func testSteppedRangeRestrictsToHourWindow() throws {
        let schedule = try AutomationCronSchedule.parse("0 9-17/4 * * *")
        let next = schedule.nextFireDate(after: date(2024, 1, 15, 0, 0), timeZone: utc)
        XCTAssertEqual(next, date(2024, 1, 15, 9, 0))
        let following = schedule.nextFireDate(after: try XCTUnwrap(next), timeZone: utc)
        XCTAssertEqual(following, date(2024, 1, 15, 13, 0))
    }

    // Tests ranges combined with lists (e.g. business hours plus a specific extra minute) by
    // asserting membership at the boundaries and the list value.
    func testRangesCombinedWithLists() throws {
        let schedule = try AutomationCronSchedule.parse("0,30 9-11 * * *")
        var cursor = date(2024, 1, 15, 8, 0)
        let expected: [(Int, Int)] = [(9, 0), (9, 30), (10, 0), (10, 30), (11, 0), (11, 30)]
        for (hour, minute) in expected {
            let next = try XCTUnwrap(schedule.nextFireDate(after: cursor, timeZone: utc))
            XCTAssertEqual(next, date(2024, 1, 15, hour, minute))
            cursor = next
        }
    }

    // Tests month and day-of-week 3-letter names (mixed case) parse and match the same as their
    // numeric equivalents.
    func testMonthAndDayOfWeekNamesMatchNumericEquivalents() throws {
        let named = try AutomationCronSchedule.parse("0 0 1 Jan,JUL *")
        let numeric = try AutomationCronSchedule.parse("0 0 1 1,7 *")
        XCTAssertEqual(named, numeric)

        let namedDow = try AutomationCronSchedule.parse("0 0 * * mon-fri")
        let numericDow = try AutomationCronSchedule.parse("0 0 * * 1-5")
        XCTAssertEqual(namedDow, numericDow)
    }

    // MARK: - Day-of-month / day-of-week interaction

    // Tests the standard cron OR rule: when both dom and dow are restricted, a date matches if
    // EITHER matches, by walking the sequence of Fridays and the 13th across January 2024.
    func testDomAndDowOrRuleWhenBothRestricted() throws {
        // January 2024: Fridays are the 5th, 12th, 19th, 26th; the 13th is a Saturday.
        let schedule = try AutomationCronSchedule.parse("0 0 13 * 5")
        var cursor = date(2024, 1, 1, 0, 0)
        let expectedDays = [5, 12, 13, 19, 26]
        for day in expectedDays {
            let next = try XCTUnwrap(schedule.nextFireDate(after: cursor, timeZone: utc))
            XCTAssertEqual(next, date(2024, 1, day, 0, 0), "expected day \(day)")
            cursor = next
        }
    }

    // Tests that when only day-of-month is restricted (dow is `*`), matching is a plain AND,
    // i.e. only the 13th fires regardless of weekday.
    func testDomOnlyRestrictedFiresOnlyOnThatDayOfMonth() throws {
        let schedule = try AutomationCronSchedule.parse("0 0 13 * *")
        let next = schedule.nextFireDate(after: date(2024, 1, 1, 0, 0), timeZone: utc)
        XCTAssertEqual(next, date(2024, 1, 13, 0, 0))
        let following = schedule.nextFireDate(after: try XCTUnwrap(next), timeZone: utc)
        XCTAssertEqual(following, date(2024, 2, 13, 0, 0))
    }

    // Tests that when only day-of-week is restricted (dom is `*`), matching is a plain AND,
    // i.e. every Friday fires regardless of day-of-month.
    func testDowOnlyRestrictedFiresOnlyOnThatWeekday() throws {
        let schedule = try AutomationCronSchedule.parse("0 0 * * 5")
        let next = schedule.nextFireDate(after: date(2024, 1, 1, 0, 0), timeZone: utc)
        XCTAssertEqual(next, date(2024, 1, 5, 0, 0))
    }

    // Tests day-of-week 0 and 7 are equivalent Sunday aliases: both parse to the same schedule
    // and produce identical fire dates.
    func testSundayZeroAndSevenAreEquivalent() throws {
        let zero = try AutomationCronSchedule.parse("0 0 * * 0")
        let seven = try AutomationCronSchedule.parse("0 0 * * 7")
        XCTAssertEqual(zero, seven)

        let start = date(2024, 1, 1, 0, 0)
        XCTAssertEqual(
            zero.nextFireDate(after: start, timeZone: utc),
            seven.nextFireDate(after: start, timeZone: utc)
        )
    }

    // MARK: - Strict "after" semantics

    // Tests that a date exactly on a fire time returns the NEXT fire, not the same instant.
    func testExactFireTimeReturnsNextOccurrenceNotSameInstant() throws {
        let schedule = try AutomationCronSchedule.parse("0 0 * * *")
        let exactlyOnFireTime = date(2024, 1, 15, 0, 0)
        let next = schedule.nextFireDate(after: exactlyOnFireTime, timeZone: utc)
        XCTAssertEqual(next, date(2024, 1, 16, 0, 0))
    }

    // MARK: - Rollover

    // Tests a monthly schedule rolls from the middle of one month into the first of the next.
    func testMonthRollover() throws {
        let schedule = try AutomationCronSchedule.parse("0 0 1 * *")
        let next = schedule.nextFireDate(after: date(2024, 1, 15, 0, 0), timeZone: utc)
        XCTAssertEqual(next, date(2024, 2, 1, 0, 0))
    }

    // Tests a monthly schedule rolls across a year boundary from December into January.
    func testYearRollover() throws {
        let schedule = try AutomationCronSchedule.parse("0 0 1 * *")
        let next = schedule.nextFireDate(after: date(2024, 12, 15, 0, 0), timeZone: utc)
        XCTAssertEqual(next, date(2025, 1, 1, 0, 0))
    }

    // Tests a Feb 29 schedule starting from a non-leap year skips forward to the next leap year
    // rather than matching a nonexistent Feb 29 in between.
    func testFeb29SchedulesSkipToNextLeapYear() throws {
        let schedule = try AutomationCronSchedule.parse("0 0 29 2 *")
        // 2023 is not a leap year; 2024 is. The search must skip 2023 entirely.
        let next = schedule.nextFireDate(after: date(2023, 1, 1, 0, 0), timeZone: utc)
        XCTAssertEqual(next, date(2024, 2, 29, 0, 0))
    }

    // MARK: - DST

    // Tests a schedule targeting a wall-clock time inside the DST spring-forward gap does not
    // hang and resolves to a later valid date once the gap has passed.
    //
    // Documented behavior: in America/New_York, clocks jump from 01:59:59 to 03:00:00 on the
    // 2024-03-10 transition, so 02:30 never occurs as a wall-clock time that day. This schedule
    // does not fire on the transition day at all; it fires the next day (2024-03-11) once 02:30
    // exists again. This is the chosen product behavior: a skipped wall-clock time is simply not
    // matched rather than being remapped to some nearby real time.
    func testDSTSpringForwardGapDoesNotHangAndSkipsToNextValidDay() throws {
        let schedule = try AutomationCronSchedule.parse("30 2 * * *")
        let start = date(2024, 3, 9, 12, 0, timeZone: newYork)
        let next = try XCTUnwrap(schedule.nextFireDate(after: start, timeZone: newYork))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 11, "the transition day (10th) has no 02:30, so the next fire is the 11th")
        XCTAssertEqual(components.hour, 2)
        XCTAssertEqual(components.minute, 30)
    }

    // Tests a schedule spanning the DST fall-back repeated hour resolves each of the two real
    // instants that share the same wall-clock reading, then rolls over to the next day, and
    // does not hang.
    //
    // Documented behavior: in America/New_York, 2024-11-03 replays 01:00-01:59 twice (once at
    // UTC-4, once at UTC-5). This search advances through real elapsed time one minute at a
    // time, so it visits both instants that display as "01:30" and treats each as a distinct
    // fire, the same way a daemon ticking every real minute would. This is the chosen product
    // behavior, not a bug: de-duplicating by wall-clock display time would require detecting
    // and special-casing UTC-offset changes.
    func testDSTFallBackRepeatedHourFiresForBothInstants() throws {
        let schedule = try AutomationCronSchedule.parse("30 1 * * *")
        // 2024-11-03 is the fall-back date in America/New_York (01:00-01:59 occurs twice).
        let start = date(2024, 11, 2, 12, 0, timeZone: newYork)
        let firstFire = try XCTUnwrap(schedule.nextFireDate(after: start, timeZone: newYork))
        let secondFire = try XCTUnwrap(schedule.nextFireDate(after: firstFire, timeZone: newYork))
        let thirdFire = try XCTUnwrap(schedule.nextFireDate(after: secondFire, timeZone: newYork))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let firstComponents = calendar.dateComponents([.day, .hour, .minute], from: firstFire)
        XCTAssertEqual(firstComponents.day, 3)
        XCTAssertEqual(firstComponents.hour, 1)
        XCTAssertEqual(firstComponents.minute, 30)

        // Both fires read "01:30" on the wall clock but are exactly one hour apart in real
        // (absolute) time, since the second instant is after the UTC offset has changed.
        let secondComponents = calendar.dateComponents([.day, .hour, .minute], from: secondFire)
        XCTAssertEqual(secondComponents.day, 3)
        XCTAssertEqual(secondComponents.hour, 1)
        XCTAssertEqual(secondComponents.minute, 30)
        XCTAssertEqual(secondFire.timeIntervalSince(firstFire), 3600)

        // The third fire rolls over to the next day, once the repeated hour is exhausted.
        let thirdComponents = calendar.dateComponents([.day], from: thirdFire)
        XCTAssertEqual(thirdComponents.day, 4)
    }

    // MARK: - Time zone sensitivity

    // Tests that the same schedule evaluated in two different time zones from the same instant
    // resolves to two different absolute instants, offset by the zones' UTC difference.
    func testSameScheduleDiffersByTimeZone() throws {
        let schedule = try AutomationCronSchedule.parse("0 9 * * *")
        let start = date(2024, 1, 1, 0, 0, timeZone: utc)

        let utcNext = try XCTUnwrap(schedule.nextFireDate(after: start, timeZone: utc))
        let laNext = try XCTUnwrap(schedule.nextFireDate(after: start, timeZone: losAngeles))

        XCTAssertNotEqual(utcNext, laNext)
        // Jan 1 2024 America/Los_Angeles is standard time, UTC-8, so 09:00 PST is 17:00 UTC.
        XCTAssertEqual(laNext, date(2024, 1, 1, 17, 0, timeZone: utc))
    }

    // MARK: - Equatable

    // Tests that equivalent field syntax (explicit list vs range) parses to an equal schedule,
    // since both expand to the same underlying value sets.
    func testEquivalentSyntaxProducesEqualSchedules() throws {
        let viaList = try AutomationCronSchedule.parse("1,2,3 * * * *")
        let viaRange = try AutomationCronSchedule.parse("1-3 * * * *")
        XCTAssertEqual(viaList, viaRange)
    }

    // Tests that schedules with different matched values are not equal.
    func testDifferingSchedulesAreNotEqual() throws {
        let a = try AutomationCronSchedule.parse("0 9 * * *")
        let b = try AutomationCronSchedule.parse("0 10 * * *")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Parse errors

    // Tests parse rejects an expression without exactly 5 fields.
    func testParseRejectsWrongFieldCount() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("* * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("5 fields"))
        }
        XCTAssertThrowsError(try AutomationCronSchedule.parse("* * * * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("5 fields"))
        }
    }

    // Tests parse rejects an out-of-range minute value.
    func testParseRejectsOutOfRangeMinute() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("60 * * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("minute"))
        }
    }

    // Tests parse rejects an out-of-range hour value.
    func testParseRejectsOutOfRangeHour() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("* 24 * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("hour"))
        }
    }

    // Tests parse rejects an out-of-range day-of-month value.
    func testParseRejectsOutOfRangeDayOfMonth() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("* * 32 * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("day-of-month"))
        }
        XCTAssertThrowsError(try AutomationCronSchedule.parse("* * 0 * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("day-of-month"))
        }
    }

    // Tests parse rejects an out-of-range month value.
    func testParseRejectsOutOfRangeMonth() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("* * * 13 *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("month"))
        }
    }

    // Tests parse rejects an out-of-range day-of-week value.
    func testParseRejectsOutOfRangeDayOfWeek() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("* * * * 8")) { error in
            XCTAssertTrue(error.localizedDescription.contains("day-of-week"))
        }
    }

    // Tests parse rejects an inverted numeric range.
    func testParseRejectsInvertedRange() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("5-3 * * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("inverted range"))
        }
    }

    // Tests parse rejects an inverted named range.
    func testParseRejectsInvertedNamedRange() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("0 0 * * fri-mon")) { error in
            XCTAssertTrue(error.localizedDescription.contains("inverted range"))
        }
    }

    // Tests parse rejects a zero step.
    func testParseRejectsZeroStep() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("*/0 * * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid step"))
        }
    }

    // Tests parse rejects a non-numeric step.
    func testParseRejectsNonNumericStep() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("*/x * * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid step"))
        }
    }

    // Tests parse rejects a step applied to a bare value with no range or wildcard base.
    func testParseRejectsStepWithoutRangeOrWildcard() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("5/2 * * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("step without a range"))
        }
    }

    // Tests parse rejects an unrecognized month name.
    func testParseRejectsUnknownMonthName() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("* * * foo *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("unrecognized value"))
        }
    }

    // Tests parse rejects an unrecognized day-of-week name.
    func testParseRejectsUnknownDayOfWeekName() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("* * * * xyz")) { error in
            XCTAssertTrue(error.localizedDescription.contains("unrecognized value"))
        }
    }

    // Tests parse rejects an empty list item produced by a stray comma.
    func testParseRejectsEmptyListItem() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("1,,3 * * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("empty list item"))
        }
    }

    // Tests parse rejects a range with a missing bound.
    func testParseRejectsRangeWithMissingBound() {
        XCTAssertThrowsError(try AutomationCronSchedule.parse("1- * * * *")) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing value"))
        }
    }
}

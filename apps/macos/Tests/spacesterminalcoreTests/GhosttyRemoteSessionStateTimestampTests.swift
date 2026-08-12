import Foundation
import XCTest
import spacesterminalcore

/// Exercises `GhosttyRemoteSessionStateTimestamp.date(from:)`'s fast manual parse against the
/// ICU-backed `ISO8601DateFormatter`s it is meant to match bit-for-bit. Tests go through the
/// public API only (not the private fast-path helper) so they cover the function's contract
/// rather than its implementation shape: any well-formed wire timestamp must resolve to exactly
/// the `Date` the formatters would have produced, and any malformed one must be rejected (or
/// accepted) exactly as the formatter-only implementation would.
final class GhosttyRemoteSessionStateTimestampTests: XCTestCase {
    nonisolated(unsafe) private static let referenceFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let referenceDefaultFormatter = ISO8601DateFormatter()

    private static func referenceDate(from string: String) -> Date? {
        referenceFractionalFormatter.date(from: string) ?? referenceDefaultFormatter.date(from: string)
    }

    // Epoch, a now-ish fixed instant, end-of-month/leap-year/leap-day boundaries, year 2000
    // (leap, divisible by 400), year 2100 (not leap, divisible by 100 but not 400), and both
    // fractional extremes.
    private let fractionalCorpus: [String] = [
        "1970-01-01T00:00:00.000Z", "2026-08-06T12:34:56.789Z", "2026-01-31T23:59:59.000Z", "2026-04-30T23:59:59.500Z", "2026-02-28T23:59:59.999Z",
        "2024-02-29T00:00:00.000Z", "2024-02-29T23:59:59.999Z", "2000-01-01T00:00:00.000Z", "2000-02-29T12:00:00.000Z", "2100-02-28T00:00:00.000Z",
        "2026-12-31T23:59:59.999Z", "2026-08-06T12:34:56.000Z",
    ]

    private let wholeSecondCorpus: [String] = [
        "1970-01-01T00:00:00Z", "2026-08-06T12:34:56Z", "2026-02-28T23:59:59Z", "2024-02-29T00:00:00Z", "2000-02-29T00:00:00Z",
        "2100-02-28T00:00:00Z", "2026-12-31T23:59:59Z",
    ]

    func testFastPathMatchesFractionalFormatterExactly() {
        for value in fractionalCorpus {
            let expected = Self.referenceFractionalFormatter.date(from: value)
            XCTAssertNotNil(expected, "reference formatter rejected corpus entry \(value)")
            let actual = GhosttyRemoteSessionStateTimestamp.date(from: value)
            XCTAssertEqual(actual, expected, "mismatch for \(value)")
        }
    }

    func testFastPathMatchesWholeSecondFormatterExactly() {
        for value in wholeSecondCorpus {
            let expected = Self.referenceDefaultFormatter.date(from: value)
            XCTAssertNotNil(expected, "reference formatter rejected corpus entry \(value)")
            let actual = GhosttyRemoteSessionStateTimestamp.date(from: value)
            XCTAssertEqual(actual, expected, "mismatch for \(value)")
        }
    }

    func testDateFromStringFromRoundTrips() {
        let dates = fractionalCorpus.compactMap { Self.referenceFractionalFormatter.date(from: $0) }
        XCTAssertEqual(dates.count, fractionalCorpus.count)
        for date in dates {
            let string = GhosttyRemoteSessionStateTimestamp.string(from: date)
            let roundTripped = GhosttyRemoteSessionStateTimestamp.date(from: string)
            XCTAssertEqual(roundTripped, date, "round trip failed for \(date)")
        }
    }

    func testRejectedAndOutOfRangeFormsMatchFormatterOnlyBehaviorExactly() {
        let inputs = [
            "2026-08-06T12:34:56+05:00", "2026-08-06T12:34:56.789+05:00", "2026-08-06T12:34:56", "2026-08-06T12:34:56.78Z",
            "2026-08-06T12:34:56.7890Z", "garbage", "", "2026-13-06T12:34:56.789Z", "2026-02-30T12:34:56.789Z", "2026-04-31T12:34:56.789Z",
            "2026-02-29T12:34:56.789Z", "2026-08-06T24:00:00.000Z", "2026-08-06T12:60:00.000Z", "2026-08-06T12:34:60.000Z",
            "0000-01-01T00:00:00.000Z",
        ]
        for value in inputs {
            let expected = Self.referenceDate(from: value)
            let actual = GhosttyRemoteSessionStateTimestamp.date(from: value)
            XCTAssertEqual(actual, expected, "mismatch for \(value.isEmpty ? "<empty>" : value)")
        }
    }
}

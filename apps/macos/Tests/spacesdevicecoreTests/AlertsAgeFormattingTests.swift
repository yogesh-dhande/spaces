// `AlertsAgeFormatting` is compiled out on Linux (it is client-only), so this test is too: an unguarded
// reference to it would fail the whole `spacesdevicecoreTests` target's Linux compile, not just this suite.
#if !os(Linux)

    import Foundation
    import Testing

    @testable import spacesdevicecore

    /// The abbreviated age shown next to an alert row on the Mac and on iOS, shared by both clients.
    @Suite struct AlertsAgeFormattingTests {
        @Test func agesAbbreviateByMagnitude() {
            let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
            #expect(AlertsAgeFormatting.abbreviatedAge(of: now.addingTimeInterval(-30), relativeTo: now) == "now")
            #expect(AlertsAgeFormatting.abbreviatedAge(of: now.addingTimeInterval(-5 * 60), relativeTo: now) == "5m")
            #expect(AlertsAgeFormatting.abbreviatedAge(of: now.addingTimeInterval(-3 * 3600), relativeTo: now) == "3h")
            #expect(AlertsAgeFormatting.abbreviatedAge(of: now.addingTimeInterval(-2 * 86400), relativeTo: now) == "2d")
        }
    }

#endif

import Testing

@testable import spacesterminalcore

@Suite struct TerminalFontSizeTests {
    @Test func defaultsToTen() { #expect(TerminalFontSize.default == .ten) }

    @Test func allCasesAreOrderedNineToTwelve() {
        #expect(TerminalFontSize.allCases.map(\.rawValue) == [9, 10, 11, 12])
    }

    @Test func missingPersistedValueResolvesToTen() { #expect(TerminalFontSize(persistedRawValue: nil) == .ten) }

    @Test func outOfRangePersistedValueResolvesToTen() { #expect(TerminalFontSize(persistedRawValue: 20) == .ten) }

    @Test func knownPersistedValuesRoundTrip() {
        for size in TerminalFontSize.allCases { #expect(TerminalFontSize(persistedRawValue: size.rawValue) == size) }
    }

    @Test func pointsAndDisplayNameMatchRawValue() {
        for size in TerminalFontSize.allCases {
            #expect(size.points == Double(size.rawValue))
            #expect(size.displayName == "\(size.rawValue)")
        }
    }
}

import Testing

@testable import spacesterminalcore

@Suite struct TerminalFontSizeTests {
    @Test func defaultsToEleven() { #expect(TerminalFontSize.default == .eleven) }

    @Test func allCasesAreOrderedNineToTwelve() {
        #expect(TerminalFontSize.allCases.map(\.rawValue) == [9, 10, 11, 12])
    }

    @Test func missingPersistedValueResolvesToEleven() { #expect(TerminalFontSize(persistedRawValue: nil) == .eleven) }

    @Test func outOfRangePersistedValueResolvesToEleven() { #expect(TerminalFontSize(persistedRawValue: 20) == .eleven) }

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

import Testing

@testable import spacesterminalcore

@Suite struct AppAppearanceModeTests {
    @Test func defaultsToDark() { #expect(AppAppearanceMode.default == .dark) }

    @Test func missingPersistedValueResolvesToDark() { #expect(AppAppearanceMode(persistedRawValue: nil) == .dark) }

    @Test func unknownPersistedValueResolvesToDark() { #expect(AppAppearanceMode(persistedRawValue: "sepia") == .dark) }

    @Test func knownPersistedValuesRoundTrip() {
        for mode in AppAppearanceMode.allCases { #expect(AppAppearanceMode(persistedRawValue: mode.rawValue) == mode) }
    }
}

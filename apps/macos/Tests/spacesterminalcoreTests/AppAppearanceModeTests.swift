import Testing

@testable import spacesterminalcore

@Suite struct AppAppearanceModeTests {
    @Test func defaultsToDark() { #expect(AppAppearanceMode.default == .dark) }

    /// Missing and unrecognized persisted values both resolve to the default: unreadable settings
    /// must degrade gracefully rather than fail or pick an arbitrary mode.
    @Test(arguments: [nil, "sepia"] as [String?])
    func unresolvablePersistedValueResolvesToDark(persistedRawValue: String?) {
        #expect(AppAppearanceMode(persistedRawValue: persistedRawValue) == .dark)
    }
}

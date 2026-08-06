import Testing

@testable import spacesterminalcore

@Suite struct TerminalTextSizeTests {
    @Test func startsAtTwelvePoints() { #expect(TerminalTextSize.default.points == 12) }

    /// Zooming moves one point per press.
    @Test func zoomingMovesOnePointPerStep() {
        #expect(TerminalTextSize.default.applying(.zoomIn).points == 13)
        #expect(TerminalTextSize.default.applying(.zoomOut).points == 11)
    }

    /// At the top of the range a further zoom-in press does nothing: the size it resolves to is the
    /// size already in use, so nothing repaints and nothing is persisted.
    @Test func zoomingInStopsAtTheLargestSize() {
        var size = TerminalTextSize.default
        for _ in 0..<20 { size = size.applying(.zoomIn) }
        #expect(size.points == 18)
        #expect(size.applying(.zoomIn) == size)
    }

    @Test func zoomingOutStopsAtTheSmallestSize() {
        var size = TerminalTextSize.default
        for _ in 0..<20 { size = size.applying(.zoomOut) }
        #expect(size.points == 9)
        #expect(size.applying(.zoomOut) == size)
    }

    /// A size the user chose survives a relaunch.
    @Test func persistedValueRoundTrips() {
        let zoomed = TerminalTextSize.default.applying(.zoomIn).applying(.zoomIn)
        #expect(TerminalTextSize(persistedRawValue: zoomed.persistedRawValue) == zoomed)
    }

    /// Missing, non-numeric, and out-of-range persisted values all resolve to the default: an
    /// unreadable setting must never leave terminals rendering at an unusable size.
    @Test(arguments: [nil, "", "medium", "0", "8", "19", "12.5"] as [String?]) func unresolvablePersistedValueResolvesToTheDefault(
        persistedRawValue: String?
    ) { #expect(TerminalTextSize(persistedRawValue: persistedRawValue) == .default) }
}

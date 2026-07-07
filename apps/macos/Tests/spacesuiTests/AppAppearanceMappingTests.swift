import AppKit
import Testing

@testable import spacesterminalcore
@testable import spacesui

@Suite struct AppAppearanceMappingTests {
    @Test func systemFollowsOSWithNoOverride() {
        #expect(AppAppearanceMode.system.nsAppearance == nil)
    }

    @Test func forcedModesPinConcreteAppearances() {
        #expect(AppAppearanceMode.light.nsAppearance?.name == .aqua)
        #expect(AppAppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }
}

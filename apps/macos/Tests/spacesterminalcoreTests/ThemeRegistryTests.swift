import XCTest

@testable import spacesterminalcore

final class ThemeRegistryTests: XCTestCase {
    func testMissingAndUnknownThemeIDsResolveToSpacesBrand() {
        XCTAssertEqual(ThemeRegistry.descriptor(id: nil).id, ThemeRegistry.defaultThemeID)
        XCTAssertEqual(ThemeRegistry.descriptor(id: ThemeID(rawValue: "not-a-theme")).id, ThemeRegistry.defaultThemeID)
        XCTAssertEqual(ThemeRegistry.descriptor(id: ThemeRegistry.defaultThemeID).displayName, "Spaces")
    }

    func testSpacesBrandResolvesExpectedSemanticTokens() {
        let brand = ThemeRegistry.spacesBrand
        XCTAssertEqual(brand.light.accent, ThemeColor(15, 122, 118))
        XCTAssertEqual(brand.dark.accent, ThemeColor(89, 219, 205))
        XCTAssertEqual(brand.light.background, ThemeColor(248, 247, 241))
        XCTAssertEqual(brand.dark.background, ThemeColor(15, 21, 23))
        XCTAssertEqual(brand.light.rowSelected, ThemeColor(15, 122, 118, alpha: 0.14))
        XCTAssertEqual(brand.dark.rowSelected, ThemeColor(89, 219, 205, alpha: 0.18))
        // Primary buttons use the same fill/ink in both appearances so ink text stays readable.
        XCTAssertEqual(brand.light.primaryButtonFill, brand.dark.primaryButtonFill)
        XCTAssertEqual(brand.light.primaryButtonText, brand.dark.primaryButtonText)
    }

    func testSpacesBrandTerminalBlendsIntoTheAppShell() {
        let brand = ThemeRegistry.spacesBrand
        // The dark terminal background is the dark sidebar background, and the light one is
        // the warm-neutral window background, so embedded terminals read as part of the shell.
        XCTAssertEqual(brand.dark.terminal.background, brand.dark.sidebarBackground)
        XCTAssertEqual(brand.light.terminal.background, brand.light.background)
        XCTAssertEqual(brand.dark.terminal.foreground, brand.dark.text)
        XCTAssertEqual(brand.light.terminal.foreground, brand.light.text)
        XCTAssertEqual(brand.dark.terminal.cursorColor, brand.dark.accent)
        XCTAssertEqual(brand.light.terminal.cursorColor, brand.light.accent)
    }

    func testThemeColorPacksToRGBForTheTerminalShim() {
        // 0x00RRGGBB packing, alpha dropped — the form handed to the C terminal shim for remote
        // (Linux daemon) session theming.
        XCTAssertEqual(ThemeColor(0, 0, 0).packedRGB, 0x00_00_00)
        XCTAssertEqual(ThemeColor(255, 255, 255).packedRGB, 0xFF_FF_FF)
        XCTAssertEqual(ThemeColor(15, 21, 23).packedRGB, 0x0F_15_17)
        XCTAssertEqual(ThemeColor(89, 219, 205, alpha: 0.5).packedRGB, 0x59_DB_CD)
    }

    func testActiveThemeDefaultsToSpacesBrandAndResolvesBoundID() {
        let original = ActiveTheme.id
        defer { ActiveTheme.id = original }

        XCTAssertEqual(ActiveTheme.descriptor.id, ThemeRegistry.defaultThemeID)
        ActiveTheme.id = ThemeID(rawValue: "not-a-theme")
        XCTAssertEqual(ActiveTheme.descriptor.id, ThemeRegistry.defaultThemeID, "Unknown bound ids resolve to the default theme")
    }
}

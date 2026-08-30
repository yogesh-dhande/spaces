import XCTest

@testable import spacesterminalcore

final class GhosttyThemeConfigGeneratorTests: XCTestCase {
    func testThemeFileExportsColorsCursorSelectionAndFullPalette() {
        let contents = GhosttyThemeConfigGenerator.themeFileContents(ThemeRegistry.spacesBrand.dark.terminal)

        XCTAssertTrue(contents.contains("background = #0f1517"))
        XCTAssertTrue(contents.contains("foreground = #eaf0ef"))
        XCTAssertTrue(contents.contains("cursor-color = #59dbcd"))
        XCTAssertTrue(contents.contains("cursor-text = #0f1517"))
        XCTAssertTrue(contents.contains("selection-background = #2c5450"))
        XCTAssertTrue(contents.contains("selection-foreground = #eaf0ef"))
        for index in 0...15 { XCTAssertTrue(contents.contains("palette = \(index)="), "Missing palette entry \(index)") }
        XCTAssertTrue(contents.contains("palette = 0=#172124"))
        XCTAssertTrue(contents.contains("palette = 15=#eaf0ef"))
    }

    func testRootConfigReferencesBothThemeVariantsAndEmbeddedSettings() {
        let contents = GhosttyThemeConfigGenerator.rootConfigContents(
            lightThemePath: "/profile/ghostty/themes/x-light", darkThemePath: "/profile/ghostty/themes/x-dark")

        XCTAssertTrue(contents.contains("theme = light:/profile/ghostty/themes/x-light,dark:/profile/ghostty/themes/x-dark"))
        XCTAssertTrue(contents.contains("window-vsync = false"))
        XCTAssertTrue(contents.contains("font-size = 12"))
        XCTAssertTrue(contents.contains("clipboard-write-limit-bytes = 1048576"))
    }

    func testWriteConfigurationGeneratesFilesUnderConfigRootAndRegenerates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configRoot = root.appendingPathComponent("ghostty", isDirectory: true)

        let configPath = try GhosttyThemeConfigGenerator.writeConfiguration(theme: ThemeRegistry.spacesBrand, configRootDirectory: configRoot)

        XCTAssertEqual(configPath, configRoot.appendingPathComponent("config").path)
        let config = try String(contentsOfFile: configPath, encoding: .utf8)
        let lightPath = configRoot.appendingPathComponent("themes/spaces-brand-light").path
        let darkPath = configRoot.appendingPathComponent("themes/spaces-brand-dark").path
        XCTAssertTrue(config.contains("theme = light:\(lightPath),dark:\(darkPath)"))
        XCTAssertEqual(
            try String(contentsOfFile: lightPath, encoding: .utf8),
            GhosttyThemeConfigGenerator.themeFileContents(ThemeRegistry.spacesBrand.light.terminal))
        XCTAssertEqual(
            try String(contentsOfFile: darkPath, encoding: .utf8),
            GhosttyThemeConfigGenerator.themeFileContents(ThemeRegistry.spacesBrand.dark.terminal))

        // Regeneration overwrites in place so stale hand edits never leak into the loaded config.
        try "tampered".write(toFile: darkPath, atomically: true, encoding: .utf8)
        _ = try GhosttyThemeConfigGenerator.writeConfiguration(theme: ThemeRegistry.spacesBrand, configRootDirectory: configRoot)
        XCTAssertEqual(
            try String(contentsOfFile: darkPath, encoding: .utf8),
            GhosttyThemeConfigGenerator.themeFileContents(ThemeRegistry.spacesBrand.dark.terminal))
    }
}

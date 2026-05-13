import AppKit
import XCTest

@testable import spacesterminalghostty

final class GhosttyTerminalSnapshotRendererTests: XCTestCase {
    func testRendererBuildsVisibleTextAndCursorCell() {
        let snapshot = GhosttyTerminalSnapshot(
            columns: 4, rows: 2, cursorColumn: 1, cursorRow: 1, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0x111111,
            cells: [
                .init(codepoint: 65, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 66, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 67, foregroundRGB: 0x00FF00, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x111111, flags: 0),
            ])

        let rendered = GhosttyTerminalSnapshotRenderer.render(snapshot)

        XCTAssertEqual(rendered.string, "AB\nC ")
        let cursorAttributes = rendered.attributes(at: 4, effectiveRange: nil)
        let cursorForeground = cursorAttributes[.foregroundColor] as? NSColor
        let cursorBackground = cursorAttributes[.backgroundColor] as? NSColor
        XCTAssertNotNil(cursorForeground)
        XCTAssertNotNil(cursorBackground)
        XCTAssertNotEqual(cursorForeground?.cgColor.components?[0], cursorBackground?.cgColor.components?[0])
    }

    func testRendererPreservesStyledCellsAndTrimsBlankTailColumns() {
        let underlineFlag: UInt16 = 1 << 7
        let snapshot = GhosttyTerminalSnapshot(
            columns: 5, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            cells: [
                .init(codepoint: 88, foregroundRGB: 0xFF0000, backgroundRGB: 0x101010, flags: underlineFlag),
                .init(codepoint: 89, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 0, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
            ])

        let rendered = GhosttyTerminalSnapshotRenderer.render(snapshot)

        XCTAssertEqual(rendered.string, "XY")
        let attributes = rendered.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testRendererCanRemapDefaultCellBackgroundToViewerBackground() {
        let snapshot = GhosttyTerminalSnapshot(
            columns: 2, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            cells: [
                .init(codepoint: 65, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0),
                .init(codepoint: 66, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x202020, flags: 0),
            ])

        let viewerBackground = NSColor(calibratedRed: 0.2, green: 0.22, blue: 0.25, alpha: 1)
        let rendered = GhosttyTerminalSnapshotRenderer.render(snapshot, defaultBackgroundOverride: viewerBackground)

        let firstAttributes = rendered.attributes(at: 0, effectiveRange: nil)
        let secondAttributes = rendered.attributes(at: 1, effectiveRange: nil)
        XCTAssertEqual((firstAttributes[.backgroundColor] as? NSColor)?.usingColorSpace(.deviceRGB), viewerBackground.usingColorSpace(.deviceRGB))
        XCTAssertNotEqual((secondAttributes[.backgroundColor] as? NSColor)?.usingColorSpace(.deviceRGB), viewerBackground.usingColorSpace(.deviceRGB))
    }
}

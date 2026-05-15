import AppKit
import XCTest

@testable import spacesterminalcore
@testable import spacesterminalui

@MainActor final class TerminalRenderedScreenAttributedRendererTests: XCTestCase {
    func testRendererMapsANSIStylesToAttributedString() {
        var buffer = TerminalScreenBuffer()
        buffer.ingest("\u{001B}[31mred\u{001B}[0m \u{001B}[1;44mblue\u{001B}[0m")

        let rendered = TerminalRenderedScreenAttributedRenderer.render(
            buffer.renderedScreen(), defaultForeground: .textColor, defaultBackground: .textBackgroundColor)

        XCTAssertEqual(rendered.string, "red blue ")
        let redAttributes = rendered.attributes(at: 0, effectiveRange: nil)
        let blueAttributes = rendered.attributes(at: 4, effectiveRange: nil)
        let cursorAttributes = rendered.attributes(at: rendered.length - 1, effectiveRange: nil)

        XCTAssertNotNil(redAttributes[.foregroundColor] as? NSColor)
        XCTAssertNotNil(blueAttributes[.backgroundColor] as? NSColor)
        XCTAssertNotEqual(blueAttributes[.backgroundColor] as? NSColor, cursorAttributes[.backgroundColor] as? NSColor)
    }

    func testRendererShowsCursorByInvertingCellColors() {
        var buffer = TerminalScreenBuffer()
        buffer.ingest("hi")

        let rendered = TerminalRenderedScreenAttributedRenderer.render(
            buffer.renderedScreen(), defaultForeground: .textColor, defaultBackground: .textBackgroundColor)

        XCTAssertEqual(rendered.string, "hi ")
        let iAttributes = rendered.attributes(at: 1, effectiveRange: nil)
        let cursorAttributes = rendered.attributes(at: 2, effectiveRange: nil)
        XCTAssertNotEqual(iAttributes[.backgroundColor] as? NSColor, cursorAttributes[.backgroundColor] as? NSColor)
    }

    func testRendererMapsHyperlinkCellsToAttributedLinks() {
        var buffer = TerminalScreenBuffer()
        buffer.ingest("\u{001B}]8;;https://example.com\u{0007}link\u{001B}]8;;\u{0007}")

        let rendered = TerminalRenderedScreenAttributedRenderer.render(
            buffer.renderedScreen(), defaultForeground: .textColor, defaultBackground: .textBackgroundColor)

        XCTAssertEqual(rendered.string, "link ")
        XCTAssertEqual(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        XCTAssertNil(rendered.attribute(.link, at: rendered.length - 1, effectiveRange: nil))
    }

    func testRendererMapsUnderlineVariantsAndUnderlineColor() {
        var buffer = TerminalScreenBuffer()
        buffer.ingest("\u{001B}[21;58;2;10;20;30mwide\u{001B}[0m")

        let rendered = TerminalRenderedScreenAttributedRenderer.render(
            buffer.renderedScreen(), defaultForeground: .textColor, defaultBackground: .textBackgroundColor)

        XCTAssertEqual(rendered.string, "wide ")
        XCTAssertEqual(rendered.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.double.rawValue)
        XCTAssertNotNil(rendered.attribute(.underlineColor, at: 0, effectiveRange: nil) as? NSColor)
    }
}

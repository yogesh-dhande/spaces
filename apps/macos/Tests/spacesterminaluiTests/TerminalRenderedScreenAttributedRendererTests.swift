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

    func testRendererReportsUnderlineCursorWithoutInvertingCellColors() {
        var buffer = TerminalScreenBuffer()
        buffer.ingest("hi\u{001B}[3 q")

        let rendered = TerminalRenderedScreenAttributedRenderer.renderResult(
            buffer.renderedScreen(), defaultForeground: .textColor, defaultBackground: .textBackgroundColor)

        XCTAssertEqual(rendered.attributedText.string, "hi ")
        XCTAssertEqual(rendered.cursorStyle, .underline)
        XCTAssertEqual(rendered.cursorRange, NSRange(location: 2, length: 1))
        let iAttributes = rendered.attributedText.attributes(at: 1, effectiveRange: nil)
        let cursorAttributes = rendered.attributedText.attributes(at: 2, effectiveRange: nil)
        XCTAssertEqual(iAttributes[.backgroundColor] as? NSColor, cursorAttributes[.backgroundColor] as? NSColor)
    }

    func testRendererReportsBarCursorWithoutInvertingCellColors() {
        var buffer = TerminalScreenBuffer()
        buffer.ingest("hi\u{001B}[5 q")

        let rendered = TerminalRenderedScreenAttributedRenderer.renderResult(
            buffer.renderedScreen(), defaultForeground: .textColor, defaultBackground: .textBackgroundColor)

        XCTAssertEqual(rendered.cursorStyle, .bar)
        XCTAssertEqual(rendered.cursorRange, NSRange(location: 2, length: 1))
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

    func testRendererMapsModernStyleStackAndResets() throws {
        var buffer = TerminalScreenBuffer()
        buffer.ingest("\u{001B}[2mfaint\u{001B}[0m \u{001B}[3mitalic\u{001B}[0m \u{001B}[8mhidden\u{001B}[0m \u{001B}[9mstrike\u{001B}[0m plain")

        let rendered = TerminalRenderedScreenAttributedRenderer.render(
            buffer.renderedScreen(), defaultForeground: .textColor, defaultBackground: .textBackgroundColor)

        XCTAssertEqual(rendered.string, "faint italic hidden strike plain ")

        let faintColor = try XCTUnwrap(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertLessThan(faintColor.alphaComponent, 1)

        let italicFont = try XCTUnwrap(rendered.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.italic))

        let hiddenForeground = try XCTUnwrap(rendered.attribute(.foregroundColor, at: 13, effectiveRange: nil) as? NSColor)
        let hiddenBackground = try XCTUnwrap(rendered.attribute(.backgroundColor, at: 13, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(hiddenForeground, hiddenBackground)

        XCTAssertEqual(rendered.attribute(.strikethroughStyle, at: 20, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(rendered.attribute(.strikethroughStyle, at: 27, effectiveRange: nil))
        XCTAssertNil(rendered.attribute(.underlineStyle, at: 27, effectiveRange: nil))
    }
}

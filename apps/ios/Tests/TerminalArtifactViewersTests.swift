#if canImport(UIKit)
    import Foundation
    import WebKit
    import XCTest
    @testable import SpacesMobile

    /// View-support tests for the terminal artifact viewers: the Markdown HTML shell builder and its
    /// escaping, the text-display truncation helper, and lossy UTF-8 decoding. These exercise the pure
    /// helpers only — no UIKit rendering.
    final class TerminalArtifactViewersTests: XCTestCase {

        // MARK: - Markdown HTML shell builder

        func testMakeHTMLInlinesJavaScriptAndCSSAndScaffolding() {
            let doc = TerminalMarkdownDocument.makeHTML(
                markdownSource: "# Title",
                markdownItJS: "/*JS-MARKER*/",
                css: "/*CSS-MARKER*/"
            )
            // Inlined JS/CSS (the web view loads with baseURL: nil and can't fetch bundle files).
            XCTAssertTrue(doc.contains("/*JS-MARKER*/"), "markdown-it JS should be inlined")
            XCTAssertTrue(doc.contains("/*CSS-MARKER*/"), "CSS should be inlined")
            // Rendered-container scaffolding.
            XCTAssertTrue(doc.contains(#"id="content""#))
            XCTAssertTrue(doc.contains(#"class="markdown-body""#))
            XCTAssertTrue(doc.contains(".render(src)"))
            // Raw HTML in agent Markdown must stay inert.
            XCTAssertTrue(doc.contains("html: false"), "html:false flag must be present")
        }

        func testMakeHTMLEscapesSourceSoItCannotBreakOutOfScript() {
            // A source deliberately crafted to break out of the <script> context and inject markup.
            let hostile = "```code``` </script><script>alert('x')</script>\"q\"\nline2"
            let doc = TerminalMarkdownDocument.makeHTML(
                markdownSource: hostile,
                markdownItJS: "/*JS*/",
                css: "/*CSS*/"
            )

            // The injected live script must not appear as markup.
            XCTAssertFalse(doc.contains("<script>alert('x')"), "hostile source must not inject a live <script>")
            XCTAssertFalse(doc.contains("alert('x')</script>"), "source's </script> must be escaped")

            // The `<`-escaping we rely on is present, so a source `<` can never start a tag.
            XCTAssertTrue(doc.contains("\\u003c"), "the source's angle brackets should be \\u003c-escaped")

            // Exactly the two real closing script tags remain (the JS block and the render block); the
            // hostile source contributed no additional </script>.
            let closingTags = doc.components(separatedBy: "</script>").count - 1
            XCTAssertEqual(closingTags, 2, "only the two document script tags should close the context")

            // Quotes and newlines from the source are JSON-escaped inside the JS string literal.
            XCTAssertTrue(doc.contains("\\\"q\\\""), "double quotes should be escaped")
            XCTAssertTrue(doc.contains("line2"))
        }

        func testJavaScriptStringLiteralEscapesAngleBracketsAndControlCharacters() {
            let literal = TerminalMarkdownDocument.javaScriptStringLiteral(for: "a<b>&c\nd")
            XCTAssertTrue(literal.hasPrefix("\""))
            XCTAssertTrue(literal.hasSuffix("\""))
            XCTAssertTrue(literal.contains("\\u003c"))
            XCTAssertTrue(literal.contains("\\u003e"))
            XCTAssertTrue(literal.contains("\\u0026"))
            XCTAssertTrue(literal.contains("\\n"))
            XCTAssertFalse(literal.contains("<"))
            XCTAssertFalse(literal.contains(">"))
        }

        // MARK: - Artifact web isolation

        func testArtifactNetworkPolicyBlocksNetworkOnlyForArtifactLoads() {
            let networkURL = URL(string: "https://example.com/beacon")!
            let webSocketURL = URL(string: "wss://example.com/events")!
            let fileURL = URL(fileURLWithPath: "/tmp/artifact.html")
            let dataURL = URL(string: "data:text/plain,ok")!

            XCTAssertTrue(TerminalWebArtifactNetworkPolicy.shouldBlockNetworkLoad(for: .fileURL(fileURL), url: networkURL))
            XCTAssertTrue(TerminalWebArtifactNetworkPolicy.shouldBlockNetworkLoad(for: .htmlString("<html></html>"), url: webSocketURL))
            XCTAssertFalse(TerminalWebArtifactNetworkPolicy.shouldBlockNetworkLoad(for: .htmlString("<html></html>"), url: dataURL))
            XCTAssertFalse(TerminalWebArtifactNetworkPolicy.shouldBlockNetworkLoad(for: .request(networkURL), url: networkURL))
        }

        @MainActor
        func testArtifactNetworkPolicyContentRuleCompiles() async throws {
            _ = try await TerminalWebArtifactNetworkPolicy.makeNetworkBlockContentRuleList()
        }

        // MARK: - Text truncation

        func testTruncationPassesUnderLimitTextThrough() {
            let text = "a short log line"
            XCTAssertEqual(TerminalTextArtifact.truncatedForDisplay(text), text)
        }

        func testTruncationCapsOverLimitTextAndAppendsFooter() {
            let overLimit = String(repeating: "x", count: TerminalTextArtifact.displayCharacterLimit + 500)
            let result = TerminalTextArtifact.truncatedForDisplay(overLimit)
            XCTAssertTrue(result.hasSuffix(TerminalTextArtifact.truncationFooter))
            XCTAssertEqual(
                result.count,
                TerminalTextArtifact.displayCharacterLimit + TerminalTextArtifact.truncationFooter.count
            )
        }

        // MARK: - Lossy decode

        func testLossyDecodeProducesStringFromInvalidUTF8() {
            // 0xFF/0xFE are invalid UTF-8 lead bytes; 0x41 is 'A'. Decoding must not throw and must keep
            // the valid character.
            let data = Data([0xFF, 0xFE, 0x41, 0x42])
            let decoded = TerminalTextArtifact.lossyString(from: data)
            XCTAssertFalse(decoded.isEmpty)
            XCTAssertTrue(decoded.contains("AB"))
        }
    }
#endif

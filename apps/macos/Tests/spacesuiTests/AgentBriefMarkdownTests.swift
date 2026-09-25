import AppKit
import Testing
import spacesterminalcore

@testable import spacesui

/// The brief column renders the agent's markdown on the chrome type scale: headings, body, and code
/// each take their role's font, list items lead with a bullet (or the literal task box the agent wrote),
/// and blocks are separated by paragraph spacing rather than blank lines.
@MainActor @Suite struct AgentBriefMarkdownTests {
    private func render(_ markdown: String) -> NSAttributedString { AgentBriefMarkdown.attributedString(from: markdown) }

    private func font(of substring: String, in rendered: NSAttributedString) throws -> NSFont {
        let range = (rendered.string as NSString).range(of: substring)
        try #require(range.location != NSNotFound, "\(substring) must be rendered")
        return try #require(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    private func paragraphStyle(of substring: String, in rendered: NSAttributedString) throws -> NSParagraphStyle {
        let range = (rendered.string as NSString).range(of: substring)
        try #require(range.location != NSNotFound, "\(substring) must be rendered")
        return try #require(rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
    }

    private func expectSameFont(_ actual: NSFont, _ expected: NSFont, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.fontName == expected.fontName, sourceLocation: sourceLocation)
        #expect(actual.pointSize == expected.pointSize, sourceLocation: sourceLocation)
    }

    @Test func emptyMarkdownRendersNothing() { #expect(render("").length == 0) }

    @Test func headingsTakeTheCardAndSectionTitleRoles() throws {
        let rendered = render("# Status\n\n## Open questions\n\n### Detail")
        #expect(rendered.string == "Status\nOpen questions\nDetail")
        expectSameFont(try font(of: "Status", in: rendered), Typography.cardTitle)
        expectSameFont(try font(of: "Open questions", in: rendered), Typography.sectionTitle)
        expectSameFont(try font(of: "Detail", in: rendered), Typography.sectionTitle)
    }

    @Test func paragraphsAreSplitByOneNewlineAndSpacedByTheLayout() throws {
        let rendered = render("First paragraph.\n\nSecond paragraph.")
        #expect(rendered.string == "First paragraph.\nSecond paragraph.", "a blank line in the source is paragraph spacing, not an empty line")
        expectSameFont(try font(of: "First", in: rendered), Typography.body)
        #expect(try paragraphStyle(of: "First", in: rendered).paragraphSpacingBefore == 0)
        #expect(try paragraphStyle(of: "Second", in: rendered).paragraphSpacingBefore > 0)
    }

    @Test func softLineBreaksStayInTheirParagraph() { #expect(render("One line\nand the next").string == "One line and the next") }

    @Test func unorderedItemsLeadWithABulletAndHangTheirText() throws {
        let rendered = render("- first\n- second")
        #expect(rendered.string == "•\tfirst\n•\tsecond")
        let style = try paragraphStyle(of: "first", in: rendered)
        #expect(style.headIndent > style.firstLineHeadIndent, "wrapped lines hang under the item's text, not under the bullet")
    }

    @Test func orderedItemsLeadWithTheirOrdinal() { #expect(render("1. first\n2. second").string == "1.\tfirst\n2.\tsecond") }

    @Test func taskItemsKeepTheLiteralBoxInPlaceOfABullet() {
        #expect(render("- [ ] open task\n- [x] done task").string == "[ ] open task\n[x] done task")
    }

    @Test func nestedItemsIndentFurtherThanTheirParent() throws {
        let rendered = render("- parent\n  - child")
        let parent = try paragraphStyle(of: "parent", in: rendered)
        let child = try paragraphStyle(of: "child", in: rendered)
        #expect(child.firstLineHeadIndent > parent.firstLineHeadIndent)
    }

    @Test func codeSpansAndCodeBlocksTakeTheMonospacedBodyRole() throws {
        let rendered = render("Run `swift test` now.\n\n```\nlet x = 1\nlet y = 2\n```")
        #expect(rendered.string == "Run swift test now.\nlet x = 1\nlet y = 2", "a code block keeps its lines and drops its trailing newline")
        expectSameFont(try font(of: "swift test", in: rendered), Typography.monoBody)
        expectSameFont(try font(of: "Run", in: rendered), Typography.body)
        expectSameFont(try font(of: "let x", in: rendered), Typography.monoBody)
        #expect(try paragraphStyle(of: "let y", in: rendered).paragraphSpacingBefore == 0, "a code block's lines are not spaced apart")
    }

    @Test func strongTextTakesTheSemiboldRoleOfTheBodySize() throws {
        let rendered = render("**Status:** green")
        expectSameFont(try font(of: "Status:", in: rendered), Typography.sectionTitle)
        expectSameFont(try font(of: "green", in: rendered), Typography.body)
    }

    @Test func linksKeepTheirDestination() throws {
        let rendered = render("See [the PR](https://example.com/pr/1).")
        let range = (rendered.string as NSString).range(of: "the PR")
        #expect(rendered.attribute(.link, at: range.location, effectiveRange: nil) as? URL == URL(string: "https://example.com/pr/1"))
        let periodRange = (rendered.string as NSString).range(of: ".")
        #expect(rendered.attribute(.link, at: periodRange.location, effectiveRange: nil) == nil)
    }
}

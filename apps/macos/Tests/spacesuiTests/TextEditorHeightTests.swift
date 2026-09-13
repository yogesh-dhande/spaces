import AppKit
import Testing
import spacesterminalcore

@testable import spacesui

/// The height rule on its own: line bounds and font metrics in, a clamped pixel height out.
@Suite struct TextEditorHeightRuleTests {
    private let rule = TextEditorHeightRule(bounds: .growingFormEditor, lineHeight: 16, verticalInset: 6)

    @Test func shortTextRestsAtTheMinimum() {
        #expect(rule.minimumHeight == CGFloat(4 * 16 + 12))
        #expect(rule.height(forUsedTextHeight: 0) == rule.minimumHeight)
        #expect(rule.height(forUsedTextHeight: 2 * 16) == rule.minimumHeight)
    }

    @Test func textBetweenTheBoundsTracksItsOwnHeight() { #expect(rule.height(forUsedTextHeight: 8 * 16) == CGFloat(8 * 16 + 12)) }

    @Test func longTextStopsAtTheCap() {
        #expect(rule.maximumHeight == CGFloat(14 * 16 + 12))
        #expect(rule.height(forUsedTextHeight: 14 * 16) == rule.maximumHeight)
        #expect(rule.height(forUsedTextHeight: 400 * 16) == rule.maximumHeight)
    }

    @Test func equalBoundsPinTheHeight() {
        let pinned = TextEditorHeightRule(bounds: .fixed(6), lineHeight: 13, verticalInset: 6)
        #expect(!pinned.bounds.growsWithContent)
        #expect(pinned.minimumHeight == pinned.maximumHeight)
        #expect(pinned.height(forUsedTextHeight: 100 * 13) == CGFloat(6 * 13 + 12))
    }

    @Test func lineHeightComesFromTheEditorFont() {
        let fromFont = TextEditorHeightRule(bounds: .growingFormEditor, font: Typography.body, verticalInset: 6)
        #expect(fromFont.lineHeight == NSLayoutManager().defaultLineHeight(for: Typography.body))
    }
}

/// The automation form's prompt and script editors as they are actually built, laid out at a form's
/// width: the scroll view's height constraint follows the text from the four-line minimum to the
/// fourteen-line cap.
@MainActor @Suite final class AutoGrowingTextEditorTests {
    /// The editors resolve rows only inside a window, so the suite owns one. It is never ordered front.
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.titled], backing: .buffered, defer: false)

    /// Mirrors `AutomationEditorController.makeAgentPromptEditor`: a prose text view at the form's
    /// prompt width, wrapped by the shared helper.
    private func makePromptEditor(seed: String) -> (NSTextView, AutoGrowingTextScrollView) {
        let textView = NSTextView()
        textView.string = seed
        textView.isRichText = false
        textView.font = Typography.body
        let scroll = scrollableTextView(textView, lines: .growingFormEditor, inputBackgroundColor: .textBackgroundColor, borderColor: .separatorColor)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        return (textView, scroll)
    }

    private var rule: TextEditorHeightRule { TextEditorHeightRule(bounds: .growingFormEditor, font: Typography.body, verticalInset: 6) }

    @Test func twoLinePromptOpensAtTheMinimum() {
        let (_, scroll) = makePromptEditor(seed: "first line\nsecond line")
        #expect(scroll.heightConstraint.constant == rule.minimumHeight)
    }

    @Test func longSeededPromptOpensAtTheCap() {
        let seed = (1...40).map { "prompt line \($0)" }.joined(separator: "\n")
        let (_, scroll) = makePromptEditor(seed: seed)
        #expect(scroll.heightConstraint.constant == rule.maximumHeight)
    }

    @Test func typingMoreLinesGrowsTheEditorUntilItHitsTheCap() {
        let (textView, scroll) = makePromptEditor(seed: "first line")
        let atRest = scroll.heightConstraint.constant
        #expect(atRest == rule.minimumHeight)

        for index in 2...8 { textView.insertText("\nline \(index)", replacementRange: NSRange(location: textView.string.utf16.count, length: 0)) }
        let grown = scroll.heightConstraint.constant
        #expect(grown > atRest)
        #expect(grown < rule.maximumHeight)

        for index in 9...40 { textView.insertText("\nline \(index)", replacementRange: NSRange(location: textView.string.utf16.count, length: 0)) }
        #expect(scroll.heightConstraint.constant == rule.maximumHeight)
    }

    /// A single long paragraph wraps at the editor's width, and wrapped lines count toward the height
    /// exactly like typed ones.
    @Test func wrappedTextCountsTowardTheHeight() {
        let (_, scroll) = makePromptEditor(seed: String(repeating: "a wrapped prompt sentence ", count: 12))
        #expect(scroll.heightConstraint.constant > rule.minimumHeight)
    }

    /// A pinned editor keeps its line count whatever it holds, so the settings and log views that share
    /// the helper are unaffected by the automation form's growth.
    @Test func pinnedEditorKeepsItsHeight() {
        let textView = NSTextView()
        textView.font = Typography.monoMetadata
        textView.string = (1...80).map { "log line \($0)" }.joined(separator: "\n")
        let scroll = scrollableTextView(textView, lines: .fixed(6), inputBackgroundColor: .textBackgroundColor, borderColor: .separatorColor)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        let pinned = TextEditorHeightRule(bounds: .fixed(6), font: Typography.monoMetadata, verticalInset: 6)
        #expect(scroll.heightConstraint.constant == pinned.minimumHeight)
    }
}

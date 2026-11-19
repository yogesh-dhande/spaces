import Foundation
import Testing

@testable import spacesui

@Suite struct SessionQueryHighlightTests {
    private func marked(_ text: String, _ query: String) -> [String] { SessionQueryHighlight.ranges(in: text, query: query).map { String(text[$0]) } }

    @Test func wordsMatchByPrefixInAnyOrderIgnoringCase() {
        #expect(marked("The Handoff keeps a stale permission record", "perm hand") == ["Handoff", "permission"])
    }

    @Test func aWordIsNotMatchedInTheMiddle() { #expect(marked("nonpermission and permission", "perm") == ["permission"]) }

    @Test func accentsAndCaseAreIgnoredInBothDirections() {
        #expect(marked("Café résumé", "cafe resume") == ["Café", "résumé"])
        #expect(marked("cafe RESUME", "café résumé") == ["cafe", "RESUME"])
    }

    @Test func aDecomposedAccentStaysInsideItsWord() {
        let decomposed = "re\u{301}sume\u{301} now"
        #expect(marked(decomposed, "resume") == ["re\u{301}sume\u{301}"])
    }

    @Test func aQuotedPhraseIsOneUnitOfConsecutiveWords() {
        let text = "fix the permission prompt, then prompt for permission"
        #expect(marked(text, "\"permission prompt\"") == ["permission prompt"])
        #expect(marked(text, "\"prompt permission\"").isEmpty)
        #expect(marked(text, "permission prompt") == ["permission", "prompt", "prompt", "permission"])
    }

    @Test func aPhraseAndPlainWordsMixInOneQuery() {
        #expect(marked("hand off the keys, hand off", "\"hand off\" keys") == ["hand off", "keys", "hand off"])
    }

    @Test func punctuationSplitsWordsLikeTheIndex() { #expect(marked("see foo-bar and foo_bar", "bar") == ["bar", "bar"]) }

    @Test func overlappingMatchesMergeIntoOneRange() { #expect(marked("handoff handoffs", "hand handoff") == ["handoff", "handoffs"]) }

    @Test func aBlankQueryOrNoMatchMarksNothing() {
        #expect(marked("some text", "").isEmpty)
        #expect(marked("some text", "   \"\" ").isEmpty)
        #expect(marked("some text", "zebra").isEmpty)
    }

    @Test func theExcerptIsFlattenedToOneLine() {
        #expect(SessionQueryHighlight.displayExcerpt("first line\n  second line \r\n\nthird") == "first line second line third")
    }
}

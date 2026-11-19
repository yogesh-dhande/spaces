import Foundation
import Testing

@testable import spacessessionindex

@Suite struct SessionSearchQueryTests {
    private func expression(_ input: String) -> String? {
        if case .match(let expression, _) = SessionSearchQuery(input) { return expression }
        return nil
    }

    @Test func blankInputListsEverything() {
        #expect(SessionSearchQuery("") == .listAll)
        #expect(SessionSearchQuery("  \n\t ") == .listAll)
    }

    @Test func bareWordsArePrefixTermsAndQuotedTextIsAPhrase() {
        #expect(expression("hand off") == "\"hand\"* \"off\"*")
        #expect(expression("\"hand off\" retry") == "\"hand off\" \"retry\"*")
    }

    @Test func fullTextOperatorsAreReducedToPlainWords() {
        #expect(expression("title:foo") == "\"title\"* \"foo\"*")
        #expect(expression("foo AND bar") == "\"foo\"* \"AND\"* \"bar\"*")
        #expect(expression("NEAR(a b) ^c d*") == "\"NEAR\"* \"a\"* \"b\"* \"c\"* \"d\"*")
        #expect(expression("-foo (bar)") == "\"foo\"* \"bar\"*")
    }

    @Test func punctuationInsideABareWordSeparatesIndependentPrefixTerms() {
        #expect(expression("database-migration") == "\"database\"* \"migration\"*")
        #expect(expression("pre-commit") == "\"pre\"* \"commit\"*")
        #expect(expression("\"unit-test\"") == "\"unit test\"")
    }

    @Test func aHyphenatedQueryMatchesWordsThatAreNotAdjacent() throws {
        let home = try SessionIndexTestHome()
        try home.writeClaudeSession(
            "s1", texts: ["the database schema migration failed", "reply one"], startingAt: Date(timeIntervalSince1970: 1_768_000_000))
        try home.writeClaudeSession(
            "s2", texts: ["install the pre-commit hook", "reply two"], startingAt: Date(timeIntervalSince1970: 1_768_001_000))
        try home.writeClaudeSession(
            "s3", texts: ["add a unit and integration test", "reply three"], startingAt: Date(timeIntervalSince1970: 1_768_002_000))
        let index = try home.makeIndex()
        _ = try index.refresh()

        #expect(try index.search(query: "database-migration").results.map(\.sessionKey) == ["s1"])
        #expect(try index.search(query: "pre-commit").results.map(\.sessionKey) == ["s2"])
        #expect(try index.search(query: "\"unit test\"").results.isEmpty)
        #expect(try index.search(query: "unit test").results.map(\.sessionKey) == ["s3"])
    }

    @Test func anUnpairedQuoteLeavesBareWords() {
        #expect(expression("\"foo bar") == "\"foo\"* \"bar\"*")
        #expect(expression("a \"b c\" \"d") == "\"a\"* \"b c\" \"d\"*")
    }

    @Test func inputWithNoWordCharactersMatchesNothing() {
        #expect(SessionSearchQuery("***") == .matchesNothing)
        #expect(SessionSearchQuery("\"\"") == .matchesNothing)
    }

    @Test func theWordsOfTheQueryLocateTheExcerpt() {
        guard case .match(_, let tokens) = SessionSearchQuery("retry \"unit test\" foo-bar") else {
            Issue.record("expected a match query")
            return
        }
        #expect(tokens == ["retry", "unit", "test", "foo", "bar"])
    }
}

@Suite struct SessionExcerptTests {
    @Test func aShortMessageIsShownWhole() {
        #expect(SessionExcerpt.make(from: "Fix the\n  retry logic", matching: ["retry"]) == "Fix the retry logic")
    }

    @Test func aLongMessageIsCutAroundTheFirstMatchAtWordBoundaries() {
        let before = String(repeating: "alpha ", count: 40)
        let after = String(repeating: "omega ", count: 60)
        let excerpt = SessionExcerpt.make(from: before + "needle " + after, matching: ["NEEDLE"])
        #expect(excerpt.hasPrefix("…alpha "))
        #expect(excerpt.contains("needle omega"))
        #expect(excerpt.hasSuffix("omega…"))
        #expect(excerpt.count < 240)
    }

    @Test func aMatchMustStartAWordAndAMatchDeepInAHugeTurnIsStillShown() {
        // "ret" inside "secret" is not a word start; the later "retry" is.
        let prefix = "a secret " + String(repeating: "filler words ", count: 20_000)
        let excerpt = SessionExcerpt.make(from: prefix + "then retry later " + String(repeating: "tail ", count: 5_000), matching: ["ret"])
        #expect(excerpt.contains("then retry later"))
        #expect(excerpt.hasPrefix("…") && excerpt.hasSuffix("…"))
        #expect(excerpt.count < 240)
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        let excerpt = SessionExcerpt.make(from: String(repeating: "x ", count: 100) + "Café menu", matching: ["cafe"])
        #expect(excerpt.contains("Café menu"))
    }
}

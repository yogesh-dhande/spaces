import Testing

@testable import spacesui

@Suite struct CommandPaletteFuzzySearchTests {
    @Test func contiguousMatchesRankAheadOfSparseMatches() {
        let results = CommandPaletteFuzzySearch.rank(
            query: "gst",
            candidates: [.init(id: "ghostty", fields: [.init(text: "Ghostty")]), .init(id: "greatest", fields: [.init(text: "Greatest")])])

        #expect(results.map(\.id) == ["ghostty", "greatest"])
        #expect(results.first!.score > results.last!.score)
    }

    @Test func wordStartsRankAheadOfInteriorMatches() {
        let results = CommandPaletteFuzzySearch.rank(
            query: "doc", candidates: [.init(id: "docs", fields: [.init(text: "Docs")]), .init(id: "adoc", fields: [.init(text: "adoc")])])

        #expect(results.map(\.id) == ["docs", "adoc"])
    }

    @Test func phraseCanMatchAcrossWorkspaceAndNameFields() throws {
        let match = try #require(
            CommandPaletteFuzzySearch.match(
                query: "atlas docs",
                fields: [
                    .init(text: "Atlas Workspace", weight: 0.9), .init(text: "Docs", weight: 1.0),
                    .init(text: "http://localhost:3000/docs", weight: 0.7),
                ]))

        #expect(match.tokenMatches.count == 2)
        #expect(match.tokenMatches.map(\.fieldIndex) == [0, 1])
    }

    @Test func compactTokenCanMatchAcrossNameAndDetailViaCombinedField() {
        let results = CommandPaletteFuzzySearch.rank(
            query: "fu",
            candidates: [
                .init(
                    id: "frontend-url",
                    fields: [
                        .init(text: "Payments", weight: 0.92), .init(text: "Frontend", weight: 1.0), .init(text: "URL", weight: 0.78),
                        .init(text: "Payments Frontend URL", weight: 0.88),
                    ]),
                .init(
                    id: "unrelated",
                    fields: [
                        .init(text: "Payments", weight: 0.92), .init(text: "Backend", weight: 1.0), .init(text: "URL", weight: 0.78),
                        .init(text: "Payments Backend URL", weight: 0.88),
                    ]),
            ])

        #expect(results.map(\.id) == ["frontend-url"])
    }

    @Test func nameWeightBeatsDetailWeightWhenBothMatch() {
        let results = CommandPaletteFuzzySearch.rank(
            query: "claude",
            candidates: [
                .init(
                    id: "name-match",
                    fields: [.init(text: "Payments"), .init(text: "Claude Code", weight: 1.0), .init(text: "agent detail", weight: 0.7)]),
                .init(
                    id: "detail-match",
                    fields: [.init(text: "Payments"), .init(text: "Agent", weight: 1.0), .init(text: "Claude Code terminal", weight: 0.7)]),
            ])

        #expect(results.map(\.id) == ["name-match", "detail-match"])
    }

    @Test func matchingIsCaseAndDiacriticInsensitive() throws {
        let match = try #require(CommandPaletteFuzzySearch.match(query: "resume", fields: [.init(text: "Resume"), .init(text: "Résumé")]))
        #expect(match.score > 0.5)
    }

    @Test func resultsPreserveInputOrderWhenScoresTie() {
        let results = CommandPaletteFuzzySearch.rank(
            query: "abc", candidates: [.init(id: "first", fields: [.init(text: "abc")]), .init(id: "second", fields: [.init(text: "abc")])])

        #expect(results.map(\.id) == ["first", "second"])
    }

    @Test func missingTokenRejectsCandidate() {
        let results = CommandPaletteFuzzySearch.rank(
            query: "atlas docs", candidates: [.init(id: "workspace-only", fields: [.init(text: "Atlas Workspace"), .init(text: "Frontend")])])

        #expect(results.isEmpty)
    }
}

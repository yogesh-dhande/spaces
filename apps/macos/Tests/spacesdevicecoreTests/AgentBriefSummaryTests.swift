import Testing

@testable import spacesdevicecore

/// The headline a brief shows wherever only one line fits: `agent list`, the agent-session rows, and the
/// blocked/done notification block.
@Suite struct AgentBriefSummaryTests {
    @Test func headingMarkerIsStripped() {
        #expect(AgentBriefSummary.summary(of: "## Fixing the flaky test\n\nStep 2 of 3") == "Fixing the flaky test")
        #expect(AgentBriefSummary.summary(of: "#\tTabbed heading") == "Tabbed heading")
    }

    @Test func listQuoteAndNumberedMarkersAreStripped() {
        #expect(AgentBriefSummary.summary(of: "- Running the suite") == "Running the suite")
        #expect(AgentBriefSummary.summary(of: "* Running the suite") == "Running the suite")
        #expect(AgentBriefSummary.summary(of: "> Waiting on review") == "Waiting on review")
        #expect(AgentBriefSummary.summary(of: ">Waiting on review") == "Waiting on review")
        #expect(AgentBriefSummary.summary(of: "12. Porting the parser") == "Porting the parser")
        #expect(AgentBriefSummary.summary(of: "> - nested marker") == "nested marker")
    }

    /// A marker character that markdown would not read as a marker (no space after it) is text.
    @Test func markerCharactersThatAreTextAreKept() {
        #expect(AgentBriefSummary.summary(of: "**Status:** green") == "**Status:** green")
        #expect(AgentBriefSummary.summary(of: "-3 flaky tests left") == "-3 flaky tests left")
        #expect(AgentBriefSummary.summary(of: "#hashtag") == "#hashtag")
        #expect(AgentBriefSummary.summary(of: "2.5x faster") == "2.5x faster")
    }

    @Test func blankAndMarkerOnlyLeadingLinesAreSkipped() {
        #expect(AgentBriefSummary.summary(of: "\n  \n\t\n  Status: green  \nmore") == "Status: green")
        #expect(AgentBriefSummary.summary(of: "#\n-\n## Real headline") == "Real headline")
    }

    @Test func surroundingWhitespaceIsTrimmedAndTabsBecomeSpaces() {
        #expect(AgentBriefSummary.summary(of: "   Status:\tgreen   ") == "Status: green")
    }

    @Test func aLineLongerThanTheCapIsCutWithAnEllipsis() throws {
        let long = String(repeating: "a", count: 200)
        let summary = try #require(AgentBriefSummary.summary(of: "# " + long))
        #expect(summary.count == AgentBriefSummary.maxLength)
        #expect(summary == String(repeating: "a", count: 119) + "…")
        #expect(AgentBriefSummary.maxLength == 120)
    }

    @Test func aLineAtTheCapIsKeptWhole() {
        let exact = String(repeating: "b", count: 120)
        #expect(AgentBriefSummary.summary(of: exact) == exact)
    }

    /// Whitespace the cut leaves at the end is dropped before the ellipsis, so it never reads "word …".
    @Test func theCutDropsTrailingWhitespaceBeforeTheEllipsis() {
        let line = String(repeating: "c", count: 118) + "   tail"
        #expect(AgentBriefSummary.summary(of: line) == String(repeating: "c", count: 118) + "…")
    }

    @Test func noBriefOrNoTextHasNoHeadline() {
        #expect(AgentBriefSummary.summary(of: nil) == nil)
        #expect(AgentBriefSummary.summary(of: "") == nil)
        #expect(AgentBriefSummary.summary(of: " \n\t\n ") == nil)
        #expect(AgentBriefSummary.summary(of: "#\n- \n>") == nil)
    }
}

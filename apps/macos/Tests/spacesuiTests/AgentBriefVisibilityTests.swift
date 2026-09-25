import AppKit
import Testing

@testable import spacesui

/// A coding agent's brief column is shown whenever the agent has a brief, until the user hides it; the
/// choice is remembered per agent, and an agent without a brief has nothing to toggle.
@MainActor @Suite struct AgentBriefVisibilityTests {
    @Test func anAgentTheUserHasNotTouchedShowsItsBrief() { #expect(AgentBriefVisibility().state(agentKey: "agent-1", brief: "# Status") == .shown) }

    @Test func anAgentWithNoBriefHasNothingToToggle() {
        var visibility = AgentBriefVisibility()
        #expect(visibility.state(agentKey: "agent-1", brief: nil) == .unavailable)
        visibility.toggle(agentKey: "agent-1", brief: nil)
        #expect(visibility.state(agentKey: "agent-1", brief: "# Status") == .shown, "toggling while there was no brief records no choice")
    }

    @Test func togglingHidesTheBriefAndTogglingAgainShowsIt() {
        var visibility = AgentBriefVisibility()
        visibility.toggle(agentKey: "agent-1", brief: "# Status")
        #expect(visibility.state(agentKey: "agent-1", brief: "# Status") == .hidden)
        visibility.toggle(agentKey: "agent-1", brief: "# Status")
        #expect(visibility.state(agentKey: "agent-1", brief: "# Status") == .shown)
    }

    @Test func aHiddenBriefStaysHiddenAcrossRewritesAndGoingAway() {
        var visibility = AgentBriefVisibility()
        visibility.toggle(agentKey: "agent-1", brief: "# Status")
        #expect(visibility.state(agentKey: "agent-1", brief: "# Rewritten") == .hidden, "the choice is the agent's, not one document's")
        #expect(visibility.state(agentKey: "agent-1", brief: nil) == .unavailable, "no brief means no column, whatever the choice")
        #expect(visibility.state(agentKey: "agent-1", brief: "# Back") == .hidden)
    }

    @Test func eachAgentKeepsItsOwnChoice() {
        var visibility = AgentBriefVisibility()
        visibility.toggle(agentKey: "agent-1", brief: "# One")
        #expect(visibility.state(agentKey: "agent-1", brief: "# One") == .hidden)
        #expect(visibility.state(agentKey: "agent-2", brief: "# Two") == .shown)
    }

    @Test func toggleSurfacesOfferTheOppositeOfTheCurrentState() {
        #expect(AgentBriefToggleState.shown.toggleTitle == "Hide Brief")
        #expect(AgentBriefToggleState.hidden.toggleTitle == "Show Brief")
    }

    @Test func theToggleGlyphIsAccentWhileShownMutedWhileHiddenAndAbsentWithoutABrief() {
        let button = NSButton()
        button.applyAgentBriefToggleState(.shown)
        #expect(!button.isHidden)
        #expect(button.contentTintColor == Theme.accent)
        #expect(button.toolTip == "Hide Brief")

        button.applyAgentBriefToggleState(.hidden)
        #expect(!button.isHidden)
        #expect(button.contentTintColor == Theme.muted)
        #expect(button.toolTip == "Show Brief")

        button.applyAgentBriefToggleState(.unavailable)
        #expect(button.isHidden)
    }
}

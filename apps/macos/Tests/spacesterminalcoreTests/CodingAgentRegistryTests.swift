import Foundation
import Testing

@testable import spacesterminalcore

/// `CodingAgent` is the single registry of coding agents Spaces integrates; every facet (identity,
/// detection, spawn-gate matching, hooks, MCP) is an exhaustive `switch self` over
/// its cases. These tests are driven by `CodingAgent.allCases` rather than naming agents individually,
/// so a half-added agent — one filled in for some facets but missed in another switch or table — fails
/// here instead of surfacing later as a silent detection or spawn-gate gap.
@Suite struct CodingAgentRegistryTests {
    /// `spaces agent spawn` resolves which agent a command launches through
    /// `AgentSpawnCommandGate`/`CodingAgent.matching(command:)`, then waits for that agent to show up as
    /// the terminal's foreground process. If an agent's primary command resolves through the gate but
    /// `TerminalForegroundProcessInspector` classifies that same executable as a different (or no)
    /// agent, spawn readiness would gate on a kind that can never arrive.
    @Test func gateAndForegroundDetectionAgreeOnPrimaryCommandForEveryAgent() {
        for agent in CodingAgent.allCases {
            #expect(CodingAgent.matching(command: agent.primaryCommandName) == agent, "gate: \(agent)")

            let process = TerminalForegroundProcessSnapshot(
                pid: 100, executablePath: "/usr/local/bin/\(agent.primaryCommandName)", argv: ["/usr/local/bin/\(agent.primaryCommandName)"])
            let detected = TerminalForegroundProcessInspector.classify(process)
            #expect(detected?.detectedAgentKind.agent == agent, "detection: \(agent)")
        }
    }

    /// `TerminalForegroundProcessInspector`'s definition table is `CodingAgent.allCases.flatMap(\.detectionVariants)`,
    /// and `TerminalDetectedAgentKind.agent` reverse-maps every kind back to its owning agent. A kind
    /// missing from every agent's `detectionVariants`, or one that two agents both claim, breaks that
    /// round trip.
    @Test func everyDetectedAgentKindBelongsToExactlyOneAgentsDetectionVariants() {
        let allVariants = CodingAgent.allCases.flatMap(\.detectionVariants)
        for kind in TerminalDetectedAgentKind.allCases {
            let owners = allVariants.filter { $0.kind == kind }
            #expect(owners.count == 1, "kind \(kind) is claimed by \(owners.count) detection variants, expected exactly 1")
        }
    }

    /// `TerminalForegroundProcessInspector.classify` walks the definitions table and returns the first
    /// match, but its own doc comment claims ordering across agents "does not matter" because matching
    /// is disjoint-set membership. That claim only holds if no two variants share an executable or
    /// node-script name; this test is what makes table order actually irrelevant rather than merely
    /// assumed.
    @Test func detectionVariantExecutableAndNodeScriptNamesArePairwiseDisjoint() {
        let allVariants = CodingAgent.allCases.flatMap(\.detectionVariants)
        for i in allVariants.indices {
            for j in allVariants.indices where j > i {
                #expect(
                    allVariants[i].executableNames.isDisjoint(with: allVariants[j].executableNames),
                    "executableNames overlap between \(allVariants[i].kind) and \(allVariants[j].kind)")
                #expect(
                    allVariants[i].nodeScriptNames.isDisjoint(with: allVariants[j].nodeScriptNames),
                    "nodeScriptNames overlap between \(allVariants[i].kind) and \(allVariants[j].kind)")
            }
        }
    }

    /// Tile text, display name, and primary command are each rendered as the sole identifier for an
    /// agent in some UI surface (settings row tile, launcher tile fallback initials, spawn/help text).
    /// A collision would make two agents indistinguishable there even though they are distinct registry
    /// entries.
    @Test func agentsHaveDistinctIdentityAndNonemptyExecutableNames() {
        let agents = CodingAgent.allCases
        #expect(Set(agents.map(\.tileText)).count == agents.count)
        #expect(Set(agents.map(\.displayName)).count == agents.count)
        #expect(Set(agents.map(\.primaryCommandName)).count == agents.count)
        for agent in agents { #expect(!agent.executableNames.isEmpty, "agent: \(agent)") }
    }

    /// `AgentSpawnCommandGate.GateError.unsupportedCommand`'s message is the only feedback a caller of
    /// `spaces agent spawn` gets for a rejected command, and it is meant to enumerate every command the
    /// gate will accept (`CodingAgent.commandListText`, derived from `allCases`). A command name that
    /// resolves through the gate but is missing from the error text would be undiscoverable from the
    /// error alone.
    @Test func unsupportedCommandErrorListsEveryAgentsPrimaryCommand() {
        let description = AgentSpawnCommandGate.GateError.unsupportedCommand.errorDescription ?? ""
        for agent in CodingAgent.allCases { #expect(description.contains(agent.primaryCommandName), "agent: \(agent)") }
    }
}

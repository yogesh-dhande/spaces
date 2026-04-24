import Testing
import streamctl

@testable import gui

@Suite struct AppKitControllerProcessEditDecisionTests {
    @Test func runningWorkspaceAppliesNameAndOnExitChangesImmediately() {
        let decision = AppKitController.runningWorkspaceProcessEditDecision(
            previous: [ProcessTemplate(name: "web", command: "npm run web", onExit: .none)],
            updated: [ProcessTemplate(name: "frontend", command: "npm run web", onExit: .restart)])

        #expect(decision == .applyImmediately)
    }

    @Test func runningWorkspacePromptsBeforeRestartingChangedCommands() {
        let decision = AppKitController.runningWorkspaceProcessEditDecision(
            previous: [ProcessTemplate(name: "web", command: "npm run web", onExit: .none)],
            updated: [ProcessTemplate(name: "frontend", command: "npm run web:v2", onExit: .restart)])

        #expect(decision == .confirmRestart(processNames: ["frontend"]))
    }

    @Test func addedProcessesDoNotForceRestartConfirmationByThemselves() {
        let decision = AppKitController.runningWorkspaceProcessEditDecision(
            previous: [ProcessTemplate(name: "web", command: "npm run web", onExit: .none)],
            updated: [
                ProcessTemplate(name: "web", command: "npm run web", onExit: .none),
                ProcessTemplate(name: "worker", command: "npm run worker", onExit: .none),
            ])

        #expect(decision == .applyImmediately)
    }
}

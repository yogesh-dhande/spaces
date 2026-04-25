import Testing
import streamctl

@testable import gui

@Suite struct AppKitControllerProcessEditDecisionTests {
    @Test func runningWorkspaceAppliesNameAndOnExitChangesImmediately() {
        let process = ProcessTemplate(name: "web", command: "npm run web", onExit: .none)
        let decision = AppKitController.runningWorkspaceProcessEditDecision(
            previous: [process], updated: [ProcessTemplate(id: process.id, name: "frontend", command: "npm run web", onExit: .restart)])

        #expect(decision == .applyImmediately)
    }

    @Test func runningWorkspacePromptsBeforeRestartingChangedCommands() {
        let process = ProcessTemplate(name: "web", command: "npm run web", onExit: .none)
        let decision = AppKitController.runningWorkspaceProcessEditDecision(
            previous: [process], updated: [ProcessTemplate(id: process.id, name: "frontend", command: "npm run web:v2", onExit: .restart)])

        #expect(decision == .confirmRestart(processNames: ["frontend"]))
    }

    @Test func addedProcessesDoNotForceRestartConfirmationByThemselves() {
        let process = ProcessTemplate(name: "web", command: "npm run web", onExit: .none)
        let decision = AppKitController.runningWorkspaceProcessEditDecision(
            previous: [process], updated: [process, ProcessTemplate(name: "worker", command: "npm run worker", onExit: .none)])

        #expect(decision == .applyImmediately)
    }
}

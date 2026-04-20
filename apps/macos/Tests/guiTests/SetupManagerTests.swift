import Testing
import appctl

@testable import gui

@MainActor @Suite struct SetupManagerTests {
    @Test func startupSkipsDeferredYabaiFailure() {
        let manager = SetupManager(checker: MockSetupChecker(
            startupBlockingResults: [
                .init(id: .terminalInstalled, passed: true),
                .init(id: .tmuxInstalled, passed: true),
                .init(id: .yabaiInstalled, passed: true),
            ],
            allResults: [
                .init(id: .terminalInstalled, passed: true),
                .init(id: .tmuxInstalled, passed: true),
                .init(id: .yabaiInstalled, passed: true),
                .init(id: .yabaiServiceRunning, passed: false),
                .init(id: .yabaiAccessibility, passed: false),
            ]))
        var completed = false

        _ = manager.makeContentView()
        manager.onComplete = { completed = true }
        manager.start()

        #expect(completed)
        #expect(!manager.isShowingSetupFlow)
        #expect(manager.currentStepTitleForTesting == nil)
    }

    @Test func deferredStartShowsYabaiStep() {
        let manager = SetupManager(checker: MockSetupChecker(
            startupBlockingResults: [
                .init(id: .terminalInstalled, passed: true),
                .init(id: .tmuxInstalled, passed: true),
                .init(id: .yabaiInstalled, passed: true),
            ],
            allResults: [
                .init(id: .terminalInstalled, passed: true),
                .init(id: .tmuxInstalled, passed: true),
                .init(id: .yabaiInstalled, passed: true),
                .init(id: .yabaiServiceRunning, passed: false),
                .init(id: .yabaiAccessibility, passed: false),
            ]))
        var completed = false

        _ = manager.makeContentView()
        manager.onComplete = { completed = true }
        manager.start(preferredInitialCheckID: .yabaiServiceRunning)

        #expect(!completed)
        #expect(manager.isShowingSetupFlow)
        #expect(manager.currentStepTitleForTesting == "Set up yabai")
    }
}

private struct MockSetupChecker: SetupChecking {
    let startupBlockingResults: [SetupCheckResult]
    let allResults: [SetupCheckResult]

    func run(_ id: SetupCheckID) -> Bool {
        allResults.first(where: { $0.id == id })?.passed ?? false
    }

    func runAll() -> [SetupCheckResult] {
        allResults
    }

    func runStartupBlockingChecks() -> [SetupCheckResult] {
        startupBlockingResults
    }
}

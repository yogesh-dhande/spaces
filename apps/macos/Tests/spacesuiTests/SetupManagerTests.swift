import AppKit
import Testing
import systembridge

@testable import spacesui

@MainActor @Suite struct SetupManagerTests {
    @Test func startupSkipsDeferredYabaiFailure() {
        let manager = SetupManager(
            checker: MockSetupChecker(
                startupBlockingResults: [.init(id: .tmuxInstalled, passed: true), .init(id: .yabaiInstalled, passed: true)],
                allResults: [
                    .init(id: .terminalInstalled, passed: false), .init(id: .tmuxInstalled, passed: true), .init(id: .yabaiInstalled, passed: true),
                    .init(id: .yabaiServiceRunning, passed: false), .init(id: .yabaiAccessibility, passed: false),
                ]))
        var completed = false

        manager.onComplete = { completed = true }
        let view = manager.begin()

        #expect(view == nil)
        #expect(completed)
        #expect(!manager.isShowingSetupFlow)
        #expect(manager.currentStepTitleForTesting == nil)
    }

    @Test func deferredStartShowsYabaiStep() {
        let manager = SetupManager(
            checker: MockSetupChecker(
                startupBlockingResults: [.init(id: .tmuxInstalled, passed: true), .init(id: .yabaiInstalled, passed: true)],
                allResults: [
                    .init(id: .terminalInstalled, passed: false), .init(id: .tmuxInstalled, passed: true), .init(id: .yabaiInstalled, passed: true),
                    .init(id: .yabaiServiceRunning, passed: false), .init(id: .yabaiAccessibility, passed: false),
                ]))
        var completed = false

        manager.onComplete = { completed = true }
        let view = manager.begin(preferredInitialCheckID: .yabaiServiceRunning)

        #expect(view != nil)
        #expect(!completed)
        #expect(manager.isShowingSetupFlow)
        #expect(manager.currentStepTitleForTesting == "Set up yabai")
    }

    @Test func startupBlockingFailureShowsSetupScreenWithCheckingStatus() {
        let manager = SetupManager(
            checker: MockSetupChecker(
                startupBlockingResults: [.init(id: .tmuxInstalled, passed: false), .init(id: .yabaiInstalled, passed: true)],
                allResults: [
                    .init(id: .terminalInstalled, passed: false), .init(id: .tmuxInstalled, passed: false), .init(id: .yabaiInstalled, passed: true),
                    .init(id: .yabaiServiceRunning, passed: true), .init(id: .yabaiAccessibility, passed: true),
                ]))

        let view = manager.begin()

        #expect(view != nil)
        #expect(manager.isShowingSetupFlow)
        #expect(manager.currentStepTitleForTesting == "Install tmux")
        #expect(viewTextContent(view).contains("Install tmux"))
        #expect(viewTextContent(view).contains("Checking..."))
    }
}

private struct MockSetupChecker: SetupChecking {
    let startupBlockingResults: [SetupCheckResult]
    let allResults: [SetupCheckResult]

    func run(_ id: SetupCheckID) -> Bool { allResults.first(where: { $0.id == id })?.passed ?? false }

    func runAll() -> [SetupCheckResult] { allResults }

    func runStartupBlockingChecks() -> [SetupCheckResult] { startupBlockingResults }
}

@MainActor private func viewTextContent(_ view: NSView?) -> [String] {
    guard let view else { return [] }
    var text: [String] = []
    if let label = view as? NSTextField {
        let value = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { text.append(value) }
    }
    for subview in view.subviews { text.append(contentsOf: viewTextContent(subview)) }
    return text
}

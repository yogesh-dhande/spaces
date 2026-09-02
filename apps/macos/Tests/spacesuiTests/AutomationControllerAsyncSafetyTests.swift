import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

@Suite struct AutomationControllerAsyncSafetyTests {
    // A freshly opened editor (no seed automation) starts its concurrency pop-up on the "new automation"
    // default, Skip, rather than Allow; an automation being edited keeps its own stored policy untouched.
    @MainActor @Test func seededConcurrencyPolicyDefaultsNewAutomationsToSkip() {
        #expect(AutomationEditorController.seededConcurrencyPolicy(nil) == .skip)

        let existing = TerminalServiceAutomationSummary(
            id: "auto-1", name: "Nightly", enabled: true, triggerKind: "manual", cronExpression: nil, script: "echo hi", workspaceID: "workspace-1",
            timeoutSeconds: nil, concurrencyPolicy: "allow", missedRunPolicy: "run_once", nextFireTime: nil, createdAt: "", updatedAt: "")
        #expect(AutomationEditorController.seededConcurrencyPolicy(existing) == .allow)
    }

    @MainActor @Test func mutationQueuePreservesEnqueueOrderAndLastSelection() async {
        let queue = AutomationMutationQueue()
        let state = MutationState()
        let first = queue.enqueue(key: "device::automation") {
            try? await Task.sleep(for: .milliseconds(50))
            await state.append(false)
        }
        let second = queue.enqueue(key: "device::automation") { await state.append(true) }
        await first.value
        await second.value
        let values = await state.values()
        #expect(values == [false, true])
        #expect(values.last == true)
    }

    @MainActor @Test func staleSaveCompletionCannotMutateReusedEditor() {
        #expect(!AutomationEditorController.shouldApplySaveCompletion(currentGeneration: 2, expectedGeneration: 1, currentWindowMatches: true))
        #expect(!AutomationEditorController.shouldApplySaveCompletion(currentGeneration: 1, expectedGeneration: 1, currentWindowMatches: false))
        #expect(AutomationEditorController.shouldApplySaveCompletion(currentGeneration: 2, expectedGeneration: 2, currentWindowMatches: true))
    }
}

private actor MutationState {
    private var recorded: [Bool] = []
    func append(_ value: Bool) { recorded.append(value) }
    func values() -> [Bool] { recorded }
}

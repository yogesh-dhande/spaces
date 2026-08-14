import Testing

@testable import spacesui

@Suite struct AutomationControllerAsyncSafetyTests {
    @MainActor @Test func mutationQueuePreservesEnqueueOrderAndLastSelection() async {
        let queue = AutomationMutationQueue()
        let state = MutationState()
        let first = queue.enqueue(key: "device::automation") {
            try? await Task.sleep(for: .milliseconds(50))
            await state.append(false)
        }
        let second = queue.enqueue(key: "device::automation") {
            await state.append(true)
        }
        await first.value
        await second.value
        let values = await state.values()
        #expect(values == [false, true])
        #expect(values.last == true)
    }

    @MainActor @Test func staleSaveCompletionCannotMutateReusedEditor() {
        #expect(
            !AutomationEditorController.shouldApplySaveCompletion(
                currentGeneration: 2, expectedGeneration: 1, currentWindowMatches: true))
        #expect(
            !AutomationEditorController.shouldApplySaveCompletion(
                currentGeneration: 1, expectedGeneration: 1, currentWindowMatches: false))
        #expect(
            AutomationEditorController.shouldApplySaveCompletion(
                currentGeneration: 2, expectedGeneration: 2, currentWindowMatches: true))
    }
}

private actor MutationState {
    private var recorded: [Bool] = []
    func append(_ value: Bool) { recorded.append(value) }
    func values() -> [Bool] { recorded }
}

import Testing

@testable import spacesui

@Suite struct AppKitControllerLifecycleTests {
    private final class ProcessLifecyclePolicySpy: ProcessLifecyclePolicyController {
        var automaticTerminationReasons: [String] = []
        var disableSuddenTerminationCallCount = 0

        func disableAutomaticTermination(_ reason: String) { automaticTerminationReasons.append(reason) }
        func disableSuddenTermination() { disableSuddenTerminationCallCount += 1 }
    }

    @Test func persistentTerminationPolicyProtectsTheAppProcess() {
        let spy = ProcessLifecyclePolicySpy()

        AppKitController.applyPersistentTerminationPolicy(processInfo: spy)

        #expect(spy.automaticTerminationReasons == [AppKitController.persistentTerminationPolicyReason()])
        #expect(spy.disableSuddenTerminationCallCount == 1)
    }
}

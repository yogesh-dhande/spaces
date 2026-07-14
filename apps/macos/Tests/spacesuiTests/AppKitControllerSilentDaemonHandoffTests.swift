import Testing

@testable import spacesui

/// Table-driven coverage of the pure fire/skip decision behind `maybeRequestSilentDaemonHandoff`: a
/// status refresh should trigger the silent daemon exec-in-place handoff exactly when an update is
/// staged, the daemon speaks a wire protocol this app can talk to, and this device/target-version pair
/// has not already been requested this app run.
@Suite struct AppKitControllerSilentDaemonHandoffTests {
    private struct Case: Sendable {
        let name: String
        let updatePending: Bool
        let compatibilityIsCompatible: Bool
        let alreadyRequestedKey: Bool
        let expectedFire: Bool
    }

    private static let cases: [Case] = [
        Case(
            name: "pending, compatible, first request for this key fires", updatePending: true, compatibilityIsCompatible: true,
            alreadyRequestedKey: false, expectedFire: true),
        Case(
            name: "pending, compatible, but already requested this run skips", updatePending: true, compatibilityIsCompatible: true,
            alreadyRequestedKey: true, expectedFire: false),
        Case(
            name: "pending, but wire-incompatible daemon skips (handled by the compatibility block)", updatePending: true,
            compatibilityIsCompatible: false, alreadyRequestedKey: false, expectedFire: false),
        Case(
            name: "no update pending skips even when compatible and unrequested", updatePending: false, compatibilityIsCompatible: true,
            alreadyRequestedKey: false, expectedFire: false),
        Case(
            name: "nothing pending, incompatible, already requested still skips", updatePending: false, compatibilityIsCompatible: false,
            alreadyRequestedKey: true, expectedFire: false),
    ]

    @Test(arguments: cases) private func decidesFireOrSkip(testCase: Case) {
        let fire = AppKitController.shouldFireSilentDaemonHandoff(
            updatePending: testCase.updatePending, compatibilityIsCompatible: testCase.compatibilityIsCompatible,
            alreadyRequestedKey: testCase.alreadyRequestedKey)
        #expect(fire == testCase.expectedFire, "\(testCase.name)")
    }
}

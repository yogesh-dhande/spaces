import AppKit
import Testing

@testable import gui

@Suite struct AppKitControllerWindowSummonTests {
    @Test func activeSpaceSummonAddsMoveToActiveSpaceBehavior() {
        let behavior = NSWindow.CollectionBehavior.fullScreenAuxiliary

        let updated = AppKitController.collectionBehaviorForActiveSpaceSummon(behavior)

        #expect(updated.contains(.moveToActiveSpace))
        #expect(updated.contains(.fullScreenAuxiliary))
    }

    @Test func activeSpaceSummonCleanupRemovesOnlyTransientBehavior() {
        let original: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .managed]
        let summoned = AppKitController.collectionBehaviorForActiveSpaceSummon(original)

        let cleaned = AppKitController.collectionBehaviorAfterActiveSpaceSummon(summoned)

        #expect(!cleaned.contains(.moveToActiveSpace))
        #expect(cleaned.contains(.fullScreenAuxiliary))
        #expect(cleaned.contains(.managed))
    }
}

import AppKit
import Testing

@testable import spacesui

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

    @Test func commandPalettePresentationActivatesAppWhenInactive() {
        #expect(AppKitController.shouldActivateAppForCommandPalettePresentation(appIsActive: false))
    }

    @Test func commandPalettePresentationSkipsActivationWhenAlreadyActive() {
        #expect(!AppKitController.shouldActivateAppForCommandPalettePresentation(appIsActive: true))
    }

    @Test func commandPalettePresentationKeepsMainWindowHiddenWhenItWasHidden() {
        #expect(!AppKitController.shouldUnhideMainWindowForCommandPalettePresentation(mainWindowIsVisible: false))
        #expect(AppKitController.shouldUnhideMainWindowForCommandPalettePresentation(mainWindowIsVisible: true))
        #expect(AppKitController.shouldOrderOutMainWindowForCommandPalettePresentation(mainWindowIsVisible: false))
        #expect(!AppKitController.shouldOrderOutMainWindowForCommandPalettePresentation(mainWindowIsVisible: true))
        #expect(AppKitController.shouldHideAppAfterCommandPaletteDismissal(mainWindowIsVisible: false))
        #expect(!AppKitController.shouldHideAppAfterCommandPaletteDismissal(mainWindowIsVisible: true))
    }

    @Test func commandPalettePresentationCompletesOnlyAfterPaletteBecomesKey() {
        #expect(!AppKitController.commandPalettePresentationIsComplete(panelIsVisible: false, panelIsKey: false))
        #expect(!AppKitController.commandPalettePresentationIsComplete(panelIsVisible: true, panelIsKey: false))
        #expect(AppKitController.commandPalettePresentationIsComplete(panelIsVisible: true, panelIsKey: true))
    }
}

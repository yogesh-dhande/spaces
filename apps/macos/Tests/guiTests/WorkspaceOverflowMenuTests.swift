import AppKit
import Testing

@testable import gui

@MainActor @Suite struct WorkspaceOverflowMenuTests {
    @Test func menuIncludesCopyPathAndRevealItems() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(workspaceID: "ws-1", path: "/tmp/ws-1", isHidden: false, target: nil)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Copy path"))
        #expect(titles.contains("Reveal in Finder"))
    }

    @Test func copyPathItemCarriesPathAndCmdShiftC() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(workspaceID: "ws-1", path: "/tmp/ws-1", isHidden: false, target: nil)
        guard let copy = menu.items.first(where: { $0.title == "Copy path" }) else {
            Issue.record("Copy path menu item missing")
            return
        }
        #expect(copy.identifier?.rawValue == "/tmp/ws-1")
        #expect(copy.keyEquivalent == "c")
        #expect(copy.keyEquivalentModifierMask == NSEvent.ModifierFlags([.command, .shift]))
    }

    @Test func revealItemCarriesPathAndCmdShiftF() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(workspaceID: "ws-1", path: "/tmp/ws-1", isHidden: false, target: nil)
        guard let reveal = menu.items.first(where: { $0.title == "Reveal in Finder" }) else {
            Issue.record("Reveal in Finder menu item missing")
            return
        }
        #expect(reveal.identifier?.rawValue == "/tmp/ws-1")
        #expect(reveal.keyEquivalent == "f")
        #expect(reveal.keyEquivalentModifierMask == NSEvent.ModifierFlags([.command, .shift]))
    }

    @Test func menuItemsHaveSymbolImages() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(workspaceID: "ws-1", path: "/tmp/ws-1", isHidden: false, target: nil)
        for item in menu.items where !item.isSeparatorItem { #expect(item.image != nil) }
    }

    @Test func menuItemActionsTargetCopyAndReveal() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(workspaceID: "ws-1", path: "/tmp/ws-1", isHidden: false, target: nil)
        let copy = menu.items.first { $0.title == "Copy path" }
        let reveal = menu.items.first { $0.title == "Reveal in Finder" }
        #expect(copy?.action == #selector(AppKitController.copyDirectoryPath(_:)))
        #expect(reveal?.action == #selector(AppKitController.revealDirectoryInFinder(_:)))
    }

    @Test func menuShowsHideForVisibleWorkspaceAndUnhideForHiddenWorkspace() {
        let visibleMenu = AppKitController.makeWorkspaceOverflowMenu(workspaceID: "ws-1", path: "/tmp/ws-1", isHidden: false, target: nil)
        let hiddenMenu = AppKitController.makeWorkspaceOverflowMenu(workspaceID: "ws-1", path: "/tmp/ws-1", isHidden: true, target: nil)

        #expect(visibleMenu.items.contains { $0.title == "Hide" })
        #expect(hiddenMenu.items.contains { $0.title == "Unhide" })
    }

    // MARK: senderIdentifier helper

    @Test func senderIdentifierReadsMenuItemIdentifier() {
        let item = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("/path/from-menu")
        #expect(AppKitController.senderIdentifier(item) == "/path/from-menu")
    }

    @Test func senderIdentifierReadsControlIdentifier() {
        let button = NSButton()
        button.identifier = NSUserInterfaceItemIdentifier("/path/from-button")
        #expect(AppKitController.senderIdentifier(button) == "/path/from-button")
    }

    @Test func senderIdentifierReturnsNilForUnknownSender() { #expect(AppKitController.senderIdentifier(NSObject()) == nil) }

    @Test func senderIdentifierReturnsNilWhenIdentifierMissing() {
        let item = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        #expect(AppKitController.senderIdentifier(item) == nil)
    }
}

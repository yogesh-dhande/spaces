import AppKit
import Testing

@testable import spacesui

@MainActor @Suite struct WorkspaceOverflowMenuTests {
    @Test func menuIncludesCopyPathAndRevealItems() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Copy path"))
        #expect(titles.contains("Reveal in Finder"))
    }

    @Test func remoteWorkspaceMenuOmitsRevealButKeepsCopyPath() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/remote/ws-1", target: nil, isLocalDevice: false, daemonActionsEnabled: true)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Copy path"))
        #expect(!titles.contains("Reveal in Finder"))
    }

    @Test func copyPathItemCarriesPathWithoutShortcut() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true)
        guard let copy = menu.items.first(where: { $0.title == "Copy path" }) else {
            Issue.record("Copy path menu item missing")
            return
        }
        #expect(copy.identifier?.rawValue == "/tmp/ws-1")
        #expect(copy.keyEquivalent == "")
        #expect(copy.keyEquivalentModifierMask == [])
    }

    @Test func revealItemCarriesPathWorkspaceContextAndCmdShiftF() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true)
        guard let reveal = menu.items.first(where: { $0.title == "Reveal in Finder" }) else {
            Issue.record("Reveal in Finder menu item missing")
            return
        }
        #expect(reveal.identifier?.rawValue == "/tmp/ws-1")
        guard let context = AppKitController.senderWorkspacePathActionContext(reveal) else {
            Issue.record("Reveal in Finder menu item missing workspace path context")
            return
        }
        #expect(context.workspaceID == "ws-1")
        #expect(context.path == "/tmp/ws-1")
        #expect(reveal.keyEquivalent == "f")
        #expect(reveal.keyEquivalentModifierMask == NSEvent.ModifierFlags([.command, .shift]))
    }

    @Test func unreachableDeviceKeepsPathActionsAndDisablesOnlyTheDaemonBackedItem() {
        // An unreachable device's workspace stays browsable: the menu keeps its shape, and Copy path and
        // Reveal in Finder — neither of which needs the daemon — keep working. Archive does need it, so
        // it is disabled rather than removed, which would reshuffle the menu mid-outage.
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: false)
        #expect(!menu.autoenablesItems)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Copy path"))
        #expect(titles.contains("Reveal in Finder"))
        #expect(titles.contains("Delete…"))
        #expect(menu.items.first { $0.title == "Copy path" }?.isEnabled == true)
        #expect(menu.items.first { $0.title == "Reveal in Finder" }?.isEnabled == true)
        #expect(menu.items.first { $0.title == "Delete…" }?.isEnabled == false)
    }

    @Test func reachableDeviceEnablesTheDaemonBackedItem() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true)
        #expect(menu.items.first { $0.title == "Delete…" }?.isEnabled == true)
    }

    @Test func menuItemsHaveSymbolImages() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true)
        for item in menu.items where !item.isSeparatorItem { #expect(item.image != nil) }
    }

    @Test func menuItemActionsTargetCopyAndReveal() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true)
        let copy = menu.items.first { $0.title == "Copy path" }
        let reveal = menu.items.first { $0.title == "Reveal in Finder" }
        #expect(copy?.action == #selector(AppKitController.copyDirectoryPath(_:)))
        #expect(reveal?.action == #selector(AppKitController.revealDirectoryInFinder(_:)))
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

    @Test func senderWorkspacePathActionContextReturnsNilWithoutRepresentedContext() {
        let item = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("/path/from-menu")
        #expect(AppKitController.senderWorkspacePathActionContext(item) == nil)
    }
}

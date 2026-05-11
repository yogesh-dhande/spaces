import AppKit
import Testing

@testable import spacesui
@testable import workspacecore

@MainActor @Suite struct WorkspaceOverflowMenuTests {
    @Test func menuIncludesCopyPathAndRevealItems() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(workspaceID: "ws-1", path: "/tmp/ws-1", isHidden: false, target: nil)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Copy path"))
        #expect(titles.contains("Reveal in Finder"))
    }

    @Test func copyPathItemCarriesPathWithoutShortcut() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(workspaceID: "ws-1", path: "/tmp/ws-1", isHidden: false, target: nil)
        guard let copy = menu.items.first(where: { $0.title == "Copy path" }) else {
            Issue.record("Copy path menu item missing")
            return
        }
        #expect(copy.identifier?.rawValue == "/tmp/ws-1")
        #expect(copy.keyEquivalent == "")
        #expect(copy.keyEquivalentModifierMask == [])
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

    @Test func workspaceTargetGroupMenuIncludesMemberRemovalAndDisband() {
        let snapshot = WorkspaceTargetGroupSnapshot(
            group: WorkspaceTargetGroup(id: "group-1", workspaceID: "ws-1", name: "Frontend", orderIndex: 0, createdAt: "now", updatedAt: "now"),
            members: [
                WorkspaceTargetGroupMember(groupID: "group-1", orderIndex: 0, kind: .browserSession, referenceID: "http://localhost:3000"),
                WorkspaceTargetGroupMember(groupID: "group-1", orderIndex: 1, kind: .process, referenceID: "process-web"),
            ])
        let process = RunningProcessRecord(
            id: "process-web", workspaceID: "ws-1", templateName: "web", command: "npm run dev", terminalApp: nil, windowID: nil, pid: nil,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)

        let menu = AppKitController.makeWorkspaceTargetGroupMenu(
            workspaceID: "ws-1", snapshot: snapshot, browserSessions: [BrowserSession(name: "frontend", url: "http://localhost:3000")],
            processesByID: ["process-web": process], trackedWindows: [], agentWindows: [], target: nil)

        let titles = menu.items.map(\.title)
        #expect(titles.contains("Remove frontend"))
        #expect(titles.contains("Remove web"))
        #expect(titles.contains("Disband group"))
    }

    @Test func workspaceTargetGroupMenuWiresMemberAndDisbandActions() {
        let snapshot = WorkspaceTargetGroupSnapshot(
            group: WorkspaceTargetGroup(id: "group-1", workspaceID: "ws-1", name: nil, orderIndex: 0, createdAt: "now", updatedAt: "now"),
            members: [WorkspaceTargetGroupMember(groupID: "group-1", orderIndex: 0, kind: .process, referenceID: "process-web")])
        let process = RunningProcessRecord(
            id: "process-web", workspaceID: "ws-1", templateName: "web", command: "npm run dev", terminalApp: nil, windowID: nil, pid: nil,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)

        let menu = AppKitController.makeWorkspaceTargetGroupMenu(
            workspaceID: "ws-1", snapshot: snapshot, browserSessions: [], processesByID: ["process-web": process], trackedWindows: [],
            agentWindows: [], target: nil)

        guard let remove = menu.items.first(where: { $0.title == "Remove web" }),
            let disband = menu.items.first(where: { $0.title == "Disband group" })
        else {
            Issue.record("Expected target-group menu items missing")
            return
        }

        #expect(remove.action.map(NSStringFromSelector) == "removeWorkspaceTargetGroupMemberAction:")
        #expect(disband.action.map(NSStringFromSelector) == "disbandWorkspaceTargetGroupAction:")
        #expect(remove.identifier?.rawValue == "ws-1\tgroup-1\tprocess\tprocess-web")
        #expect(disband.identifier?.rawValue == "ws-1\tgroup-1")
    }
}

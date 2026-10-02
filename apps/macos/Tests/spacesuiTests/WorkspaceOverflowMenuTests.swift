import AppKit
import Testing

@testable import spacesui
@testable import workspacecore

@MainActor @Suite struct WorkspaceOverflowMenuTests {
    private static let defaultBriefShortcut = HotkeySpec(key: "b", modifiers: [.cmd, .alt])
    private static let defaultComeBackLaterShortcut = HotkeySpec(key: "l", modifiers: [.cmd, .alt])

    @Test func menuIncludesCopyPathAndRevealItems() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: false,
            briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Copy path"))
        #expect(titles.contains("Reveal in Finder"))
    }

    @Test func remoteWorkspaceMenuOmitsRevealButKeepsCopyPath() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/remote/ws-1", target: nil, isLocalDevice: false, daemonActionsEnabled: true, isHomeWorkspace: false,
            briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Copy path"))
        #expect(!titles.contains("Reveal in Finder"))
    }

    @Test func copyPathItemCarriesPathWithoutShortcut() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: false,
            briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
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
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: false,
            briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
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
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: false, isHomeWorkspace: false,
            briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
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
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: false,
            briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
        #expect(menu.items.first { $0.title == "Delete…" }?.isEnabled == true)
    }

    /// The home row is the daemon's own, not a project the user added, so its overflow menu keeps the two
    /// path actions and offers no Delete. Hide, on the sidebar row's context menu, is how it leaves the list.
    @Test func homeWorkspaceMenuKeepsPathActionsAndOmitsDelete() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-home", path: "/Users/someone", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: true,
            briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
        let titles = menu.items.map { $0.title }
        #expect(titles.contains("Copy path"))
        #expect(titles.contains("Reveal in Finder"))
        #expect(!titles.contains("Delete…"))
        #expect(menu.items.last?.isSeparatorItem == false, "no trailing separator is left behind where Delete was")
    }

    @Test func menuItemsHaveSymbolImages() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: false,
            briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
        for item in menu.items where !item.isSeparatorItem { #expect(item.image != nil) }
    }

    @Test func menuItemActionsTargetCopyAndReveal() {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: false,
            briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
        let copy = menu.items.first { $0.title == "Copy path" }
        let reveal = menu.items.first { $0.title == "Reveal in Finder" }
        #expect(copy?.action == #selector(AppKitController.copyDirectoryPath(_:)))
        #expect(reveal?.action == #selector(AppKitController.revealDirectoryInFinder(_:)))
    }

    // MARK: Hide/Show Brief

    private func briefItem(_ state: AgentBriefToggleState) -> NSMenuItem? {
        AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: false,
            briefToggle: state, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut
        ).items.first
    }

    /// The brief item leads the menu, above Copy path, and toggles the focused pane's brief.
    @Test func briefItemLeadsTheMenuAboveCopyPath() throws {
        let menu = AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: false,
            briefToggle: .shown, briefShortcut: Self.defaultBriefShortcut, comeBackLater: nil, comeBackLaterShortcut: Self.defaultComeBackLaterShortcut)
        let titles = menu.items.map(\.title)
        let briefIndex = try #require(titles.firstIndex(of: "Hide Brief"))
        let copyIndex = try #require(titles.firstIndex(of: "Copy path"))
        #expect(briefIndex == 0)
        #expect(briefIndex < copyIndex)
        let item = menu.items[briefIndex]
        #expect(item.action == #selector(AppKitController.toggleWorkspaceFocusedPaneBrief(_:)))
        #expect(item.identifier?.rawValue == "ws-1")
        #expect(item.keyEquivalent == "b")
        #expect(item.keyEquivalentModifierMask == NSEvent.ModifierFlags([.command, .option]))
    }

    /// The item shows the configured brief chord, not a fixed one.
    @Test func briefItemShowsTheConfiguredShortcut() throws {
        let item = try #require(
            AppKitController.makeWorkspaceOverflowMenu(
                workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: true, isHomeWorkspace: false,
                briefToggle: .shown, briefShortcut: HotkeySpec(key: "j", modifiers: [.cmd, .ctrl]), comeBackLater: nil,
                comeBackLaterShortcut: Self.defaultComeBackLaterShortcut
            ).items.first)
        #expect(item.keyEquivalent == "j")
        #expect(item.keyEquivalentModifierMask == NSEvent.ModifierFlags([.command, .control]))
    }

    @Test func briefItemIsTitledWithTheActionItPerforms() {
        #expect(briefItem(.shown)?.title == "Hide Brief")
        #expect(briefItem(.hidden)?.title == "Show Brief")
    }

    /// The item keeps its place when the focused pane has no brief, so the menu keeps one shape, and is
    /// disabled there; auto-enabling is off, so the explicit state is what the user sees.
    @Test func briefItemIsEnabledOnlyWhileTheFocusedPaneHasABrief() {
        #expect(briefItem(.shown)?.isEnabled == true)
        #expect(briefItem(.hidden)?.isEnabled == true)
        #expect(briefItem(.unavailable)?.title == "Show Brief")
        #expect(briefItem(.unavailable)?.isEnabled == false)
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

    private func comeBackLaterItem(
        _ toggle: ComeBackLaterToggle?, daemonActionsEnabled: Bool = true, shortcut: HotkeySpec? = Self.defaultComeBackLaterShortcut
    ) -> NSMenuItem? {
        AppKitController.makeWorkspaceOverflowMenu(
            workspaceID: "ws-1", path: "/tmp/ws-1", target: nil, isLocalDevice: true, daemonActionsEnabled: daemonActionsEnabled,
            isHomeWorkspace: false, briefToggle: .unavailable, briefShortcut: Self.defaultBriefShortcut, comeBackLater: toggle,
            comeBackLaterShortcut: shortcut
        ).items.first { $0.action == #selector(AppKitController.toggleWorkspaceFocusedPaneComeBackLater(_:)) }
    }

    /// The Come Back Later item follows the pane's row: titled with the action it performs, carrying the
    /// configured chord, and enabled only while the row has started and the device can act.
    @Test func comeBackLaterItemFlipsItsTitleAndShowsTheConfiguredShortcut() throws {
        let off = ComeBackLaterToggle(rowKind: .agent, rowID: "a", isOn: false, hasStarted: true)
        let on = ComeBackLaterToggle(rowKind: .agent, rowID: "a", isOn: true, hasStarted: true)
        let item = try #require(comeBackLaterItem(off))
        #expect(item.title == "Come Back Later")
        #expect(item.keyEquivalent == "l")
        #expect(item.keyEquivalentModifierMask == NSEvent.ModifierFlags([.command, .option]))
        #expect(item.isEnabled)
        #expect(comeBackLaterItem(on)?.title == "Remove from Alerts")
        #expect(comeBackLaterItem(off, shortcut: HotkeySpec(key: "j", modifiers: [.cmd, .ctrl]))?.keyEquivalent == "j")
    }

    @Test func comeBackLaterItemIsDisabledWithoutARowAnOfflineDeviceOrAnUnstartedRow() {
        let off = ComeBackLaterToggle(rowKind: .process, rowID: "p", isOn: false, hasStarted: true)
        #expect(comeBackLaterItem(nil)?.isEnabled == false)
        #expect(comeBackLaterItem(off, daemonActionsEnabled: false)?.isEnabled == false)
        #expect(comeBackLaterItem(ComeBackLaterToggle(rowKind: .process, rowID: "p", isOn: false, hasStarted: false))?.isEnabled == false)
    }
}

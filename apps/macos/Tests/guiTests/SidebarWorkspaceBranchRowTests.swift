import AppKit
import Testing

@testable import gui

@MainActor @Suite struct SidebarWorkspaceBranchRowTests {
    @Test func returnsRowForNonEmptyBranch() {
        let row = AppKitController.makeSidebarWorkspaceBranchRow(
            branch: "main", textColor: .labelColor, accessibilityID: "sidebar-workspace-branch-42")
        #expect(row != nil)
    }

    @Test func returnsNilForEmptyBranch() {
        let row = AppKitController.makeSidebarWorkspaceBranchRow(branch: "", textColor: .labelColor, accessibilityID: "x")
        #expect(row == nil)
    }

    @Test func returnsNilForWhitespaceOnlyBranch() {
        let row = AppKitController.makeSidebarWorkspaceBranchRow(branch: "   \n\t  ", textColor: .labelColor, accessibilityID: "x")
        #expect(row == nil)
    }

    @Test func rowLabelShowsTrimmedBranchName() {
        let row = AppKitController.makeSidebarWorkspaceBranchRow(branch: "  feature/sidebar-redesign  ", textColor: .labelColor, accessibilityID: "x")
        let label = row?.arrangedSubviews.compactMap { $0 as? NSTextField }.first
        #expect(label?.stringValue == "feature/sidebar-redesign")
        #expect(label?.toolTip == "feature/sidebar-redesign")
    }

    @Test func labelUsesMonospacedFont() {
        let row = AppKitController.makeSidebarWorkspaceBranchRow(branch: "main", textColor: .labelColor, accessibilityID: "x")
        let label = row?.arrangedSubviews.compactMap { $0 as? NSTextField }.first
        #expect(label?.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @Test func labelCarriesAccessibilityIdentifier() {
        let row = AppKitController.makeSidebarWorkspaceBranchRow(
            branch: "main", textColor: .labelColor, accessibilityID: "sidebar-workspace-branch-abc")
        let label = row?.arrangedSubviews.compactMap { $0 as? NSTextField }.first
        #expect(label?.accessibilityIdentifier() == "sidebar-workspace-branch-abc")
    }

    @Test func rowIsIndentedToAlignUnderWorkspaceLabel() {
        // The first arranged subview is an invisible 16pt indent so the branch
        // text lines up under the workspace title (past the 10pt status icon + 6pt title-row spacing).
        let row = AppKitController.makeSidebarWorkspaceBranchRow(branch: "main", textColor: .labelColor, accessibilityID: "x")
        guard let indent = row?.arrangedSubviews.first else {
            Issue.record("Branch row should have an indent view as its first arranged subview")
            return
        }
        // Force layout to evaluate the width constraint.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        row.map { host.addSubview($0) }
        host.layoutSubtreeIfNeeded()
        #expect(indent.frame.width == 16, "Expected 16pt indent, got \(indent.frame.width)")
    }
}

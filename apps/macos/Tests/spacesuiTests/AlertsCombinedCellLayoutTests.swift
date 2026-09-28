import AppKit
import Testing

@testable import spacesui

/// The one thing about the Alert column's combined cell that only AppKit's real layout engine can answer:
/// that an overlong `project / workspace / name` identity compresses in the intended order (title, then
/// workspace, then project, then name) rather than an arbitrary field clipping or the cell overflowing
/// its column. A content-only test cannot see compression, since `AlertsController.alertsCombinedSegments`
/// only decides which strings appear, not how AppKit resolves their widths under pressure.
@Suite @MainActor struct AlertsCombinedCellLayoutTests {
    private func row(projectName: String, workspaceName: String, name: String) -> AlertsController.AlertsRenderPlan.Row {
        let entry = AlertsController.AlertsAttentionEntry(
            attentionID: "a", icon: "terminal", iconTint: .terminal, label: name, detail: nil, shortcut: "", countsTowardBadge: true, eventDate: nil)
        return AlertsController.AlertsRenderPlan.Row(
            entry: entry, projectName: projectName, isAutomationsRow: false, workspaceName: workspaceName, deviceText: nil, isOffline: false,
            ageText: "now", shortcutIndex: 1)
    }

    /// Pins `cell` to `width` inside a bare host view and forces a real Auto Layout pass, off-screen, the
    /// same technique `CompatibilityBlockLayoutTests` uses: a window is not required for constraint-based
    /// frames to resolve.
    private func layOut(_ cell: NSView, atWidth width: CGFloat) {
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: max(width, 1) + 100, height: 60))
        cell.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: pane.leadingAnchor), cell.topAnchor.constraint(equalTo: pane.topAnchor),
            cell.widthAnchor.constraint(equalToConstant: width),
        ])
        pane.layoutSubtreeIfNeeded()
    }

    @Test func aLongIdentityCompressesWorkspaceBeforeNameAndNeverExceedsTheColumnWidth() throws {
        let longProject = "a very long project name that would never fit on its own"
        let longWorkspace = "an equally long workspace branch name that also cannot fit"
        let (cell, nameField, _) = AlertsController.alertsCombinedCell(
            row: row(projectName: longProject, workspaceName: longWorkspace, name: "build box"), automationID: nil)
        let nameIntrinsicWidth = nameField.intrinsicContentSize.width
        let workspaceField = try #require(
            cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == longWorkspace }, "expected a workspace field in the cell")
        let workspaceIntrinsicWidth = workspaceField.intrinsicContentSize.width

        // Narrow enough that project and workspace cannot both hold their full intrinsic width, but wide
        // enough that compressing them alone (their compression resistance floors at 0, unlike the
        // production `TableGrid`, which adds its own minimum) can still satisfy name's intrinsic width.
        let columnWidth = nameIntrinsicWidth + 90
        layOut(cell, atWidth: columnWidth)

        #expect(cell.frame.width == columnWidth, "the cell must never push past the column width it is pinned to")
        // `>=`, not `==`: NSStackView can hand a required-hugging view a few points of leftover slack once
        // its lower-priority siblings compress, so an uncompressed field's resolved width is not always bit
        // for bit its raw `intrinsicContentSize`. What matters is that it never drops below it.
        #expect(nameField.frame.width >= nameIntrinsicWidth, "name is the last segment to give way and never shrinks below its intrinsic width")
        #expect(
            workspaceField.frame.width < workspaceIntrinsicWidth,
            "workspace must compress once project, workspace, and name together do not fit the column")
    }

    /// Title is the first segment to give way, ahead of workspace: at a width where compressing the title
    /// alone is enough, name and workspace both keep their intrinsic width.
    @Test func aLongTitleCompressesBeforeWorkspaceOrName() throws {
        let entry = AlertsController.AlertsAttentionEntry(
            attentionID: "a", icon: "terminal", iconTint: .terminal, label: "build box",
            detail: "a very long live title that would never fit in the remaining column space on its own", shortcut: "", countsTowardBadge: true,
            eventDate: nil)
        let row = AlertsController.AlertsRenderPlan.Row(
            entry: entry, projectName: "spaces", isAutomationsRow: false, workspaceName: "feature-x", deviceText: nil, isOffline: false,
            ageText: "now", shortcutIndex: 1)
        let (cell, nameField, detailField) = AlertsController.alertsCombinedCell(row: row, automationID: nil)
        let titleField = try #require(detailField, "a row with a title must build a detail field")
        let titleIntrinsicWidth = titleField.intrinsicContentSize.width
        let nameIntrinsicWidth = nameField.intrinsicContentSize.width
        let workspaceField = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "feature-x" })
        let workspaceIntrinsicWidth = workspaceField.intrinsicContentSize.width

        // Wide enough for every segment but the title at its full intrinsic width.
        let columnWidth = cell.fittingSize.width - titleIntrinsicWidth / 2
        layOut(cell, atWidth: columnWidth)

        #expect(cell.frame.width == columnWidth)
        // `>=`, not `==`: see the comment on the first test for why an uncompressed required-hugging
        // field's resolved width can sit a few points above its raw `intrinsicContentSize`.
        #expect(nameField.frame.width >= nameIntrinsicWidth)
        #expect(workspaceField.frame.width >= workspaceIntrinsicWidth)
        #expect(titleField.frame.width < titleIntrinsicWidth)
    }
}

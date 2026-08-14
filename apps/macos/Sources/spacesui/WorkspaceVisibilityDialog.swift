import AppKit
import spacesterminalcore

/// One row of the Workspaces dialog outline, in the reference form `NSOutlineView` needs for item
/// identity. The nodes themselves are values (see `WorkspaceVisibilityTree`); these wrappers are
/// rebuilt on every reload, so nothing about them is allowed to carry state across reloads.
@MainActor final class WorkspaceVisibilityOutlineItem: NSObject {
    enum Content {
        case device(WorkspaceVisibilityDeviceNode)
        case project(WorkspaceVisibilityProjectNode)
        case workspace(WorkspaceVisibilityWorkspaceNode)
    }

    let content: Content
    private(set) var children: [WorkspaceVisibilityOutlineItem] = []

    init(_ content: Content) {
        self.content = content
        super.init()
    }

    /// Builds the whole item tree from the value tree in one pass, so the data source never has to
    /// re-wrap nodes per query and item identity stays stable for the life of one reload.
    static func tree(from devices: [WorkspaceVisibilityDeviceNode]) -> [WorkspaceVisibilityOutlineItem] {
        devices.map { device in
            let deviceItem = WorkspaceVisibilityOutlineItem(.device(device))
            deviceItem.children = device.projects.map { project in
                let projectItem = WorkspaceVisibilityOutlineItem(.project(project))
                projectItem.children = project.workspaces.map { WorkspaceVisibilityOutlineItem(.workspace($0)) }
                return projectItem
            }
            return deviceItem
        }
    }
}

/// A visibility checkbox, carrying which flag it drives so one action selector serves every row.
final class WorkspaceVisibilityCheckbox: NSButton {
    enum Flag {
        case project(projectID: String)
        case workspace(workspaceID: String)
    }

    var flag: Flag?
}

/// Data source + delegate for the Workspaces dialog's outline. Kept separate from the sidebar's own
/// outline controller so the two never share delegate callbacks.
@MainActor final class WorkspaceVisibilityOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Leading inset of a project row's content inside its cell.
    private static let projectContentInset: CGFloat = 4
    /// Extra leading inset on a workspace row, on top of the level indentation, so a workspace
    /// checkbox never lines up with its project's checkbox.
    private static let workspaceContentInset: CGFloat = 12

    var devices: [WorkspaceVisibilityDeviceNode] = [] { didSet { items = WorkspaceVisibilityOutlineItem.tree(from: devices) } }
    private var items: [WorkspaceVisibilityOutlineItem] = []

    /// Called with the project id and whether its workspaces should now be visible.
    var onToggleProjectVisible: ((String, Bool) -> Void)?
    /// Called with the workspace id and whether it should now be visible.
    var onToggleWorkspaceVisible: ((String, Bool) -> Void)?

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return items.count }
        return (item as? WorkspaceVisibilityOutlineItem)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return items[index] }
        return (item as! WorkspaceVisibilityOutlineItem).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? WorkspaceVisibilityOutlineItem else { return false }
        switch item.content {
        // Device headers are always expanded and are not collapsible, so they report as expandable
        // (they have children to show) while `shouldCollapseItem` refuses to close them.
        case .device: return true
        case .project(let project): return project.isExpandable
        case .workspace: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let item = item as? WorkspaceVisibilityOutlineItem, case .device = item.content else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let item = item as? WorkspaceVisibilityOutlineItem, case .device = item.content else { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        guard let item = item as? WorkspaceVisibilityOutlineItem, case .device = item.content else { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    /// A device header gets extra height so its uppercase label reads as a break between devices
    /// rather than as one more row in the list.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? WorkspaceVisibilityOutlineItem, case .device = item.content else { return 24 }
        return 32
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? WorkspaceVisibilityOutlineItem else { return nil }
        switch item.content {
        case .device(let device): return deviceCell(device)
        case .project(let project): return projectCell(project)
        case .workspace(let workspace): return workspaceCell(workspace)
        }
    }

    /// Expands every row. The dialog is a recovery surface: a hidden row the user came here to find
    /// must never be behind a closed triangle, so expansion is not persisted or restored — it is just
    /// always open, including while searching.
    func expandAll(_ outlineView: NSOutlineView) {
        for item in items {
            outlineView.expandItem(item)
            for child in item.children { outlineView.expandItem(child) }
        }
    }

    // MARK: - Cells

    private func deviceCell(_ device: WorkspaceVisibilityDeviceNode) -> NSView {
        let label = NSTextField(labelWithString: device.name.uppercased())
        label.font = Typography.metadataTitle
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return paddedCell(content: label, leadingInset: 0)
    }

    private func projectCell(_ project: WorkspaceVisibilityProjectNode) -> NSView {
        let checkbox = checkbox(
            isChecked: project.isChecked,
            flag: {
                switch project.toggle {
                case .project: .project(projectID: project.projectID)
                case .workspace(let workspaceID, _): .workspace(workspaceID: workspaceID)
                }
            }(),
            accessibilityIdentifier: "project-visibility-checkbox")
        checkbox.toolTip = project.isChecked ? "Shown in sidebar" : "Hidden from sidebar"

        let glyph = NSImageView()
        if project.isGitRepo {
            glyph.image = RowPrimitives.projectGlyphImage
        } else {
            // A non-git project reads as a plain directory in the sidebar; the folder glyph keeps the
            // two row kinds apart here as well.
            glyph.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder project")
        }
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.widthAnchor.constraint(equalToConstant: 13).isActive = true
        glyph.heightAnchor.constraint(equalToConstant: 13).isActive = true

        let title = NSTextField(labelWithString: project.name)
        title.font = Typography.rowLabel
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        let trailing = NSTextField(labelWithString: project.trailingText)
        trailing.font = Typography.metadata
        trailing.textColor = .secondaryLabelColor
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [checkbox, glyph, title, NSView(), trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        let cell = paddedCell(content: row, leadingInset: Self.projectContentInset)
        // A hidden project keeps its children listed and toggleable; dimming the whole subtree is what
        // says the project flag, not the child flags, is what is suppressing them.
        cell.alphaValue = project.isDimmed ? 0.55 : 1
        return cell
    }

    private func workspaceCell(_ workspace: WorkspaceVisibilityWorkspaceNode) -> NSView {
        let checkbox = checkbox(
            isChecked: workspace.isChecked, flag: .workspace(workspaceID: workspace.workspaceID),
            accessibilityIdentifier: "workspace-visibility-checkbox")
        checkbox.toolTip = workspace.isChecked ? "Shown in sidebar" : "Hidden from sidebar"

        let title = NSTextField(labelWithString: workspace.name)
        title.font = Typography.rowLabel
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [checkbox, title, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        let cell = paddedCell(content: row, leadingInset: Self.projectContentInset + Self.workspaceContentInset)
        cell.alphaValue = workspace.isDimmed ? 0.55 : 1
        return cell
    }

    private func checkbox(isChecked: Bool, flag: WorkspaceVisibilityCheckbox.Flag, accessibilityIdentifier: String)
        -> WorkspaceVisibilityCheckbox
    {
        let checkbox = WorkspaceVisibilityCheckbox(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
        checkbox.state = isChecked ? .on : .off
        checkbox.flag = flag
        checkbox.setAccessibilityIdentifier(accessibilityIdentifier)
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        return checkbox
    }

    private func paddedCell(content: NSView, leadingInset: CGFloat) -> NSTableCellView {
        let cell = NSTableCellView()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leadingInset),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func toggle(_ sender: WorkspaceVisibilityCheckbox) {
        guard let flag = sender.flag else { return }
        let shouldBeVisible = sender.state == .on
        switch flag {
        case .project(let projectID): onToggleProjectVisible?(projectID, shouldBeVisible)
        case .workspace(let workspaceID): onToggleWorkspaceVisible?(workspaceID, shouldBeVisible)
        }
    }
}

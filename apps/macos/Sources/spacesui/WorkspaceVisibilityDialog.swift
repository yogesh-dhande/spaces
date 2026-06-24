import AppKit

/// One row in the workspace visibility dialog table. Visibility is persisted as
/// the workspace's `isHidden` flag; the checkbox shows `!isHidden`.
struct WorkspaceVisibilityRow: Sendable, Equatable {
    let workspaceID: String
    let deviceID: String
    let title: String
    let projectName: String
    let deviceName: String
    let branch: String
    let isHidden: Bool
}

/// Data source + delegate for the visibility dialog's table. Kept separate from
/// AppKitController's sidebar outline so the two table-like views never share
/// delegate callbacks.
@MainActor final class WorkspaceVisibilityTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let visibleColumn = NSUserInterfaceItemIdentifier("visible")
    static let titleColumn = NSUserInterfaceItemIdentifier("title")
    static let projectColumn = NSUserInterfaceItemIdentifier("project")
    static let deviceColumn = NSUserInterfaceItemIdentifier("device")
    static let branchColumn = NSUserInterfaceItemIdentifier("branch")

    var rows: [WorkspaceVisibilityRow] = []
    /// Called with the workspace id and whether it should now be visible.
    var onToggleVisible: ((String, Bool) -> Void)?

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count, let columnID = tableColumn?.identifier else { return nil }
        let entry = rows[row]

        if columnID == Self.visibleColumn {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            checkbox.state = entry.isHidden ? .off : .on
            checkbox.tag = row
            checkbox.toolTip = entry.isHidden ? "Hidden from sidebar" : "Shown in sidebar"
            checkbox.setAccessibilityIdentifier("workspace-visibility-checkbox")
            return checkbox
        }

        let text: String
        switch columnID {
        case Self.titleColumn: text = entry.title
        case Self.projectColumn: text = entry.projectName
        case Self.deviceColumn: text = entry.deviceName
        case Self.branchColumn: text = entry.branch
        default: text = ""
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        label.textColor = columnID == Self.titleColumn ? .labelColor : .secondaryLabelColor
        return label
    }

    @objc private func toggle(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < rows.count else { return }
        onToggleVisible?(rows[sender.tag].workspaceID, sender.state == .on)
    }
}

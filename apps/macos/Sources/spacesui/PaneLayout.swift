import AppKit
import systembridge

/// Measurements shared by the home panes (Alerts, Automations, Resources, Prompts), so every pane's
/// header, rows, and controls line up when the user moves between them.
///
/// The pane's content insets are owned by `showScrollableDetailStack`, which every pane embeds its
/// stack in; only the spacing between the stack's rows lives here.
enum PaneLayout {
    /// Vertical gap between the title row, the search or tabs row, and the content below them.
    static let rowSpacing: CGFloat = 16
    /// Height of the title row that carries the page title and the pane's actions.
    static let titleRowHeight: CGFloat = 28
    /// Corner radius of the pane's buttons and quiet controls.
    static let controlRadius = UIRadius.compact

    /// The vertical stack a pane's rows go into, configured the same way for every pane.
    @MainActor static func makeStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

import AppKit
import spacesdevicecore

/// A terminal pane's content view: the terminal pane's own view, with the agent's brief column beside it
/// at the trailing edge while there is a brief to show.
///
/// The column sits outside the terminal pane's view rather than inside it so everything that view pins
/// to its own edges (the pane banner, the find bar, the takeover scrim) stays over the terminal and
/// never reaches over the column. The terminal gives up the column's width; the column is removed, not
/// hidden, whenever it has nothing to show.
@MainActor final class AgentBriefPaneContainerView: NSView {
    private let terminalView: NSView
    private var terminalTrailingToContainer: NSLayoutConstraint!
    private(set) var briefColumn: AgentBriefColumnView?
    private var shownBrief: AgentBriefPresentation?

    init(terminalView: NSView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        terminalTrailingToContainer = terminalView.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor), terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor), terminalTrailingToContainer,
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Shows `brief` in the column, or removes the column when nil. Returns whether the column held the
    /// window's first responder when it was removed, so the caller can hand keyboard focus back to the
    /// terminal instead of leaving it on the window.
    @discardableResult func apply(_ brief: AgentBriefPresentation?) -> Bool {
        shownBrief = brief
        guard let brief else { return removeBriefColumn() }
        let column = briefColumn ?? installBriefColumn()
        column.update(markdown: brief.markdown, updatedAt: brief.updatedAt)
        return false
    }

    /// Whether `responder` lives inside the brief column.
    func briefColumnOwns(_ responder: NSResponder?) -> Bool {
        guard let briefColumn else { return false }
        var current = responder as? NSView
        while let candidate = current {
            if candidate === briefColumn { return true }
            current = candidate.superview
        }
        return false
    }

    /// Whether the column is on screen, and the headline of what it shows, for the pane's debug dump.
    var briefDebugState: (visible: Bool, summary: String?) { (briefColumn != nil, AgentBriefSummary.summary(of: shownBrief?.markdown)) }

    private func installBriefColumn() -> AgentBriefColumnView {
        let column = AgentBriefColumnView()
        addSubview(column)
        terminalTrailingToContainer.isActive = false
        // Just under required, so a pane narrower than the column squeezes the column rather than
        // breaking the layout; the terminal then keeps whatever width is left.
        let width = column.widthAnchor.constraint(equalToConstant: AgentBriefColumnView.width)
        width.priority = .required - 1
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor), column.leadingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor), width,
        ])
        briefColumn = column
        return column
    }

    private func removeBriefColumn() -> Bool {
        guard let briefColumn else { return false }
        let heldFocus = briefColumnOwns(window?.firstResponder)
        briefColumn.removeFromSuperview()
        self.briefColumn = nil
        terminalTrailingToContainer.isActive = true
        return heldFocus
    }
}

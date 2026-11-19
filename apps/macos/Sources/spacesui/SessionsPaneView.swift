import AppKit
import spacesdevicecore
import spacesterminalcore
import systembridge

/// Everything the Sessions pane draws, as the controller computed it.
struct SessionsPaneState: Equatable {
    struct DeviceChoice: Equatable {
        let id: String
        let name: String
    }

    var deviceChoices: [DeviceChoice]
    var selectedDeviceID: String
    /// The agents the device has sessions of: the filter menu's choices.
    var agentChoices: [CodingAgent]
    var selectedAgents: [CodingAgent]
    var agentsTitle: String
    /// The device's projects: the project filter menu's choices.
    var projectChoices: [SpacesDeviceAgentSessionProject]
    var selectedProjectID: String?
    var countText: String?
    var progressText: String?
    var errorText: String?
    /// Shown in place of the results: the device is offline, nothing matched, or the first answer is pending.
    var message: String?
    var rows: [SessionsPaneModel.Row]
    var query: String
    var selectedKey: String?
    var resumingKey: String?
    var resumeError: SessionsPaneModel.ResumeError?
    var canShowMore: Bool
    var isLoadingMore: Bool
}

/// The Sessions pane's views: the title, the search field with the count, a row of filters (device,
/// agents, project), a status line, and the results as one list.
///
/// The toolbar controls are built once and updated in place, because the search field holds the keyboard
/// while the user types and an open menu closes when its items are replaced; only the results are rebuilt,
/// and only when what they show changed, since the controller re-renders on every poll.
@MainActor final class SessionsPaneView: NSObject, NSSearchFieldDelegate {
    /// The pane's content, shown through `showScrollableDetailStack`.
    let stack = NSStackView()

    var onQueryChange: (String) -> Void = { _ in }
    var onDeviceChosen: (String) -> Void = { _ in }
    var onAgentToggled: (CodingAgent) -> Void = { _ in }
    var onAllAgents: () -> Void = {}
    /// The chosen project's id, or nil for all projects.
    var onProjectChosen: (String?) -> Void = { _ in }
    var onRowActivate: (String) -> Void = { _ in }
    var onMoveSelection: (Int) -> Void = { _ in }
    var onShowMore: () -> Void = {}

    private let devicePopUp = NSPopUpButton()
    private let agentsPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let projectsPopUp = NSPopUpButton()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let results = NSStackView()
    private let showMoreButton = NSButton(title: "Show more", target: nil, action: nil)
    private var applied: SessionsPaneState?
    private var rowViews: [String: SessionRowView] = [:]

    init(query: String) {
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Sessions")
        titleLabel.font = Typography.pageTitle
        titleLabel.textColor = Theme.text
        stack.addArrangedSubview(titleLabel)

        devicePopUp.target = self
        devicePopUp.action = #selector(deviceChanged)
        devicePopUp.setContentHuggingPriority(.required, for: .horizontal)
        devicePopUp.setAccessibilityIdentifier("sessions-device")
        agentsPopUp.setContentHuggingPriority(.required, for: .horizontal)
        agentsPopUp.setAccessibilityIdentifier("sessions-agents")
        projectsPopUp.target = self
        projectsPopUp.action = #selector(projectChanged)
        projectsPopUp.setContentHuggingPriority(.required, for: .horizontal)
        projectsPopUp.setAccessibilityIdentifier("sessions-projects")

        searchField.placeholderString = "Search sessions"
        searchField.sendsSearchStringImmediately = true
        searchField.stringValue = query
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityIdentifier("sessions-search")
        searchField.setContentHuggingPriority(NSLayoutConstraint.Priority(250), for: .horizontal)

        countLabel.font = Typography.metadata
        countLabel.textColor = Theme.muted
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setAccessibilityIdentifier("sessions-count")

        let searchRow = NSStackView(views: [searchField, countLabel])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8
        stack.addArrangedSubview(searchRow)
        constrainFormFieldToFillWidth(searchRow, in: stack)

        let filterRow = NSStackView(views: [devicePopUp, agentsPopUp, projectsPopUp])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 8
        stack.addArrangedSubview(filterRow)
        stack.setCustomSpacing(8, after: searchRow)

        progressLabel.font = Typography.metadata
        progressLabel.textColor = Theme.muted
        progressLabel.setAccessibilityIdentifier("sessions-progress")
        stack.addArrangedSubview(progressLabel)

        errorLabel.font = Typography.metadata
        errorLabel.textColor = Theme.red
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.setAccessibilityIdentifier("sessions-error")
        stack.addArrangedSubview(errorLabel)
        constrainFormFieldToFillWidth(errorLabel, in: stack)

        results.orientation = .vertical
        results.alignment = .leading
        results.spacing = 2
        stack.addArrangedSubview(results)
        constrainFormFieldToFillWidth(results, in: stack)

        showMoreButton.target = self
        showMoreButton.action = #selector(showMoreClicked)
        showMoreButton.setAccessibilityIdentifier("sessions-show-more")
        Theme.applySecondaryStyle(to: showMoreButton)
        stack.addArrangedSubview(showMoreButton)

        messageLabel.font = Typography.rowDetail
        messageLabel.textColor = Theme.muted
        messageLabel.alignment = .center
        messageLabel.setAccessibilityIdentifier("sessions-message")
        stack.addArrangedSubview(messageLabel)
        constrainFormFieldToFillWidth(messageLabel, in: stack)
    }

    func focusSearch() { searchField.window?.makeFirstResponder(searchField) }

    @objc private func searchChanged() { onQueryChange(searchField.stringValue) }
    @objc private func showMoreClicked() { onShowMore() }

    @objc private func deviceChanged() { if let id = devicePopUp.selectedItem?.representedObject as? String { onDeviceChosen(id) } }

    @objc private func agentToggled(_ sender: NSMenuItem) {
        if let agent = (sender.representedObject as? String).flatMap(CodingAgent.init(rawValue:)) { onAgentToggled(agent) }
    }

    @objc private func allAgentsChosen() { onAllAgents() }

    @objc private func projectChanged() { onProjectChosen(projectsPopUp.selectedItem?.representedObject as? String) }

    /// Arrow keys move the selection and Return resumes it without leaving the search field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): onMoveSelection(1)
        case #selector(NSResponder.moveUp(_:)): onMoveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): onRowActivateSelected()
        default: return false
        }
        return true
    }

    private var selectedKey: String? { applied?.selectedKey }
    private func onRowActivateSelected() { if let key = selectedKey { onRowActivate(key) } }

    // MARK: - Render

    func render(_ state: SessionsPaneState, scrollSelectionIntoView: Bool) {
        let previous = applied
        applied = state
        updateToolbar(state, previous: previous)
        progressLabel.stringValue = state.progressText ?? ""
        progressLabel.isHidden = state.progressText == nil
        errorLabel.stringValue = state.errorText ?? ""
        errorLabel.isHidden = state.errorText == nil
        messageLabel.stringValue = state.message ?? ""
        messageLabel.isHidden = state.message == nil
        showMoreButton.isHidden = !state.canShowMore
        showMoreButton.isEnabled = !state.isLoadingMore
        Self.setShowMoreTitle(showMoreButton, loading: state.isLoadingMore)

        if previous?.rows != state.rows || previous?.query != state.query || previous?.selectedKey != state.selectedKey
            || previous?.resumingKey != state.resumingKey || previous?.resumeError != state.resumeError
        {
            rebuildResults(state)
        }
        if scrollSelectionIntoView, let key = state.selectedKey, let row = rowViews[key] { row.scrollToVisible(row.bounds) }
    }

    private static func setShowMoreTitle(_ button: NSButton, loading: Bool) {
        button.attributedTitle = NSAttributedString(
            string: loading ? "Loading" : "Show more", attributes: [.foregroundColor: NSColor.labelColor, .font: Typography.secondaryButtonLabel])
    }

    private func updateToolbar(_ state: SessionsPaneState, previous: SessionsPaneState?) {
        if previous?.deviceChoices != state.deviceChoices || previous?.selectedDeviceID != state.selectedDeviceID {
            devicePopUp.removeAllItems()
            for choice in state.deviceChoices {
                devicePopUp.addItem(withTitle: choice.name)
                devicePopUp.lastItem?.representedObject = choice.id
                if choice.id == state.selectedDeviceID { devicePopUp.select(devicePopUp.lastItem) }
            }
        }
        if previous?.agentChoices != state.agentChoices || previous?.selectedAgents != state.selectedAgents
            || previous?.agentsTitle != state.agentsTitle
        {
            rebuildAgentsMenu(state)
        }
        if previous?.projectChoices != state.projectChoices || previous?.selectedProjectID != state.selectedProjectID { rebuildProjectsMenu(state) }
        countLabel.stringValue = state.countText ?? ""
        countLabel.isHidden = state.countText == nil
    }

    /// "All projects", then the device's projects in its order (home last). The represented object is the
    /// project id; the first item has none.
    private func rebuildProjectsMenu(_ state: SessionsPaneState) {
        projectsPopUp.removeAllItems()
        projectsPopUp.addItem(withTitle: SessionsPaneModel.allProjectsTitle)
        projectsPopUp.menu?.addItem(.separator())
        for project in state.projectChoices {
            projectsPopUp.addItem(withTitle: SessionsPaneModel.title(of: project))
            projectsPopUp.lastItem?.representedObject = project.id
            if project.id == state.selectedProjectID { projectsPopUp.select(projectsPopUp.lastItem) }
        }
    }

    /// A pull-down whose first item is the button's title; the rest toggle one agent each.
    private func rebuildAgentsMenu(_ state: SessionsPaneState) {
        agentsPopUp.removeAllItems()
        agentsPopUp.addItem(withTitle: state.agentsTitle)
        let all = NSMenuItem(title: "All agents", action: #selector(allAgentsChosen), keyEquivalent: "")
        all.target = self
        all.state = state.selectedAgents.isEmpty ? .on : .off
        agentsPopUp.menu?.addItem(all)
        agentsPopUp.menu?.addItem(.separator())
        for agent in state.agentChoices {
            let item = NSMenuItem(title: agent.displayName, action: #selector(agentToggled(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.rawValue
            item.state = state.selectedAgents.contains(agent) ? .on : .off
            agentsPopUp.menu?.addItem(item)
        }
    }

    private func rebuildResults(_ state: SessionsPaneState) {
        for view in results.arrangedSubviews {
            results.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = [:]
        for row in state.rows {
            let isResuming = state.resumingKey == row.key
            let error = state.resumeError?.key == row.key ? state.resumeError?.message : nil
            let view = SessionRowView(
                row: row, query: state.query, isSelected: state.selectedKey == row.key, statusText: error ?? (isResuming ? "Opening" : nil),
                statusIsError: error != nil, onActivate: { [weak self] in self?.onRowActivate(row.key) })
            rowViews[row.key] = view
            results.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: results.widthAnchor).isActive = true
        }
    }
}

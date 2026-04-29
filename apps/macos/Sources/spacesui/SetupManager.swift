import AppKit
import Foundation
import systembridge

protocol SetupChecking {
    func run(_ id: SetupCheckID) -> Bool
    func runAll() -> [SetupCheckResult]
    func runStartupBlockingChecks() -> [SetupCheckResult]
}

extension SetupChecker: SetupChecking {}

/// Step metadata for the onboarding UI.
/// `ids` lists every SetupCheckID that must pass for this step to be considered done.
private struct SetupStep {
    let ids: [SetupCheckID]
    let icon: String
    let title: String
    let body: String
    let action: SetupStepAction
}

private enum SetupStepAction {
    case openURL(URL)
    case copyCommand(String)
    /// Show a shell command copy-box followed by a URL button (two sequential actions).
    case commandAndURL(command: String, url: URL, urlLabel: String)
}

@MainActor final class SetupManager: NSObject {
    private let checker: any SetupChecking

    // Steps 3 & 4 are combined: yabai's --spaces query also requires Accessibility, so
    // "service running" and "accessibility granted" cannot be detected independently.
    private let steps: [SetupStep] = [
        SetupStep(
            ids: [.terminalInstalled], icon: "terminal", title: "Install a terminal",
            body:
                "Spaces opens terminal processes in iTerm2 or Ghostty. If neither is installed, install Ghostty with Homebrew or from the Ghostty website.",
            action: .commandAndURL(
                command: "brew install --cask ghostty", url: URL(string: "https://ghostty.org/")!, urlLabel: "Open Ghostty Website")),
        SetupStep(
            ids: [.tmuxInstalled], icon: "rectangle.split.1x2", title: "Install tmux",
            body: "Spaces uses tmux to keep process sessions recoverable when terminal windows close.", action: .copyCommand("brew install tmux")),
        SetupStep(
            ids: [.yabaiInstalled], icon: "hammer", title: "Install yabai",
            body: "yabai is a window manager Spaces uses to capture and focus windows.", action: .copyCommand("brew install yabai")),
        SetupStep(
            ids: [.yabaiServiceRunning, .yabaiAccessibility], icon: "hand.raised", title: "Set up yabai",
            body:
                "Start the yabai service and grant it Accessibility permission to manage windows.\n\nApple Menu → System Settings → Privacy & Security → Accessibility → enable yabai.",
            action: .commandAndURL(
                command: "yabai --start-service", url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
                urlLabel: "Open System Settings")),
    ]

    private var stepStatuses: [SetupCheckID: Bool] = [:]
    private var currentIndex: Int = 0
    private var pollingTask: Task<Void, Never>?
    private var becameActiveObserver: (any NSObjectProtocol)?
    private var isAutoAdvancing = false

    // Checklist row views (one per step, in order)
    private var checklistIconViews: [NSImageView] = []
    private var checklistLabelViews: [NSTextField] = []

    // Current step detail views
    private weak var detailIconView: NSImageView?
    private weak var detailTitleLabel: NSTextField?
    private weak var detailBodyLabel: NSTextField?
    private weak var detailCommandBox: NSView?
    private weak var detailStatusSpinner: NSProgressIndicator?
    private weak var detailStatusLabel: NSTextField?
    private(set) var isShowingSetupFlow = false
    var currentStepTitleForTesting: String? {
        guard isShowingSetupFlow, currentIndex < steps.count else { return nil }
        return steps[currentIndex].title
    }

    var onComplete: (() -> Void)?

    init(checker: any SetupChecking = SetupChecker()) {
        self.checker = checker
        super.init()
    }

    // MARK: - Public API

    /// Returns the full-window content view to install as `window.contentView`.
    func makeContentView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let checklist = makeChecklistView()
        let separator = makeSeparator()
        let detail = makeDetailView()

        let outer = NSStackView(views: [checklist, separator, detail])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 0
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.setCustomSpacing(20, after: checklist)
        outer.setCustomSpacing(20, after: separator)

        card.addSubview(outer)
        container.addSubview(card)

        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: card.topAnchor), outer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: card.leadingAnchor), outer.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            card.centerXAnchor.constraint(equalTo: container.centerXAnchor), card.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 400),

            separator.widthAnchor.constraint(equalTo: outer.widthAnchor), detail.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])

        return container
    }

    func start(preferredInitialCheckID: SetupCheckID? = nil) {
        let results = if preferredInitialCheckID == nil { checker.runStartupBlockingChecks() } else { checker.runAll() }
        for result in results { stepStatuses[result.id] = result.passed }

        guard let firstFailIndex = initialFailIndex(preferredInitialCheckID: preferredInitialCheckID) else {
            isShowingSetupFlow = false
            onComplete?()
            return
        }

        isShowingSetupFlow = true
        currentIndex = firstFailIndex
        updateChecklistDisplay()
        updateDetailDisplay()

        becameActiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor [weak self] in self?.recheckCurrentStep() }
        }

        startPolling()
    }

    func stop() {
        stopPolling()
        if let obs = becameActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            becameActiveObserver = nil
        }
    }

    // MARK: - View builders

    private func makeChecklistView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        checklistIconViews = []
        checklistLabelViews = []

        for step in steps {
            let iconView = NSImageView()
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true

            let label = NSTextField(labelWithString: step.title)
            label.font = .systemFont(ofSize: 13)
            label.translatesAutoresizingMaskIntoConstraints = false

            let row = NSStackView(views: [iconView, label])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false

            stack.addArrangedSubview(row)
            checklistIconViews.append(iconView)
            checklistLabelViews.append(label)
        }

        return stack
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func makeDetailView() -> NSView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        self.detailIconView = icon

        let titleLbl = NSTextField(labelWithString: "")
        titleLbl.font = .boldSystemFont(ofSize: 16)
        titleLbl.textColor = .labelColor
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        self.detailTitleLabel = titleLbl

        let bodyLbl = NSTextField(wrappingLabelWithString: "")
        bodyLbl.font = .systemFont(ofSize: 13)
        bodyLbl.textColor = .secondaryLabelColor
        bodyLbl.translatesAutoresizingMaskIntoConstraints = false
        bodyLbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.detailBodyLabel = bodyLbl

        let cmdBox = NSView()
        cmdBox.translatesAutoresizingMaskIntoConstraints = false
        cmdBox.wantsLayer = true
        self.detailCommandBox = cmdBox

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
        self.detailStatusSpinner = spinner

        let statusLbl = NSTextField(labelWithString: "Checking...")
        statusLbl.font = .systemFont(ofSize: 12)
        statusLbl.textColor = .secondaryLabelColor
        statusLbl.translatesAutoresizingMaskIntoConstraints = false
        self.detailStatusLabel = statusLbl

        let statusRow = NSStackView(views: [spinner, statusLbl])
        statusRow.orientation = .horizontal
        statusRow.spacing = 5
        statusRow.alignment = .centerY
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, titleLbl, bodyLbl, cmdBox, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(6, after: titleLbl)
        stack.setCustomSpacing(14, after: bodyLbl)
        stack.setCustomSpacing(10, after: cmdBox)

        return stack
    }

    // MARK: - Display updates

    private func updateChecklistDisplay() {
        for (i, step) in steps.enumerated() { updateChecklistRow(i, passed: allIDsPassed(for: step), isCurrent: i == currentIndex) }
    }

    private func updateChecklistRow(_ index: Int, passed: Bool, isCurrent: Bool) {
        guard index < checklistIconViews.count, index < checklistLabelViews.count else { return }
        let iconView = checklistIconViews[index]
        let label = checklistLabelViews[index]

        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: isCurrent ? .semibold : .regular)

        if passed {
            iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            iconView.contentTintColor = .systemGreen
            label.font = .systemFont(ofSize: 13)
            label.textColor = .tertiaryLabelColor
        } else if isCurrent {
            iconView.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            iconView.contentTintColor = .controlAccentColor
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .labelColor
        } else {
            iconView.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            iconView.contentTintColor = .tertiaryLabelColor
            label.font = .systemFont(ofSize: 13)
            label.textColor = .tertiaryLabelColor
        }
    }

    private func updateDetailDisplay() {
        guard currentIndex < steps.count else { return }
        let step = steps[currentIndex]

        let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        detailIconView?.image = NSImage(systemSymbolName: step.icon, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        detailIconView?.contentTintColor = .secondaryLabelColor

        detailTitleLabel?.stringValue = step.title
        detailBodyLabel?.stringValue = step.body
        rebuildCommandBox(for: step)
        setDetailStatusLoading()
    }

    private func rebuildCommandBox(for step: SetupStep) {
        guard let box = detailCommandBox else { return }
        for v in box.subviews { v.removeFromSuperview() }
        for c in box.constraints where c.firstAttribute == .width || c.firstAttribute == .height { c.isActive = false }

        switch step.action {
        case .copyCommand(let cmd):
            box.isHidden = false
            box.layer?.cornerRadius = UIRadius.compact
            box.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

            let label = NSTextField(labelWithString: cmd)
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false

            let copyBtn = NSButton(
                image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")!, target: self, action: #selector(copyCommandPressed)
            )
            copyBtn.bezelStyle = .inline
            copyBtn.isBordered = false
            copyBtn.contentTintColor = .secondaryLabelColor
            copyBtn.translatesAutoresizingMaskIntoConstraints = false
            copyBtn.widthAnchor.constraint(equalToConstant: 18).isActive = true
            copyBtn.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let row = NSStackView(views: [label, copyBtn])
            row.orientation = .horizontal
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false

            box.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: box.topAnchor, constant: 9), row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9),
                row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            ])

        case .openURL(let url):
            box.isHidden = false
            box.layer?.cornerRadius = 0
            box.layer?.backgroundColor = NSColor.clear.cgColor

            let actionTitle: String
            switch step.ids.first {
            case .terminalInstalled: actionTitle = "Download Ghostty"
            default: actionTitle = "Open System Settings"
            }
            let openBtn = NSButton(title: actionTitle, target: self, action: #selector(openURLPressed(_:)))
            openBtn.bezelStyle = .rounded
            openBtn.translatesAutoresizingMaskIntoConstraints = false
            openBtn.setAccessibilityIdentifier(url.absoluteString)

            box.addSubview(openBtn)
            NSLayoutConstraint.activate([
                openBtn.topAnchor.constraint(equalTo: box.topAnchor), openBtn.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                openBtn.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            ])

        case .commandAndURL(let cmd, let url, let urlLabel):
            box.isHidden = false
            box.layer?.cornerRadius = 0
            box.layer?.backgroundColor = NSColor.clear.cgColor

            // Command row
            let cmdContainer = NSView()
            cmdContainer.wantsLayer = true
            cmdContainer.layer?.cornerRadius = UIRadius.compact
            cmdContainer.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            cmdContainer.translatesAutoresizingMaskIntoConstraints = false

            let cmdLabel = NSTextField(labelWithString: cmd)
            cmdLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            cmdLabel.textColor = .labelColor
            cmdLabel.translatesAutoresizingMaskIntoConstraints = false

            let copyBtn = NSButton(
                image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")!, target: self, action: #selector(copyCommandPressed)
            )
            copyBtn.bezelStyle = .inline
            copyBtn.isBordered = false
            copyBtn.contentTintColor = .secondaryLabelColor
            copyBtn.translatesAutoresizingMaskIntoConstraints = false
            copyBtn.widthAnchor.constraint(equalToConstant: 18).isActive = true
            copyBtn.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let cmdRow = NSStackView(views: [cmdLabel, copyBtn])
            cmdRow.orientation = .horizontal
            cmdRow.spacing = 8
            cmdRow.translatesAutoresizingMaskIntoConstraints = false

            cmdContainer.addSubview(cmdRow)
            NSLayoutConstraint.activate([
                cmdRow.topAnchor.constraint(equalTo: cmdContainer.topAnchor, constant: 9),
                cmdRow.bottomAnchor.constraint(equalTo: cmdContainer.bottomAnchor, constant: -9),
                cmdRow.leadingAnchor.constraint(equalTo: cmdContainer.leadingAnchor, constant: 12),
                cmdRow.trailingAnchor.constraint(equalTo: cmdContainer.trailingAnchor, constant: -10),
            ])

            // URL button
            let urlBtn = NSButton(title: urlLabel, target: self, action: #selector(openURLPressed(_:)))
            urlBtn.bezelStyle = .rounded
            urlBtn.translatesAutoresizingMaskIntoConstraints = false
            urlBtn.setAccessibilityIdentifier(url.absoluteString)

            // Stack them vertically
            let inner = NSStackView(views: [cmdContainer, urlBtn])
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 10
            inner.translatesAutoresizingMaskIntoConstraints = false

            box.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.topAnchor.constraint(equalTo: box.topAnchor), inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                inner.leadingAnchor.constraint(equalTo: box.leadingAnchor), inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                cmdContainer.widthAnchor.constraint(equalTo: inner.widthAnchor),
            ])
        }
    }

    private func setDetailStatusLoading() {
        detailStatusSpinner?.startAnimation(nil)
        detailStatusSpinner?.isHidden = false
        detailStatusLabel?.stringValue = "Checking..."
        detailStatusLabel?.textColor = .secondaryLabelColor
    }

    private func setDetailStatusPassed() {
        detailStatusSpinner?.stopAnimation(nil)
        detailStatusSpinner?.isHidden = true
        detailStatusLabel?.stringValue = "✓ Ready"
        detailStatusLabel?.textColor = .systemGreen
    }

    // MARK: - Polling

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.recheckCurrentStep() }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func recheckCurrentStep() {
        guard !isAutoAdvancing, currentIndex < steps.count else { return }
        let step = steps[currentIndex]

        // Refresh each ID's status
        for id in step.ids { stepStatuses[id] = checker.run(id) }

        if allIDsPassed(for: step) {
            isAutoAdvancing = true
            updateChecklistRow(currentIndex, passed: true, isCurrent: true)
            setDetailStatusPassed()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.advanceOrComplete()
            }
        }
    }

    private func advanceOrComplete() {
        stopPolling()
        isAutoAdvancing = false

        let nextFail = steps.indices.dropFirst(currentIndex + 1).first(where: { !allIDsPassed(for: steps[$0]) })

        if let next = nextFail {
            currentIndex = next
            updateChecklistDisplay()
            updateDetailDisplay()
            startPolling()
        } else {
            isShowingSetupFlow = false
            stop()
            onComplete?()
        }
    }

    // MARK: - Helpers

    private func allIDsPassed(for step: SetupStep) -> Bool { step.ids.allSatisfy { stepStatuses[$0] ?? false } }

    private func hasStartupBlockingFailure(for step: SetupStep) -> Bool {
        let blockingIDs = step.ids.filter { SetupChecker.startupBlockingCheckIDs.contains($0) }
        guard !blockingIDs.isEmpty else { return false }
        return blockingIDs.contains { !(stepStatuses[$0] ?? false) }
    }

    private func initialFailIndex(preferredInitialCheckID: SetupCheckID?) -> Int? {
        if let preferredInitialCheckID, let preferredStepIndex = steps.firstIndex(where: { $0.ids.contains(preferredInitialCheckID) }) {
            if let preferredFailure = steps.indices.dropFirst(preferredStepIndex).first(where: { !allIDsPassed(for: steps[$0]) }) {
                return preferredFailure
            }
            return steps.indices.first(where: { !allIDsPassed(for: steps[$0]) })
        }
        return steps.indices.first(where: { hasStartupBlockingFailure(for: steps[$0]) })
    }

    // MARK: - Actions

    @objc private func copyCommandPressed() {
        guard currentIndex < steps.count else { return }
        let step = steps[currentIndex]
        let cmd: String?
        switch step.action {
        case .copyCommand(let c): cmd = c
        case .commandAndURL(let c, _, _): cmd = c
        case .openURL: cmd = nil
        }
        if let cmd {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }

    @objc private func openURLPressed(_ sender: NSButton) {
        let urlString = sender.accessibilityIdentifier()
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

import AppKit
import systembridge

/// The first-run blocking screen that gates the workspace UI until Spaces is allowed to control
/// Google Chrome through Apple Events (the macOS "Automation" permission). Spaces drives every
/// browser-session focus by scripting Chrome, so the app cannot function without it.
///
/// `requestAccess()` raises the system consent prompt while the grant is undetermined. Once the
/// user denies it, macOS stops offering that prompt, so the screen switches to pointing at System
/// Settings and polls the live status to advance automatically when the user enables it there.
@MainActor final class ChromeAutomationSetupController {
    var onGranted: (() -> Void)?

    private let container = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let grantButton = NSButton()
    private let settingsButton = NSButton()
    private var pollTimer: Timer?
    private var isRequestingAccess = false

    /// Builds the setup view, applies the current permission state, and starts polling so a grant
    /// made in System Settings advances the app without a relaunch.
    func begin() -> NSView {
        buildLayout()
        applyStatus(ChromeAutomationPermission.status())
        startPolling()
        return container
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func buildLayout() {
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Allow Spaces to control Google Chrome")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center

        let body = NSTextField(wrappingLabelWithString:
            "Spaces opens and focuses your workspace browser sessions in Google Chrome. macOS asks for your "
            + "permission before Spaces can control Chrome.")
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        grantButton.title = "Grant Access"
        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .large
        grantButton.keyEquivalent = "\r"
        grantButton.target = self
        grantButton.action = #selector(grantAccess)

        settingsButton.title = "Open System Settings"
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .large
        settingsButton.target = self
        settingsButton.action = #selector(openSystemSettings)

        let recheckButton = NSButton(title: "Recheck", target: self, action: #selector(recheck))
        recheckButton.bezelStyle = .accessoryBar
        recheckButton.controlSize = .small

        let buttonRow = NSStackView(views: [grantButton, settingsButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [icon, title, body, statusLabel, buttonRow, recheckButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(18, after: statusLabel)
        stack.setCustomSpacing(10, after: buttonRow)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    /// Reflects the live permission state in the screen and advances once Chrome automation is
    /// granted. A denied grant hides the in-app "Grant Access" path (macOS no longer prompts) and
    /// emphasizes System Settings.
    private func applyStatus(_ status: ChromeAutomationStatus) {
        switch status {
        case .granted, .unavailable:
            stop()
            onGranted?()
        case .notDetermined:
            grantButton.isHidden = false
            settingsButton.isHidden = true
            statusLabel.stringValue = "Click Grant Access, then choose OK when macOS asks to allow Spaces to control Chrome."
        case .denied:
            grantButton.isHidden = true
            settingsButton.isHidden = false
            statusLabel.stringValue =
                "Chrome control is turned off for Spaces. Open System Settings ▸ Privacy & Security ▸ Automation and enable Google Chrome for Spaces."
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRequestingAccess else { return }
                self.applyStatus(ChromeAutomationPermission.status())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc private func grantAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        grantButton.isEnabled = false
        Task { @MainActor in
            let status = await Task.detached { ChromeAutomationPermission.requestAccess() }.value
            self.isRequestingAccess = false
            self.grantButton.isEnabled = true
            self.applyStatus(status)
        }
    }

    @objc private func openSystemSettings() {
        guard let url = URL(string: ChromeAutomationPermission.systemSettingsAutomationURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func recheck() {
        applyStatus(ChromeAutomationPermission.status())
    }
}

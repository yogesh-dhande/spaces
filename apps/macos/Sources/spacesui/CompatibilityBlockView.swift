import AppKit
import spacesclientcore
import spacesterminalcore
import workspacecore

/// Full-pane block shown when a device's daemon is wire-incompatible with this app. Mirrors the iOS
/// `CompatibilityBannerView`: title, explanation, and a restart action (absent when the fix is a client
/// update rather than a daemon restart).
///
/// A too-old **Linux** daemon is a special case: a restart respawns the same old binary, so instead of
/// the Restart button it shows the version-pinned installer one-liner the user runs on the Linux device
/// to replace the binary and restart the service.
final class CompatibilityBlockView: NSView {
    private let onRestart: (() -> Void)?

    init(verdict: SpacesWireCompatibility, deviceName: String, status: TerminalServiceDaemonStatus?, onRestart: (() -> Void)?) {
        self.onRestart = onRestart
        // A too-old Linux daemon cannot be fixed by the restart RPC (it just relaunches the same binary);
        // the user reinstalls on the device instead, so we show the installer command rather than a button.
        let showsLinuxInstaller = verdict == .daemonTooOld && status?.isLinuxDaemon == true
        super.init(frame: .zero)
        wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        icon.contentTintColor = .systemOrange
        let titleText = showsLinuxInstaller ? "Update \(deviceName)'s Spaces daemon" : Self.title(for: verdict, deviceName: deviceName)
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(title)
        stack.addArrangedSubview(header)

        let detailText =
            showsLinuxInstaller
            ? "The daemon on \(deviceName) is older than this app, and a restart won't update it. Run the command below on the Linux device — "
                + "running terminals, agents, and processes on it are preserved — then reconnect. Other paired devices remain available."
            : Self.detail(for: verdict, deviceName: deviceName)
        let detail = NSTextField(wrappingLabelWithString: detailText)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        stack.addArrangedSubview(detail)

        if showsLinuxInstaller {
            let command = NSTextField(labelWithString: SpacesLinuxInstaller.installCommand(version: AppVersion.short))
            command.isSelectable = true
            command.isEditable = false
            command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            command.lineBreakMode = .byCharWrapping
            command.maximumNumberOfLines = 0
            stack.addArrangedSubview(command)
        }

        if !showsLinuxInstaller, onRestart != nil {
            let button = NSButton(title: "Restart Daemon", target: self, action: #selector(restartTapped))
            button.bezelStyle = .rounded
            button.keyEquivalent = "\r"
            stack.addArrangedSubview(button)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    // AppKit only calls `updateLayer()` when `wantsUpdateLayer` is true; without this the card's
    // orange border/background would never be applied.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true  // re-resolve the appearance-sensitive colors on light/dark switch
    }

    @objc private func restartTapped() { onRestart?() }

    private static func title(for verdict: SpacesWireCompatibility, deviceName: String) -> String {
        switch verdict {
        case .clientTooOld: "Device version not compatible"
        case .daemonTooOld: "Device needs a daemon restart"
        case .compatible: "Daemon update pending"
        }
    }

    private static func detail(for verdict: SpacesWireCompatibility, deviceName: String) -> String {
        switch verdict {
        case .clientTooOld: "\(deviceName) runs a newer version than this app. Please update this client to reconnect to it."
        case .daemonTooOld:
            "The daemon on \(deviceName) is older than this app needs. Restart it to apply the update — running terminals, agents, and "
                + "processes keep running. Other paired devices remain available."
        case .compatible: "A newer Spaces is installed; the daemon keeps running the older build until it restarts."
        }
    }
}

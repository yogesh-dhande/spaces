import AppKit
import spacesclientcore
import spacesterminalcore
import workspacecore

/// Full-pane block shown when a device's daemon is wire-incompatible with this app. Mirrors the iOS
/// `CompatibilityBannerView`: title, explanation, restart-impact counts, and a restart action (absent
/// when the fix is a client update rather than a daemon restart).
///
/// A too-old **Linux** daemon is a special case: a restart respawns the same old binary, so instead of
/// the Restart button it shows the version-pinned installer one-liner the user runs on the Linux device
/// to replace the binary and restart the service.
final class CompatibilityBlockView: NSView {
    private let onRestart: (() -> Void)?

    init(verdict: SpacesWireCompatibility, status: TerminalServiceDaemonStatus?, onRestart: (() -> Void)?) {
        self.onRestart = onRestart
        // A too-old Linux daemon cannot be fixed by the restart RPC (it just relaunches the same binary);
        // the user reinstalls on the device instead, so we show the installer command rather than a button.
        let showsLinuxInstaller = verdict == .daemonTooOld && status?.isLinuxDaemon == true
        super.init(frame: .zero)
        wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        icon.contentTintColor = .systemOrange
        let title = NSTextField(labelWithString: showsLinuxInstaller ? "Update this device's Spaces daemon" : Self.title(for: verdict))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(title)
        stack.addArrangedSubview(header)

        let detailText =
            showsLinuxInstaller
            ? "The daemon on this device is older than this app, and a restart won't update it. Run the command below on the Linux device, "
                + "then reconnect. Other paired devices remain available."
            : Self.detail(for: verdict)
        let detail = NSTextField(wrappingLabelWithString: detailText)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
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

        if !showsLinuxInstaller, onRestart != nil, let impact = Self.impactSummary(status: status) {
            let impactLabel = NSTextField(wrappingLabelWithString: impact)
            impactLabel.font = .systemFont(ofSize: 12)
            impactLabel.textColor = .secondaryLabelColor
            stack.addArrangedSubview(impactLabel)
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

    private static func title(for verdict: SpacesWireCompatibility) -> String {
        switch verdict {
        case .clientTooOld: "Update Spaces to use this device"
        case .daemonTooOld: "This device needs a daemon restart"
        case .compatible: "Daemon update pending"
        }
    }

    private static func detail(for verdict: SpacesWireCompatibility) -> String {
        switch verdict {
        case .clientTooOld: "This device runs a newer Spaces than this app. Update Spaces to reconnect to this device."
        case .daemonTooOld:
            "The daemon on this device is older than this app needs. Restart it to apply the update and reconnect. "
                + "Other paired devices remain available."
        case .compatible: "A newer Spaces is installed; the daemon keeps running the older build until it restarts."
        }
    }

    private static func impactSummary(status: TerminalServiceDaemonStatus?) -> String? {
        guard let status else { return nil }
        var parts: [String] = []
        if status.activeSessionCount > 0 { parts.append(count(status.activeSessionCount, "terminal")) }
        if status.runningProcesses > 0 { parts.append(count(status.runningProcesses, "process", plural: "processes")) }
        let agents = status.activeAgents + status.waitingAgents
        if agents > 0 { parts.append(count(agents, "coding agent")) }
        guard !parts.isEmpty else { return "Restarting won't interrupt any running work." }
        return "Restarting will stop " + parts.joined(separator: ", ") + "."
    }

    private static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }
}

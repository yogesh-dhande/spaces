import AppKit
import spacesclientcore
import spacesterminalcore
import workspacecore

/// Full-pane block shown when a device's daemon is wire-incompatible with this app. Mirrors the iOS
/// `CompatibilityBannerView`: title, explanation, and — only when `BlockRemedy` says a restart or an app
/// update actually fixes something — an action button.
///
/// Rendering is driven by `DaemonUpdateRemedy` (via `blockRemedy(verdict:status:)`), not the raw
/// `SpacesWireCompatibility` verdict: a too-old daemon with nothing staged on its device
/// (`.installUpdateOnDevice`) cannot be fixed by a restart — that would just re-exec the same binary and
/// leave the block stuck — so every OS in that state shows install guidance instead of a button:
///   - Linux: the version-pinned `install.sh` one-liner the user runs on the device.
///   - A remote Mac: instructions to open Spaces on that device and install the update there.
///   - This Mac (the local daemon): a "Check for Updates…" button wired to Sparkle, when available.
/// Only `.applyStagedUpdate` — a newer build already installed on the device — offers a restart/update
/// button, labeled "Update Daemon" since that names the outcome.
final class CompatibilityBlockView: NSView {
    /// What the block renders, carrying exactly the version facts each case is guaranteed to have (so
    /// `content(...)` never needs to invent placeholder text for data it doesn't have). Produced by
    /// `blockRemedy(verdict:status:)`, which is `nil` for a device that needs no block at all.
    enum BlockRemedy: Equatable {
        /// This client's own app build must update. `daemonVersion` is `nil` only in the no-status
        /// conservative fallback (see `blockRemedy`); once a status is known it is always present.
        case updateClient(daemonVersion: String?)
        /// A newer build is installed on the device and a restart applies it — the only case with a
        /// restart/update button. Both versions are guaranteed non-nil: this case is only produced from
        /// a status whose `isUpdatePending` is true, which by definition requires a staged
        /// `installedVersion`, and `version` (the daemon's own running build) is never optional.
        case applyStagedUpdate(daemonVersion: String, installedVersion: String)
        /// The daemon is too old and nothing newer is staged; `daemonVersion` is `nil` only in the
        /// no-status conservative fallback.
        case installUpdateOnDevice(daemonVersion: String?)

        /// The only case for which offering a restart/update action makes sense — mirrors
        /// `DaemonUpdateRemedy.offersDaemonUpdateAction`.
        var offersDaemonUpdateAction: Bool {
            if case .applyStagedUpdate = self { return true }
            return false
        }
    }

    /// Pure "what should the block show" descriptor, independent of AppKit so it is unit-testable
    /// without instantiating a view. `actionButtonTitle == nil` means no button is rendered.
    struct Content: Equatable {
        let title: String
        let detail: String
        let installerCommand: String?
        let actionButtonTitle: String?
    }

    private let onAction: (() -> Void)?

    init(
        remedy: BlockRemedy, deviceName: String, isLocalDevice: Bool, isLinuxDaemon: Bool, onRestart: (() -> Void)?, onCheckForUpdates: (() -> Void)?
    ) {
        let content = Self.content(
            remedy: remedy, deviceName: deviceName, isLocalDevice: isLocalDevice, isLinuxDaemon: isLinuxDaemon, clientVersion: AppVersion.short,
            canCheckForUpdates: onCheckForUpdates != nil)
        // Only one of these is ever the button's target for a given remedy — see `content(...)`, which
        // decides the button's *title*, and this switch, which picks the matching closure. The caller
        // (`AppKitController`) already withholds whichever closure isn't justified for this device, so at
        // most one is non-nil in practice.
        switch remedy {
        case .applyStagedUpdate: onAction = onRestart
        case .installUpdateOnDevice: onAction = isLocalDevice ? onCheckForUpdates : nil
        case .updateClient: onAction = nil
        }
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
        let title = NSTextField(labelWithString: content.title)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(title)
        stack.addArrangedSubview(header)

        let detail = NSTextField(wrappingLabelWithString: content.detail)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        stack.addArrangedSubview(detail)

        if let installerCommand = content.installerCommand {
            let command = NSTextField(labelWithString: installerCommand)
            command.isSelectable = true
            command.isEditable = false
            command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            command.lineBreakMode = .byCharWrapping
            command.maximumNumberOfLines = 0
            stack.addArrangedSubview(command)
        }

        if let actionButtonTitle = content.actionButtonTitle, onAction != nil {
            let button = NSButton(title: actionButtonTitle, target: self, action: #selector(actionTapped))
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

    @objc private func actionTapped() { onAction?() }

    /// Maps a device's verdict/status onto what the block should render, or `nil` when the device needs
    /// no block at all (a compatible, up-to-date daemon).
    ///
    /// Without a `status` there is no installed-version fact to justify a staged-update or
    /// "nothing to do" story, so this falls back to a deliberate conservative reading of the verdict
    /// alone: too-old-client still means update this app, too-old-daemon still means *some* update is
    /// needed on that device, but neither carries a version number or offers an action button. This
    /// fallback is reachable in principle (a verdict known before its paired status has landed), unlike
    /// the cases below, which is why it stays a real branch rather than an assertion.
    nonisolated static func blockRemedy(verdict: SpacesWireCompatibility, status: TerminalServiceDaemonStatus?) -> BlockRemedy? {
        guard let status else {
            switch verdict {
            case .clientTooOld: return .updateClient(daemonVersion: nil)
            case .daemonTooOld: return .installUpdateOnDevice(daemonVersion: nil)
            case .compatible: return nil
            }
        }
        switch DaemonUpdateRemedy.remedy(for: status) {
        case .none: return nil
        case .updateClient: return .updateClient(daemonVersion: nonEmpty(status.version))
        case .applyStagedUpdate(let installedVersion): return .applyStagedUpdate(daemonVersion: status.version, installedVersion: installedVersion)
        case .installUpdateOnDevice: return .installUpdateOnDevice(daemonVersion: nonEmpty(status.version))
        }
    }

    /// Builds the block's copy and button choice for `remedy`. `clientVersion` is display-only context
    /// threaded through for the user's benefit — it plays no part in picking the title, detail, or
    /// button below; `remedy` already encodes every decision, and a client must never re-derive one by
    /// comparing its own build against a daemon's (unrelated release trains — see `DaemonUpdateRemedy`).
    nonisolated static func content(
        remedy: BlockRemedy, deviceName: String, isLocalDevice: Bool, isLinuxDaemon: Bool, clientVersion: String, canCheckForUpdates: Bool
    ) -> Content {
        switch remedy {
        case .updateClient(let daemonVersion):
            let detail =
                daemonVersion != nil
                ? "\(deviceName) is running Spaces \(daemonVersion!), newer than this app (Spaces \(clientVersion)). Update this app to reconnect "
                    + "to it." : "\(deviceName) runs a newer version than this app. Update this app to reconnect to it."
            return Content(title: "Device version not compatible", detail: detail, installerCommand: nil, actionButtonTitle: nil)

        case .applyStagedUpdate(let daemonVersion, let installedVersion):
            let detail =
                "\(deviceName) is running Spaces \(daemonVersion); Spaces \(installedVersion) is installed there. Update the daemon to apply "
                + "it — running terminals, agents, and processes keep running. Other paired devices remain available."
            return Content(title: "\(deviceName) needs a daemon update", detail: detail, installerCommand: nil, actionButtonTitle: "Update Daemon")

        case .installUpdateOnDevice(let daemonVersion):
            if isLinuxDaemon {
                let detail =
                    "The daemon on \(deviceName) is running Spaces \(daemonVersion ?? "an older build"), older than this app needs (Spaces "
                    + "\(clientVersion)), and a restart won't update it — nothing newer is installed there. Run the command below on the Linux "
                    + "device — running terminals, agents, and processes on it are preserved — then reconnect. Other paired devices remain "
                    + "available."
                return Content(
                    title: "Update \(deviceName)'s Spaces daemon", detail: detail,
                    installerCommand: SpacesLinuxInstaller.installCommand(version: clientVersion), actionButtonTitle: nil)
            }
            if isLocalDevice {
                let detail =
                    "This Mac's Spaces daemon is running \(daemonVersion ?? "an older build"), older than this app needs (Spaces "
                    + "\(clientVersion)). Update Spaces on this Mac — once it's installed, the daemon picks up the update on its own, and "
                    + "running terminals, agents, and processes are preserved."
                return Content(
                    title: "This Mac needs a Spaces update", detail: detail, installerCommand: nil,
                    actionButtonTitle: canCheckForUpdates ? "Check for Updates…" : nil)
            }
            let detail =
                "\(deviceName) is running Spaces \(daemonVersion ?? "an older build"), older than this app needs (Spaces \(clientVersion)), and "
                + "nothing newer is installed there. Open Spaces on \(deviceName) and install the update, then reconnect. Other paired devices "
                + "remain available."
            return Content(title: "\(deviceName) needs a Spaces update", detail: detail, installerCommand: nil, actionButtonTitle: nil)
        }
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

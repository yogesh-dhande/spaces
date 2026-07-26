import AppKit
import Carbon
import CoreImage
import Foundation
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty
import spacesterminalui
import systembridge
import workspacecore

/// Owns the Devices settings section and the device-pairing subsystem: the
/// connected-devices list, the iPhone/iPad pairing QR code, remote-device SSH
/// pairing, and device rename/removal. `AppKitController` holds a single instance
/// and delegates these to it.
///
/// The Devices section renders into the Settings window, so this controller reaches
/// the host's `settings` controller for the window/section/content state. The `@objc`
/// action handlers stay on the host (their buttons bind their target to the host) and
/// forward here; the device-rename text field uses the host's shared `NSControl`
/// delegate, which routes back into this controller.
@MainActor final class DevicePairingController {
    unowned let host: AppKitController

    init(host: AppKitController) { self.host = host }

    /// Shown when the Device API control endpoint is disabled for this profile by an environment override.
    /// A relaunch inherits the same environment, so it cannot bring the socket up; the restart action is
    /// suppressed for this failure. A genuine daemon-down failure (which a relaunch resolves) carries a
    /// different message.
    nonisolated static let deviceAPIControlDisabledMessage =
        "Device API control is unavailable for this profile. Relaunch Spaces without the disabled Device API environment override."

    /// Stable message for a local daemon whose control endpoint is unreachable (the daemon is down), as
    /// opposed to one that is reachable but returned a real error. `controlResponse(forThrownError:)`
    /// produces it from a connectivity throw so the restart action can key off it without string-matching
    /// a variable POSIX error description.
    nonisolated static let deviceAPIUnreachableMessage = "The local Spaces daemon isn't reachable. Restart it to reconnect."

    /// Cached because ISO8601DateFormatter construction is expensive; used for parsing/formatting
    /// device-pairing timestamps (remote pairing window `expiresAt`, paired-device `updatedAt`).
    /// ISO8601DateFormatter is documented thread-safe.
    private static let iso8601Formatter = ISO8601DateFormatter()

    /// The Restart Local Daemon action is offered only for failures a relaunch can actually resolve: the
    /// daemon answered that its Device API is not running, or its control endpoint was unreachable (the
    /// daemon is down). It is suppressed for the disabled-override case (a relaunch inherits the same
    /// environment), while a relaunch is already running (so a second click can't start a concurrent
    /// relaunch), and — crucially — for a reachable daemon that returned a real status/settings error,
    /// which carries its own message and must surface instead of prompting a session-stopping restart.
    /// Pure so the gating is directly testable.
    nonisolated static func localDaemonRestartActionIsAvailable(responseMessage: String, isRelaunching: Bool) -> Bool {
        guard !isRelaunching else { return false }
        return responseMessage == SpacesDeviceAPIControlClient.deviceAPINotRunningMessage || responseMessage == deviceAPIUnreachableMessage
    }

    /// Classifies an error thrown while talking to the local control endpoint into a control response: the
    /// disabled-override message when the endpoint is deliberately off, the stable unreachable message when
    /// the endpoint is merely down (so the restart action appears), or the error's own description for any
    /// other failure (which offers no restart). Nonisolated so the relaunch flow's detached task can reuse it.
    nonisolated static func controlResponse(forThrownError error: any Error) -> SpacesDeviceAPIControlResponse {
        if let disabledResponse = deviceAPIDisabledOverrideResponse(for: error) { return disabledResponse }
        if SpacesDeviceAPIControlClient.isControlEndpointUnavailable(error) {
            return SpacesDeviceAPIControlResponse(ok: false, message: deviceAPIUnreachableMessage)
        }
        return SpacesDeviceAPIControlResponse(ok: false, message: error.localizedDescription)
    }

    private struct ClientConnectedDevice: Sendable {
        let id: String
        let name: String
        let host: String?
        let port: Int?
        let sshHost: String?
        let sshUser: String?
        let sshPort: Int?
        let isLocal: Bool
        let isAvailable: Bool
        let requiresReconnect: Bool

        /// The label shown for this device in the Devices settings list. The local device always
        /// renders as "Local" regardless of its stored machine name; remote devices show their stored name.
        var displayName: String { isLocal ? "Local" : name }
    }

    private struct ClientDevicePairingWindow {
        let deviceID: String
        let deviceName: String
        let linkString: String
        let expiresAt: Date

        var isVisible: Bool { expiresAt > Date() }
    }

    private weak var remoteDeviceSSHHostField: NSTextField?
    private weak var remoteDeviceNameField: NSTextField?
    private weak var remoteDeviceSSHUserField: NSTextField?
    private weak var remoteDeviceSSHPortField: NSTextField?
    /// The collapsible row holding the optional username/port fields. Hidden until the user
    /// expands "Advanced" so the form reads as host-only by default.
    private weak var remoteDeviceAdvancedRow: NSView?
    private weak var remoteDeviceAdvancedToggle: NSButton?
    private weak var remoteDevicePairingStatusLabel: NSTextField?
    /// The Connect button and the recovery install block, retained weakly so the install/connect flows
    /// can toggle their enabled/hidden state on the live views without a full panel re-render (a re-render
    /// would wipe the section-local status label).
    private weak var remoteDeviceConnectButton: NSButton?
    private weak var remoteDeviceInstallBlock: NSView?
    private weak var remoteDeviceInstallCommandField: NSTextField?
    private weak var remoteDeviceInstallButton: NSButton?
    private weak var remoteDeviceInstallSpinner: NSProgressIndicator?
    private var currentDevicePairingWindow: ClientDevicePairingWindow?
    private var devicePanelStatusMessage: (message: String, isError: Bool)?
    private var isRelaunchingLocalDaemon = false
    /// The pinned Linux install one-liner surfaced after a pairing attempt found Spaces missing on a Linux
    /// device. Non-nil drives the recovery install block: the section rebuilds the block from this on every
    /// render, so it survives panel rebuilds rather than living only on the transient views.
    private var remoteDeviceLinuxInstallCommand: String?
    /// True while the SSH install-and-pair recovery is running, so a rebuild keeps the install and Connect
    /// buttons disabled and the spinner visible.
    private var isInstallingRemoteSpaces = false
    var renamingClientDeviceID: String?
    weak var renamingClientDeviceField: NSTextField?

    func showMobileConnection() {
        devicePanelStatusMessage = nil
        host.settings.openSettings(section: .devices)
    }

    /// The disabled-override response applies only when the Device API is actually turned off by the
    /// environment override: a relaunch inherits the same environment and cannot help, so the restart
    /// action is suppressed. A control endpoint that is merely unreachable — e.g. the socket is down while
    /// live terminal sessions blocked the automatic relaunch — is recoverable, so this returns nil and the
    /// caller keeps the Restart Local Daemon action available.
    nonisolated static func deviceAPIDisabledOverrideResponse(for error: any Error) -> SpacesDeviceAPIControlResponse? {
        guard SpacesDeviceAPIControlClient.isControlEndpointUnavailable(error), SpacesDeviceAPIDefaults.isDisabledByEnvironment() else { return nil }
        return SpacesDeviceAPIControlResponse(ok: false, message: deviceAPIControlDisabledMessage)
    }

    func currentDeviceControlResponse() -> SpacesDeviceAPIControlResponse {
        do { return try SpacesDeviceAPIControlClient.statusEnsuringCurrentTerminalService() } catch {
            return Self.controlResponse(forThrownError: error)
        }
    }

    /// Switches the open settings dialog to the Devices section and renders it with the given response.
    /// Opens the settings dialog on the Devices section when it is not already showing.
    private func showDeviceSettings(_ response: SpacesDeviceAPIControlResponse) {
        if host.settings.settingsWindow?.isVisible == true, host.settings.settingsSectionContentContainer != nil {
            host.settings.selectedSettingsSection = .devices
            for (section, row) in host.settings.settingsSectionRowViews { row.isSelected = section == .devices }
            renderDeviceSettings(response: response)
        } else {
            host.settings.openSettings(section: .devices)
        }
    }

    private func refreshVisibleDeviceSettings(_ response: SpacesDeviceAPIControlResponse) {
        guard host.settings.settingsWindow?.isVisible == true, host.settings.selectedSettingsSection == .devices,
            host.settings.settingsSectionContentContainer != nil
        else { return }
        renderDeviceSettings(response: response)
    }

    func renderDeviceSettings(response: SpacesDeviceAPIControlResponse) {
        host.activeShortcutCaptureSetting = nil
        host.shortcutButtonsBySetting.removeAll()
        host.settings.renderSettingsCards(deviceSettingsCards(response: response))
    }

    private func visibleDevicePairingWindow(for response: SpacesDeviceAPIControlResponse) -> SpacesDevicePairingWindowSnapshot? {
        if let pairingWindow = response.pairingWindow, pairingWindow.expiresAt > Date() { return pairingWindow }
        return nil
    }

    private func deviceSettingsCards(response: SpacesDeviceAPIControlResponse) -> [NSView] {
        var cards: [NSView] = []
        let pairingWindow = visibleDevicePairingWindow(for: response)

        if let status = devicePanelStatusMessage {
            let statusLabel = host.helpTextLabel(status.message)
            statusLabel.textColor = status.isError ? .systemRed : .secondaryLabelColor
            // Status messages can carry a long unbreakable path; wrap on characters so the path stays
            // fully visible across lines rather than being clipped at the (now width-capped) window edge.
            statusLabel.lineBreakMode = .byCharWrapping
            cards.append(statusLabel)
        }

        if let displayWindow = visibleClientDevicePairingWindow(response: response, pairingWindow: pairingWindow) {
            cards.append(clientDevicePairingQRCodeSection(displayWindow))
        }

        cards.append(connectedDevicesSection(response: response))
        cards.append(remoteDevicePairingSection())
        return cards
    }

    private func visibleClientDevicePairingWindow(response: SpacesDeviceAPIControlResponse, pairingWindow: SpacesDevicePairingWindowSnapshot?)
        -> ClientDevicePairingWindow?
    {
        if let currentDevicePairingWindow, currentDevicePairingWindow.isVisible { return currentDevicePairingWindow }
        currentDevicePairingWindow = nil
        guard let pairingWindow, pairingWindow.expiresAt > Date() else { return nil }
        let deviceName = response.status?.bonjourServiceName ?? "This Mac"
        let window = ClientDevicePairingWindow(
            deviceID: SpacesPairedDeviceRecord.localDeviceID, deviceName: deviceName, linkString: pairingWindow.linkString,
            expiresAt: pairingWindow.expiresAt)
        currentDevicePairingWindow = window
        return window
    }

    private func clientDevicePairingQRCodeSection(_ window: ClientDevicePairingWindow) -> NSView {
        var rows: [NSView] = []
        rows.append(devicePairingInstructionLabel("Scan this QR code with Spaces on iPhone or iPad to pair it with \(window.deviceName)."))
        rows.append(mobileQRCodeView(link: window.linkString))
        let hosts = (try? SpacesDevicePairingLink.parse(window.linkString))?.hosts ?? []
        if !hosts.isEmpty { rows.append(pairingLinkAddressesView(hosts: hosts)) }
        return mobilePanelSection(icon: "qrcode", title: "Pair iPhone or iPad", rows: rows)
    }

    /// Summarizes the addresses this pairing link advertises, so the person scanning the QR code can
    /// tell at a glance whether a tailnet fallback was found. When the daemon found no tailnet address
    /// (only ever the case for a bare LAN-only link) this shows guidance instead of a one-item list,
    /// since a single "Local network · ..." line would otherwise read like the pairing feature is
    /// incomplete rather than like a deliberate, capability-gated fallback.
    private func pairingLinkAddressesView(hosts: [String]) -> NSView {
        guard hosts.contains(where: { SpacesDeviceHostAddressKind(host: $0) == .tailscale }) else {
            return host.helpTextLabel("Reaching this Mac from outside its local network needs Tailscale (or another VPN) running on both devices.")
        }
        let accentColor = host.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let labels = hosts.map { candidate -> NSTextField in
            let label = host.helpTextLabel("\(SpacesDeviceHostAddressKind(host: candidate).label) · \(candidate)")
            label.textColor = accentColor
            return label
        }
        let stack = NSStackView(views: labels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func connectedDevicesSection(response: SpacesDeviceAPIControlResponse) -> NSView {
        var rows: [NSView] = []
        let devices = connectedClientDevices(localStatus: response.status, requireLocalStatus: true)
        rows.append(contentsOf: devices.map(connectedDeviceRow(_:)))
        if !response.ok {
            let errorLabel = host.helpTextLabel(response.message)
            errorLabel.lineBreakMode = .byCharWrapping
            rows.append(errorLabel)
            // A non-ok control response means the local daemon (or just its Device API endpoint) is
            // down/unreachable. Offer a one-click relaunch right next to the error — but only for failures a
            // relaunch can resolve, and not while a relaunch is already running. This is the only place the
            // local daemon restart lives; restartLocalDaemon warns before killing if the daemon still reports
            // live sessions (the Device API can be down while the terminal service is not).
            if Self.localDaemonRestartActionIsAvailable(responseMessage: response.message, isRelaunching: isRelaunchingLocalDaemon) {
                let restartButton = host.actionButton(
                    title: "Restart Local Daemon", symbol: "arrow.clockwise", tooltip: "Relaunch the local spacesd daemon on this Mac",
                    action: #selector(AppKitController.restartLocalDaemon), primary: true)
                rows.append(mobilePanelButtonRow([restartButton]))
            }
        }
        return mobilePanelSection(icon: "desktopcomputer.and.macbook", title: "Connected Devices", rows: rows)
    }

    private func connectedDeviceRow(_ device: ClientConnectedDevice) -> NSView {
        let detail = NSTextField(labelWithString: clientDeviceDetailText(device))
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        let nameView: NSView
        if !device.isLocal, renamingClientDeviceID == device.id {
            let editor = NSTextField(string: device.name)
            editor.font = .systemFont(ofSize: 12, weight: .medium)
            editor.delegate = host
            editor.identifier = NSUserInterfaceItemIdentifier(device.id)
            editor.toolTip = "Press Return to save, Esc to cancel."
            editor.setAccessibilityIdentifier("connected-device-rename-input")
            renamingClientDeviceField = editor
            Task { @MainActor [weak editor] in
                guard let editor else { return }
                editor.window?.makeFirstResponder(editor)
                editor.selectText(nil)
            }
            nameView = editor
        } else {
            let title = NSTextField(labelWithString: device.displayName)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingTail
            nameView = title
        }

        let textStack = NSStackView(views: [nameView, detail])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pairButton = host.sidebarRowIconButton(
            symbol: "iphone.radiowaves.left.and.right", tooltip: "Pair iPhone or iPad with \(device.displayName)",
            action: #selector(AppKitController.pairIOSWithConnectedDevice(_:)))
        pairButton.identifier = NSUserInterfaceItemIdentifier(device.id)
        pairButton.isEnabled = device.isAvailable

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(pairButton)
        if !device.isLocal {
            let removeButton = host.sidebarRowIconButton(
                symbol: "xmark.circle", tooltip: "Remove this device", action: #selector(AppKitController.removeMacPairedDevice(_:)))
            removeButton.identifier = NSUserInterfaceItemIdentifier(device.id)
            row.addArrangedSubview(removeButton)

            let menu = NSMenu()
            let renameItem = NSMenuItem(title: "Rename", action: #selector(AppKitController.beginClientDeviceRename(_:)), keyEquivalent: "")
            renameItem.target = host
            renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            renameItem.identifier = NSUserInterfaceItemIdentifier(device.id)
            menu.addItem(renameItem)
            row.menu = menu
        }
        return row
    }

    private func devicePairingInstructionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func mobileQRCodeView(link: String) -> NSView {
        let qrSize: CGFloat = 200
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let qrView = NSImageView()
        qrView.image = qrImage(for: link, size: qrSize)
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.wantsLayer = true
        qrView.layer?.backgroundColor = NSColor.white.cgColor
        qrView.layer?.cornerRadius = 4
        qrView.layer?.masksToBounds = true
        container.addSubview(qrView)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: qrSize), qrView.widthAnchor.constraint(equalToConstant: qrSize),
            qrView.heightAnchor.constraint(equalToConstant: qrSize), qrView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            qrView.topAnchor.constraint(equalTo: container.topAnchor), qrView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func remoteDevicePairingSection() -> NSView {
        var rows: [NSView] = []
        rows.append(
            devicePairingInstructionLabel(
                "Enter the SSH details for a Mac or Linux device. Install Spaces on the device first: the Spaces app on a Mac, or the Spaces installer on Ubuntu 24.04."
            ))

        let sshHostField = NSTextField()
        sshHostField.placeholderString = "SSH host"
        sshHostField.setAccessibilityIdentifier("remote-device-ssh-host")
        sshHostField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        remoteDeviceSSHHostField = sshHostField
        rows.append(sshHostField)

        // Optional display name for the paired device; when left blank the daemon-reported name is used.
        let nameField = NSTextField()
        nameField.placeholderString = "Name (optional)"
        nameField.setAccessibilityIdentifier("remote-device-name")
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        remoteDeviceNameField = nameField
        rows.append(nameField)

        // Username and port are optional (they default to the SSH login and port 22), so they live
        // behind a collapsed "Advanced" disclosure to keep the common case a single host field.
        let advancedToggle = NSButton(title: "Advanced", target: host, action: #selector(AppKitController.toggleRemoteDeviceAdvancedFields(_:)))
        advancedToggle.isBordered = false
        advancedToggle.bezelStyle = .inline
        advancedToggle.setButtonType(.momentaryChange)
        advancedToggle.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Advanced")
        advancedToggle.imagePosition = .imageLeading
        advancedToggle.imageHugsTitle = true
        advancedToggle.font = .systemFont(ofSize: 12, weight: .medium)
        advancedToggle.contentTintColor = .secondaryLabelColor
        advancedToggle.toolTip = "Optional SSH username and port"
        advancedToggle.setAccessibilityIdentifier("remote-device-advanced-toggle")
        remoteDeviceAdvancedToggle = advancedToggle
        rows.append(mobilePanelButtonRow([advancedToggle]))

        let sshUserField = NSTextField()
        sshUserField.placeholderString = "username (defaults to SSH login)"
        sshUserField.setAccessibilityIdentifier("remote-device-ssh-user")
        remoteDeviceSSHUserField = sshUserField

        let sshPortField = NSTextField()
        sshPortField.placeholderString = "port (22)"
        sshPortField.setAccessibilityIdentifier("remote-device-ssh-port")
        remoteDeviceSSHPortField = sshPortField

        let advancedRow = NSStackView(views: [sshUserField, sshPortField])
        advancedRow.orientation = .horizontal
        advancedRow.alignment = .centerY
        advancedRow.spacing = 8
        advancedRow.translatesAutoresizingMaskIntoConstraints = false
        sshUserField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        sshPortField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        advancedRow.isHidden = true
        remoteDeviceAdvancedRow = advancedRow
        rows.append(advancedRow)

        let connectButton = host.actionButton(
            title: "Connect Remote Device", symbol: "link", tooltip: "Connect this Mac with another device over SSH",
            action: #selector(AppKitController.connectRemoteDeviceFromPairingPanel), primary: true)
        connectButton.isEnabled = !isInstallingRemoteSpaces
        remoteDeviceConnectButton = connectButton
        rows.append(mobilePanelButtonRow([connectButton]))

        let statusLabel = host.helpTextLabel("")
        statusLabel.isHidden = true
        remoteDevicePairingStatusLabel = statusLabel
        rows.append(statusLabel)

        rows.append(remoteDeviceInstallSection())

        return mobilePanelSection(icon: "link.badge.plus", title: "Add Remote Device", rows: rows)
    }

    /// The recovery block shown after a pairing attempt reports Spaces is missing on a Linux device: the
    /// pinned install one-liner (copyable) plus a button to run it over SSH and pair. Visibility and content
    /// derive from `remoteDeviceLinuxInstallCommand`/`isInstallingRemoteSpaces` so a panel rebuild restores
    /// the block exactly; the flows also toggle the retained views directly to avoid a status-wiping re-render.
    private func remoteDeviceInstallSection() -> NSView {
        let commandField = NSTextField(labelWithString: remoteDeviceLinuxInstallCommand ?? "")
        commandField.isSelectable = true
        commandField.isEditable = false
        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.lineBreakMode = .byCharWrapping
        commandField.maximumNumberOfLines = 0
        commandField.setAccessibilityIdentifier("remote-device-install-command")
        commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remoteDeviceInstallCommandField = commandField

        let copyButton = host.sidebarRowIconButton(
            symbol: "doc.on.doc", tooltip: "Copy install command", action: #selector(AppKitController.copyRemoteDeviceInstallCommand))
        copyButton.setAccessibilityIdentifier("remote-device-install-command-copy")

        let commandRow = NSStackView(views: [commandField, copyButton])
        commandRow.orientation = .horizontal
        commandRow.alignment = .top
        commandRow.spacing = 8

        let installButton = host.actionButton(
            title: "Install Spaces over SSH", symbol: "arrow.down.circle", tooltip: "Run the installer on the remote device over SSH, then pair",
            action: #selector(AppKitController.installSpacesOnRemoteDevice), primary: false)
        installButton.isEnabled = !isInstallingRemoteSpaces
        installButton.setAccessibilityIdentifier("remote-device-install-ssh")
        remoteDeviceInstallButton = installButton

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = !isInstallingRemoteSpaces
        if isInstallingRemoteSpaces { spinner.startAnimation(nil) }
        remoteDeviceInstallSpinner = spinner

        let actionRow = mobilePanelButtonRow([installButton])
        if let actionStack = actionRow as? NSStackView { actionStack.insertArrangedSubview(spinner, at: 1) }

        let block = NSStackView(views: [commandRow, actionRow])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 8
        commandRow.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        actionRow.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        block.isHidden = remoteDeviceLinuxInstallCommand == nil
        remoteDeviceInstallBlock = block
        return block
    }

    /// Expands or collapses the optional username/port fields and rotates the disclosure chevron.
    func toggleRemoteDeviceAdvancedFields(_ sender: NSButton) {
        guard let advancedRow = remoteDeviceAdvancedRow else { return }
        let willExpand = advancedRow.isHidden
        advancedRow.isHidden = !willExpand
        let symbol = willExpand ? "chevron.down" : "chevron.right"
        sender.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Advanced")
    }

    private func mobilePanelSection(icon: String, title: String, rows: [NSView]) -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setContentHuggingPriority(.required, for: .vertical)

        let accentColor = host.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let iconView = NSImageView()
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            iconView.image = image.withSymbolConfiguration(.init(paletteColors: [accentColor]))
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        header.addArrangedSubview(iconView)
        header.addArrangedSubview(titleLabel)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if !rows.isEmpty { stack.addArrangedSubview(mobilePanelDivider()) }
        for row in rows {
            let paddedRow = mobilePanelPaddedRow(row)
            stack.addArrangedSubview(paddedRow)
            paddedRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        section.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: section.leadingAnchor), stack.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            stack.topAnchor.constraint(equalTo: section.topAnchor), stack.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])
        return section
    }

    private func mobilePanelPaddedRow(_ view: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9),
        ])
        return container
    }

    private func mobilePanelDivider(indent: CGFloat = 0) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        bindAppearanceReactiveLayer(divider) { view in view.layer?.backgroundColor = Theme.border.cgColor }
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 1),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -indent),
            divider.topAnchor.constraint(equalTo: container.topAnchor), divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func mobilePanelButtonRow(_ buttons: [NSButton]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        for button in buttons {
            button.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    func openDevicePairingWindow() {
        do {
            let response = try SpacesDeviceAPIControlClient.openPairingWindowEnsuringCurrentTerminalService()
            if let window = response.pairingWindow {
                currentDevicePairingWindow = ClientDevicePairingWindow(
                    deviceID: SpacesPairedDeviceRecord.localDeviceID, deviceName: response.status?.bonjourServiceName ?? "This Mac",
                    linkString: window.linkString, expiresAt: window.expiresAt)
            }
            devicePanelStatusMessage = nil
            showDeviceSettings(response)
        } catch {
            if let unavailableResponse = Self.deviceAPIDisabledOverrideResponse(for: error) {
                showDeviceSettings(unavailableResponse)
            } else {
                host.showError(error)
            }
        }
    }

    func pairIOSWithConnectedDevice(_ sender: NSButton) {
        guard let deviceID = sender.identifier?.rawValue else { return }
        if deviceID == SpacesPairedDeviceRecord.localDeviceID {
            openDevicePairingWindow()
            return
        }
        guard let device = host.macPairedDevices().first(where: { $0.id == deviceID }) else { return }
        devicePanelStatusMessage = (message: "Opening pairing window on \(device.name)...", isError: false)
        refreshVisibleDeviceSettingsAfterClientDeviceChange()
        Task { [weak self] in
            do {
                let appVersion = AppVersion.short
                let profile = try? SpacesProfile.current()
                let result = try await Task.detached(priority: .userInitiated) {
                    try SpacesDevicePairingClient.openRemotePairingWindow(for: device, appVersion: appVersion, profile: profile)
                }.value
                let expiresAt = result.expiresAt.flatMap { Self.iso8601Formatter.date(from: $0) } ?? Date().addingTimeInterval(300)
                self?.currentDevicePairingWindow = ClientDevicePairingWindow(
                    deviceID: device.id, deviceName: result.name, linkString: result.linkString, expiresAt: expiresAt)
                self?.devicePanelStatusMessage = nil
                self?.refreshVisibleDeviceSettingsAfterClientDeviceChange()
            } catch {
                self?.devicePanelStatusMessage = (message: error.localizedDescription, isError: true)
                self?.refreshVisibleDeviceSettingsAfterClientDeviceChange()
            }
        }
    }

    func connectRemoteDeviceFromPairingPanel() {
        // Each attempt starts from a clean recovery state: hide any install block left from a prior failure
        // so it only reappears if this attempt again finds Spaces missing.
        remoteDeviceLinuxInstallCommand = nil
        remoteDeviceInstallBlock?.isHidden = true
        let sshHostText = remoteDeviceSSHHostField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nameText = remoteDeviceNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sshUserText = remoteDeviceSSHUserField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sshPortText = remoteDeviceSSHPortField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.usespaces.spaces"
        let deviceName = Host.current().localizedName ?? "Mac"
        let appVersion = AppVersion.short
        setRemoteDevicePairingStatus("Validating SSH and preparing the remote device...", isError: false)
        Task { [weak self] in
            do {
                let sshPort = try Self.parsedSSHPort(sshPortText)
                let profile = try? SpacesProfile.current()
                let clientInstallationID = SpacesDevicePairingClient.localMacClientInstallationID(profile: profile)
                let result = try await Task.detached(priority: .userInitiated) {
                    try SpacesDevicePairingClient.pairRemoteDevice(
                        SpacesRemoteDevicePairingRequest(
                            sshHost: sshHostText, sshUser: Self.normalizedPanelField(sshUserText), sshPort: sshPort,
                            clientInstallationID: clientInstallationID, clientBundleID: bundleID, clientDeviceName: deviceName,
                            clientAppVersion: appVersion, customName: Self.normalizedPanelField(nameText), profile: profile))
                }.value
                self?.setRemoteDevicePairingStatus("Connected \(result.name).", isError: false)
                self?.refreshVisibleDeviceSettingsAfterClientDeviceChange()
                self?.host.requestSidebarReload()
            } catch {
                guard let self else { return }
                // A Linux device without Spaces installed carries the pinned install one-liner: surface the
                // recovery block so the user can install over SSH (or copy the command) instead of only an error.
                if case SpacesRemoteDevicePairingError.remoteSpacesNotInstalled(let message, let linuxInstallCommand) = error,
                    let command = linuxInstallCommand
                {
                    self.remoteDeviceLinuxInstallCommand = command
                    self.remoteDeviceInstallCommandField?.stringValue = command
                    self.remoteDeviceInstallBlock?.isHidden = false
                    self.setRemoteDevicePairingStatus(message, isError: true)
                } else {
                    self.remoteDeviceLinuxInstallCommand = nil
                    self.remoteDeviceInstallBlock?.isHidden = true
                    self.setRemoteDevicePairingStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    /// Runs the pinned Linux installer on the remote host over SSH (up to ten minutes) and then pairs, the
    /// recovery for a pairing attempt that reported Spaces missing. Reads and validates the SSH fields exactly
    /// like `connectRemoteDeviceFromPairingPanel`. While it runs, the install and Connect buttons are disabled
    /// and the spinner spins; on success the block is cleared and the Devices pane refreshes like the connect
    /// success path, and on failure the block stays so the command remains copyable.
    func installSpacesOnRemoteDevice() {
        guard !isInstallingRemoteSpaces else { return }
        let sshHostText = remoteDeviceSSHHostField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nameText = remoteDeviceNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sshUserText = remoteDeviceSSHUserField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sshPortText = remoteDeviceSSHPortField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.usespaces.spaces"
        let deviceName = Host.current().localizedName ?? "Mac"
        let appVersion = AppVersion.short
        isInstallingRemoteSpaces = true
        remoteDeviceInstallButton?.isEnabled = false
        remoteDeviceConnectButton?.isEnabled = false
        remoteDeviceInstallSpinner?.isHidden = false
        remoteDeviceInstallSpinner?.startAnimation(nil)
        setRemoteDevicePairingStatus("Installing Spaces on \(sshHostText)... This can take a few minutes.", isError: false)
        Task { [weak self] in
            do {
                let sshPort = try Self.parsedSSHPort(sshPortText)
                let profile = try? SpacesProfile.current()
                let clientInstallationID = SpacesDevicePairingClient.localMacClientInstallationID(profile: profile)
                let result = try await Task.detached(priority: .userInitiated) {
                    try SpacesDevicePairingClient.installSpacesOnRemoteDeviceAndPair(
                        SpacesRemoteDevicePairingRequest(
                            sshHost: sshHostText, sshUser: Self.normalizedPanelField(sshUserText), sshPort: sshPort,
                            clientInstallationID: clientInstallationID, clientBundleID: bundleID, clientDeviceName: deviceName,
                            clientAppVersion: appVersion, customName: Self.normalizedPanelField(nameText), profile: profile))
                }.value
                guard let self else { return }
                self.isInstallingRemoteSpaces = false
                self.remoteDeviceLinuxInstallCommand = nil
                self.remoteDeviceInstallSpinner?.stopAnimation(nil)
                self.remoteDeviceInstallBlock?.isHidden = true
                self.setRemoteDevicePairingStatus("Connected \(result.name).", isError: false)
                self.refreshVisibleDeviceSettingsAfterClientDeviceChange()
                self.host.requestSidebarReload()
            } catch {
                guard let self else { return }
                self.isInstallingRemoteSpaces = false
                self.remoteDeviceInstallSpinner?.stopAnimation(nil)
                self.remoteDeviceInstallSpinner?.isHidden = true
                self.remoteDeviceInstallButton?.isEnabled = true
                self.remoteDeviceConnectButton?.isEnabled = true
                self.setRemoteDevicePairingStatus(error.localizedDescription, isError: true)
            }
        }
    }

    /// Copies the pinned install one-liner to the pasteboard. Inlined because `AppKitController.copyToPasteboard`
    /// is private and this is the only device-panel copy site.
    func copyRemoteDeviceInstallCommand() {
        guard let command = remoteDeviceLinuxInstallCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Relaunches the local `spacesd` daemon after it failed to start. This is the only local-daemon
    /// restart entry point. It calls `TerminalService.relaunch` directly (stop-then-start) rather than
    /// the `requestDaemonRestart` RPC, because a crashed daemon has no reachable control endpoint to
    /// receive that RPC — a stop-then-start relaunch cannot use the exec-in-place handoff either, since
    /// there is no live daemon process to quiesce sessions and hand off from. On completion it re-renders
    /// the Devices pane against an authoritative status and reloads the sidebar so the "This Mac" offline
    /// caption clears.
    ///
    /// The Device API control endpoint can be down while the terminal service still holds live sessions
    /// (`responseEnsuringCurrentTerminalService` deliberately returns the not-running response instead of
    /// relaunching in that case, to avoid killing them). Unlike a daemon-update handoff, this relaunch
    /// really does stop the daemon and every live session, so it warns before proceeding whenever any
    /// session is live. Liveness is read from the terminal service's own session list, the same signal
    /// that protective path keys off; the Device API status is unreachable here, so the warning cannot
    /// give a precise breakdown. When nothing is live (the daemon is fully down) the relaunch proceeds
    /// with no prompt.
    func restartLocalDaemon() {
        Task { @MainActor [weak self] in
            guard let self, !self.isRelaunchingLocalDaemon else { return }
            let hasLiveSessions = await Task.detached(priority: .userInitiated) { !((try? TerminalService.listSessions()) ?? []).isEmpty }.value
            guard !self.isRelaunchingLocalDaemon else { return }
            if hasLiveSessions {
                let alert = NSAlert()
                alert.messageText = "Restart the local daemon?"
                alert.informativeText = "This will stop all running terminals, processes, and coding agents on this device."
                alert.addButton(withTitle: "Restart")
                alert.addButton(withTitle: "Defer")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            self.performLocalDaemonRelaunch()
        }
    }

    private func performLocalDaemonRelaunch() {
        // Mark the relaunch in progress before rendering: the placeholder below is also `ok: false`, so
        // without this the pane would re-render an active Restart Local Daemon button and a second click
        // could start a concurrent relaunch against the same daemon (localDaemonRestartActionIsAvailable
        // suppresses the button while this is set).
        isRelaunchingLocalDaemon = true
        devicePanelStatusMessage = (message: "Restarting the local daemon…", isError: false)
        // The daemon is down, so render the in-progress banner from a placeholder response rather than a
        // live status query (which would just time out again).
        renderDeviceSettings(response: SpacesDeviceAPIControlResponse(ok: false, message: "Restarting the local daemon…"))
        Task { [weak self] in
            let response = await Task.detached(priority: .userInitiated) { () -> SpacesDeviceAPIControlResponse in
                do { _ = try TerminalService.relaunch() } catch { return DevicePairingController.controlResponse(forThrownError: error) }
                do { return try SpacesDeviceAPIControlClient.statusEnsuringCurrentTerminalService() } catch {
                    return DevicePairingController.controlResponse(forThrownError: error)
                }
            }.value
            guard let self else { return }
            self.isRelaunchingLocalDaemon = false
            self.devicePanelStatusMessage = nil
            self.refreshVisibleDeviceSettings(response)
            self.host.requestSidebarReload(forceRemoteRefresh: true)
        }
    }

    func removeMacPairedDevice(_ sender: NSButton) {
        guard let deviceID = sender.identifier?.rawValue else { return }
        let deviceName = host.macPairedDevices().first(where: { $0.id == deviceID })?.name ?? "this device"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(deviceName)?"
        alert.informativeText = "Spaces will disconnect from this device and forget its pairing. You can pair it again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let database = try host.clientDatabase()
            try database.deletePairedDevice(id: deviceID)
            try SpacesDeviceCredentialStore.deleteToken(deviceID: deviceID)
            refreshVisibleDeviceSettingsAfterClientDeviceChange()
            host.requestSidebarReload()
        } catch { host.showError(error) }
    }

    func beginClientDeviceRename(_ sender: NSMenuItem) {
        guard let deviceID = sender.identifier?.rawValue else { return }
        renamingClientDeviceID = deviceID
        refreshVisibleDeviceSettingsAfterClientDeviceChange()
    }

    func cancelClientDeviceRename() {
        guard renamingClientDeviceID != nil else { return }
        renamingClientDeviceID = nil
        renamingClientDeviceField = nil
        refreshVisibleDeviceSettingsAfterClientDeviceChange()
    }

    func commitClientDeviceRename(deviceID: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingClientDeviceID = nil
        renamingClientDeviceField = nil
        do {
            let database = try host.clientDatabase()
            if !trimmed.isEmpty, var record = try database.pairedDevices().first(where: { $0.id == deviceID }), record.name != trimmed {
                record.name = trimmed
                record.updatedAt = Self.iso8601Formatter.string(from: Date())
                try database.upsert(device: record)
                host.requestSidebarReload()
            }
            refreshVisibleDeviceSettingsAfterClientDeviceChange()
        } catch { host.showError(error) }
    }

    private func setRemoteDevicePairingStatus(_ message: String, isError: Bool) {
        guard let label = remoteDevicePairingStatusLabel else { return }
        label.stringValue = message
        label.textColor = isError ? .systemRed : .secondaryLabelColor
        label.isHidden = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshVisibleDeviceSettingsAfterClientDeviceChange() {
        do { refreshVisibleDeviceSettings(try SpacesDeviceAPIControlClient.status(timeout: 1)) } catch {}
    }

    private func connectedClientDevices(localStatus: SpacesDeviceAPIStatus? = nil, requireLocalStatus: Bool = false) -> [ClientConnectedDevice] {
        let localHost = localStatus?.networkAddresses.first ?? localStatus?.host
        let local = ClientConnectedDevice(
            id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", host: localHost, port: localStatus?.port, sshHost: nil, sshUser: nil,
            sshPort: nil, isLocal: true, isAvailable: !requireLocalStatus || localStatus != nil, requiresReconnect: false)
        let remote = host.macPairedDevices().map {
            let hasCredentials = AppKitController.pairedDeviceHasRequiredCredentials(device: $0)
            return ClientConnectedDevice(
                id: $0.id, name: $0.name, host: $0.host, port: $0.port, sshHost: $0.sshHost, sshUser: $0.sshUser, sshPort: $0.sshPort, isLocal: false,
                isAvailable: hasCredentials, requiresReconnect: !hasCredentials)
        }
        return [local] + remote
    }

    private func clientDeviceDetailText(_ device: ClientConnectedDevice) -> String {
        var parts: [String] = []
        if device.requiresReconnect { parts.append("Reconnect required") }
        if let host = device.host, let port = device.port {
            parts.append("\(host):\(port)")
        } else if device.isLocal {
            parts.append(device.isAvailable ? "Local daemon" : "Local daemon unavailable")
        }
        if let sshHost = device.sshHost {
            let userPrefix = device.sshUser.map { "\($0)@" } ?? ""
            let portSuffix = device.sshPort.map { ":\($0)" } ?? ""
            parts.append("ssh: \(userPrefix)\(sshHost)\(portSuffix)")
        }
        return parts.joined(separator: "  ")
    }

    private func qrImage(for value: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(value.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let quietZone: CGFloat = 16
        let availableSize = max(size - (quietZone * 2), 1)
        let scale = max(floor(availableSize / output.extent.width), 1)
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(transformed, from: transformed.extent) else { return nil }
        let qrSize = transformed.extent.size
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cgImage, size: qrSize).draw(
            in: NSRect(x: (size - qrSize.width) / 2, y: (size - qrSize.height) / 2, width: qrSize.width, height: qrSize.height),
            from: NSRect(origin: .zero, size: qrSize), operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }

    nonisolated private static func normalizedPanelField(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func parsedSSHPort(_ value: String) throws -> Int? {
        guard let normalized = normalizedPanelField(value) else { return nil }
        guard let port = Int(normalized), (1...65_535).contains(port) else {
            throw WorkspaceError.invalidArgument(message: "SSH port must be between 1 and 65535.")
        }
        return port
    }
}

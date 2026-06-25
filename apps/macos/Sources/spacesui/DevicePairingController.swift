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
@MainActor
final class DevicePairingController {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
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
    }

    private struct ClientDevicePairingWindow {
        let deviceID: String
        let deviceName: String
        let linkString: String
        let expiresAt: Date

        var isVisible: Bool { expiresAt > Date() }
    }

    private weak var remoteDeviceSSHHostField: NSTextField?
    private weak var remoteDeviceSSHUserField: NSTextField?
    private weak var remoteDeviceSSHPortField: NSTextField?
    private weak var remoteDevicePairingStatusLabel: NSTextField?
    private var currentDevicePairingWindow: ClientDevicePairingWindow?
    private var devicePanelStatusMessage: (message: String, isError: Bool)?
    var renamingClientDeviceID: String?
    weak var renamingClientDeviceField: NSTextField?

    func showMobileConnection() {
        devicePanelStatusMessage = nil
        host.settings.openSettings(section: .devices)
    }

    private func mobileConnectionUnavailableResponse(for error: Error) -> SpacesDeviceAPIControlResponse? {
        guard SpacesDeviceAPIControlClient.isControlEndpointUnavailable(error) else { return nil }
        return SpacesDeviceAPIControlResponse(
            ok: false,
            message: "Device API control is unavailable for this profile. Relaunch Spaces without the disabled Device API environment override.")
    }

    func currentDeviceControlResponse() -> SpacesDeviceAPIControlResponse {
        do { return try SpacesDeviceAPIControlClient.statusEnsuringCurrentTerminalService() } catch {
            if let unavailableResponse = mobileConnectionUnavailableResponse(for: error) { return unavailableResponse }
            return SpacesDeviceAPIControlResponse(ok: false, message: error.localizedDescription)
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
        return mobilePanelSection(icon: "qrcode", title: "Pair iPhone or iPad", rows: rows)
    }

    private func connectedDevicesSection(response: SpacesDeviceAPIControlResponse) -> NSView {
        var rows: [NSView] = []
        let devices = connectedClientDevices(localStatus: response.status, requireLocalStatus: true)
        rows.append(contentsOf: devices.map(connectedDeviceRow(_:)))
        if !response.ok { rows.append(host.helpTextLabel(response.message)) }
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
            let title = NSTextField(labelWithString: device.name)
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
            symbol: "iphone.radiowaves.left.and.right", tooltip: "Pair iPhone or iPad with \(device.name)",
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
                "Enter the SSH details for a Mac or Linux device. Macs need the Spaces app installed first. Linux is set up automatically over SSH."))

        let sshHostField = NSTextField()
        sshHostField.placeholderString = "SSH host"
        sshHostField.setAccessibilityIdentifier("remote-device-ssh-host")
        remoteDeviceSSHHostField = sshHostField

        let sshUserField = NSTextField()
        sshUserField.placeholderString = "username"
        sshUserField.setAccessibilityIdentifier("remote-device-ssh-user")
        remoteDeviceSSHUserField = sshUserField

        let sshPortField = NSTextField()
        sshPortField.placeholderString = "port"
        sshPortField.setAccessibilityIdentifier("remote-device-ssh-port")
        remoteDeviceSSHPortField = sshPortField

        let sshRow = NSStackView(views: [sshHostField, sshUserField, sshPortField])
        sshRow.orientation = .horizontal
        sshRow.alignment = .centerY
        sshRow.spacing = 8
        sshRow.translatesAutoresizingMaskIntoConstraints = false
        sshHostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        sshUserField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        sshPortField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        rows.append(sshRow)

        let connectButton = host.actionButton(
            title: "Connect Remote Device", symbol: "link", tooltip: "Connect this Mac with another device over SSH",
            action: #selector(AppKitController.connectRemoteDeviceFromPairingPanel), primary: true)
        rows.append(mobilePanelButtonRow([connectButton]))

        let statusLabel = host.helpTextLabel("")
        statusLabel.isHidden = true
        remoteDevicePairingStatusLabel = statusLabel
        rows.append(statusLabel)

        return mobilePanelSection(icon: "link.badge.plus", title: "Add Remote Device", rows: rows)
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
        divider.layer?.backgroundColor = Theme.border.cgColor
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
            if let unavailableResponse = mobileConnectionUnavailableResponse(for: error) {
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
                let remoteArtifactPublicKey = AppVersion.remoteArtifactPublicKey
                let result = try await Task.detached(priority: .userInitiated) {
                    try SpacesDevicePairingClient.openRemotePairingWindow(
                        for: device, appVersion: appVersion, remoteArtifactPublicKey: remoteArtifactPublicKey)
                }.value
                let expiresAt = result.expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date().addingTimeInterval(300)
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
        let sshHostText = remoteDeviceSSHHostField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sshUserText = remoteDeviceSSHUserField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sshPortText = remoteDeviceSSHPortField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.usespaces.spaces"
        let deviceName = Host.current().localizedName ?? "Mac"
        let appVersion = AppVersion.short
        let remoteArtifactPublicKey = AppVersion.remoteArtifactPublicKey
        setRemoteDevicePairingStatus("Validating SSH and preparing the remote device...", isError: false)
        Task { [weak self] in
            do {
                let sshPort = try Self.parsedSSHPort(sshPortText)
                let clientInstallationID = SpacesDevicePairingClient.localMacClientInstallationID()
                let result = try await Task.detached(priority: .userInitiated) {
                    try SpacesDevicePairingClient.pairRemoteDevice(
                        SpacesRemoteDevicePairingRequest(
                            sshHost: sshHostText, sshUser: Self.normalizedPanelField(sshUserText), sshPort: sshPort,
                            clientInstallationID: clientInstallationID, clientBundleID: bundleID, clientDeviceName: deviceName,
                            clientAppVersion: appVersion, remoteArtifactPublicKey: remoteArtifactPublicKey))
                }.value
                self?.setRemoteDevicePairingStatus("Connected \(result.name).", isError: false)
                self?.refreshVisibleDeviceSettingsAfterClientDeviceChange()
                self?.host.requestSidebarReload()
            } catch { self?.setRemoteDevicePairingStatus(error.localizedDescription, isError: true) }
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
            try SpacesDeviceCredentialStore.deleteTransportKey(deviceID: deviceID)
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
                record.updatedAt = ISO8601DateFormatter().string(from: Date())
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
            let hasCredentials = AppKitController.pairedDeviceHasRequiredCredentials(deviceID: $0.id)
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

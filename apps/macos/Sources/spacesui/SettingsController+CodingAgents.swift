import AppKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

/// Settings → Coding Agents: lists supported coding agents for the selected device (This Mac or a
/// paired remote), showing whether each is available and has Spaces hooks installed, with an
/// Install/Reinstall action. Status and installs run against the device's daemon over the Device API,
/// so the same UI manages local and remote hooks.
extension SettingsController {
    func renderCodingAgentsSection() {
        renderSettingsCards([codingAgentsCard()])
        reloadCodingAgentsStatus()
    }

    private func codingAgentsCard() -> NSView {
        let devices = codingAgentsDevices()
        if !devices.contains(where: { $0.record.id == codingAgentsDeviceID }) {
            codingAgentsDeviceID = devices.first?.record.id ?? SpacesPairedDeviceRecord.localDeviceID
        }

        let picker = NSPopUpButton()
        for device in devices {
            picker.addItem(withTitle: device.label)
            picker.itemArray.last?.representedObject = device.record.id
        }
        picker.selectItem(at: devices.firstIndex { $0.record.id == codingAgentsDeviceID } ?? 0)
        picker.target = self
        picker.action = #selector(codingAgentsDeviceChanged(_:))
        picker.setAccessibilityIdentifier("settings-coding-agents-device")
        let deviceField = host.settingsLabeledField(name: "Device", hint: "Install hooks on this machine's coding agents.", control: picker)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        codingAgentsRowsContainer = rows
        renderCodingAgentsRows(message: nil, isLoading: true)

        let hint = host.helpTextLabel(
            "Hooks let each agent report when it starts, is working, is blocked on you, or finishes. Reinstall after updating an agent.")

        return host.formSectionCard(
            icon: "chevron.left.forwardslash.chevron.right", title: "Coding Agents",
            subtitle: "Auto-installed on this Mac and whenever a device connects; install here for agents you add later.",
            contentViews: [deviceField, rows, hint])
    }

    // MARK: - Device selection

    /// This Mac plus every paired remote, as (record, display label) pairs.
    private func codingAgentsDevices() -> [(record: SpacesPairedDeviceRecord, label: String)] {
        var devices: [(SpacesPairedDeviceRecord, String)] = []
        if let local = try? host.clientDatabase().pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID) {
            devices.append((local, "This Mac"))
        }
        for remote in host.macPairedDevices() { devices.append((remote, remote.name)) }
        return devices
    }

    private func resolvedCodingAgentsDevice() -> SpacesPairedDeviceRecord? {
        codingAgentsDevices().first { $0.record.id == codingAgentsDeviceID }?.record
    }

    @objc func codingAgentsDeviceChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String, id != codingAgentsDeviceID else { return }
        codingAgentsDeviceID = id
        codingAgentsStatus = []
        codingAgentsInstallingKind = nil
        reloadCodingAgentsStatus()
    }

    // MARK: - Status fetch

    func reloadCodingAgentsStatus() {
        codingAgentsReloadToken += 1
        let token = codingAgentsReloadToken
        guard let device = resolvedCodingAgentsDevice() else {
            renderCodingAgentsRows(message: "This device is unavailable.", isLoading: false)
            return
        }
        codingAgentsStatus = []
        renderCodingAgentsRows(message: nil, isLoading: true)
        let profile = try? SpacesProfile.current()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SpacesDeviceClient.agentHooksStatus(device: device, profile: profile) }
            await self?.applyCodingAgentsStatusFetch(result, token: token)
        }
    }

    private func applyCodingAgentsStatusFetch(_ result: Result<[AgentHookStatus], any Error>, token: Int) {
        guard token == codingAgentsReloadToken else { return }  // a newer reload superseded this fetch
        switch result {
        case .success(let status):
            codingAgentsStatus = status
            renderCodingAgentsRows(message: nil, isLoading: false)
        case .failure(let error):
            codingAgentsStatus = []
            renderCodingAgentsRows(message: "Could not reach this device: \(error.localizedDescription)", isLoading: false)
        }
    }

    // MARK: - Rows

    private func renderCodingAgentsRows(message: String?, isLoading: Bool) {
        guard let container = codingAgentsRowsContainer else { return }
        for view in container.arrangedSubviews {
            container.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let canInstall = resolvedCodingAgentsDevice() != nil && !isLoading && codingAgentsInstallingKind == nil
        for (index, kind) in SupportedCodingAgentHook.allCases.enumerated() {
            let status = codingAgentsStatus.first { $0.kind == kind }
            let row = codingAgentRow(kind: kind, status: status, index: index, isLoading: isLoading, canInstall: canInstall)
            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
        if let message {
            let label = host.helpTextLabel(message)
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
    }

    private func codingAgentRow(kind: SupportedCodingAgentHook, status: AgentHookStatus?, index: Int, isLoading: Bool, canInstall: Bool) -> NSView {
        let available = status?.available ?? false
        let installed = status?.hooksInstalled ?? false

        let tile = RowPrimitives.typeTextTile(.agent, text: kind.tileText, accessibilityLabel: kind.displayName)

        let name = NSTextField(labelWithString: kind.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)

        let captionText: String
        if isLoading {
            captionText = "Checking availability and hooks"
        } else if let status {
            if status.available && status.hooksInstalled {
                captionText = "Detected, hooks installed"
            } else if status.available {
                captionText = "Detected, hooks not installed"
            } else if status.hooksInstalled {
                captionText = "Not detected, hooks installed"
            } else {
                captionText = "Not detected, hooks not installed"
            }
        } else if installed {
            captionText = "Status unavailable, hooks installed"
        } else {
            captionText = "Status unavailable"
        }
        let caption = NSTextField(labelWithString: captionText)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let labelStack = NSStackView(views: [name, caption])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusDotKind: RowPrimitives.StatusKind = installed ? .running : (available ? .waiting : .idle)
        var rowViews: [NSView] = [statusDotSlot(kind: statusDotKind), tile, labelStack, NSView()]
        if available {
            let isInstalling = codingAgentsInstallingKind == kind
            let button = NSButton(
                title: isInstalling ? "Installing..." : (installed ? "Reinstall" : "Install"), target: self,
                action: #selector(installCodingAgentHooks(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = index
            button.isEnabled = canInstall
            button.setAccessibilityIdentifier("settings-coding-agents-install-\(kind.rawValue)")
            rowViews.append(button)
        }

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("settings-coding-agents-row-\(kind.rawValue)")
        return row
    }

    private func statusDotSlot(kind: RowPrimitives.StatusKind) -> NSView {
        RowPrimitives.statusSlot(RowPrimitives.statusDot(kind))
    }

    // MARK: - Install

    @objc func installCodingAgentHooks(_ sender: NSButton) {
        guard codingAgentsInstallingKind == nil else { return }
        let kinds = SupportedCodingAgentHook.allCases
        guard kinds.indices.contains(sender.tag), let device = resolvedCodingAgentsDevice() else { return }
        let kind = kinds[sender.tag]
        codingAgentsReloadToken += 1
        codingAgentsInstallToken += 1
        let token = codingAgentsInstallToken
        let deviceID = device.id
        codingAgentsInstallingKind = kind
        renderCodingAgentsRows(message: nil, isLoading: false)
        let profile = try? SpacesProfile.current()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SpacesDeviceClient.installAgentHooks([kind], device: device, profile: profile) }
            await self?.applyCodingAgentsInstall(result, token: token, deviceID: deviceID)
        }
    }

    private func applyCodingAgentsInstall(_ result: Result<[AgentHookStatus], any Error>, token: Int, deviceID: String) {
        guard token == codingAgentsInstallToken, deviceID == codingAgentsDeviceID else { return }
        codingAgentsInstallingKind = nil
        switch result {
        case .success(let status):
            codingAgentsStatus = status
            renderCodingAgentsRows(message: nil, isLoading: false)
        case .failure(let error):
            renderCodingAgentsRows(message: "Install failed: \(error.localizedDescription)", isLoading: false)
        }
    }
}

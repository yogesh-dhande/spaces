import AppKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

/// The shared form/database helpers `CodingAgentsView` needs from its host.
///
/// `AppKitController` supplies all of them, but the view is embedded in the launch setup flow as well
/// as in Settings, and the setup screen runs before the main window content exists. Depending on the
/// narrow protocol instead of the controller keeps that ordering from mattering, and keeps the view
/// testable without an app.
@MainActor protocol CodingAgentsHost: AnyObject {
    func formSectionCard(icon: String?, title: String, subtitle: String, iconColor: NSColor?, trailingView: NSView?, contentViews: [NSView]) -> NSView
    func settingsLabeledField(name: String, hint: String, control: NSView) -> NSView
    func helpTextLabel(_ text: String) -> NSTextField
    func clientDatabase() throws -> SpacesClientDatabase
    func macPairedDevices() -> [SpacesPairedDeviceRecord]
}

extension AppKitController: CodingAgentsHost {}

/// Lists supported coding agents for a selected device (This Mac or a paired remote), showing whether
/// each agent's CLI is detected and how completely its Spaces hooks are installed, with a per-agent
/// Install / Update / Reinstall action.
///
/// Status and installs run against the selected device's daemon over the Device API, so one view
/// manages local and remote hooks. It is embedded in Settings → Coding Agents and in the launch setup
/// flow's coding-agents step.
///
/// Install failures are held in memory rather than persisted: every install is user-initiated, so the
/// failure is on screen at the moment it happens and cannot outlive the problem it describes.
@MainActor final class CodingAgentsView {
    /// What the local device's agents look like right now, for a setup step that wants to relabel its
    /// button without issuing a second status request.
    struct LocalSummary: Equatable {
        /// Every detected agent on This Mac carries current hooks. False when no agent is detected at
        /// all — there is nothing to have finished installing.
        let allDetectedCurrent: Bool
        /// Some detected agent is missing hooks or carrying an older hook version.
        let hasActionableAgent: Bool
    }

    /// Fires after any status fetch or install that targeted the local device. Remote devices do not
    /// emit: the setup step's gating is deliberately local-only.
    var onLocalStatusChange: ((LocalSummary) -> Void)?

    private unowned let host: any CodingAgentsHost

    private var deviceID: String = SpacesPairedDeviceRecord.localDeviceID
    private weak var rowsContainer: NSStackView?
    private var status: [AgentHookStatus] = []
    /// The failure from the install just run, per agent, so a row that Spaces could not fix explains
    /// itself instead of only reporting "hooks not installed".
    private var failures: [SupportedCodingAgentHook: String] = [:]
    /// Increments per reload so a stale in-flight fetch's result is discarded when the user switches devices.
    private var reloadToken = 0
    /// Increments per install so a stale completion cannot update rows for a different selected device.
    private var installToken = 0
    /// Non-nil while an Install/Update/Reinstall request is in flight.
    private var installingKind: SupportedCodingAgentHook?

    init(host: any CodingAgentsHost, onLocalStatusChange: ((LocalSummary) -> Void)? = nil) {
        self.host = host
        self.onLocalStatusChange = onLocalStatusChange
    }

    /// Every detected agent's state, reduced to what a setup step needs to decide what to say.
    static func localSummary(status: [AgentHookStatus]) -> LocalSummary {
        let detected = status.filter(\.available)
        return LocalSummary(
            allDetectedCurrent: !detected.isEmpty && detected.allSatisfy { $0.installState == .current },
            hasActionableAgent: detected.contains { $0.installState != .current })
    }

    /// Builds the card and starts a status reload for the selected device.
    func makeCard(subtitle: String = "Install Spaces lifecycle hooks on this machine's coding agents.") -> NSView {
        let devices = self.devices()
        if !devices.contains(where: { $0.record.id == deviceID }) { deviceID = devices.first?.record.id ?? SpacesPairedDeviceRecord.localDeviceID }

        let picker = NSPopUpButton()
        for device in devices {
            picker.addItem(withTitle: device.label)
            picker.itemArray.last?.representedObject = device.record.id
        }
        picker.selectItem(at: devices.firstIndex { $0.record.id == deviceID } ?? 0)
        picker.target = self
        picker.action = #selector(deviceChanged(_:))
        picker.setAccessibilityIdentifier("settings-coding-agents-device")
        let deviceField = host.settingsLabeledField(name: "Device", hint: "Install hooks on this machine's coding agents.", control: picker)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        rowsContainer = rows
        renderRows(message: nil, isLoading: true)

        let hint = host.helpTextLabel(
            "Hooks let each agent report when it starts, is working, is blocked on you, or finishes. "
                + "Reinstall after moving the Spaces CLI or updating an agent.")

        let card = host.formSectionCard(
            icon: "chevron.left.forwardslash.chevron.right", title: "Coding Agents", subtitle: subtitle, iconColor: nil, trailingView: nil,
            contentViews: [deviceField, rows, hint])
        reload()
        return card
    }

    // MARK: - Device selection

    /// This Mac plus every paired remote, as (record, display label) pairs.
    private func devices() -> [(record: SpacesPairedDeviceRecord, label: String)] {
        var devices: [(SpacesPairedDeviceRecord, String)] = []
        if let local = try? host.clientDatabase().pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID) { devices.append((local, "This Mac")) }
        for remote in host.macPairedDevices() { devices.append((remote, remote.name)) }
        return devices
    }

    private func resolvedDevice() -> SpacesPairedDeviceRecord? { devices().first { $0.record.id == deviceID }?.record }

    private var isLocalDeviceSelected: Bool { deviceID == SpacesPairedDeviceRecord.localDeviceID }

    @objc private func deviceChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String, id != deviceID else { return }
        deviceID = id
        status = []
        failures = [:]
        installingKind = nil
        reload()
    }

    // MARK: - Status fetch

    func reload() {
        reloadToken += 1
        let token = reloadToken
        guard let device = resolvedDevice() else {
            renderRows(message: "This device is unavailable.", isLoading: false)
            return
        }
        status = []
        renderRows(message: nil, isLoading: true)
        let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SpacesDeviceClient.agentHooksStatus(device: device, profile: profile) }
            await self?.applyStatusFetch(result, token: token)
        }
    }

    private func applyStatusFetch(_ result: Result<[AgentHookStatus], any Error>, token: Int) {
        guard token == reloadToken else { return }  // a newer reload superseded this fetch
        switch result {
        case .success(let fetched):
            status = fetched
            renderRows(message: nil, isLoading: false)
        case .failure(let error):
            status = []
            renderRows(message: "Could not reach this device: \(error.localizedDescription)", isLoading: false)
        }
        emitLocalStatusChangeIfLocal()
    }

    private func emitLocalStatusChangeIfLocal() {
        guard isLocalDeviceSelected else { return }
        onLocalStatusChange?(Self.localSummary(status: status))
    }

    // MARK: - Rows

    private func renderRows(message: String?, isLoading: Bool) {
        guard let container = rowsContainer else { return }
        for view in container.arrangedSubviews {
            container.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let canInstall = resolvedDevice() != nil && !isLoading && installingKind == nil
        for (index, kind) in SupportedCodingAgentHook.allCases.enumerated() {
            let row = agentRow(kind: kind, status: status.first { $0.kind == kind }, index: index, isLoading: isLoading, canInstall: canInstall)
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

    private func agentRow(kind: SupportedCodingAgentHook, status: AgentHookStatus?, index: Int, isLoading: Bool, canInstall: Bool) -> NSView {
        let available = status?.available ?? false
        let installState = status?.installState ?? .notInstalled

        let tile = RowPrimitives.typeTextTile(.agent, text: kind.tileText, accessibilityLabel: kind.displayName)

        let name = NSTextField(labelWithString: kind.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)

        // A recorded failure explains a row Spaces just tried and could not fix — most often a
        // `config.toml` only the user can untangle. Once hooks are current the message is stale by
        // definition, so it is never shown then.
        let failureMessage = installState == .current ? nil : failures[kind]
        let caption = NSTextField(labelWithString: captionText(status: status, failureMessage: failureMessage, isLoading: isLoading))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = (failureMessage != nil && !isLoading) ? .systemRed : .secondaryLabelColor
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 3

        let labelStack = NSStackView(views: [name, caption])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var rowViews: [NSView] = [
            RowPrimitives.statusSlot(RowPrimitives.statusDot(statusDotKind(available: available, installState: installState))), tile, labelStack,
            NSView(),
        ]
        if available {
            let isInstalling = installingKind == kind
            let button = NSButton(
                title: isInstalling ? "Installing..." : installActionTitle(installState), target: self, action: #selector(installHooks(_:)))
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

    /// `outdated` reads as "needs attention" exactly like a missing install, because the same click
    /// fixes both; the caption is what tells them apart.
    private func statusDotKind(available: Bool, installState: AgentHookInstallState) -> RowPrimitives.StatusKind {
        switch installState {
        case .current: .running
        case .outdated: .waiting
        case .notInstalled: available ? .waiting : .idle
        }
    }

    private func installActionTitle(_ installState: AgentHookInstallState) -> String {
        switch installState {
        case .current: "Reinstall"
        case .outdated: "Update"
        case .notInstalled: "Install"
        }
    }

    private func captionText(status: AgentHookStatus?, failureMessage: String?, isLoading: Bool) -> String {
        if isLoading { return "Checking availability and hooks" }
        if let failureMessage { return failureMessage }
        guard let status else { return "Status unavailable" }
        let hooks =
            switch status.installState {
            case .current: "hooks installed"
            case .outdated: "hooks out of date"
            case .notInstalled: "hooks not installed"
            }
        return "\(status.available ? "Detected" : "Not detected"), \(hooks)"
    }

    // MARK: - Install

    @objc private func installHooks(_ sender: NSButton) {
        guard installingKind == nil else { return }
        let kinds = SupportedCodingAgentHook.allCases
        guard kinds.indices.contains(sender.tag), let device = resolvedDevice() else { return }
        let kind = kinds[sender.tag]
        reloadToken += 1  // an in-flight status fetch must not overwrite this install's result
        installToken += 1
        let token = installToken
        let targetDeviceID = device.id
        installingKind = kind
        renderRows(message: nil, isLoading: false)
        let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SpacesDeviceClient.installAgentHooks([kind], device: device, profile: profile) }
            await self?.applyInstall(result, token: token, deviceID: targetDeviceID, kind: kind)
        }
    }

    /// An install request can succeed while the agent it targeted fails, so the per-agent failures are
    /// what decide whether the user sees an error.
    private func applyInstall(_ result: Result<AgentHookInstallOutcome, any Error>, token: Int, deviceID: String, kind: SupportedCodingAgentHook) {
        guard token == installToken, deviceID == self.deviceID else { return }
        installingKind = nil
        switch result {
        case .success(let outcome):
            status = outcome.agents
            // Keep this agent's message in step with what just happened, so a row stops explaining a
            // problem the user has since fixed.
            failures[kind] = outcome.failures.first { $0.kind == kind }?.message
            renderRows(message: outcome.failures.first.map { "Install failed: \($0.message)" }, isLoading: false)
        case .failure(let error): renderRows(message: "Install failed: \(error.localizedDescription)", isLoading: false)
        }
        emitLocalStatusChangeIfLocal()
    }
}

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
/// the host's `settings` controller for the window/section/content state. Its own
/// buttons and menu items bind their target to this controller; the device-rename
/// text field uses the host's shared `NSControl` delegate, which routes back into
/// this controller.
@MainActor final class DevicePairingController: NSObject {
    unowned let host: AppKitController
    /// Reads the Mac's paired remote/mobile devices (excluding this Mac). Injected rather than reaching
    /// through `host.macPairedDevices()` so this controller owns its data dependency directly and a test
    /// can substitute a fixed device list.
    private let pairedDevices: () -> [SpacesPairedDeviceRecord]
    /// Opens the per-client desktop-state database paired-device records are read from and persisted to.
    /// Injected rather than reaching through `host.clientDatabase()` so this controller owns its
    /// persistence dependency directly and a test can substitute a throwaway database.
    private let database: () throws -> SpacesClientDatabase

    init(host: AppKitController, pairedDevices: @escaping () -> [SpacesPairedDeviceRecord], database: @escaping () throws -> SpacesClientDatabase) {
        self.host = host
        self.pairedDevices = pairedDevices
        self.database = database
        super.init()
    }

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
        /// Whether this client holds what it needs to talk to the device: a live local daemon for the local
        /// row, a stored credential for a remote one. Gates the row's pairing action, which needs a working
        /// channel to mint a code. Distinct from `status`, which reports whether the device is answering.
        let isAvailable: Bool
        let requiresReconnect: Bool
        let status: DeviceRowStatus

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

    /// Which inline panel the Devices card has open. The card shows at most one at a time: a device
    /// row's iPhone/iPad pairing panel, or the add-remote-device SSH form that ends the list.
    enum DeviceRowExpansion: Equatable, Sendable {
        case pairing(deviceID: String)
        case addRemoteDevice
    }

    /// One entry in the Devices card. A `row` sits on the card surface; an `expandedRow` is the row
    /// whose panel is open and shares the `panel`'s inset surface, so the two read as one block.
    private enum DevicesCardEntry {
        case row(NSView)
        case expandedRow(NSView)
        case panel(NSView)
    }

    /// The single-expansion rule for the Devices card: activating a row's disclosure control opens it and
    /// closes whatever else was open, and activating the control of the row that is already open closes it —
    /// but only while that row's panel is actually on screen. A pairing expansion outlives its panel (the
    /// code expires, or the open returned no window), and a click on such a row must ask for a fresh code
    /// rather than spend itself closing something the user cannot see. Pure so the rule is testable without
    /// building the pane.
    nonisolated static func expansion(after current: DeviceRowExpansion?, activating activated: DeviceRowExpansion, currentPanelIsLive: Bool)
        -> DeviceRowExpansion?
    {
        current == activated && currentPanelIsLive ? nil : activated
    }

    /// True while a remote-device connect or install attempt is running. The add-remote disclosure stays
    /// open for the length of an attempt because its inline status label is where the result is reported.
    private var isRemoteDeviceAttemptInFlight: Bool { isConnectingRemoteDevice || isInstallingRemoteSpaces }

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
    /// The add-remote disclosure, retained weakly so a running attempt can gray it out on the live view: the
    /// form holds the status label that reports the attempt, so it must not be collapsed until the attempt
    /// lands, and a live-disabled control says that instead of silently ignoring the click.
    private weak var addRemoteDeviceToggle: NSButton?
    /// The live row pairing buttons, held weakly, so a running attempt can gray them out on the views already
    /// on screen and restore them when it lands. Only rows whose device can actually be paired are tracked; a
    /// button disabled because its device is unreachable must stay that way when the attempt ends.
    private let devicePairButtons = NSHashTable<NSButton>.weakObjects()
    /// The live row remove buttons, held weakly for the same reason: removing a device rebuilds the pane,
    /// which would take a running attempt's form off screen with the fields and status label it needs.
    private let deviceRemoveButtons = NSHashTable<NSButton>.weakObjects()
    /// What the add-remote form holds between renders. Every change to the pane rebuilds it wholesale, so the
    /// entered values are read out of the live fields before the rebuild and seeded back into the new ones;
    /// otherwise a rename, a removal, or a device changing state silently empties a half-filled form.
    private struct RemoteDeviceFormDraft {
        var sshHost = ""
        var name = ""
        var sshUser = ""
        var sshPort = ""
        var advancedExpanded = false
    }
    private var remoteDeviceFormDraft = RemoteDeviceFormDraft()
    /// True while the background status refresh's probe is running, so stacked load-state transitions queue
    /// no second probe against the same daemon.
    private var isProbingDeviceStatusForRefresh = false
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
    /// True while a plain connect attempt is in flight. Together with `isInstallingRemoteSpaces` this keeps
    /// the add-remote disclosure pinned open and the Connect button disabled for the length of an attempt,
    /// so the form cannot be collapsed out from under a running attempt (its status label is the only place
    /// the result is reported) and a second click cannot start an overlapping pairing.
    private var isConnectingRemoteDevice = false
    /// Which row's inline panel is open, or nil when the card is a plain list.
    private var expandedDeviceRow: DeviceRowExpansion?
    /// The pairing-window request in flight, if any: the row that asked, and a token a later request
    /// invalidates. A row counts as showing its panel while its request runs, even before a code exists.
    private var inFlightPairingRequest: (deviceID: String, token: Int)?
    private var pairingRequestTokenSeed = 0
    /// The device load states the pane last painted. Sidebar load-state transitions happen in the
    /// background, so `refreshDeviceSettingsForDeviceStatusChange` compares against these to repaint
    /// exactly when a device's connection state changed and never otherwise.
    private var lastRenderedDeviceLoadStates: [String: DeviceModelStore.SidebarDeviceLoadState] = [:]
    var renamingClientDeviceID: String?
    weak var renamingClientDeviceField: NSTextField?

    @objc func showMobileConnection() {
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

    /// Called when Settings is about to replace the Devices content with another section, or close the window
    /// holding it. The pane's views go away with it and nothing reads them afterwards, so the add-remote
    /// form's entered values are taken out of them here; the expansion itself is controller state and comes
    /// back with the section.
    func prepareDeviceSettingsForContentReplacement() { captureRemoteDeviceFormDraft() }

    /// Drops everything the add-remote form holds: what was entered, and the install recovery a failed
    /// attempt left behind. Opening the form again starts on a new device rather than under the previous
    /// one's install command and retry action.
    private func discardRemoteDeviceFormState() {
        remoteDeviceFormDraft = RemoteDeviceFormDraft()
        remoteDeviceLinuxInstallCommand = nil
    }

    /// Reads the add-remote form's live fields into the draft the next render seeds from. Only the fields of
    /// the form that is currently open are read: the weak references outlive the views a previous render
    /// built, and a closed form's values were dropped when the user closed it.
    private func captureRemoteDeviceFormDraft() {
        guard expandedDeviceRow == .addRemoteDevice, let sshHostField = remoteDeviceSSHHostField else { return }
        remoteDeviceFormDraft = RemoteDeviceFormDraft(
            sshHost: sshHostField.stringValue, name: remoteDeviceNameField?.stringValue ?? "",
            sshUser: remoteDeviceSSHUserField?.stringValue ?? "", sshPort: remoteDeviceSSHPortField?.stringValue ?? "",
            advancedExpanded: remoteDeviceAdvancedRow?.isHidden == false)
    }

    private func refreshVisibleDeviceSettings(_ response: SpacesDeviceAPIControlResponse) {
        guard host.settings.settingsWindow?.isVisible == true, host.settings.selectedSettingsSection == .devices,
            host.settings.settingsSectionContentContainer != nil
        else { return }
        renderDeviceSettings(response: response)
    }

    func renderDeviceSettings(response: SpacesDeviceAPIControlResponse) {
        captureRemoteDeviceFormDraft()
        lastRenderedDeviceLoadStates = deviceSectionLoadStates()
        host.shortcuts.activeShortcutCaptureSetting = nil
        host.shortcuts.shortcutButtonsBySetting.removeAll()
        host.settings.renderSettingsCards(deviceSettingsCards(response: response))
    }

    private func visibleDevicePairingWindow(for response: SpacesDeviceAPIControlResponse) -> SpacesDevicePairingWindowSnapshot? {
        if let pairingWindow = response.pairingWindow, pairingWindow.expiresAt > Date() { return pairingWindow }
        return nil
    }

    private func deviceSettingsCards(response: SpacesDeviceAPIControlResponse) -> [NSView] {
        var cards: [NSView] = []

        if let status = devicePanelStatusMessage {
            let statusLabel = host.helpTextLabel(status.message)
            statusLabel.textColor = status.isError ? .systemRed : .secondaryLabelColor
            // Status messages can carry a long unbreakable path; wrap on characters so the path stays
            // fully visible across lines rather than being clipped at the (now width-capped) window edge.
            statusLabel.lineBreakMode = .byCharWrapping
            cards.append(statusLabel)
        }

        cards.append(devicesSection(response: response))
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

    /// Whether the row's pairing panel is showing anything: a live code, or the request that will produce
    /// one. Its button collapses the row only then; on a row whose window expired (or whose open returned
    /// nothing) the same click asks for a fresh code instead.
    private func pairingPanelIsLive(deviceID: String) -> Bool {
        if inFlightPairingRequest?.deviceID == deviceID { return true }
        guard let window = currentDevicePairingWindow else { return false }
        return window.deviceID == deviceID && window.isVisible
    }

    /// The pairing panel shown inline beneath the device row that opened it: the QR code for that device's
    /// pairing window, alongside the addresses the link advertises. Returns nil while the row is expanded but
    /// no live window exists yet — a remote device's window is opened asynchronously, and every window expires
    /// — so the row falls back to a plain row rather than showing a code that would not work.
    private func devicePairingPanel(for device: ClientConnectedDevice, response: SpacesDeviceAPIControlResponse) -> NSView? {
        guard
            let window = visibleClientDevicePairingWindow(response: response, pairingWindow: visibleDevicePairingWindow(for: response)),
            window.deviceID == device.id
        else { return nil }

        let heading = NSTextField(labelWithString: "Scan with Spaces on iPhone or iPad")
        heading.font = Typography.controlLabel
        heading.textColor = Theme.text
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let instruction = devicePairingInstructionLabel("Open Spaces on the phone, add a device, and point its camera at this code.")
        instruction.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var details: [NSView] = [heading, instruction]
        let hosts = (try? SpacesDevicePairingLink.parse(window.linkString))?.hosts ?? []
        if !hosts.isEmpty { details.append(pairingLinkAddressesView(hosts: hosts)) }

        let detailStack = NSStackView(views: details)
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 6
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        // A leading-aligned stack does not stretch its children, and the wrapping labels need a definite
        // width to wrap against rather than an intrinsic one that would widen the settings window.
        for detail in details { detail.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true }

        let qrSize: CGFloat = 150
        let panel = NSStackView(views: [mobileQRCodeView(link: window.linkString, size: qrSize), detailStack])
        panel.orientation = .horizontal
        panel.alignment = .top
        panel.spacing = 14
        panel.translatesAutoresizingMaskIntoConstraints = false
        detailStack.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -(qrSize + panel.spacing)).isActive = true
        panel.setAccessibilityIdentifier("device-pairing-panel")
        return panel
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
        let accentColor = host.sidebar.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
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

    /// The one card the Devices pane shows: this Mac and every connected device as rows, each able to
    /// expand an inline pairing panel, followed by the local-daemon error (when the control response is not
    /// ok) and the collapsed "Add remote device over SSH" disclosure.
    private func devicesSection(response: SpacesDeviceAPIControlResponse) -> NSView {
        var entries: [DevicesCardEntry] = []
        // The rows below are rebuilt from scratch, so the previous render's pairing buttons are gone.
        devicePairButtons.removeAllObjects()
        deviceRemoveButtons.removeAllObjects()
        for device in connectedClientDevices(response: response) {
            let isPairingExpanded = expandedDeviceRow == .pairing(deviceID: device.id)
            let row = connectedDeviceRow(device, isPairingExpanded: isPairingExpanded, response: response)
            if isPairingExpanded, let panel = devicePairingPanel(for: device, response: response) {
                entries.append(.expandedRow(row))
                entries.append(.panel(panel))
            } else {
                entries.append(.row(row))
            }
        }

        // A non-ok control response means the local daemon (or just its Device API endpoint) is
        // down/unreachable. The error reads inline under the device rows; the recovery action lives in the
        // local row's overflow menu, gated on the same failure classes a relaunch can actually resolve.
        // restartLocalDaemon warns before killing if the daemon still reports live sessions (the Device API
        // can be down while the terminal service is not).
        if !response.ok {
            let errorLabel = host.helpTextLabel(response.message)
            errorLabel.lineBreakMode = .byCharWrapping
            entries.append(.row(errorLabel))
        }

        let isAddRemoteExpanded = expandedDeviceRow == .addRemoteDevice
        let disclosure = addRemoteDeviceDisclosureRow(expanded: isAddRemoteExpanded)
        if isAddRemoteExpanded {
            entries.append(.expandedRow(disclosure))
            entries.append(.panel(remoteDevicePairingPanel()))
        } else {
            entries.append(.row(disclosure))
        }

        return devicesCard(icon: "desktopcomputer.and.macbook", title: "Devices", entries: entries)
    }

    /// A device row's connection state, mapped onto the shared status-dot vocabulary: solid green when the
    /// device is answering, solid orange while it waits on the user to re-pair, hollow grey while its first
    /// load is still in flight, hollow red when its daemon is not answering.
    enum DeviceRowStatus: Equatable, Sendable {
        case reachable
        case connecting
        case reconnectRequired
        case unreachable

        var statusKind: RowPrimitives.StatusKind {
            switch self {
            case .reachable: return .ready
            case .connecting: return .idle
            case .reconnectRequired: return .waiting
            case .unreachable: return .exited
            }
        }

        var tooltip: String {
            switch self {
            case .reachable: return "Reachable"
            case .connecting: return "Connecting…"
            case .reconnectRequired: return "Reconnect required"
            case .unreachable: return "Unreachable"
            }
        }
    }

    /// A remote device's row status. A missing credential outranks reachability because re-pairing, not
    /// waiting, is what fixes it. Otherwise the row reports the sidebar's load state for that device, which
    /// is the client's only real reachability signal: a stored credential says nothing about whether the
    /// device is powered on, so it must never on its own paint the row as reachable. A device whose section
    /// has not loaded yet (or does not exist yet) is still connecting rather than known-good or known-bad.
    nonisolated static func remoteDeviceStatus(hasCredentials: Bool, loadState: DeviceModelStore.SidebarDeviceLoadState?) -> DeviceRowStatus {
        guard hasCredentials else { return .reconnectRequired }
        switch loadState {
        case .loaded: return .reachable
        case .offline: return .unreachable
        case .loading, nil: return .connecting
        }
    }

    /// The wording of the remove-device confirmation. Removal only ever touches this Mac's own records, so
    /// the copy is pinned here (and asserted in tests) to keep it from drifting into implying the removed
    /// device is stopped or wiped.
    nonisolated static func removeDeviceConfirmation(deviceName: String) -> (title: String, message: String) {
        (
            title: "Remove \(deviceName) from this Mac?",
            message: "Its projects, workspaces, and running terminals stay on \(deviceName) and keep running. This Mac deletes the pairing and "
                + "its stored credential, and stops listing that device. Pair it again to get it back."
        )
    }

    /// The overflow menu for a device row, also used as the row's right-click context menu. It carries only
    /// actions that exist elsewhere in this controller: rename and remove for a connected device, and the
    /// local daemon relaunch when the control response reports a failure a relaunch can resolve. An empty
    /// menu means the row gets no overflow button at all.
    private func deviceRowMenu(for device: ClientConnectedDevice, response: SpacesDeviceAPIControlResponse) -> NSMenu {
        let menu = NSMenu()
        if device.isLocal {
            if !response.ok,
                Self.localDaemonRestartActionIsAvailable(responseMessage: response.message, isRelaunching: isRelaunchingLocalDaemon)
            {
                let restartItem = NSMenuItem(
                    title: "Restart Local Daemon", action: #selector(DevicePairingController.restartLocalDaemon), keyEquivalent: "")
                restartItem.target = self
                restartItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
                menu.addItem(restartItem)
            }
            return menu
        }

        let renameItem = NSMenuItem(title: "Rename…", action: #selector(DevicePairingController.beginClientDeviceRename(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        renameItem.identifier = NSUserInterfaceItemIdentifier(device.id)
        menu.addItem(renameItem)

        let removeItem = NSMenuItem(title: "Remove Device…", action: #selector(DevicePairingController.removeMacPairedDevice(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        removeItem.identifier = NSUserInterfaceItemIdentifier(device.id)
        menu.addItem(removeItem)
        return menu
    }

    /// The last row of the card: a collapsed disclosure that expands the SSH form in place, so the pane
    /// reads as a device list until the user asks to add one.
    private func addRemoteDeviceDisclosureRow(expanded: Bool) -> NSView {
        let toggle = NSButton(
            title: expanded ? "Add remote device over SSH" : "Add remote device over SSH…", target: self,
            action: #selector(DevicePairingController.toggleAddRemoteDeviceForm))
        toggle.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        toggle.imagePosition = .imageLeading
        toggle.imageHugsTitle = true
        toggle.setButtonType(.momentaryChange)
        Theme.applyTextStyle(to: toggle, color: Theme.muted)
        toggle.toolTip = "Connect this Mac with another Mac or Linux device over SSH"
        toggle.setAccessibilityIdentifier("add-remote-device-toggle")
        toggle.isEnabled = !isRemoteDeviceAttemptInFlight
        addRemoteDeviceToggle = toggle
        return mobilePanelButtonRow([toggle])
    }

    private func connectedDeviceRow(_ device: ClientConnectedDevice, isPairingExpanded: Bool, response: SpacesDeviceAPIControlResponse) -> NSView {
        let detail = NSTextField(labelWithString: clientDeviceDetailText(device))
        detail.font = Typography.caption
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        let nameView: NSView
        if !device.isLocal, renamingClientDeviceID == device.id {
            let editor = NSTextField(string: device.name)
            editor.font = Typography.controlLabel
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
            title.font = Typography.controlLabel
            title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingTail
            nameView = title
        }

        let textStack = NSStackView(views: [nameView, detail])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A labeled button rather than a bare icon: pairing a phone is the pane's primary job and was not
        // discoverable as an unlabeled glyph.
        let pairButton = NSButton(
            title: "Pair iPhone", target: self, action: #selector(DevicePairingController.togglePairingForConnectedDevice(_:)))
        pairButton.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        pairButton.imagePosition = .imageLeading
        pairButton.imageHugsTitle = true
        pairButton.setButtonType(.momentaryChange)
        Theme.applyTextStyle(to: pairButton, color: device.isAvailable ? Theme.accentStrong : .tertiaryLabelColor)
        // A row can stay expanded with no code under it (the code expired, or the request for one is still
        // running), and clicking then asks for a fresh code rather than closing, so the tooltip follows the
        // panel rather than the expansion.
        pairButton.toolTip =
            isPairingExpanded && pairingPanelIsLive(deviceID: device.id)
            ? "Hide the pairing code for \(device.displayName)" : "Pair iPhone or iPad with \(device.displayName)"
        pairButton.identifier = NSUserInterfaceItemIdentifier(device.id)
        pairButton.isEnabled = device.isAvailable && !isRemoteDeviceAttemptInFlight
        pairButton.setAccessibilityIdentifier("device-row-pair-\(device.id)")
        if device.isAvailable { devicePairButtons.add(pairButton) }

        let statusSlot = RowPrimitives.statusSlot(RowPrimitives.statusDot(device.status.statusKind))
        statusSlot.toolTip = device.status.tooltip

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(statusSlot)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(pairButton)
        if !device.isLocal {
            let removeButton = host.sidebarRowIconButton(
                symbol: "trash", tooltip: "Remove \(device.displayName) from this Mac",
                action: #selector(DevicePairingController.removeMacPairedDevice(_:)))
            removeButton.target = self
            removeButton.identifier = NSUserInterfaceItemIdentifier(device.id)
            removeButton.contentTintColor = Theme.red
            removeButton.setAccessibilityIdentifier("device-row-remove-\(device.id)")
            removeButton.isEnabled = !isRemoteDeviceAttemptInFlight
            deviceRemoveButtons.add(removeButton)
            row.addArrangedSubview(removeButton)
            // Right-click on the row keeps offering the same actions as the overflow button. The two menus
            // are separate instances because an NSMenu serves one presentation at a time.
            row.menu = deviceRowMenu(for: device, response: response)
        }

        let overflowMenu = deviceRowMenu(for: device, response: response)
        if !overflowMenu.items.isEmpty {
            let overflowButton = host.sidebarRowIconButton(
                symbol: "ellipsis", tooltip: "More actions for \(device.displayName)",
                action: #selector(DevicePairingController.showDeviceRowMenu(_:)))
            overflowButton.target = self
            overflowButton.menu = overflowMenu
            overflowButton.setAccessibilityIdentifier("device-row-menu-\(device.id)")
            row.addArrangedSubview(overflowButton)
        }
        return row
    }

    /// Pops the row's overflow menu below its button. The menu is built with the row so it reflects the
    /// control response that rendered it.
    @objc func showDeviceRowMenu(_ sender: NSButton) {
        guard let menu = sender.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func devicePairingInstructionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Typography.rowDetail
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func mobileQRCodeView(link: String, size qrSize: CGFloat) -> NSView {
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
            container.heightAnchor.constraint(equalToConstant: qrSize), container.widthAnchor.constraint(equalToConstant: qrSize),
            qrView.widthAnchor.constraint(equalToConstant: qrSize), qrView.heightAnchor.constraint(equalToConstant: qrSize),
            qrView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            qrView.topAnchor.constraint(equalTo: container.topAnchor), qrView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// The add-remote-device form, rendered inline under its disclosure row rather than as an always-open
    /// card. Field identities and validation are unchanged: a bare SSH host, an optional display name, and
    /// the optional username/port behind the "Advanced" disclosure.
    private func remoteDevicePairingPanel() -> NSView {
        var rows: [NSView] = []
        rows.append(
            devicePairingInstructionLabel(
                "Enter the SSH details for a Mac or Linux device. A Mac needs the Spaces app installed and opened once; an Ubuntu 24.04 device without Spaces is installed over SSH as part of connecting."
            ))

        let sshHostField = NSTextField()
        sshHostField.placeholderString = "SSH host"
        sshHostField.stringValue = remoteDeviceFormDraft.sshHost
        sshHostField.setAccessibilityIdentifier("remote-device-ssh-host")
        sshHostField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        remoteDeviceSSHHostField = sshHostField
        rows.append(sshHostField)

        // Optional display name for the paired device; when left blank the daemon-reported name is used.
        let nameField = NSTextField()
        nameField.placeholderString = "Name (optional)"
        nameField.stringValue = remoteDeviceFormDraft.name
        nameField.setAccessibilityIdentifier("remote-device-name")
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        remoteDeviceNameField = nameField
        rows.append(nameField)

        // Username and port are optional (they default to the SSH login and port 22), so they live
        // behind a collapsed "Advanced" disclosure to keep the common case a single host field.
        let advancedToggle = NSButton(title: "Advanced", target: self, action: #selector(DevicePairingController.toggleRemoteDeviceAdvancedFields(_:)))
        advancedToggle.isBordered = false
        advancedToggle.bezelStyle = .inline
        advancedToggle.setButtonType(.momentaryChange)
        advancedToggle.image = NSImage(
            systemSymbolName: remoteDeviceFormDraft.advancedExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: "Advanced")
        advancedToggle.imagePosition = .imageLeading
        advancedToggle.imageHugsTitle = true
        advancedToggle.font = Typography.controlLabel
        advancedToggle.contentTintColor = .secondaryLabelColor
        advancedToggle.toolTip = "Optional SSH username and port"
        advancedToggle.setAccessibilityIdentifier("remote-device-advanced-toggle")
        remoteDeviceAdvancedToggle = advancedToggle
        rows.append(mobilePanelButtonRow([advancedToggle]))

        let sshUserField = NSTextField()
        sshUserField.placeholderString = "username (defaults to SSH login)"
        sshUserField.stringValue = remoteDeviceFormDraft.sshUser
        sshUserField.setAccessibilityIdentifier("remote-device-ssh-user")
        remoteDeviceSSHUserField = sshUserField

        let sshPortField = NSTextField()
        sshPortField.placeholderString = "port (22)"
        sshPortField.stringValue = remoteDeviceFormDraft.sshPort
        sshPortField.setAccessibilityIdentifier("remote-device-ssh-port")
        remoteDeviceSSHPortField = sshPortField

        let advancedRow = NSStackView(views: [sshUserField, sshPortField])
        advancedRow.orientation = .horizontal
        advancedRow.alignment = .centerY
        advancedRow.spacing = 8
        advancedRow.translatesAutoresizingMaskIntoConstraints = false
        sshUserField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        sshPortField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        advancedRow.isHidden = !remoteDeviceFormDraft.advancedExpanded
        remoteDeviceAdvancedRow = advancedRow
        rows.append(advancedRow)

        let connectButton = actionButton(
            title: "Connect Remote Device", symbol: "link", tooltip: "Connect this Mac with another device over SSH",
            action: #selector(DevicePairingController.connectRemoteDeviceFromPairingPanel), primary: true, target: self)
        connectButton.isEnabled = !isRemoteDeviceAttemptInFlight
        remoteDeviceConnectButton = connectButton
        rows.append(mobilePanelButtonRow([connectButton]))

        let statusLabel = host.helpTextLabel("")
        statusLabel.isHidden = true
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.setAccessibilityIdentifier("remote-device-status")
        remoteDevicePairingStatusLabel = statusLabel
        rows.append(statusLabel)

        rows.append(remoteDeviceInstallSection())

        let panel = NSStackView(views: rows)
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 8
        panel.translatesAutoresizingMaskIntoConstraints = false
        for row in rows { row.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true }
        return panel
    }

    /// Expands or collapses the add-remote-device form. Kept open while an attempt is running, because the
    /// form holds the status label that reports the attempt's outcome.
    @objc func toggleAddRemoteDeviceForm() {
        guard !isRemoteDeviceAttemptInFlight else { return }
        devicePanelStatusMessage = nil
        expandedDeviceRow = Self.expansion(after: expandedDeviceRow, activating: .addRemoteDevice, currentPanelIsLive: true)
        // Closing the form discards what was entered into it; the draft only survives renders of an open form.
        if expandedDeviceRow != .addRemoteDevice { discardRemoteDeviceFormState() }
        refreshVisibleDeviceSettingsAfterClientDeviceChange()
    }

    /// The recovery block shown once a pairing attempt reports Spaces is missing on a Linux device: the
    /// pinned install one-liner (copyable) plus a button that retries the SSH install the attempt already
    /// started automatically, so a failed install leaves both a manual and a one-click path. Visibility and content
    /// derive from `remoteDeviceLinuxInstallCommand`/`isInstallingRemoteSpaces` so a panel rebuild restores
    /// the block exactly; the flows also toggle the retained views directly to avoid a status-wiping re-render.
    private func remoteDeviceInstallSection() -> NSView {
        let commandField = NSTextField(labelWithString: remoteDeviceLinuxInstallCommand ?? "")
        commandField.isSelectable = true
        commandField.isEditable = false
        commandField.font = Typography.monoBody
        commandField.lineBreakMode = .byCharWrapping
        commandField.maximumNumberOfLines = 0
        commandField.setAccessibilityIdentifier("remote-device-install-command")
        commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remoteDeviceInstallCommandField = commandField

        let copyButton = host.sidebarRowIconButton(
            symbol: "doc.on.doc", tooltip: "Copy install command", action: #selector(DevicePairingController.copyRemoteDeviceInstallCommand))
        copyButton.target = self
        copyButton.setAccessibilityIdentifier("remote-device-install-command-copy")

        let commandRow = NSStackView(views: [commandField, copyButton])
        commandRow.orientation = .horizontal
        commandRow.alignment = .top
        commandRow.spacing = 8

        let installButton = actionButton(
            title: "Install Spaces over SSH", symbol: "arrow.down.circle", tooltip: "Run the installer on the remote device over SSH, then pair",
            action: #selector(DevicePairingController.installSpacesOnRemoteDevice), primary: false, target: self)
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
    @objc func toggleRemoteDeviceAdvancedFields(_ sender: NSButton) {
        guard let advancedRow = remoteDeviceAdvancedRow else { return }
        let willExpand = advancedRow.isHidden
        advancedRow.isHidden = !willExpand
        let symbol = willExpand ? "chevron.down" : "chevron.right"
        sender.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Advanced")
    }

    /// Builds the Devices card: an accented header, then its entries separated by hairlines. A row that has
    /// an open panel shares the panel's inset surface and takes no divider between the two, so the pair reads
    /// as one block.
    private func devicesCard(icon: String, title: String, entries: [DevicesCardEntry]) -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setContentHuggingPriority(.required, for: .vertical)

        let accentColor = host.sidebar.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let iconView = NSImageView()
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            iconView.image = image.withSymbolConfiguration(.init(paletteColors: [accentColor]))
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Typography.sectionTitle
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

        var needsDivider = !entries.isEmpty
        for entry in entries {
            let padded: NSView
            switch entry {
            case .row(let view):
                if needsDivider { appendDivider(to: stack) }
                padded = mobilePanelPaddedRow(view)
                needsDivider = true
            case .expandedRow(let view):
                if needsDivider { appendDivider(to: stack) }
                padded = mobilePanelInsetRow(view, leadingInset: 14)
                // The panel that follows belongs to this row, so no hairline separates them.
                needsDivider = false
            case .panel(let view):
                padded = mobilePanelInsetRow(view, leadingInset: 14 + RowPrimitives.statusSlotWidth + 8)
                needsDivider = true
            }
            stack.addArrangedSubview(padded)
            padded.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        section.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: section.leadingAnchor), stack.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            stack.topAnchor.constraint(equalTo: section.topAnchor), stack.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])
        return section
    }

    private func appendDivider(to stack: NSStackView) {
        let divider = mobilePanelDivider()
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// A padded row painted on the secondary surface, used for an expanded row and its panel so the open
    /// expansion reads as one recessed block inside the card.
    private func mobilePanelInsetRow(_ view: NSView, leadingInset: CGFloat) -> NSView {
        let container = ColoredBackgroundView()
        container.fillColor = Theme.surface2
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9),
        ])
        return container
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

    /// Opens a fresh pairing window on the local daemon and renders it in the expanded local row. On failure
    /// the expansion is dropped so the row does not sit open with nothing under it.
    @objc func openDevicePairingWindow() {
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
            expandedDeviceRow = nil
            inFlightPairingRequest = nil
            if let unavailableResponse = Self.deviceAPIDisabledOverrideResponse(for: error) {
                showDeviceSettings(unavailableResponse)
            } else {
                // The expansion was just dropped; without a repaint the panel this click was replacing —
                // another row's code, or the SSH form — stays on screen under state that no longer has it
                // open. Repaint first so the pane behind the error alert already matches.
                refreshVisibleDeviceSettingsAfterClientDeviceChange()
                host.showError(error)
            }
        }
    }

    /// Toggles the inline pairing panel for a device row. Opening it closes whatever expansion was open and
    /// requests a fresh pairing window on that device — the local daemon's Device API directly, a remote
    /// device's over its authenticated Device API. Clicking the same row again collapses it and drops the
    /// window this client is holding, so the next open always shows a live code rather than a stale one.
    @objc func togglePairingForConnectedDevice(_ sender: NSButton) {
        guard let deviceID = sender.identifier?.rawValue else { return }
        // A running SSH attempt reports into the add-remote panel's status label, so opening a pairing
        // panel — which would replace that panel — waits until the attempt finishes.
        guard !isRemoteDeviceAttemptInFlight else { return }
        let target = DeviceRowExpansion.pairing(deviceID: deviceID)
        let panelIsLive = expandedDeviceRow == target && pairingPanelIsLive(deviceID: deviceID)
        devicePanelStatusMessage = nil
        // Any previously shown code, and any request still running for it, belongs to the expansion being
        // replaced or closed.
        currentDevicePairingWindow = nil
        inFlightPairingRequest = nil
        expandedDeviceRow = Self.expansion(after: expandedDeviceRow, activating: target, currentPanelIsLive: panelIsLive)
        // Opening a pairing panel replaces the add-remote form, which discards what was entered into it.
        discardRemoteDeviceFormState()
        guard expandedDeviceRow == target else {
            refreshVisibleDeviceSettingsAfterClientDeviceChange()
            return
        }
        if deviceID == SpacesPairedDeviceRecord.localDeviceID {
            openDevicePairingWindow()
            return
        }
        guard let device = pairedDevices().first(where: { $0.id == deviceID }) else { return }
        pairingRequestTokenSeed += 1
        let requestToken = pairingRequestTokenSeed
        inFlightPairingRequest = (deviceID: deviceID, token: requestToken)
        devicePanelStatusMessage = (message: "Opening pairing window on \(device.name)...", isError: false)
        refreshVisibleDeviceSettingsAfterClientDeviceChange()
        Task { [weak self] in
            do {
                let appVersion = AppVersion.short
                let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
                let result = try await Task.detached(priority: .userInitiated) {
                    try SpacesDevicePairingClient.openRemotePairingWindow(for: device, appVersion: appVersion, profile: profile)
                }.value
                guard let self else { return }
                // The user may have collapsed the row or opened another one while the request was in flight;
                // dropping the result then keeps the single-expansion state authoritative.
                guard self.inFlightPairingRequest?.token == requestToken, self.expandedDeviceRow == target else { return }
                self.inFlightPairingRequest = nil
                let expiresAt = result.expiresAt.flatMap { Self.iso8601Formatter.date(from: $0) } ?? Date().addingTimeInterval(300)
                self.currentDevicePairingWindow = ClientDevicePairingWindow(
                    deviceID: device.id, deviceName: result.name, linkString: result.linkString, expiresAt: expiresAt)
                self.devicePanelStatusMessage = nil
                self.refreshVisibleDeviceSettingsAfterClientDeviceChange()
            } catch {
                // Same rule as the success path: a request the user already moved on from reports nothing,
                // so a late failure can never post its error above another row's open panel.
                guard let self, self.inFlightPairingRequest?.token == requestToken, self.expandedDeviceRow == target else { return }
                self.inFlightPairingRequest = nil
                self.expandedDeviceRow = nil
                self.devicePanelStatusMessage = (message: error.localizedDescription, isError: true)
                self.refreshVisibleDeviceSettingsAfterClientDeviceChange()
            }
        }
    }

    @objc func connectRemoteDeviceFromPairingPanel() {
        guard !isRemoteDeviceAttemptInFlight else { return }
        landActiveClientDeviceRename()
        // Each attempt starts from a clean recovery state: hide any install block left from a prior failure
        // so it only reappears if this attempt again finds Spaces missing.
        remoteDeviceLinuxInstallCommand = nil
        remoteDeviceInstallBlock?.isHidden = true
        let request: SpacesRemoteDevicePairingRequest
        do { request = try remoteDevicePairingRequestFromPanelFields() } catch {
            setRemoteDevicePairingStatus(error.localizedDescription, isError: true)
            return
        }
        setRemoteDeviceAttemptControlsEnabled(false)
        isConnectingRemoteDevice = true
        setRemoteDevicePairingStatus("Validating SSH and preparing the remote device...", isError: false)
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { try SpacesDevicePairingClient.pairRemoteDevice(request) }.value
                guard let self else { return }
                self.isConnectingRemoteDevice = false
                self.collapseAddRemoteDeviceFormAfterSuccess("Connected \(result.name).")
                self.refreshVisibleDeviceSettingsAfterClientDeviceChange()
                self.host.requestSidebarReload()
            } catch {
                guard let self else { return }
                self.isConnectingRemoteDevice = false
                // A Linux device without Spaces installed carries the pinned install one-liner, so connecting
                // continues straight into installing it over SSH and pairing. The recovery block is surfaced
                // first so a failed install still leaves the command copyable and the button there to retry.
                if case SpacesRemoteDevicePairingError.remoteSpacesNotInstalled(_, let linuxInstallCommand) = error, let command = linuxInstallCommand
                {
                    self.remoteDeviceLinuxInstallCommand = command
                    self.remoteDeviceInstallCommandField?.stringValue = command
                    self.remoteDeviceInstallBlock?.isHidden = false
                    self.runRemoteInstallAndPair(
                        request: request,
                        statusMessage: "Spaces isn't installed on \(request.sshHost). Installing it over SSH... This can take a few minutes.")
                } else {
                    self.remoteDeviceLinuxInstallCommand = nil
                    self.remoteDeviceInstallBlock?.isHidden = true
                    self.setRemoteDeviceAttemptControlsEnabled(true)
                    self.setRemoteDevicePairingStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    /// Enables or disables the controls that must not act while a remote-device attempt is running: a second
    /// Connect would start an overlapping pairing, and collapsing the disclosure — or opening a pairing panel,
    /// which replaces it — would take the status label the attempt reports through away with it.
    /// Saves an open rename editor before an attempt starts. The editor stays reachable by keyboard while an
    /// attempt runs — Return commits, Escape cancels — and either rebuilds the pane, which would take the
    /// attempt's status label and install progress off screen. Committing keeps what was typed rather than
    /// discarding it.
    private func landActiveClientDeviceRename() {
        guard let deviceID = renamingClientDeviceID, let field = renamingClientDeviceField else { return }
        commitClientDeviceRename(deviceID: deviceID, newName: field.stringValue)
    }

    private func setRemoteDeviceAttemptControlsEnabled(_ enabled: Bool) {
        remoteDeviceConnectButton?.isEnabled = enabled
        addRemoteDeviceToggle?.isEnabled = enabled
        for pairButton in devicePairButtons.allObjects { pairButton.isEnabled = enabled }
        for removeButton in deviceRemoveButtons.allObjects { removeButton.isEnabled = enabled }
    }

    /// Collapses the add-remote-device disclosure once an attempt succeeds and reports the result at the top
    /// of the pane, where it survives the form going away. A failed attempt leaves the form open with its own
    /// status label so the fields stay filled in for a retry.
    private func collapseAddRemoteDeviceFormAfterSuccess(_ message: String) {
        expandedDeviceRow = nil
        discardRemoteDeviceFormState()
        devicePanelStatusMessage = (message: message, isError: false)
    }

    /// Retries the SSH install after the automatic run that connecting starts failed, so the user is never
    /// left with only a copyable command. Reads the SSH fields again, since they stay editable while the
    /// install block is showing.
    @objc func installSpacesOnRemoteDevice() {
        guard !isRemoteDeviceAttemptInFlight else { return }
        landActiveClientDeviceRename()
        let request: SpacesRemoteDevicePairingRequest
        do { request = try remoteDevicePairingRequestFromPanelFields() } catch {
            setRemoteDevicePairingStatus(error.localizedDescription, isError: true)
            return
        }
        runRemoteInstallAndPair(request: request, statusMessage: "Installing Spaces on \(request.sshHost)... This can take a few minutes.")
    }

    /// Runs the pinned Linux installer on the remote host over SSH (up to ten minutes) and then pairs. Shared
    /// by the automatic run that a pairing attempt starts when it finds Spaces missing on a Linux device and
    /// by the "Install Spaces over SSH" button that retries it. While it runs, the install and Connect buttons
    /// are disabled and the spinner spins; on success the block is cleared and the Devices pane refreshes like
    /// the connect success path, and on failure the block stays so the command remains copyable and retryable.
    ///
    /// The in-progress guard lives here rather than on the callers: it is the single entry point for both, and
    /// the Connect button it disables is what would otherwise start a second overlapping run.
    private func runRemoteInstallAndPair(request: SpacesRemoteDevicePairingRequest, statusMessage: String) {
        guard !isInstallingRemoteSpaces else { return }
        isInstallingRemoteSpaces = true
        remoteDeviceInstallButton?.isEnabled = false
        setRemoteDeviceAttemptControlsEnabled(false)
        remoteDeviceInstallSpinner?.isHidden = false
        remoteDeviceInstallSpinner?.startAnimation(nil)
        setRemoteDevicePairingStatus(statusMessage, isError: false)
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SpacesDevicePairingClient.installSpacesOnRemoteDeviceAndPair(request)
                }.value
                guard let self else { return }
                self.isInstallingRemoteSpaces = false
                self.remoteDeviceLinuxInstallCommand = nil
                self.remoteDeviceInstallSpinner?.stopAnimation(nil)
                self.remoteDeviceInstallBlock?.isHidden = true
                self.collapseAddRemoteDeviceFormAfterSuccess("Connected \(result.name).")
                self.refreshVisibleDeviceSettingsAfterClientDeviceChange()
                self.host.requestSidebarReload()
            } catch {
                guard let self else { return }
                self.isInstallingRemoteSpaces = false
                self.remoteDeviceInstallSpinner?.stopAnimation(nil)
                self.remoteDeviceInstallSpinner?.isHidden = true
                self.remoteDeviceInstallButton?.isEnabled = true
                self.setRemoteDeviceAttemptControlsEnabled(true)
                self.setRemoteDevicePairingStatus(error.localizedDescription, isError: true)
            }
        }
    }

    /// Builds a pairing request from the panel's SSH fields, shared by the connect and install flows so both
    /// read and validate the form identically. Throws when the optional port field holds an invalid port,
    /// which the callers report in the same red status style as any other pairing failure.
    private func remoteDevicePairingRequestFromPanelFields() throws -> SpacesRemoteDevicePairingRequest {
        let sshHostText = remoteDeviceSSHHostField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nameText = remoteDeviceNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sshUserText = remoteDeviceSSHUserField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sshPortText = remoteDeviceSSHPortField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
        return SpacesRemoteDevicePairingRequest(
            sshHost: sshHostText, sshUser: Self.normalizedPanelField(sshUserText), sshPort: try Self.parsedSSHPort(sshPortText),
            clientInstallationID: SpacesDevicePairingClient.localMacClientInstallationID(profile: profile),
            clientBundleID: Bundle.main.bundleIdentifier ?? "dev.usespaces.spaces", clientDeviceName: Host.current().localizedName ?? "Mac",
            clientAppVersion: AppVersion.short, customName: Self.normalizedPanelField(nameText), profile: profile)
    }

    /// Copies the pinned install one-liner to the pasteboard. Inlined because `AppKitController.copyToPasteboard`
    /// is private and this is the only device-panel copy site.
    @objc func copyRemoteDeviceInstallCommand() {
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
    @objc func restartLocalDaemon() {
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

    /// Confirms, then removes a connected device. Reached from both the row's trash button and the row
    /// menu's Remove Device item; `sender` is whichever of the two carries the device id.
    ///
    /// Removal is entirely local to this Mac: it deletes the paired-device record, the stored credential for
    /// it, and any daemon-update progress tracked against it. Nothing is sent to the removed device — its
    /// daemon, projects, workspaces, and running terminals are untouched — so the alert says exactly that
    /// rather than implying the other end is shut down.
    @objc func removeMacPairedDevice(_ sender: Any) {
        guard let deviceID = (sender as? any NSUserInterfaceItemIdentification)?.identifier?.rawValue else { return }
        let deviceName = pairedDevices().first(where: { $0.id == deviceID })?.name ?? "this device"
        let confirmation = Self.removeDeviceConfirmation(deviceName: deviceName)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        // Cancel is the default so Return dismisses without destroying anything; Remove is marked destructive
        // so AppKit renders it as the dangerous choice.
        let removeButton = alert.addButton(withTitle: "Remove")
        removeButton.hasDestructiveAction = true
        removeButton.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let database = try self.database()
            try database.deletePairedDevice(id: deviceID)
            try SpacesDeviceCredentialStore.deleteToken(deviceID: deviceID)
            host.daemonUpdate.forgetDaemonUpdateProgress(deviceID: deviceID)
            // A pairing panel or rename editor open on the removed row has nothing left to point at.
            if expandedDeviceRow == .pairing(deviceID: deviceID) {
                expandedDeviceRow = nil
                currentDevicePairingWindow = nil
            }
            if renamingClientDeviceID == deviceID { renamingClientDeviceID = nil }
            refreshVisibleDeviceSettingsAfterClientDeviceChange()
            host.requestSidebarReload()
        } catch { host.showError(error) }
    }

    @objc func beginClientDeviceRename(_ sender: NSMenuItem) {
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
            let database = try self.database()
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

    /// Repaints the open Devices pane when a device's connection state changed underneath it: a remote
    /// daemon dropping out, a device finishing its first load, the local daemon going down. The sidebar's
    /// data-change funnel calls this, which is where every load-state transition lands.
    ///
    /// That funnel runs several times a second while any device streams updates, so this reads nothing but
    /// in-memory state until a load state actually changed: no database read, no credential read, and no
    /// daemon call. A real change then repaints from the same status probe every other change to this pane
    /// uses, so the row statuses, the inline local-daemon failure, and the restart action move together
    /// instead of one of them lagging. That probe is blocking socket I/O, and nothing about this path is
    /// user-initiated, so it runs off the main actor and applies its answer back on it: a daemon that
    /// accepts the connection and then goes quiet must not freeze the app for its timeout.
    ///
    /// Load state is therefore the only trigger, and it does not describe everything the pane paints: the
    /// local Device API can stop answering while the terminal service keeps serving a loaded overview, and
    /// this pane keeps its previous statuses until the next render (any action in it, or reselecting the
    /// section). Accepted: closing that gap means polling the daemon on a timer for as long as the pane sits
    /// open, and each answer rebuilds the pane wholesale — which resets its scroll position — for a status
    /// that is almost always the one already shown.
    func refreshDeviceSettingsForDeviceStatusChange() {
        guard host.settings.settingsWindow?.isVisible == true, host.settings.selectedSettingsSection == .devices,
            host.settings.settingsSectionContentContainer != nil
        else { return }
        // Repainting rebuilds the pane's editable controls. Their contents survive it — the form draft is
        // carried across, and a rename editor is rebuilt with its device's name — but first responder and the
        // insertion point are not, so a repaint arriving mid-keystroke would drop the user out of the field.
        // A background status change therefore waits while the SSH form or a rename editor is open; closing
        // either repaints from current state, as does any action in the pane.
        let probedLoadStates = deviceSectionLoadStates()
        guard expandedDeviceRow != .addRemoteDevice, renamingClientDeviceID == nil, !isProbingDeviceStatusForRefresh,
            probedLoadStates != lastRenderedDeviceLoadStates
        else { return }
        isProbingDeviceStatusForRefresh = true
        Task { [weak self] in
            let response = await Task.detached(priority: .userInitiated) { () -> SpacesDeviceAPIControlResponse in
                do { return try SpacesDeviceAPIControlClient.status(timeout: 1) } catch {
                    return DevicePairingController.controlResponse(forThrownError: error)
                }
            }.value
            guard let self else { return }
            self.isProbingDeviceStatusForRefresh = false
            // The user may have started typing into the SSH form or a rename editor while the probe ran;
            // the same suppression that skips the refresh applies to landing it.
            guard self.expandedDeviceRow != .addRemoteDevice, self.renamingClientDeviceID == nil else { return }
            self.refreshVisibleDeviceSettings(response)
            // The render stamps the load states as of now, but this response describes the ones the probe
            // started from, and transitions that landed while it ran were skipped by the in-flight guard.
            // Stamping what the response actually describes leaves those pending, and asking again here
            // repaints them rather than waiting for a sidebar change that may not come.
            self.lastRenderedDeviceLoadStates = probedLoadStates
            self.refreshDeviceSettingsForDeviceStatusChange()
        }
    }

    private func deviceSectionLoadStates() -> [String: DeviceModelStore.SidebarDeviceLoadState] {
        host.deviceModel.deviceSections.reduce(into: [:]) { $0[$1.deviceID] = $1.loadState }
    }

    /// Re-renders the Devices pane after this client's own device state changed. A failing local control
    /// endpoint is rendered rather than swallowed: the device list, the pairing panels, and the add-remote
    /// form all stay usable while the local daemon is down, and the failure itself is what the pane reports.
    private func refreshVisibleDeviceSettingsAfterClientDeviceChange() {
        do { refreshVisibleDeviceSettings(try SpacesDeviceAPIControlClient.status(timeout: 1)) } catch {
            refreshVisibleDeviceSettings(Self.controlResponse(forThrownError: error))
        }
    }

    private func connectedClientDevices(response: SpacesDeviceAPIControlResponse) -> [ClientConnectedDevice] {
        let localStatus = response.status
        let localHost = localStatus?.networkAddresses.first ?? localStatus?.host
        // The local row's status comes from the control-endpoint probe this render already made, which is the
        // freshest reachability fact the client has about its own daemon. A failed answer counts as
        // unreachable even when it carries a status payload — a daemon reporting that its Device API is not
        // running answers exactly that way — so the dot never reads green above the inline failure and the
        // restart action the same response produces.
        let localIsAvailable = response.ok && localStatus != nil
        let local = ClientConnectedDevice(
            id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", host: localHost, port: localStatus?.port, sshHost: nil, sshUser: nil,
            sshPort: nil, isLocal: true, isAvailable: localIsAvailable, requiresReconnect: false,
            status: localIsAvailable ? .reachable : .unreachable)
        let remote = pairedDevices().map {
            let hasCredentials = AppKitController.pairedDeviceHasRequiredCredentials(device: $0)
            return ClientConnectedDevice(
                id: $0.id, name: $0.name, host: $0.dialHost, port: $0.port, sshHost: $0.sshHost, sshUser: $0.sshUser, sshPort: $0.sshPort,
                isLocal: false, isAvailable: hasCredentials, requiresReconnect: !hasCredentials,
                status: Self.remoteDeviceStatus(hasCredentials: hasCredentials, loadState: host.deviceSection(id: $0.id)?.loadState))
        }
        return [local] + remote
    }

    private func clientDeviceDetailText(_ device: ClientConnectedDevice) -> String {
        var parts: [String] = []
        // The local row is labeled "Local" in the list, so its caption names the machine it actually is.
        if device.isLocal { parts.append("This Mac") }
        if device.requiresReconnect { parts.append("Reconnect required") }
        if let host = device.host, let port = device.port {
            // A remote device is reachable at several addresses; the one shown is the address it is
            // currently dialed at (proven, or the preferred candidate until one is proven), labeled by
            // network path the way the iOS device list and the pairing sheet label theirs. The local
            // device is reached over loopback and has no such choice, so it stays a bare address.
            parts.append(device.isLocal ? "\(host):\(port)" : "\(SpacesDeviceHostAddressKind(host: host).label) · \(host):\(port)")
        } else if device.isLocal {
            parts.append(device.isAvailable ? "Local daemon" : "Local daemon unavailable")
        }
        if let sshHost = device.sshHost {
            let userPrefix = device.sshUser.map { "\($0)@" } ?? ""
            let portSuffix = device.sshPort.map { ":\($0)" } ?? ""
            parts.append("ssh: \(userPrefix)\(sshHost)\(portSuffix)")
        }
        return parts.joined(separator: " · ")
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

/// Grays out the device row menus while an SSH connect or install is running. Rename, remove, and the local
/// daemon restart each rebuild the Devices pane, which would take the running attempt's form away with the
/// fields it holds and the status label it reports through. The trailing row buttons are disabled directly;
/// a menu is built with its row but presented later, so its items answer here instead.
extension DevicePairingController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !isRemoteDeviceAttemptInFlight }
}

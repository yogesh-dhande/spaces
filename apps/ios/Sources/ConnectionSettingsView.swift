import SwiftUI
import UIKit
import spacesdevicecore
import spacesterminalcore

struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings: SpacesMobileConnectionSettings
    @State private var pendingPairingLink: SpacesDevicePairingLink?
    @State private var devicePendingRemoval: SpacesMobilePairedDeviceRecord?
    @State private var renamingDeviceID: String?
    @State private var renameText: String = ""
    @FocusState private var isRenameFieldFocused: Bool
    @State private var isConfirmingPairing = false
    @State private var isShowingScanner = false
    @State private var isPairing = false
    @State private var errorMessage: String?
    private let initialPairingLink: SpacesDevicePairingLink?
    let pairedDevices: [SpacesMobilePairedDeviceRecord]
    let activeDeviceID: String?
    let noticeMessage: String?
    /// While Demo Mode is on the device list is the single synthetic Demo Mac, so pairing is disabled and
    /// removing that row means leaving Demo Mode rather than forgetting a real device.
    let isDemoMode: Bool
    let onPairingLinkConsumed: () -> Void
    let onSelectDevice: (String) -> Void
    let onRemoveDevice: (String) -> Void
    let onRenameDevice: (String, String) -> Void
    let onSave: (SpacesMobileConnectionSettings, String) -> Void

    init(
        initialSettings: SpacesMobileConnectionSettings, initialPairingLink: SpacesDevicePairingLink? = nil,
        pairedDevices: [SpacesMobilePairedDeviceRecord] = [], activeDeviceID: String? = nil, noticeMessage: String? = nil, isDemoMode: Bool = false,
        onPairingLinkConsumed: @escaping () -> Void = {}, onSelectDevice: @escaping (String) -> Void = { _ in },
        onRemoveDevice: @escaping (String) -> Void = { _ in }, onRenameDevice: @escaping (String, String) -> Void = { _, _ in },
        onSave: @escaping (SpacesMobileConnectionSettings, String) -> Void
    ) {
        _settings = State(initialValue: initialSettings)
        self.initialPairingLink = initialPairingLink
        self.pairedDevices = pairedDevices
        self.activeDeviceID = activeDeviceID
        self.noticeMessage = noticeMessage
        self.isDemoMode = isDemoMode
        self.onPairingLinkConsumed = onPairingLinkConsumed
        self.onSelectDevice = onSelectDevice
        self.onRemoveDevice = onRemoveDevice
        self.onRenameDevice = onRenameDevice
        self.onSave = onSave
    }

    private var isDemoDevicePendingRemoval: Bool { devicePendingRemoval?.id == SpacesMobileDemoDevice.id }

    var body: some View {
        Form {
            if !pairedDevices.isEmpty { Section("Connected Devices") { ForEach(pairedDevices) { device in deviceRow(device) } } }

            Section {
                Button {
                    isShowingScanner = true
                } label: {
                    if isPairing {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Pairing…")
                        }
                    } else {
                        Label("Scan QR Code to Pair", systemImage: "qrcode.viewfinder")
                    }
                }.disabled(isPairing || isDemoMode)

                if isDemoMode { Text("Turn off Demo Mode to pair a device.").font(.footnote).foregroundStyle(.secondary) }
                if let noticeMessage { Text(noticeMessage).font(.footnote).foregroundStyle(.orange) }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }

                #if DEBUG
                    Section("Debug") { NavigationLink("Browser Proxy Smoke Test") { BrowserProxySmokeTestView() } }
                #endif
            }
        }.navigationTitle("Paired Devices").navigationBarTitleDisplayMode(.inline).tint(Theme.accent).alert(
            pendingPairingLink.map { "Pair with \($0.name)?" } ?? "Pair Device?", isPresented: $isConfirmingPairing
        ) {
            Button("Pair") {
                guard let pendingPairingLink else { return }
                Task { await pairDevice(using: pendingPairingLink) }
            }
            Button("Cancel", role: .cancel) { pendingPairingLink = nil }
        } message: {
            if let pendingPairingLink {
                Text(
                    pendingPairingLink.hosts.map { "\(SpacesDeviceHostAddressKind(host: $0).label) · \($0):\(pendingPairingLink.port)" }.joined(
                        separator: "\n")
                ).font(.caption.monospaced())
            }
        }.confirmationDialog(
            isDemoDevicePendingRemoval ? "Turn Off Demo Mode?" : devicePendingRemoval.map { "Remove \($0.name)?" } ?? "Remove Device?",
            isPresented: removalConfirmationBinding, titleVisibility: .visible, presenting: devicePendingRemoval
        ) { device in
            // Removing the synthetic Demo Mac is not a device removal — the model maps it to leaving Demo
            // Mode — so the action label says so honestly.
            Button(device.id == SpacesMobileDemoDevice.id ? "Turn Off Demo Mode" : "Remove Device", role: .destructive) {
                onRemoveDevice(device.id)
                devicePendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { devicePendingRemoval = nil }
        }.fullScreenCover(isPresented: $isShowingScanner) { QRCodeScannerView { payload in handleScannedPayload(payload) } }.task {
            applyIncomingPairingLink(initialPairingLink)
        }.onChange(of: initialPairingLink) { _, newValue in applyIncomingPairingLink(newValue) }
    }

    @ViewBuilder private func deviceRow(_ device: SpacesMobilePairedDeviceRecord) -> some View {
        if renamingDeviceID == device.id {
            TextField("Device name", text: $renameText).focused($isRenameFieldFocused).submitLabel(.done).onSubmit { commitRename(for: device) }
                .onAppear { isRenameFieldFocused = true }.onDisappear { commitRename(for: device) }
        } else {
            HStack(spacing: 10) {
                Button {
                    settings.hosts = device.hosts
                    settings.port = device.port
                    settings.certificateFingerprint = device.certificateFingerprint
                    onSelectDevice(device.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(device.name).foregroundStyle(.primary)
                            if device.id == SpacesMobileDemoDevice.id { demoTag }
                        }
                        // Show the address actually in use, not necessarily the most-preferred
                        // candidate: `activeHost` is the one that most recently connected.
                        Text("\(device.activeHost ?? device.hosts.first ?? ""):\(device.port)").font(.caption.monospaced()).foregroundStyle(
                            .secondary
                        ).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    devicePendingRemoval = device
                } label: {
                    // The Demo Mac is not a stored device; removing it leaves Demo Mode, so the control reads
                    // as turning the feature off rather than as forgetting a pairing.
                    Image(systemName: device.id == SpacesMobileDemoDevice.id ? "xmark.circle" : "trash")
                }.buttonStyle(.borderless).accessibilityLabel(device.id == SpacesMobileDemoDevice.id ? "Turn Off Demo Mode" : "Remove Device")
            }.contextMenu {
                // The Demo Mac is synthetic and has no stored name to edit, so it offers no Rename.
                if device.id != SpacesMobileDemoDevice.id {
                    Button {
                        beginRename(for: device)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }
            }
        }
    }

    /// Compact chip marking the synthetic Demo Mac in the device list.
    private var demoTag: some View {
        Text("Demo").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent).padding(.horizontal, 6).padding(.vertical, 2).background(
            Theme.accentTint, in: Capsule())
    }

    @MainActor private func beginRename(for device: SpacesMobilePairedDeviceRecord) {
        // Persist any in-progress edit before switching fields; otherwise the prior
        // field's onDisappear fires after renamingDeviceID has already moved on and
        // its guard silently drops the edit.
        commitActiveRename()
        renameText = device.name
        renamingDeviceID = device.id
    }

    @MainActor private func commitActiveRename() {
        guard let activeID = renamingDeviceID, let device = pairedDevices.first(where: { $0.id == activeID }) else {
            renamingDeviceID = nil
            return
        }
        commitRename(for: device)
    }

    @MainActor private func commitRename(for device: SpacesMobilePairedDeviceRecord) {
        guard renamingDeviceID == device.id else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingDeviceID = nil
        if !trimmed.isEmpty, trimmed != device.name { onRenameDevice(device.id, trimmed) }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(get: { devicePendingRemoval != nil }, set: { if !$0 { devicePendingRemoval = nil } })
    }

    @MainActor private func applyIncomingPairingLink(_ pairingLink: SpacesDevicePairingLink?) {
        guard let pairingLink else { return }
        pendingPairingLink = pairingLink
        errorMessage = nil
        isConfirmingPairing = true
        onPairingLinkConsumed()
    }

    @MainActor private func handleScannedPayload(_ payload: String) {
        do {
            pendingPairingLink = try SpacesDevicePairingLink.parse(payload)
            errorMessage = nil
            isConfirmingPairing = true
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func pairDevice(using pairingLink: SpacesDevicePairingLink) async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        do {
            var pairedSettings = settings
            pairedSettings.hosts = pairingLink.hosts
            pairedSettings.port = pairingLink.port
            pairedSettings.certificateFingerprint = pairingLink.certificateFingerprint
            let bridgeClient = SpacesDeviceAPIClient(settings: pairedSettings, deviceName: UIDevice.current.name)
            let commandChannel = bridgeClient.makeCommandChannel()
            let issuedAuthToken: String
            do { issuedAuthToken = try await bridgeClient.pair(pairingLink: pairingLink, commandChannel: commandChannel) } catch {
                await commandChannel.close()
                throw error
            }
            await commandChannel.close()
            pairedSettings.authToken = issuedAuthToken
            settings = pairedSettings
            pendingPairingLink = nil
            errorMessage = nil
            onSave(pairedSettings, pairingLink.name)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

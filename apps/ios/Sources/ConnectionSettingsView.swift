import SwiftUI
import spacesdevicecore

struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings: SpacesMobileConnectionSettings
    @State private var pendingPairingLink: SpacesDevicePairingLink?
    @State private var isConfirmingPairing = false
    @State private var isShowingScanner = false
    @State private var isPairing = false
    @State private var isLaunchingSpaces = false
    @State private var errorMessage: String?
    private let initialPairingLink: SpacesDevicePairingLink?
    let pairedDevices: [SpacesMobilePairedDeviceRecord]
    let activeDeviceID: String?
    let noticeMessage: String?
    let onPairingLinkConsumed: () -> Void
    let onLaunchSpaces: (() async -> Void)?
    let onSelectDevice: (String) -> Void
    let onRemoveDevice: (String) -> Void
    let onSave: (SpacesMobileConnectionSettings, String) -> Void

    init(
        initialSettings: SpacesMobileConnectionSettings,
        initialPairingLink: SpacesDevicePairingLink? = nil,
        pairedDevices: [SpacesMobilePairedDeviceRecord] = [],
        activeDeviceID: String? = nil,
        noticeMessage: String? = nil,
        onPairingLinkConsumed: @escaping () -> Void = {},
        onLaunchSpaces: (() async -> Void)? = nil,
        onSelectDevice: @escaping (String) -> Void = { _ in },
        onRemoveDevice: @escaping (String) -> Void = { _ in },
        onSave: @escaping (SpacesMobileConnectionSettings, String) -> Void
    ) {
        _settings = State(initialValue: initialSettings)
        self.initialPairingLink = initialPairingLink
        self.pairedDevices = pairedDevices
        self.activeDeviceID = activeDeviceID
        self.noticeMessage = noticeMessage
        self.onPairingLinkConsumed = onPairingLinkConsumed
        self.onLaunchSpaces = onLaunchSpaces
        self.onSelectDevice = onSelectDevice
        self.onRemoveDevice = onRemoveDevice
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connected Devices") {
                    if pairedDevices.isEmpty {
                        Text("No devices are paired.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pairedDevices) { device in
                            HStack(spacing: 10) {
                                Button {
                                    settings.host = device.host
                                    settings.port = device.port
                                    settings.certificateFingerprint = device.certificateFingerprint
                                    onSelectDevice(device.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .foregroundStyle(.primary)
                                        Text("\(device.host):\(device.port)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button(role: .destructive) {
                                    onRemoveDevice(device.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

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
                            Label(
                                "Scan QR Code to Pair",
                                systemImage: "qrcode.viewfinder"
                            )
                        }
                    }
                    .disabled(isPairing)

                    if settings.isPaired, let onLaunchSpaces {
                        Button {
                            Task {
                                isLaunchingSpaces = true
                                await onLaunchSpaces()
                                isLaunchingSpaces = false
                            }
                        } label: {
                            if isLaunchingSpaces {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("Launching…")
                                }
                            } else {
                                Label("Launch Spaces on Mac", systemImage: "macwindow")
                            }
                        }
                        .disabled(isLaunchingSpaces)
                    }

                    if let noticeMessage {
                        Text(noticeMessage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Add Device")
                } footer: {
                    Text("Scan a QR code from a Mac or Linux device running spacesd.")
                }
            }
            .navigationTitle("Devices")
            .tint(Theme.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                pendingPairingLink.map { "Pair with \($0.name)?" } ?? "Pair Device?",
                isPresented: $isConfirmingPairing
            ) {
                Button("Pair") {
                    guard let pendingPairingLink else { return }
                    Task { await pairDevice(using: pendingPairingLink) }
                }
                Button("Cancel", role: .cancel) { pendingPairingLink = nil }
            } message: {
                if let pendingPairingLink {
                    Text("\(pendingPairingLink.host):\(pendingPairingLink.port)")
                }
            }
            .fullScreenCover(isPresented: $isShowingScanner) {
                QRCodeScannerView { payload in
                    handleScannedPayload(payload)
                }
            }
            .task {
                applyIncomingPairingLink(initialPairingLink)
            }
            .onChange(of: initialPairingLink) { _, newValue in
                applyIncomingPairingLink(newValue)
            }
        }
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func pairDevice(using pairingLink: SpacesDevicePairingLink) async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        do {
            var pairedSettings = settings
            pairedSettings.host = pairingLink.host
            pairedSettings.port = pairingLink.port
            pairedSettings.transportKey = pairingLink.transportKey
            pairedSettings.certificateFingerprint = pairingLink.certificateFingerprint
            let bridgeClient = SpacesDeviceAPIClient(settings: pairedSettings)
            let commandChannel = bridgeClient.makeCommandChannel()
            let issuedAuthToken: String
            do {
                issuedAuthToken = try await bridgeClient.pair(pairingLink: pairingLink, commandChannel: commandChannel)
            } catch {
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

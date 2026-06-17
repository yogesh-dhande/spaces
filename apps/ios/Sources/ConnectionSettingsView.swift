import SwiftUI
import spacesmobilecore

struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings: SpacesMobileConnectionSettings
    @State private var pendingPairingLink: SpacesMobilePairingLink?
    @State private var isConfirmingPairing = false
    @State private var isShowingScanner = false
    @State private var isPairing = false
    @State private var isLaunchingSpaces = false
    @State private var errorMessage: String?
    @State private var discovery = SpacesMobileBridgeDiscovery()
    private let initialPairingLink: SpacesMobilePairingLink?
    let noticeMessage: String?
    let onPairingLinkConsumed: () -> Void
    let onLaunchSpaces: (() async -> Void)?
    let onSave: (SpacesMobileConnectionSettings) -> Void

    init(
        initialSettings: SpacesMobileConnectionSettings,
        initialPairingLink: SpacesMobilePairingLink? = nil,
        noticeMessage: String? = nil,
        onPairingLinkConsumed: @escaping () -> Void = {},
        onLaunchSpaces: (() async -> Void)? = nil,
        onSave: @escaping (SpacesMobileConnectionSettings) -> Void
    ) {
        _settings = State(initialValue: initialSettings)
        self.initialPairingLink = initialPairingLink
        self.noticeMessage = noticeMessage
        self.onPairingLinkConsumed = onPairingLinkConsumed
        self.onLaunchSpaces = onLaunchSpaces
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        StatusDot(kind: settings.isPaired ? .running : .idle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.isPaired ? "Paired" : "Not paired")
                                .font(.system(size: 13, weight: .medium))
                            Text("\(settings.trimmedHost):\(settings.port)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
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
                }

                Section("Nearby Macs") {
                    if discovery.discoveredBridges.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Searching…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(Array(discovery.discoveredBridges.enumerated()), id: \.element.id) { _, bridge in
                            Button {
                                settings.host = bridge.host
                                settings.port = bridge.port
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(String(bridge.serviceName.trimmingPrefix("Spaces ")), systemImage: "macbook")
                                        .foregroundStyle(.primary)
                                    Text("\(bridge.host):\(bridge.port)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .padding(.leading, 28)
                                }
                            }
                        }
                    }
                }

                Section("Endpoint") {
                    TextField("Host", text: $settings.host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", value: $settings.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
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
                                settings.isPaired ? "Scan QR Code to Re-Pair" : "Scan QR Code",
                                systemImage: "qrcode.viewfinder"
                            )
                        }
                    }
                    .disabled(isPairing)

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
                    Text(settings.isPaired ? "Re-pair This Device" : "Pair This Device")
                } footer: {
                    Text("Scan the QR code from the Mac app to pair. Nearby Macs can still be selected for the saved endpoint.")
                }
            }
            .navigationTitle("Connection")
            .tint(Theme.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(settings)
                        dismiss()
                    }
                    .disabled(!settings.isValid)
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
                discovery.start()
                applyIncomingPairingLink(initialPairingLink)
            }
            .onChange(of: initialPairingLink) { _, newValue in
                applyIncomingPairingLink(newValue)
            }
            .onDisappear {
                discovery.stop()
            }
        }
    }

    @MainActor private func applyIncomingPairingLink(_ pairingLink: SpacesMobilePairingLink?) {
        guard let pairingLink else { return }
        pendingPairingLink = pairingLink
        errorMessage = nil
        isConfirmingPairing = true
        onPairingLinkConsumed()
    }

    @MainActor private func handleScannedPayload(_ payload: String) {
        do {
            pendingPairingLink = try SpacesMobilePairingLink.parse(payload)
            errorMessage = nil
            isConfirmingPairing = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func pairDevice(using pairingLink: SpacesMobilePairingLink) async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        do {
            var pairedSettings = settings
            pairedSettings.host = pairingLink.host
            pairedSettings.port = pairingLink.port
            pairedSettings.transportKey = pairingLink.transportKey
            pairedSettings.certificateFingerprint = pairingLink.certificateFingerprint
            let bridgeClient = SpacesMobileBridgeClient(settings: pairedSettings)
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
            onSave(pairedSettings)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

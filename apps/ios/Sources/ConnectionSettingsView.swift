import SwiftUI
import spacesmobilecore

struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings: SpacesMobileConnectionSettings
    @State private var pairingLinkText = ""
    @State private var pendingPairingLink: SpacesMobilePairingLink?
    @State private var isConfirmingPairing = false
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var discovery = SpacesMobileBridgeDiscovery()
    private let initialPairingLink: SpacesMobilePairingLink?
    let noticeMessage: String?
    let onPairingLinkConsumed: () -> Void
    let onSave: (SpacesMobileConnectionSettings) -> Void

    init(
        initialSettings: SpacesMobileConnectionSettings,
        initialPairingLink: SpacesMobilePairingLink? = nil,
        noticeMessage: String? = nil,
        onPairingLinkConsumed: @escaping () -> Void = {},
        onSave: @escaping (SpacesMobileConnectionSettings) -> Void
    ) {
        _settings = State(initialValue: initialSettings)
        self.initialPairingLink = initialPairingLink
        self.noticeMessage = noticeMessage
        self.onPairingLinkConsumed = onPairingLinkConsumed
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nearby Macs") {
                    if discovery.discoveredBridges.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Searching")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(discovery.discoveredBridges) { bridge in
                            Button {
                                settings.host = bridge.host
                                settings.port = bridge.port
                            } label: {
                                HStack {
                                    Label(bridge.serviceName, systemImage: "macbook.and.iphone")
                                    Spacer()
                                    Text("\(bridge.host):\(bridge.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Bridge") {
                    TextField("Host", text: $settings.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper(value: $settings.port, in: 1...65535) {
                        HStack {
                            Text("Port")
                            Spacer()
                            Text("\(settings.port)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Pairing") {
                    LabeledContent("Status") {
                        Text(settings.isPaired ? "Paired" : "Not Paired")
                            .foregroundStyle(settings.isPaired ? .green : .secondary)
                    }
                    TextField("Paste Pairing Link", text: $pairingLinkText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                    Button {
                        confirmPastedPairingLink()
                    } label: {
                        if isPairing {
                            ProgressView()
                        } else {
                            Text(settings.isPaired ? "Re-Pair This Device" : "Pair This Device")
                        }
                    }
                    .disabled(isPairing || pairingLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
                }

                Section("Defaults") {
                    Text("Scan the QR code from the Mac app or paste the full pairing link. Nearby Macs can still be selected for the saved endpoint.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connection")
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
            .confirmationDialog(
                pendingPairingLink.map { "Pair with \($0.name)?" } ?? "Pair Device?",
                isPresented: $isConfirmingPairing,
                titleVisibility: .visible
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
        pairingLinkText = pairingLink.absoluteString
        pendingPairingLink = pairingLink
        errorMessage = nil
        isConfirmingPairing = true
        onPairingLinkConsumed()
    }

    @MainActor private func confirmPastedPairingLink() {
        do {
            pendingPairingLink = try SpacesMobilePairingLink.parse(pairingLinkText)
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
            pairingLinkText = ""
            pendingPairingLink = nil
            errorMessage = nil
            onSave(pairedSettings)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

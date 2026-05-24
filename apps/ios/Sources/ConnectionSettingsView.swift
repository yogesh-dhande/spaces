import SwiftUI
import spacesmobilecore

struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings: SpacesMobileConnectionSettings
    @State private var pairingCode = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var discovery = SpacesMobileBridgeDiscovery()
    let noticeMessage: String?
    let onSave: (SpacesMobileConnectionSettings) -> Void

    init(
        initialSettings: SpacesMobileConnectionSettings,
        noticeMessage: String? = nil,
        onSave: @escaping (SpacesMobileConnectionSettings) -> Void
    ) {
        _settings = State(initialValue: initialSettings)
        self.noticeMessage = noticeMessage
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

                Section("Authentication") {
                    LabeledContent("Bundle") {
                        Text(SpacesMobileFirstPartyPolicy.allowedBundleID)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Status") {
                        Text(settings.isPaired ? "Paired" : "Not Paired")
                            .foregroundStyle(settings.isPaired ? .green : .secondary)
                    }
                    SecureField("Pairing Code", text: $pairingCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await pairDevice() }
                    } label: {
                        if isPairing {
                            ProgressView()
                        } else {
                            Text(settings.isPaired ? "Re-Pair This Device" : "Pair This Device")
                        }
                    }
                    .disabled(!settings.isValid || pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPairing)

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
                    Text(
                        "Run `spaces mobile status` on your Mac for the pairing code. Spaces stores the issued device credential and reuses it automatically."
                    )
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
            .task {
                discovery.start()
            }
            .onDisappear {
                discovery.stop()
            }
        }
    }

    @MainActor private func pairDevice() async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        do {
            let bridgeClient = SpacesMobileBridgeClient(settings: settings)
            let commandChannel = bridgeClient.makeCommandChannel()
            let issuedAuthToken: String
            do {
                issuedAuthToken = try await bridgeClient.pair(
                    pairingCode: pairingCode.trimmingCharacters(in: .whitespacesAndNewlines),
                    commandChannel: commandChannel
                )
            } catch {
                await commandChannel.close()
                throw error
            }
            await commandChannel.close()
            settings.authToken = issuedAuthToken
            pairingCode = ""
            errorMessage = nil
            onSave(settings)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

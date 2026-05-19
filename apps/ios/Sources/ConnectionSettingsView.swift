import SwiftUI
import spacesmobilecore

struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings: SpacesMobileConnectionSettings
    @State private var pairingCode = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
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
                        "Run `spaces mobile serve` on your Mac, then enter the 6-digit pairing code once. Spaces stores the issued device credential and reuses it automatically."
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
        }
    }

    @MainActor private func pairDevice() async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        do {
            let issuedAuthToken = try await SpacesMobileBridgeClient(settings: settings).pair(
                pairingCode: pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
            )
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

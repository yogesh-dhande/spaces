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
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    nearbyMacsCard
                    endpointCard
                    pairCard
                    Text("Scan the QR code from the Mac app or paste the full pairing link. Nearby Macs can still be selected for the saved endpoint.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.mutedSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Theme.bg.ignoresSafeArea())
            .scrollContentBackground(.hidden)
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

    private var statusCard: some View {
        SectionCard {
            HStack(spacing: 10) {
                StatusDot(kind: settings.isPaired ? .running : .idle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.isPaired ? "Paired" : "Not paired")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("\(settings.trimmedHost):\(settings.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.init(top: 12, leading: 14, bottom: 12, trailing: 14))
        }
    }

    private var nearbyMacsCard: some View {
        SectionCard {
            SectionHeader("Nearby Macs")
            RowDivider(inset: 0)
            if discovery.discoveredBridges.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                }
                .padding(.init(top: 9, leading: 14, bottom: 9, trailing: 14))
            } else {
                ForEach(Array(discovery.discoveredBridges.enumerated()), id: \.element.id) { index, bridge in
                    if index > 0 { RowDivider() }
                    Button {
                        settings.host = bridge.host
                        settings.port = bridge.port
                    } label: {
                        HStack(spacing: 10) {
                            TypeIconTile(systemName: "macbook.and.iphone")
                            Text(bridge.serviceName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(bridge.host):\(bridge.port)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                        .padding(.init(top: 9, leading: 14, bottom: 9, trailing: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var endpointCard: some View {
        SectionCard {
            SectionHeader("Endpoint")
            RowDivider(inset: 0)
            VStack(spacing: 12) {
                BrandTextField(label: "Host", text: $settings.host, placeholder: "127.0.0.1")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Port")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    TextField("Port", value: $settings.port, format: .number.grouping(.never))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.init(top: 12, leading: 14, bottom: 12, trailing: 14))
        }
    }

    private var pairCard: some View {
        SectionCard {
            SectionHeader(settings.isPaired ? "Re-pair this device" : "Pair this device")
            RowDivider(inset: 0)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pairing link")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    TextField("Paste pairing link", text: $pairingLinkText, axis: .vertical)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Button {
                    confirmPastedPairingLink()
                } label: {
                    if isPairing {
                        ProgressView().tint(Theme.primaryButtonText)
                    } else {
                        Text(settings.isPaired ? "Re-Pair This Device" : "Pair This Device")
                    }
                }
                .buttonStyle(BrandPrimaryButtonStyle())
                .disabled(isPairing || pairingLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let noticeMessage {
                    Text(noticeMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.orange)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.red)
                }
            }
            .padding(.init(top: 12, leading: 14, bottom: 12, trailing: 14))
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

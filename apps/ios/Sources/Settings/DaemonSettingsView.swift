import SwiftUI
import spacesterminalcore

/// Daemon status detail for the active device, plus the restart action with its
/// impact confirmation.
struct DaemonSettingsView: View {
    let model: SpacesMobileAppModel
    @State private var isConfirmingRestart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let compatibility = model.compatibility, !compatibility.isCompatible {
                    CompatibilityBannerView(
                        compatibility: compatibility, daemonStatus: model.daemonStatus, isMutating: model.isMutating
                    ) { isConfirmingRestart = true }
                } else if model.daemonUpdatePending {
                    CompatibilityBannerView(
                        compatibility: .compatible, daemonStatus: model.daemonStatus, isMutating: model.isMutating, onRestart: {})
                } else {
                    compatibleStatus
                }
                if let status = model.daemonStatus {
                    detailRow(label: "Device", value: model.connectionSummary)
                    detailRow(label: "Daemon version", value: status.version)
                    detailRow(label: "Protocol version", value: "\(status.protocolVersion)")
                }
                if model.daemonStatus != nil {
                    Button {
                        isConfirmingRestart = true
                    } label: {
                        Text("Restart Daemon")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.red)
                    .disabled(model.isMutating)
                    .accessibilityIdentifier("settings.daemon.restart")
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Daemon")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .confirmationDialog(
            "Restart this device's daemon?",
            isPresented: $isConfirmingRestart,
            titleVisibility: .visible
        ) {
            Button("Restart Daemon", role: .destructive) {
                Task { await model.requestDaemonRestart() }
            }
            Button("Defer", role: .cancel) {}
        } message: {
            Text(model.daemonRestartImpactMessage)
        }
    }

    private var compatibleStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(kind: model.compatibility == .compatible ? .done : .idle)
                Text(model.compatibility == .compatible ? "Compatible" : "Not connected")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text(
                model.compatibility == .compatible
                    ? "This device's daemon matches the app's wire protocol."
                    : "No daemon handshake yet. Check the connection on the Spaces tab."
            )
            .font(.system(size: 13))
            .foregroundStyle(Theme.mutedSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.mutedSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

import SwiftUI
import spacesterminalcore

/// Blocking banner shown when the active device's daemon is wire-incompatible with this app, plus a
/// quiet "update pending" variant when the daemon is compatible but older. The blocking variant
/// surfaces the restart-impact counts so the user can defer until critical work finishes.
struct CompatibilityBannerView: View {
    let compatibility: SpacesWireCompatibility
    let daemonStatus: TerminalServiceDaemonStatus?
    let isMutating: Bool
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.orange)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.mutedSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if canRestartFromHere, let impact = impactSummary {
                Text(impact)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canRestartFromHere {
                Button(action: onRestart) {
                    Text("Restart Daemon")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.orange)
                .disabled(isMutating)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.orange.opacity(0.5), lineWidth: 1))
    }

    private var needsRestart: Bool { compatibility == .daemonTooOld }

    /// A Linux daemon can only be updated from the Spaces Mac app (over SSH); this app can request a
    /// restart but cannot refresh the binary, so for Linux we direct the user to the Mac instead of
    /// offering a restart that would respawn the same old binary.
    private var isLinuxDaemon: Bool { daemonStatus?.isLinuxDaemon ?? false }

    /// Whether this app can usefully restart the daemon itself (vs. directing the user to the Mac).
    private var canRestartFromHere: Bool { needsRestart && !isLinuxDaemon }

    private var title: String {
        switch compatibility {
        case .clientTooOld: "Update Spaces to use this device"
        case .daemonTooOld: isLinuxDaemon ? "Update this device from your Mac" : "This device needs a daemon restart"
        case .compatible: "Daemon update pending"
        }
    }

    private var detail: String {
        switch compatibility {
        case .clientTooOld:
            "This device runs a newer Spaces than this app. Update the app from the App Store to reconnect."
        case .daemonTooOld:
            isLinuxDaemon
                ? "This device's daemon is older than this app needs. Update it from the Spaces app on your Mac — this app can't update a Linux daemon directly. It reconnects once updated."
                : "The daemon on this device is older than this app needs. Restart it to apply the update and reconnect."
        case .compatible:
            "A newer Spaces is installed on this device; the daemon keeps running the older build until it restarts."
        }
    }

    private var impactSummary: String? {
        guard needsRestart, let status = daemonStatus else { return nil }
        var parts: [String] = []
        if status.activeSessionCount > 0 { parts.append(countPhrase(status.activeSessionCount, "terminal")) }
        if status.runningProcesses > 0 { parts.append(countPhrase(status.runningProcesses, "process", plural: "processes")) }
        let agents = status.activeAgents + status.waitingAgents
        if agents > 0 { parts.append(countPhrase(agents, "coding agent")) }
        guard !parts.isEmpty else { return "Restarting won't interrupt any running work." }
        return "Restarting will stop \(listPhrase(parts))."
    }

    private func countPhrase(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }

    private func listPhrase(_ parts: [String]) -> String {
        switch parts.count {
        case 1: parts[0]
        case 2: "\(parts[0]) and \(parts[1])"
        default: parts.dropLast().joined(separator: ", ") + ", and " + (parts.last ?? "")
        }
    }
}

import SwiftUI

/// The self-update card: the same quiet card as the staged-update one, driven by the step the device's
/// own update is on. Accent border while the update is going as planned; orange when it stalled or
/// failed, since then the user has something to do. The available step's button starts the update and
/// the stalled and failed steps' button retries it.
struct DaemonSelfUpdateCardView: View {
    let content: DaemonSelfUpdateContent
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(content.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                DaemonVersionPairLabel(pair: content.versionPair)
            }
            Text(content.body).font(.system(size: 13)).foregroundStyle(Theme.mutedSecondary).fixedSize(horizontal: false, vertical: true)
            if let progress = content.progress { DaemonSelfUpdateProgressBar(progress: progress) }
            if let footnote = content.footnote {
                Text(footnote).font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary)
            }
            if let actionTitle = content.actionTitle {
                Button(action: onAction) {
                    Text(actionTitle).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 9).foregroundStyle(
                        content.isWarning ? Theme.orange : Theme.accent
                    ).overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
                            (content.isWarning ? Theme.orange : Theme.accent).opacity(0.7), lineWidth: 1))
                }.buttonStyle(.plain).accessibilityIdentifier("compatibility.daemonSelfUpdate")
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
            Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        ).overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                content.isWarning ? Theme.orange.opacity(0.6) : Theme.accent.opacity(0.5), lineWidth: 1))
    }
}

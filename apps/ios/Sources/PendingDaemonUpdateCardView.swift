import SwiftUI

/// The quiet card for a device that works fine and has a newer Spaces installed than the build its
/// daemon is running. It never blocks: the rows below it stay fully usable, and the update applies
/// whenever the user asks for it.
///
/// Accent rather than orange, and no warning icon: nothing is wrong, and nothing running on the device
/// stops when the update is applied. The blocking states are the hero's (`DaemonVersionHeroView`).
struct PendingDaemonUpdateCardView: View {
    let content: DaemonCompatibilityPresentation.PendingUpdate
    let isMutating: Bool
    /// True while this app is applying the update and polling for it to land, so the action reports
    /// progress rather than just going inert for the length of the poll.
    let isApplyingUpdate: Bool
    let onUpdate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(content.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                versionPair
            }
            Text(content.body).font(.system(size: 13)).foregroundStyle(Theme.mutedSecondary).fixedSize(horizontal: false, vertical: true)
            Button(action: onUpdate) {
                // The update polls for up to half a minute while the daemon restarts, and this card is
                // the only place the user is watching: a disabled button alone reads as an unresponsive
                // tap, so the label says what is happening for the whole wait.
                HStack(spacing: 6) {
                    if isApplyingUpdate { ProgressView().controlSize(.small) }
                    Text(isApplyingUpdate ? "Updating…" : content.actionTitle).font(.system(size: 13, weight: .semibold))
                }.frame(maxWidth: .infinity).padding(.vertical, 9).foregroundStyle(Theme.accent).overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
            }.buttonStyle(.plain).disabled(isMutating || isApplyingUpdate).accessibilityIdentifier("compatibility.updateDaemon")
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
            Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        ).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
    }

    /// The same `running → staged` fact the hero states large, sized down to a trailing detail: here it
    /// is context for a card whose sentence already carries the message. Digit-monospaced so the two
    /// versions align on their dots.
    private var versionPair: some View {
        HStack(spacing: 5) {
            Text(content.versionPair.from).foregroundStyle(Theme.mutedSecondary)
            Text("\u{2192}").foregroundStyle(Theme.accent)
            Text(content.versionPair.to).foregroundStyle(Theme.text)
        }.font(.system(size: 12).monospacedDigit()).lineLimit(1)
    }
}

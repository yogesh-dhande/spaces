import SwiftUI

/// The screen a device gets while this app cannot use it. The situation is a version gap, so the gap
/// itself is the layout: an orange eyebrow naming the state, the two versions the gap spans, a quiet
/// line saying whose versions those are, one sentence of pitch, and at most one action. Mirrors the Mac
/// app's compatibility block so both clients present the same situation the same way.
///
/// No card and no warning icon: this owns the whole screen, so a border around content with nothing
/// beside it would be chrome for its own sake, and the eyebrow carries the severity by itself.
struct DaemonVersionHeroView: View {
    let content: DaemonCompatibilityPresentation.Hero
    let isMutating: Bool
    /// True while the retry this hero offers is running, so the button reports progress for the length
    /// of the poll rather than going silently inert.
    let isApplyingUpdate: Bool
    let onAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(content.eyebrow).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.orange).multilineTextAlignment(
                .center)
            versionPairRow.padding(.top, 14)
            Text(content.whoLine).font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).multilineTextAlignment(.center).padding(.top, 8)
            Text(content.body).font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).fixedSize(
                horizontal: false, vertical: true
            ).padding(.top, 18)
            if let actionTitle = content.actionTitle {
                Button(action: onAction) {
                    HStack(spacing: 6) {
                        if isApplyingUpdate { ProgressView().controlSize(.small).tint(Theme.primaryButtonText) }
                        Text(isApplyingUpdate ? "Updating…" : actionTitle).font(.system(size: 14, weight: .semibold))
                    }.frame(maxWidth: .infinity).padding(.vertical, 11).foregroundStyle(Theme.primaryButtonText).background(
                        Theme.primaryButtonFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }.buttonStyle(.plain).disabled(isMutating || isApplyingUpdate).padding(.top, 18).accessibilityIdentifier("compatibility.updateDaemon")
            }
        }.frame(maxWidth: 340).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
    }

    /// `from → to`, the screen's largest element. Digit-monospaced so the two versions align on their
    /// dots instead of drifting apart, and separated by color rather than weight to say which side has
    /// to move.
    private var versionPairRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(content.versionPair.from).foregroundStyle(Theme.mutedSecondary)
            Text("\u{2192}").foregroundStyle(Theme.accent)
            Text(content.versionPair.to).foregroundStyle(Theme.text)
        }.font(.system(size: 28, weight: .regular).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
    }
}

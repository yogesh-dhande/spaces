import SwiftUI

/// The in-app banner for a new alert: a card pinned to the top of the app that opens the alert's terminal
/// when tapped. It dismisses itself after `displayDuration` and can be swiped up away; a newer alert
/// replaces it, restarting the timer.
struct AlertBannerView: View {
    static let displayDuration: Duration = .seconds(4)

    let event: SpacesMobileAttentionEvent
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                StatusDot(kind: StatusDot.Kind(attentionKind: event.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.bannerTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(event.detail).font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                RowChevron()
            }.padding(.horizontal, 14).padding(.vertical, 12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16)).overlay(
                RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.borderStrong, lineWidth: 1)
            ).shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 4).gesture(
            DragGesture(minimumDistance: 8).onEnded { value in if value.translation.height < -12 { onDismiss() } }
        ).task(id: event.id) {
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            onDismiss()
        }.accessibilityIdentifier("alert.banner").transition(.move(edge: .top).combined(with: .opacity))
    }
}

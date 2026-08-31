import SwiftUI

/// Shared full-bleed skeleton for a terminal-chrome detail screen's placeholder state: a centered
/// icon above caller-supplied body content, filling the available space between the two spacers.
///
/// Used by `TerminalDetailView.statusShell` (own-session waiting states: reconnecting, taking
/// over, viewer-locked) and `TerminalLaunchPendingView` (a fresh terminal launch in flight). Both
/// share this spacer/icon/spacer shell and the icon's font/opacity, but diverge past the icon —
/// `statusShell` shows just the status text plus an optional Take Over button, while the launch
/// view interleaves a `ProgressView` and a second detail line at different padding. Rather than
/// force those into one parameterized "extra content" slot (which would reorder one of them or
/// change its padding), the body past the icon stays entirely at each call site as `content`.
struct TerminalStatusPlaceholder<Content: View>: View {
    let systemName: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: systemName).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
            content
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

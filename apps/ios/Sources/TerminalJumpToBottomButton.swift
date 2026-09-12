import SwiftUI

/// The floating control offered over the terminal while `TerminalViewerModel.isScrolledIntoScrollback` is
/// true. A tap snaps the session's viewport back to its live bottom row.
struct TerminalJumpToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(Theme.surface).overlay(Circle().strokeBorder(Theme.borderStrong, lineWidth: 1)).frame(width: 30, height: 30).overlay(
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            )
            // Mirrors the floating shadow the Mac terminal pane banner uses for chrome sitting on top of the
            // terminal surface (`TerminalPaneBanner`: black at 0.18 opacity, radius 8, offset (0, -1)).
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: -1)
            // The visible circle stays 30pt; the tap target is widened to the 44pt minimum the same way the
            // Copy pill does it, so the hit area grows without inflating the control's visible size.
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("terminal-jump-to-bottom").accessibilityLabel("Jump to bottom")
    }
}

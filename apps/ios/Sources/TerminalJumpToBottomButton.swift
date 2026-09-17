import SwiftUI

/// The floating control offered over the terminal while `TerminalViewerModel.isScrolledIntoScrollback` is
/// true. A tap returns the screen to the session's newest rows.
///
/// `hasNewOutput` marks the control while the session printed under a history flick this device is
/// scrolling on its own: the frames never stopped arriving, so the rows the user is reading are history
/// and there is something newer below them. It is a dot on the control rather than a separate badge,
/// because the control is already the one affordance for "take me back down".
struct TerminalJumpToBottomButton: View {
    let hasNewOutput: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(Theme.surface).overlay(Circle().strokeBorder(Theme.borderStrong, lineWidth: 1)).frame(width: 30, height: 30).overlay(
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            ).overlay(alignment: .topTrailing) {
                // Sits on the circle's upper-right edge, clear of the chevron, and carries the surface
                // color as a ring so it reads as a marker on the control rather than part of its border.
                if hasNewOutput {
                    Circle().fill(Theme.accent).overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5)).frame(width: 9, height: 9).offset(
                        x: 1, y: -1)
                }
            }
            // Mirrors the floating shadow the Mac terminal pane banner uses for chrome sitting on top of the
            // terminal surface (`TerminalPaneBanner`: black at 0.18 opacity, radius 8, offset (0, -1)).
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: -1)
            // The visible circle stays 30pt; the tap target is widened to the 44pt minimum the same way the
            // Copy pill does it, so the hit area grows without inflating the control's visible size.
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("terminal-jump-to-bottom").accessibilityLabel(
            hasNewOutput ? "Jump to bottom, new output" : "Jump to bottom")
    }
}

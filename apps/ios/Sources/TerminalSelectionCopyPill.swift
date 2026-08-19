import SwiftUI

/// The single floating pill offered while the daemon's shared terminal selection is present. A tap reads
/// the selection's full text (including any part scrolled out of view) and copies it to the pasteboard;
/// iOS never creates a selection itself (#514), so this is the entire copy-side affordance.
///
/// `isCopied` swaps the label to "Copied" for brief confirmation after a successful copy; a failed copy
/// leaves the label reading "Copy" with no alert, so the user can simply retap (`TerminalDetailView`
/// owns that timing).
struct TerminalSelectionCopyPill: View {
    let isCopied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isCopied ? "Copied" : "Copy").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent).lineLimit(1).padding(.horizontal, 12)
                .padding(.vertical, 6).background(Capsule().fill(Theme.surface2)).overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 1))
                // The pill reads as a compact callout, but every tap target stays at least the 44pt minimum:
                // padding the capsule itself out to 44pt would blow up its visual size, so the hit area is
                // widened past the visible capsule with `frame`/`contentShape` instead. The extra hit area
                // sits inside the anchor's above/below gap, never toward the selected text, so it cannot
                // cover content the user selected.
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("terminal.selectionCopy").accessibilityLabel(isCopied ? "Copied" : "Copy selection")
    }
}

import SwiftUI
import spacesterminalcore

/// The small `from → to` detail the update cards share.
struct DaemonVersionPairLabel: View {
    let pair: DaemonVersionPair

    var body: some View {
        HStack(spacing: 5) {
            Text(pair.from).foregroundStyle(Theme.mutedSecondary)
            Text("\u{2192}").foregroundStyle(Theme.accent)
            Text(pair.to).foregroundStyle(Theme.text)
        }.font(.system(size: 12).monospacedDigit()).lineLimit(1)
    }
}

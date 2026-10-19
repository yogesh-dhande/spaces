import SwiftUI

/// The bar a self-update step shows: filled to the downloaded fraction, spinning when there is nothing to
/// measure, and full but dimmed for a step the device is finishing, so it reads as in progress without
/// claiming a percentage.
struct DaemonSelfUpdateProgressBar: View {
    let progress: DaemonSelfUpdateContent.Progress

    var body: some View {
        switch progress {
        case .determinate(let fraction): ProgressView(value: fraction).tint(Theme.accent)
        case .indeterminate: ProgressView().progressViewStyle(.linear).tint(Theme.accent)
        case .full: ProgressView(value: 1).tint(Theme.accent).opacity(0.45)
        }
    }
}

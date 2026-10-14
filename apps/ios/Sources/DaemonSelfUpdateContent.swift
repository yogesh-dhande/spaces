import spacesterminalcore

/// What the self-update card and the blocked hero say for one resolved `DaemonSelfUpdatePresentation`,
/// built from the shared copy so the Mac and the phone state the same facts the same way.
struct DaemonSelfUpdateContent: Equatable {
    enum Progress: Equatable {
        /// Fraction of the download received, 0 through 1.
        case determinate(Double)
        /// A running step with nothing to measure.
        case indeterminate
        /// A step the device is finishing; the bar is full and the step text says what it is doing. The Mac
        /// shows these steps with AppKit's animated indeterminate bar; SwiftUI on iOS has no indeterminate
        /// linear style (only a spinner), so a dimmed full bar keeps the card's shape steady instead.
        case full
    }

    let title: String
    let versionPair: DaemonVersionPair
    let body: String
    let footnote: String?
    let progress: Progress?
    /// The available state's button starts an update; the stalled and failed states' button retries one.
    let actionTitle: String?
    /// True for the states that went wrong or stalled, drawn with an orange border instead of the accent.
    let isWarning: Bool
    let isAvailable: Bool

    /// `nil` when the device has nothing to say about self-update.
    static func make(_ presentation: DaemonSelfUpdatePresentation, deviceName: String) -> DaemonSelfUpdateContent? {
        func pair(_ from: String, _ to: String) -> DaemonVersionPair { DaemonVersionPair(from: DaemonVersionPair.displayVersion(from), to: to) }
        let updatingTitle = DaemonSelfUpdateCopy.downloadingTitle(deviceName: deviceName)
        switch presentation {
        case .none: return nil
        case .available(let from, let to):
            return DaemonSelfUpdateContent(
                title: DaemonSelfUpdateCopy.availableTitle, versionPair: pair(from, to),
                body: DaemonSelfUpdateCopy.availableBody(version: to, deviceName: deviceName), footnote: nil, progress: nil,
                actionTitle: DaemonSelfUpdateCopy.updateButtonTitle(deviceName: deviceName), isWarning: false, isAvailable: true)
        case .downloading(let from, let to, let received, let total):
            let progress: Progress
            if let total, total > 0 { progress = .determinate(min(1, max(0, Double(received) / Double(total)))) } else { progress = .indeterminate }
            return DaemonSelfUpdateContent(
                title: updatingTitle, versionPair: pair(from, to), body: DaemonSelfUpdateCopy.downloadingDetail(received: received, total: total),
                footnote: DaemonSelfUpdateCopy.downloadingFootnote, progress: progress, actionTitle: nil, isWarning: false, isAvailable: false)
        case .installing(let from, let to):
            return DaemonSelfUpdateContent(
                title: updatingTitle, versionPair: pair(from, to), body: DaemonSelfUpdateCopy.installingBody(version: to), footnote: nil,
                progress: .full, actionTitle: nil, isWarning: false, isAvailable: false)
        case .restarting(let from, let to):
            return DaemonSelfUpdateContent(
                title: updatingTitle, versionPair: pair(from, to), body: DaemonSelfUpdateCopy.restartingBody(version: to), footnote: nil,
                progress: .full, actionTitle: nil, isWarning: false, isAvailable: false)
        case .stillRestarting(let from, let to):
            return DaemonSelfUpdateContent(
                title: DaemonSelfUpdateCopy.stillRestartingTitle, versionPair: pair(from, to),
                body: DaemonSelfUpdateCopy.stillRestartingBody(deviceName: deviceName, version: to), footnote: nil, progress: nil,
                actionTitle: DaemonSelfUpdateCopy.tryAgainTitle, isWarning: true, isAvailable: false)
        case .failed(let from, let to, let reason):
            return DaemonSelfUpdateContent(
                title: DaemonSelfUpdateCopy.failedTitle, versionPair: pair(from, to), body: reason, footnote: nil, progress: nil,
                actionTitle: DaemonSelfUpdateCopy.tryAgainTitle, isWarning: true, isAvailable: false)
        }
    }
}

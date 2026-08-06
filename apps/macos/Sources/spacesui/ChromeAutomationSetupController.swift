import AppKit
import Foundation
import spacesterminalcore
import systembridge

/// The first-run blocking screen that gates the workspace UI until Spaces is allowed to control
/// Google Chrome through Apple Events (the macOS "Automation" permission). Spaces drives every
/// browser-session focus by scripting Chrome, so the app cannot function without it.
///
/// The screen presents a single primary action whose label and behavior depend on the mode:
/// - `needsGrant`: "Grant Access" raises the macOS consent prompt while the grant is undecided.
/// - `denied`: "Open System Settings" deep-links to the Automation pane, because macOS stops
///   offering the prompt after a denial.
/// - `promptSuppressed`: "Open System Settings", with guidance to reset a stale permission record
///   that is keeping macOS from ever showing the prompt (see `ChromeAutomationAskOutcome`).
///
/// A 1.5s poll advances automatically once access is granted (so enabling it in System Settings
/// needs no relaunch) and can escalate `needsGrant` to `denied`, but never regresses an
/// ask-derived `denied`/`promptSuppressed` back to `needsGrant` — the ask result is more
/// authoritative than a passive read, and re-offering "Grant Access" there would re-offer an action
/// that provably does nothing. Manual "Recheck" fully re-applies the passive status (including back
/// to `needsGrant`), which is the recovery path after the user resets the stale record.
@MainActor final class ChromeAutomationSetupController {
    /// The mode drives the primary action's title, behavior, and the status text. Distinct from
    /// `ChromeAutomationStatus`: `denied` and `promptSuppressed` both derive from a refused ask and
    /// are latched against the poll, whereas the passive status only ever reads back the raw TCC state.
    enum Mode: Equatable {
        case needsGrant
        case denied
        case promptSuppressed
    }

    var onGranted: (() -> Void)?

    /// The current mode, exposed for tests. `nil` until `begin()`/`recheck()` applies a status.
    private(set) var mode: Mode?

    private let statusProvider: @Sendable () -> ChromeAutomationStatus
    private let askProvider: @Sendable () -> ChromeAutomationAskOutcome

    private let container = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private var pollTimer: Timer?
    private var isRequestingAccess = false

    /// - Parameters:
    ///   - statusProvider: reads the passive automation status; defaults to the real system check.
    ///   - askProvider: raises the consent prompt and classifies the result; defaults to the real ask.
    ///     Both are injectable so tests can drive the state machine without timers or Apple Events.
    init(
        statusProvider: @escaping @Sendable () -> ChromeAutomationStatus = { ChromeAutomationPermission.status() },
        askProvider: @escaping @Sendable () -> ChromeAutomationAskOutcome = { ChromeAutomationPermission.requestAccessOutcome() }
    ) {
        self.statusProvider = statusProvider
        self.askProvider = askProvider
    }

    /// The step's content view. The caller installs this before calling `begin()`, because a
    /// permission granted between the caller's check and `begin()` completes the step through
    /// `onGranted` before `begin()` returns, and the next step's content must win.
    var view: NSView { container }

    /// Applies the current permission state and starts polling so a grant made in System Settings
    /// advances the app without a relaunch. Completes immediately through `onGranted` — before
    /// returning — when the permission is already granted.
    func begin() {
        buildLayout()
        // Poll before applying the status, not after: an already-granted permission completes the step
        // from inside `applyStatus`, and its `stop()` can only invalidate a timer that already exists.
        // Starting the timer afterwards would leave it running against a step nobody can stop again.
        startPolling()
        applyStatus(statusProvider())
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Whether the auto-advance poll is running. Exposed for tests to confirm a granted permission
    /// stops polling.
    var isPolling: Bool { pollTimer != nil }

    private func buildLayout() {
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Allow Spaces to control Google Chrome")
        title.font = Typography.sheetTitle
        title.alignment = .center

        let body = NSTextField(
            wrappingLabelWithString: "Spaces opens and focuses your workspace browser sessions in Google Chrome. macOS asks for your "
                + "permission before Spaces can control Chrome.")
        body.font = Typography.body
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = Typography.rowDetail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        // One primary action whose title/behavior change with the mode. Keeping a single button —
        // rather than swapping two different-width buttons via `isHidden` — avoids the stack reflow
        // that misaligned the layout across a denied → notDetermined round trip.
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(primaryAction)

        let recheckButton = NSButton(title: "Recheck", target: self, action: #selector(recheckAction))
        recheckButton.bezelStyle = .accessoryBar
        recheckButton.controlSize = .small

        let stack = NSStackView(views: [icon, title, body, statusLabel, actionButton, recheckButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(18, after: statusLabel)
        stack.setCustomSpacing(10, after: actionButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor), stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420), body.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    /// Fully reflects a freshly read passive status in the screen and advances once granted. Called
    /// from `begin()` and manual `recheck()`, both of which trust the passive read completely — unlike
    /// the poll, which latches ask-derived denials (see `pollTick`).
    private func applyStatus(_ status: ChromeAutomationStatus) {
        switch status {
        case .granted, .unavailable: complete()
        case .notDetermined: enter(.needsGrant)
        case .denied: enter(.denied)
        }
    }

    /// Applies a mode to the screen: sets the current mode and refreshes the action button and status
    /// text. Layout stays fixed; only titles and the button's semantics change.
    private func enter(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .needsGrant:
            actionButton.title = "Grant Access"
            statusLabel.stringValue = "Click Grant Access, then choose OK when macOS asks to allow Spaces to control Chrome."
        case .denied:
            actionButton.title = "Open System Settings"
            statusLabel.stringValue =
                "Chrome control is turned off for Spaces. Open System Settings ▸ Privacy & Security ▸ Automation and enable Google Chrome for Spaces."
        case .promptSuppressed:
            actionButton.title = "Open System Settings"
            statusLabel.stringValue = Self.promptSuppressedStatusText
        }
    }

    private func complete() {
        stop()
        onGranted?()
    }

    /// Guidance for the suppressed-prompt state, where macOS refuses to show the consent prompt
    /// because a permission record from a different Spaces build signature is on file. The remedy is a
    /// `tccutil reset AppleEvents <bundle id>`; the bundle id is the running app's, never a hardcoded
    /// constant (the only Chrome bundle id in this module is the automation *target*, not Spaces).
    static var promptSuppressedStatusText: String {
        if let bundleID = Bundle.main.bundleIdentifier {
            return "macOS didn't show the consent prompt because a permission record from a previous Spaces build is in the way. "
                + "Reset it by running `tccutil reset AppleEvents \(bundleID)` in Terminal, then click Recheck."
        }
        return "macOS didn't show the consent prompt because a permission record from a previous Spaces build is in the way. "
            + "Reset the Automation permission for Spaces, then click Recheck."
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollTick() } }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// One poll iteration. Deliberately narrower than `applyStatus`: it may advance to done on a
    /// granted/unavailable read and may escalate `needsGrant` → `denied`, but it must never move an
    /// ask-derived `denied`/`promptSuppressed` mode back to `needsGrant`. The passive read behind a
    /// suppressed prompt reports `notDetermined`, so regressing on it would re-offer a "Grant Access"
    /// button that provably does nothing — the flip-flop this latch exists to stop.
    func pollTick() {
        guard !isRequestingAccess else { return }
        let status = statusProvider()
        switch status {
        case .granted, .unavailable: complete()
        case .denied: enter(.denied)
        case .notDetermined:
            // Only offer the grant path when no ask-derived denial is latched. Leave `denied`/
            // `promptSuppressed` untouched.
            if mode == nil || mode == .needsGrant { enter(.needsGrant) }
        }
    }

    /// Raises the consent prompt and applies the classified outcome. Wrapped by the `@objc` button
    /// action; exposed for tests to drive without an AppKit event. The poll is suppressed for the
    /// duration so it cannot overwrite the ask result mid-flight.
    func performGrantAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        actionButton.isEnabled = false
        defer {
            isRequestingAccess = false
            actionButton.isEnabled = true
        }
        let outcome = await Task.detached { [askProvider] in askProvider() }.value
        switch outcome {
        case .granted: complete()
        case .deniedByUser: enter(.denied)
        case .promptSuppressed: enter(.promptSuppressed)
        }
    }

    /// Fully re-applies the passive status, including back to `needsGrant`. This is the only path that
    /// can un-latch a `denied`/`promptSuppressed` mode, serving as the recovery after the user resets
    /// a stale TCC record (`tccutil reset AppleEvents …`) so the prompt can appear again.
    func recheck() { applyStatus(statusProvider()) }

    @objc private func primaryAction() {
        switch mode {
        case .needsGrant: Task { @MainActor in await self.performGrantAccess() }
        case .denied, .promptSuppressed: openSystemSettings()
        case nil: break
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: ChromeAutomationPermission.systemSettingsAutomationURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func recheckAction() { recheck() }
}

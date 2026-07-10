import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import systembridge

/// Sequences the launch setup steps, replacing the main window's content until every pending step is
/// done, then handing back to the workspace UI through `onComplete`. A launch with no pending step
/// completes immediately and is never seen.
///
/// Two steps exist. Chrome Automation blocks: Spaces focuses browser sessions by scripting Chrome and
/// cannot work without it. Coding-agent hooks do not: they make agents report their state, but Spaces
/// runs without them, and Spaces never writes a coding agent's config without the user asking — so
/// hooks are offered here and in Settings → Coding Agents rather than installed silently.
@MainActor final class SetupFlowController {
    /// Called once every pending step has been completed or skipped.
    var onComplete: (() -> Void)?

    /// How long launch waits for the local daemon to report agent status before giving up on the
    /// coding-agents step for this launch.
    ///
    /// This must stay larger than the Device API's own request timeout, or the probe is abandoned
    /// before the request it is waiting on can succeed or fail — which silently drops the step on
    /// exactly the cold-daemon launch where it is most needed. The daemon also resolves agent
    /// availability by asking the user's login shell for its `PATH`, sourcing their whole rc chain,
    /// which is slow the first time and cached afterwards.
    ///
    /// The probe starts when the flow begins and runs while the Chrome Automation step is on screen,
    /// so a user who has that step to complete never waits on it at all. A daemon that is wedged must
    /// not hold the app on a spinner forever; giving up costs the user nothing, because the step is
    /// left undismissed and reappears next launch.
    static let localAgentStatusTimeout: Duration = .seconds(15)

    private unowned let host: any CodingAgentsHost
    private let database: SpacesClientDatabase?
    private let container = NSView()
    private var chromeSetup: ChromeAutomationSetupController?
    /// Retained for the lifetime of the step: it is the target of the per-agent install buttons, and
    /// `NSControl.target` does not hold its target.
    private var codingAgents: CodingAgentsView?
    private var continueButton: NSButton?
    /// Started when the flow begins so it overlaps the Chrome Automation step. Nil when the step is
    /// already dismissed for this hook version, in which case no daemon call is made at all.
    private var localAgentStatusTask: Task<[AgentHookStatus]?, Never>?

    init(host: any CodingAgentsHost, database: SpacesClientDatabase?) {
        self.host = host
        self.database = database
        container.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Pure decisions

    /// Whether launch should even ask the daemon for agent status. Once the user has dismissed the step
    /// for the hook version this build writes, there is nothing a probe could change — so the steady
    /// state costs no daemon round trip at all.
    static func shouldProbeLocalAgents(dismissedHookVersion: Int?, currentHookVersion: Int) -> Bool {
        dismissedHookVersion != currentHookVersion
    }

    /// Whether the coding-agents step should be shown.
    ///
    /// `localAgents == nil` means the local daemon did not answer. Omit the step rather than nag about
    /// agents Spaces could not see — and, crucially, the caller must not record a dismissal in that
    /// case, or an unreachable daemon at first launch would suppress the step forever.
    ///
    /// The decision reads This Mac only. A paired remote may be asleep or unreachable, and blocking
    /// launch on its round trip would hang the app; the step's device picker still installs on remotes.
    static func requiresCodingAgentsSetup(localAgents: [AgentHookStatus]?, dismissedHookVersion: Int?, currentHookVersion: Int) -> Bool {
        guard let localAgents, shouldProbeLocalAgents(dismissedHookVersion: dismissedHookVersion, currentHookVersion: currentHookVersion) else {
            return false
        }
        return localAgents.contains { $0.available && $0.installState != .current }
    }

    // MARK: - Flow

    /// The flow's content view. The caller installs this as the window's content *before* calling
    /// `begin()`, because a launch with no pending step completes inside `begin()` and hands the window
    /// to the workspace UI; installing it afterwards would cover that UI with this empty container.
    var view: NSView { container }

    /// Enters the first pending step. Completes immediately through `onComplete` — before returning —
    /// when no step is pending.
    func begin() {
        // Start the probe before the first step renders, so a cold `spacesd` warms up while the user
        // works through the Chrome Automation screen instead of after it.
        if Self.shouldProbeLocalAgents(dismissedHookVersion: dismissedHookVersion(), currentHookVersion: AgentHookCommand.hookVersion) {
            let profile = try? SpacesProfile.current()
            localAgentStatusTask = Task.detached(priority: .userInitiated) { Self.localAgentStatus(profile: profile) }
        }
        if AppKitController.requiresChromeAutomationSetup(ChromeAutomationPermission.status()) {
            enterChromeAutomationStep()
        } else {
            enterCodingAgentsStepIfNeeded()
        }
    }

    func stop() {
        chromeSetup?.stop()
        chromeSetup = nil
    }

    private func finish() {
        stop()
        onComplete?()
    }

    private func enterChromeAutomationStep() {
        chromeSetup?.stop()
        let controller = ChromeAutomationSetupController()
        chromeSetup = controller
        // Capture `controller` weakly: it owns `onGranted`, so a strong capture would retain the
        // controller (and its view hierarchy) past the point where `stop()` clears `chromeSetup`,
        // leaking a setup controller each time the flow is shown.
        controller.onGranted = { [weak self, weak controller] in
            guard let self, let controller, self.chromeSetup === controller else { return }
            self.chromeSetup?.stop()
            self.chromeSetup = nil
            self.enterCodingAgentsStepIfNeeded()
        }
        // Show the step before starting it, never after: an already-granted permission fires
        // `onGranted` inside `begin()`, and the content the next step installs must not be replaced
        // by this step's now-inert view.
        setContent(controller.view)
        controller.begin()
    }

    /// Resolves the coding-agents step against the local daemon, then either shows it or hands off to
    /// the workspace UI. The status probe runs here rather than inside `CodingAgentsView` because the
    /// answer decides whether the step exists at all.
    private func enterCodingAgentsStepIfNeeded() {
        let currentVersion = AgentHookCommand.hookVersion
        guard Self.shouldProbeLocalAgents(dismissedHookVersion: dismissedHookVersion(), currentHookVersion: currentVersion) else {
            finish()
            return
        }
        setContent(probingPlaceholder())
        Task { @MainActor [weak self] in
            guard let self else { return }
            let localAgents = await localAgentStatusWithinTimeout()
            guard Self.requiresCodingAgentsSetup(localAgents: localAgents, dismissedHookVersion: dismissedHookVersion(), currentHookVersion: currentVersion)
            else {
                // Every detected agent is already current: nothing to ask, and nothing will change until
                // the hook version moves, so record the dismissal. When the daemon never answered
                // (`localAgents == nil`) leave it unrecorded so the next launch asks again.
                if localAgents != nil { recordDismissedHookVersion() }
                finish()
                return
            }
            showCodingAgentsStep()
        }
    }

    private func showCodingAgentsStep() {
        let agents = CodingAgentsView(host: host)
        agents.onLocalStatusChange = { [weak self] summary in
            self?.continueButton?.title = summary.allDetectedCurrent ? "Done" : "Continue"
        }
        codingAgents = agents

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Connect your coding agents")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center

        let body = NSTextField(
            wrappingLabelWithString: "Spaces can install lifecycle hooks so each agent reports when it starts, is working, is blocked on you, "
                + "or finishes. You can install these later from Settings.")
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center

        let skipButton = NSButton(title: "Skip", target: self, action: #selector(dismissCodingAgentsStep))
        skipButton.bezelStyle = .rounded
        skipButton.controlSize = .large
        skipButton.setAccessibilityIdentifier("setup-coding-agents-skip")

        let continueButton = NSButton(title: "Continue", target: self, action: #selector(dismissCodingAgentsStep))
        continueButton.bezelStyle = .rounded
        continueButton.controlSize = .large
        continueButton.keyEquivalent = "\r"
        continueButton.setAccessibilityIdentifier("setup-coding-agents-continue")
        self.continueButton = continueButton

        let buttonRow = NSStackView(views: [skipButton, continueButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let card = agents.makeCard(subtitle: "Detected agents on this machine and any paired device.")

        let stack = NSStackView(views: [icon, title, body, card, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(22, after: body)
        stack.setCustomSpacing(22, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false

        setContent(centered(stack, maximumWidth: 560, extraConstraints: [body.widthAnchor.constraint(lessThanOrEqualToConstant: 440)]))
    }

    /// Skip and Continue do the same thing, and deliberately so: both mean "stop asking me about this
    /// hook version". The user has seen the step and decided, whether or not they installed anything.
    /// A later Spaces release that changes the hooks bumps `hookVersion` and asks once more.
    @objc private func dismissCodingAgentsStep() {
        recordDismissedHookVersion()
        finish()
    }

    // MARK: - Local agent status

    /// Awaits the probe started in `begin()`, or nil when it has not answered within
    /// `localAgentStatusTimeout`. The probe is a blocking Device API call, so it cannot be cancelled;
    /// the timeout stops *waiting* on it rather than stopping it, and the orphaned request is harmless
    /// because it is read-only. A probe that started during the Chrome step has usually already
    /// finished, in which case this returns at once.
    private func localAgentStatusWithinTimeout() async -> [AgentHookStatus]? {
        guard let localAgentStatusTask else { return nil }
        return await withCheckedContinuation { continuation in
            let hasResumed = ResumeOnce()
            Task {
                let status = await localAgentStatusTask.value
                if hasResumed.claim() { continuation.resume(returning: status) }
            }
            Task {
                try? await Task.sleep(for: Self.localAgentStatusTimeout)
                if hasResumed.claim() {
                    NSLog("Spaces: coding-agents setup step skipped, local daemon did not report agent status in time")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated static func localAgentStatus(profile: SpacesProfile?) -> [AgentHookStatus]? {
        do {
            // Bootstrap rather than read the stored paired-device record. This is the launch's first
            // daemon call, and only bootstrapping starts `spacesd`: a plain request re-bootstraps just
            // to recover a *missing* auth token, so with a token already on disk it dials the record's
            // endpoint and waits out its whole timeout against a daemon nobody started. Bootstrapping
            // also returns the daemon's current host, port, and certificate fingerprint, which a record
            // persisted before the last restart can no longer be trusted to carry (a dev profile binds
            // an ephemeral Device API port; installed builds keep the fixed default).
            let local = try SpacesDeviceClient.bootstrapLocalDevice(clientApp: SpacesDeviceClient.macOSClientApp(), profile: profile)
            return try SpacesDeviceClient.agentHooksStatus(device: local, profile: profile)
        } catch {
            // The step is skipped for this launch and left undismissed, so it is offered again once
            // the daemon answers. Logged because a probe that always failed would otherwise present as
            // a setup step that silently never appears.
            NSLog("Spaces: coding-agents setup step skipped, agent hook status unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Guards a `CheckedContinuation` that two racing tasks may reach; only the first claim resumes it.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    // MARK: - Dismissal marker

    private func dismissedHookVersion() -> Int? {
        guard let database, let stored = try? database.setting(key: ClientSettingsKey.agentHooksSetupDismissedVersion) else { return nil }
        return Int(stored)
    }

    private func recordDismissedHookVersion() {
        try? database?.setSetting(key: ClientSettingsKey.agentHooksSetupDismissedVersion, value: String(AgentHookCommand.hookVersion))
    }

    // MARK: - Layout

    private func probingPlaceholder() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: "Checking your coding agents...")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        return centered(stack, maximumWidth: 320, extraConstraints: [])
    }

    private func centered(_ stack: NSView, maximumWidth: CGFloat, extraConstraints: [NSLayoutConstraint]) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate(
            [
                stack.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor), stack.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
                stack.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth),
            ] + extraConstraints)
        return wrapper
    }

    private func setContent(_ view: NSView) {
        for subview in container.subviews { subview.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor), view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor), view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

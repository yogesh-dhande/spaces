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
/// Three steps exist. Chrome Automation blocks: Spaces focuses browser sessions by scripting Chrome and
/// cannot work without it. Coding-agent hooks do not: they make agents report their state, but Spaces
/// runs without them, and Spaces never writes a coding agent's config without the user asking, so
/// hooks are offered here and in Settings → Coding Agents rather than installed silently. Restore
/// sessions asks what to do with the coding agents the local daemon is offering to bring back; it is
/// last because its answer has to land immediately before the workspace UI restores its pane layouts,
/// which is what puts each restored agent back in the pane its predecessor held.
@MainActor final class SetupFlowController {
    /// Called once every pending step has been completed or skipped.
    var onComplete: (() -> Void)?

    /// How long a launch waits on the local daemon in total before giving up on the steps that read it
    /// (coding agents, and the restore offer) for this launch.
    ///
    /// This must stay larger than the Device API's own request timeout, or a probe is abandoned
    /// before the request it is waiting on can succeed or fail, which silently drops the step on
    /// exactly the cold-daemon launch where it is most needed. The daemon also resolves agent
    /// availability by asking the user's login shell for its `PATH`, sourcing their whole rc chain,
    /// which is slow the first time and cached afterwards.
    ///
    /// It is a budget for the whole flow, not per step: the probes start when the flow begins and run
    /// while the Chrome Automation step is on screen, so a user who has that step to complete never
    /// waits on them at all, and a wedged daemon costs one timeout however many steps read it. Giving
    /// up costs the user nothing, because the steps are left undismissed and reappear next launch.
    static let localProbeTimeout: Duration = .seconds(25)

    private unowned let host: any CodingAgentsHost
    private let database: SpacesClientDatabase?
    private let sessionRestore: SessionRestoreController
    private let container = NSView()
    private var chromeSetup: ChromeAutomationSetupController?
    /// Retained for the lifetime of the step: it is the target of the per-agent install buttons, and
    /// `NSControl.target` does not hold its target. Released by `stopCodingAgentsStep` as the step is
    /// left, whichever way it is left.
    private(set) var codingAgents: CodingAgentsView?
    private var continueButton: NSButton?
    /// Retained for the lifetime of the restore step, for the same reason as `codingAgents`.
    private var restoreOffer: SessionRestoreOfferView?
    /// The local daemon's status, whose `restorableSessions` decide the restore step. Started when the
    /// flow begins so it overlaps the Chrome Automation step.
    private var daemonStatusWait: LaunchProbeWait<TerminalServiceDaemonStatus>?
    /// The local agent hook status that decides the coding-agents step, or nil when that step is already
    /// dismissed for this hook version and nothing is asked.
    ///
    /// Waited on separately from the daemon status even though both come from the same daemon: this read
    /// is the slow one (it resolves the user's login shell `PATH`), and a launch where it hangs or fails
    /// must still be able to offer the restore step off the status that did come back.
    private var agentStatusWait: LaunchProbeWait<[AgentHookStatus]>?

    init(host: any CodingAgentsHost, database: SpacesClientDatabase?, sessionRestore: SessionRestoreController) {
        self.host = host
        self.database = database
        self.sessionRestore = sessionRestore
        container.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Pure decisions

    /// Whether launch should even ask the daemon for agent status. A dismissal is the only thing that
    /// can suppress the probe, because it is the only thing a probe could not overturn: the user has
    /// said no for this hook version. Every other launch must ask, since the answer is exactly what
    /// this cannot know locally — whether the user has since installed a coding agent whose hooks are
    /// missing. Suppressing the probe on "nothing to install right now" would freeze that answer
    /// forever and silently retire the step for a user who installs Claude or Codex tomorrow.
    static func shouldProbeLocalAgents(dismissedHookVersion: Int?, currentHookVersion: Int) -> Bool { dismissedHookVersion != currentHookVersion }

    /// Whether the coding-agents step should be shown.
    ///
    /// `localAgents == nil` means the local daemon did not answer. Omit the step rather than nag about
    /// agents Spaces could not see.
    ///
    /// The decision reads This Mac only. A paired remote may be asleep or unreachable, and blocking
    /// launch on its round trip would hang the app; the step's device picker still installs on remotes.
    static func requiresCodingAgentsSetup(localAgents: [AgentHookStatus]?, dismissedHookVersion: Int?, currentHookVersion: Int) -> Bool {
        guard let localAgents, shouldProbeLocalAgents(dismissedHookVersion: dismissedHookVersion, currentHookVersion: currentHookVersion) else {
            return false
        }
        // Anything short of `current` keeps the step, including hooks an agent has not been told to
        // trust. Spaces cannot finish that one itself, but the step is where the row explains what the
        // user does about it, and the alternative is launching straight past an agent that reports
        // nothing.
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
        // Start the probes before the first step renders, so a cold `spacesd` warms up while the user
        // works through the Chrome Automation screen instead of after it.
        let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
        let deadline = ContinuousClock.now.advanced(by: Self.localProbeTimeout)
        // One bootstrap for both reads: a launch must start `spacesd` once, not twice. The agent probe
        // waits on the context this one produces, and its failure or hang stays its own.
        let connection = Task.detached(priority: .userInitiated) { Self.bootstrapLocalDaemon(profile: profile) }
        daemonStatusWait = LaunchProbeWait(
            description: "the launch restore step", deadline: deadline,
            task: Task.detached(priority: .userInitiated) {
                guard let context = await connection.value else { return nil }
                return Self.probe("the daemon status") { try SpacesDeviceClient.daemonStatus(context: context) }
            })
        if Self.shouldProbeLocalAgents(dismissedHookVersion: dismissedHookVersion(), currentHookVersion: AgentHookCommand.hookVersion) {
            agentStatusWait = LaunchProbeWait(
                description: "the launch coding-agents step", deadline: deadline,
                task: Task.detached(priority: .userInitiated) {
                    guard let context = await connection.value else { return nil }
                    return Self.probe("the coding agent hook status") { try SpacesDeviceClient.agentHooksStatus(context: context) }
                })
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
        stopCodingAgentsStep()
    }

    /// Tears the coding-agents step down as it is left. `finish()` reaches this through `stop()`, but the
    /// step is also left for the restore step, which does not finish the flow: without this, the removed
    /// view stays retained behind the restore prompt with its agent-config file watcher and its reload
    /// callbacks still live.
    private func stopCodingAgentsStep() {
        codingAgents?.stopAgentConfigWatch()
        codingAgents = nil
        continueButton = nil
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
            enterRestoreSessionsStepIfNeeded()
            return
        }
        setContent(probingPlaceholder(message: "Checking your coding agents..."))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let agents = await agentStatusWait?.value()
            guard
                Self.requiresCodingAgentsSetup(localAgents: agents, dismissedHookVersion: dismissedHookVersion(), currentHookVersion: currentVersion)
            else {
                // Nothing to install right now: either no detected agent needs hooks, or the daemon
                // never answered. Do not record a dismissal: the user has not seen the step, and
                // "nothing to do today" is not "never ask again". Recording one here would retire the
                // step for good the moment it first ran on a machine with no coding agent installed.
                enterRestoreSessionsStepIfNeeded()
                return
            }
            showCodingAgentsStep()
        }
    }

    /// Internal rather than private so a test can enter this step without a daemon to probe.
    func showCodingAgentsStep() {
        let agents = CodingAgentsView(host: host)
        agents.onLocalStatusChange = { [weak self] summary in self?.continueButton?.title = summary.allDetectedCurrent ? "Done" : "Continue" }
        codingAgents = agents

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "Connect your coding agents")
        title.font = Typography.sheetTitle
        title.alignment = .center

        let body = NSTextField(
            wrappingLabelWithString: "Spaces can install lifecycle hooks so each agent reports when it starts, is working, is blocked on you, "
                + "or finishes. You can install these later from Settings.")
        body.font = Typography.body
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
        stopCodingAgentsStep()
        enterRestoreSessionsStepIfNeeded()
    }

    // MARK: - Restore sessions step

    /// Offers the coding-agent sessions the local daemon captured when Spaces last stopped, then hands
    /// off to the workspace UI. Skipped in one breath when the daemon is offering nothing, or when this
    /// client has already answered the record it is offering.
    private func enterRestoreSessionsStepIfNeeded() {
        // Only show the spinner when there is actually something to wait for. The status usually landed
        // while an earlier step was on screen, in which case this resolves without a frame of
        // placeholder.
        if daemonStatusWait?.isSettled == false { setContent(probingPlaceholder(message: "Checking for unfinished sessions...")) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let daemonStatus = await daemonStatusWait?.value()
            guard let offer = sessionRestore.launchOffer(localDaemonStatus: daemonStatus) else {
                finish()
                return
            }
            showRestoreSessionsStep(offer: offer)
        }
    }

    private func showRestoreSessionsStep(offer: SessionRestoreOffer) {
        let view = SessionRestoreOfferView(offer: offer, host: host) { [weak self] answer in self?.answerRestoreOffer(answer, offer: offer) }
        restoreOffer = view
        setContent(view.view)
    }

    /// Answers the offer and continues. The wait is deliberate: Restore relaunches the agents on the
    /// daemon and hands back where each one landed, and the pane retarget it drives has to be recorded
    /// before `onComplete` lets the workspace UI restore its layouts.
    ///
    /// An answer that never landed keeps the step on screen with the reason, rather than walking into the
    /// workspace UI as though the question had been settled: the agents are still on the device, nothing
    /// is recorded as answered, and the user can try again or Skip.
    private func answerRestoreOffer(_ answer: SessionRestoreAnswer, offer: SessionRestoreOffer) {
        restoreOffer?.showAnswerInProgress(answer == .restore ? "Restoring your sessions..." : "Discarding...")
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .failed(let message) = await sessionRestore.answer(answer, offer: offer, panePlacement: .persistedLayouts) {
                restoreOffer?.showAnswerFailed(message)
                return
            }
            finish()
        }
    }

    // MARK: - Local daemon probe

    /// Opens this launch's one connection to the local daemon, or nil when it cannot be reached.
    ///
    /// Bootstraps rather than reading the stored paired-device record. This is the launch's first
    /// daemon call, and only bootstrapping starts `spacesd`: a plain request re-bootstraps just to
    /// recover a *missing* auth token, so with a token already on disk it dials the record's endpoint
    /// and waits out its whole timeout against a daemon nobody started. Bootstrapping also returns the
    /// daemon's current host, port, and certificate fingerprint, which a record persisted before the
    /// last restart can no longer be trusted to carry (a dev profile binds an ephemeral Device API
    /// port; installed builds keep the fixed default).
    private nonisolated static func bootstrapLocalDaemon(profile: SpacesProfile?) -> DeviceRequestContext? {
        probe("the local daemon connection") {
            DeviceRequestContext(
                device: try SpacesDeviceClient.bootstrapLocalDevice(clientApp: SpacesDeviceClient.macOSClientApp(), profile: profile),
                profile: profile)
        }
    }

    /// Runs one probe read, reporting a failure as nil. Each read fails on its own: the steps decide
    /// independently, and every one of them treats a missing answer as "omit this step", so a read that
    /// fails costs the user only the step that needed it. Nothing is dismissed or answered either way,
    /// so both are offered again once the daemon answers: the hooks step next launch, and the restore
    /// offer as a sheet as soon as the daemon reports its record to the running app. Logged because a
    /// probe that always failed would otherwise present as setup steps that silently never appear.
    private nonisolated static func probe<Value>(_ description: String, _ read: () throws -> Value) -> Value? {
        do { return try read() } catch {
            NSLog("Spaces: launch setup could not read \(description): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Dismissal marker

    private func dismissedHookVersion() -> Int? {
        guard let database, let stored = try? database.setting(key: ClientSettingsKey.agentHooksSetupDismissedVersion) else { return nil }
        return Int(stored)
    }

    /// Records that the user saw the step and decided. Called only from `dismissCodingAgentsStep`, the
    /// Skip/Continue action: the marker means "the user said no to this hook version", never "Spaces
    /// found nothing to install", and writing it from anywhere else would suppress a step the user was
    /// never offered.
    private func recordDismissedHookVersion() {
        try? database?.setSetting(key: ClientSettingsKey.agentHooksSetupDismissedVersion, value: String(AgentHookCommand.hookVersion))
    }

    // MARK: - Layout

    private func probingPlaceholder(message: String) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: message)
        label.font = Typography.body
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

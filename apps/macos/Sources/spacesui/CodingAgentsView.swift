import AppKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// The shared form/database helpers `CodingAgentsView` needs from its host.
///
/// `AppKitController` supplies all of them, but the view is embedded in the launch setup flow as well
/// as in Settings, and the setup screen runs before the main window content exists. Depending on the
/// narrow protocol instead of the controller keeps that ordering from mattering, and keeps the view
/// testable without an app.
@MainActor protocol CodingAgentsHost: AnyObject {
    func formSectionCard(icon: String?, title: String, subtitle: String, iconColor: NSColor?, trailingView: NSView?, contentViews: [NSView]) -> NSView
    func settingsLabeledField(name: String, hint: String, control: NSView) -> NSView
    func helpTextLabel(_ text: String) -> NSTextField
    func clientDatabase() throws -> SpacesClientDatabase
    func macPairedDevices() -> [SpacesPairedDeviceRecord]
}

extension AppKitController: CodingAgentsHost {
    // These three forward to the free functions in FormControls.swift, resolving the sidebar's
    // theme-reactive colors that formSectionCard needs. The module-qualified `spacesui.` prefix
    // is required here: an unqualified call would resolve to this very method (matching name and
    // signature) and recurse forever.
    func formSectionCard(
        icon: String?, title: String, subtitle: String = "", iconColor: NSColor? = nil, trailingView: NSView? = nil, contentViews: [NSView]
    ) -> NSView {
        spacesui.formSectionCard(
            icon: icon, title: title, subtitle: subtitle, iconColor: iconColor, trailingView: trailingView, contentViews: contentViews,
            defaultAccentColor: sidebar.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184)),
            dividerColor: sidebar.sidebarCardBorderColor(isSelected: false))
    }

    func settingsLabeledField(name: String, hint: String, control: NSView) -> NSView {
        spacesui.settingsLabeledField(name: name, hint: hint, control: control)
    }

    func helpTextLabel(_ text: String) -> NSTextField { spacesui.helpTextLabel(text) }
}

/// Where a change to the agent's own config can land, resolved by `CodingAgentsView`.
///
/// At file scope rather than nested in the view because the filesystem watcher hands its callback this
/// value on its own queue, and a type nested in a `@MainActor` class is isolated to that actor.
struct AgentConfigWatchTargets: Sendable {
    /// The Codex config directory, resolved through any symlink, as FSEvents names it.
    let configDirectory: String
    /// The resolved path of each of the two files that is a symlink out of that directory.
    let linkedFiles: [String]
    /// The config directory plus each linked file's own directory: what the watcher is given.
    let directories: [String]
}

/// Lists supported coding agents for a selected device (This Mac or a paired remote), showing whether
/// each agent's CLI is detected and how completely its Spaces hooks are installed, with the one action
/// (Install, Update, or Trust) that moves a row toward reporting, when Spaces has one.
///
/// Status, installs, and trusts run against the selected device's daemon over the Device API, so one
/// view manages local and remote hooks. It is embedded in Settings → Coding Agents and in the launch
/// setup flow's coding-agents step.
///
/// Failures are held in memory rather than persisted: every install and trust is user-initiated, so the
/// failure is on screen at the moment it happens and cannot outlive the problem it describes.
@MainActor final class CodingAgentsView {
    /// What the local device's agents look like right now, for a setup step that wants to relabel its
    /// button without issuing a second status request.
    struct LocalSummary: Equatable {
        /// Every detected agent on This Mac carries current hooks. False when no agent is detected at
        /// all — there is nothing to have finished installing.
        let allDetectedCurrent: Bool
        /// Some detected agent is not reporting yet: hooks missing, hooks from an older Spaces, hooks
        /// the agent has not trusted, or hooks switched off in the agent. The last of those is finished
        /// by the user inside the agent rather than by a button here, but it is still work standing
        /// between them and an agent that reports anything, so it counts here for the same reason it
        /// keeps the setup step up.
        let hasActionableAgent: Bool
    }

    /// Fires after any status fetch, install, or trust that targeted the local device. Remote devices do not
    /// emit: the setup step's gating is deliberately local-only.
    var onLocalStatusChange: ((LocalSummary) -> Void)?

    private unowned let host: any CodingAgentsHost

    private var deviceID: String = SpacesPairedDeviceRecord.localDeviceID
    private weak var rowsContainer: NSStackView?
    private var status: [AgentHookStatus] = []
    /// The failure from the install or trust just run, per agent, so a row that Spaces could not fix
    /// explains itself instead of only reporting "hooks not installed". Every fresh status prunes it
    /// (`standingFailures`).
    private var failures: [CodingAgent: RowFailure] = [:]
    /// Increments per reload so a stale in-flight fetch's result is discarded when the user switches devices.
    private var reloadToken = 0
    /// Increments per install or trust so a stale completion cannot update rows for a different selected device.
    private var actionToken = 0
    /// The row action whose request is in flight, if any. One at a time across every row.
    private var inFlight: (kind: CodingAgent, action: RowAction)?
    /// Rows whose hooks this view trusted since the card was built. Trust reaches only sessions that
    /// start afterwards, so such a row says so for as long as the user is looking at the result.
    private var trustedRows: Set<TrustedRow> = []
    /// Watches the local Codex config directory while a row waits on something the user does outside
    /// Spaces. Nil whenever nothing is waiting; see `updateAgentConfigWatch`.
    private var agentConfigWatcher: FileSystemWatcher?
    /// Whether these rows are on screen. Set when the card is built (the section opened, or the setup
    /// step shown) and cleared when the section, the window, or the setup flow goes away. A status fetch
    /// that started while the rows were up lands after that, and it must not rebuild a watch for rows
    /// nothing is left to update.
    private var isActive = false
    /// Increments whenever the watch is dropped or replaced, so a callback already on its way when the
    /// watcher went away is discarded. `FileSystemWatcher.stop()` makes no promise about callbacks
    /// already in flight, and a dropped watcher is exactly the case where a reload has nowhere to land.
    private var agentConfigWatchGeneration = 0

    init(host: any CodingAgentsHost, onLocalStatusChange: ((LocalSummary) -> Void)? = nil) {
        self.host = host
        self.onLocalStatusChange = onLocalStatusChange
    }

    /// How long a burst of writes to the agent's config directory is coalesced before the rows reload.
    /// Long enough that the several writes one review makes cost one reload, short enough that the row
    /// has caught up by the time the user switches back to Spaces.
    static let agentConfigWatchLatency: TimeInterval = 0.3

    /// Whether the Codex row can change from under Spaces, through Codex's own config writes rather than
    /// through this view's button.
    ///
    /// Every state an installed Codex row moves between is one Codex writes: trusting the hooks,
    /// switching them off, switching them on again, and turning `features.hooks` off and on, which
    /// moves the row between `current` and `outdated` while the entries themselves stay put. A row
    /// sitting at `current` is the one the user is most likely to invalidate next, so watching only the
    /// waiting states leaves it reporting green after Codex has stopped running the hooks, and dropping
    /// the watch at `outdated` strands the row there until the section is reopened. `notInstalled` is
    /// the one state no Codex write reaches: an install is what leaves it, and this view reloads after
    /// its own install. Only Codex is asked about, because the watch covers Codex's config directory.
    static func needsAgentConfigWatch(status: [AgentHookStatus]) -> Bool {
        status.contains { $0.kind == .codex && $0.available && Self.agentConfigWatchStates.contains($0.installState) }
    }

    /// The install states Codex's own config writes reach and leave.
    static let agentConfigWatchStates: Set<AgentHookInstallState> = [.current, .outdated, .awaitingTrust, .disabledByAgent]

    /// Every detected agent's state, reduced to what a setup step needs to decide what to say.
    static func localSummary(status: [AgentHookStatus]) -> LocalSummary {
        let detected = status.filter(\.available)
        return LocalSummary(
            allDetectedCurrent: !detected.isEmpty && detected.allSatisfy { $0.installState == .current },
            hasActionableAgent: detected.contains { $0.installState != .current })
    }

    /// Builds the card and starts a status reload for the selected device.
    func makeCard(subtitle: String = "Install Spaces lifecycle hooks on this machine's coding agents.") -> NSView {
        isActive = true  // the rows are going on screen, so a change made outside Spaces has somewhere to land
        trustedRows = []
        let devices = self.devices()
        if !devices.contains(where: { $0.record.id == deviceID }) { deviceID = devices.first?.record.id ?? SpacesPairedDeviceRecord.localDeviceID }

        let picker = NSPopUpButton()
        for device in devices {
            picker.addItem(withTitle: device.label)
            picker.itemArray.last?.representedObject = device.record.id
        }
        picker.selectItem(at: devices.firstIndex { $0.record.id == deviceID } ?? 0)
        picker.target = self
        picker.action = #selector(deviceChanged(_:))
        picker.setAccessibilityIdentifier("settings-coding-agents-device")
        let deviceField = host.settingsLabeledField(name: "Device", hint: "Install hooks on this machine's coding agents.", control: picker)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        rowsContainer = rows
        renderRows(message: nil, isLoading: true)

        let hint = host.helpTextLabel("Hooks let each agent report when it starts, is working, is blocked on you, or finishes.")

        let card = host.formSectionCard(
            icon: "chevron.left.forwardslash.chevron.right", title: "Coding Agents", subtitle: subtitle, iconColor: nil, trailingView: nil,
            contentViews: [deviceField, rows, hint])
        reload()
        return card
    }

    // MARK: - Device selection

    /// This Mac plus every paired remote, as (record, display label) pairs.
    private func devices() -> [(record: SpacesPairedDeviceRecord, label: String)] {
        var devices: [(SpacesPairedDeviceRecord, String)] = []
        if let local = try? host.clientDatabase().pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID) { devices.append((local, "This Mac")) }
        for remote in host.macPairedDevices() { devices.append((remote, remote.name)) }
        return devices
    }

    private func resolvedDevice() -> (record: SpacesPairedDeviceRecord, label: String)? { devices().first { $0.record.id == deviceID } }

    private var isLocalDeviceSelected: Bool { deviceID == SpacesPairedDeviceRecord.localDeviceID }

    @objc private func deviceChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String, id != deviceID else { return }
        deviceID = id
        status = []
        failures = [:]
        inFlight = nil
        dropAgentConfigWatch()  // the rows are about to describe a different machine's files
        reload()
    }

    // MARK: - Status fetch

    func reload() {
        reloadToken += 1
        let token = reloadToken
        guard let device = resolvedDevice()?.record else {
            renderRows(message: "This device is unavailable.", isLoading: false)
            return
        }
        status = []
        renderRows(message: nil, isLoading: true)
        let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SpacesDeviceClient.agentHooksStatus(context: DeviceRequestContext(device: device, profile: profile)) }
            await self?.applyStatusFetch(result, token: token)
        }
    }

    private func applyStatusFetch(_ result: Result<[AgentHookStatus], any Error>, token: Int) {
        // A newer reload superseded this fetch, or the rows went away while it was in flight.
        guard isActive, token == reloadToken else { return }
        switch result {
        case .success(let fetched):
            status = fetched
            failures = Self.standingFailures(failures, after: fetched)
            renderRows(message: nil, isLoading: false)
        case .failure(let error):
            status = []
            renderRows(message: "Could not reach this device: \(error.localizedDescription)", isLoading: false)
        }
        updateAgentConfigWatch()
        emitLocalStatusChangeIfLocal()
    }

    private func emitLocalStatusChangeIfLocal() {
        guard isLocalDeviceSelected else { return }
        onLocalStatusChange?(Self.localSummary(status: status))
    }

    // MARK: - Watching the agent's own config

    /// Trusting the hooks inside Codex, switching a hook off, and switching it back on all happen in a
    /// terminal while this view is on screen and Spaces is not involved. Without a watch the row goes on
    /// reporting the task it asked the user to do after they have done it, reports green after Codex has
    /// stopped running the hooks, and the launch setup step never reaches Done.
    ///
    /// Armed only for This Mac, and only while a row is installed at all: a remote device's files are
    /// not on this machine, and a row that is not installed yet changes only through this view's own
    /// button, which reloads after itself.
    ///
    /// The watch covers directories rather than the two files themselves, which is what makes the write
    /// it exists to catch visible at all: Codex replaces `config.toml` by renaming a new file over it
    /// (verified against codex-cli 0.153.4 by comparing the inode across a config write), so a watch
    /// held on the file itself would be left holding the file that was replaced. `FileSystemWatcher`
    /// coalesces the burst, so the several writes of one review cost one reload.
    private func updateAgentConfigWatch() {
        guard isActive, isLocalDeviceSelected, Self.needsAgentConfigWatch(status: status) else {
            dropAgentConfigWatch()
            return
        }
        guard agentConfigWatcher == nil else { return }  // already covered; restarting would only re-probe
        let directory = CodingAgent.codex.configDirectoryURL(home: AgentHookInstaller.defaultHome()).path
        // Resolved once, here: a link the user makes later is picked up by the next watch, which the
        // reload after any install and reopening the section both arm.
        let targets = Self.agentConfigWatchTargets(configDirectory: directory, fileManager: .default)
        let generation = agentConfigWatchGeneration
        let watcher = FileSystemWatcher(paths: targets.directories, latency: Self.agentConfigWatchLatency) { [weak self] paths, mustRescan in
            guard Self.isRelevantConfigChange(paths: paths, mustRescan: mustRescan, targets: targets) else { return }
            Task { @MainActor in
                guard let self, self.isActive, generation == self.agentConfigWatchGeneration else { return }
                self.reload()
            }
        }
        agentConfigWatcher = watcher
        // A watch that cannot start costs the user only the reload reopening the section already gives
        // them, so it is not worth a message of its own on a row that already explains itself.
        Task { try? await watcher.start() }
    }

    /// The names of the two files in the Codex config directory these rows read.
    nonisolated static let agentConfigFileNames = ["config.toml", "hooks.json"]

    /// Resolves where a write to either file lands.
    ///
    /// Either file is commonly a symlink into a dotfiles repository, and every writer, Spaces' own
    /// included (`AgentHookConfigFile`), follows that chain and replaces the file at the end of it, so
    /// the write lands in the repository's directory and leaves `~/.codex` untouched. Watching the
    /// resolved directory as well is what makes that write visible, and resolving it the same way the
    /// writer does is what keeps the watch on the file the writer actually replaces. A file that is not
    /// a link resolves to itself and adds nothing, because the config directory already covers it.
    nonisolated static func agentConfigWatchTargets(configDirectory: String, fileManager: FileManager) -> AgentConfigWatchTargets {
        let directoryURL = URL(fileURLWithPath: configDirectory)
        var directories = [resolvedPath(directoryURL.path)]
        var linkedFiles: [String] = []
        for name in agentConfigFileNames {
            let fileURL = directoryURL.appendingPathComponent(name)
            let target = AgentHookConfigFile.writeTarget(for: fileURL, fileManager: fileManager)
            guard target.path != fileURL.path else { continue }  // not a link: the config directory covers it
            let resolved = resolvedPath(target.path)
            linkedFiles.append(resolved)
            let parent = (resolved as NSString).deletingLastPathComponent
            if !directories.contains(parent) { directories.append(parent) }
        }
        return AgentConfigWatchTargets(configDirectory: directories[0], linkedFiles: linkedFiles, directories: directories)
    }

    /// One normalization for both sides of every path comparison. FSEvents reports a path with every
    /// symlink already resolved, and `~/.codex` or an ancestor of it is often a link, so the two sides
    /// agree only if this side resolves the same way. `FilesystemPaths.realPath` is what does, and it
    /// is the same normalization the Codex trust keys are built with.
    nonisolated private static func resolvedPath(_ path: String) -> String { FilesystemPaths.realPath(path) }

    /// Whether a batch of filesystem events is one of the two files this view reads, rather than one of
    /// the many other things a running Codex writes.
    ///
    /// The watch is on the config directory and FSEvents reports every path under it, so an unfiltered
    /// callback fires for the session transcripts, SQLite journals, and lock files Codex writes while it
    /// works, and each one costs a full reload: the rows empty, the Device API is queried again, and the
    /// codex feature probe runs again. The watcher asks for file-level events, so the reported paths are
    /// precise enough to name the file that changed. A `config.toml` arriving by rename is reported at
    /// its own path, and the directory's own path is accepted too so a rename reported at directory
    /// granularity still counts. A batch flagged `mustRescan` carries paths the watcher itself says not
    /// to trust, so it counts as relevant and the reload decides from the files.
    ///
    /// A linked file is named exactly, at its own path and at the directory it sits in, because that
    /// directory belongs to a dotfiles repository whose own churn is nothing these rows read.
    ///
    /// `nonisolated` because the watcher calls it on its own queue, before any hop to the main actor.
    nonisolated static func isRelevantConfigChange(paths: [String], mustRescan: Bool, targets: AgentConfigWatchTargets) -> Bool {
        if mustRescan { return true }
        let linked = Set(targets.linkedFiles)
        let linkedDirectories = Set(linked.map { ($0 as NSString).deletingLastPathComponent })
        return paths.contains { path in
            let resolved = resolvedPath(path)
            if resolved == targets.configDirectory { return true }
            if linked.contains(resolved) || linkedDirectories.contains(resolved) { return true }
            guard (resolved as NSString).deletingLastPathComponent == targets.configDirectory else { return false }
            return agentConfigFileNames.contains((resolved as NSString).lastPathComponent)
        }
    }

    /// Drops the watch and marks the rows off screen, so neither a late filesystem callback nor a status
    /// fetch still in flight rebuilds it. Nothing on screen changes; building the card arms it again.
    func stopAgentConfigWatch() {
        isActive = false
        dropAgentConfigWatch()
    }

    /// Drops the watch while leaving the rows on screen, for a change of device: the watch is rebuilt by
    /// the reload that follows if the newly selected device still needs one.
    private func dropAgentConfigWatch() {
        agentConfigWatchGeneration += 1
        agentConfigWatcher = nil
    }

    /// Whether a change to the agent's own config currently reaches these rows.
    var isWatchingAgentConfig: Bool { agentConfigWatcher != nil }

    // MARK: - Rows

    private func renderRows(message: String?, isLoading: Bool) {
        guard let container = rowsContainer else { return }
        for view in container.arrangedSubviews {
            container.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let canAct = resolvedDevice() != nil && !isLoading && inFlight == nil
        for (index, kind) in CodingAgent.allCases.enumerated() {
            let row = agentRow(kind: kind, status: status.first { $0.kind == kind }, index: index, isLoading: isLoading, canAct: canAct)
            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
        if let message {
            let label = host.helpTextLabel(message)
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
    }

    private func agentRow(kind: CodingAgent, status: AgentHookStatus?, index: Int, isLoading: Bool, canAct: Bool) -> NSView {
        let available = status?.available ?? false
        let installState = status?.installState ?? .notInstalled

        let tile = RowPrimitives.typeTextTile(.agent, text: kind.tileText, accessibilityLabel: kind.displayName)

        let name = NSTextField(labelWithString: kind.displayName)
        name.font = Typography.rowLabel

        // A recorded failure explains a row Spaces just tried and could not fix, most often a
        // `config.toml` only the user can untangle, or an agent that would not record a trust.
        let failureMessage = failures[kind]?.message
        let caption = NSTextField(labelWithString: Self.captionText(status: status, failureMessage: failureMessage, isLoading: isLoading))
        caption.font = Typography.metadata
        caption.textColor = (failureMessage != nil && !isLoading) ? .systemRed : .secondaryLabelColor
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 3
        // A caption's single-line intrinsic width is otherwise a hard floor, so a long sentence widens
        // the settings window instead of wrapping inside the row, and the window keeps that width
        // afterwards. Let it compress and wrap, as the help text under the card does.
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var labels: [NSView] = [name, caption]
        if !isLoading, installState == .current, trustedRows.contains(TrustedRow(deviceID: deviceID, kind: kind)) {
            let note = NSTextField(labelWithString: Self.trustedNote(agentName: kind.displayName))
            note.font = Typography.metadata
            note.textColor = Theme.mutedSecondary
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 2
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labels.append(note)
        }

        let labelStack = NSStackView(views: labels)
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rowViews: [NSView] = [
            RowPrimitives.statusSlot(RowPrimitives.statusDot(statusDotKind(available: available, installState: installState))), tile, labelStack,
            NSView(),
        ]
        let inFlightAction = inFlight?.kind == kind ? inFlight?.action : nil
        if let action = inFlightAction ?? (isLoading ? nil : Self.rowAction(for: status)) {
            let button = NSButton(
                title: Self.actionTitle(action, agentName: kind.displayName, inProgress: inFlightAction != nil), target: self,
                action: #selector(performRowAction(_:)))
            button.tag = index
            button.isEnabled = canAct
            button.toolTip = Self.actionToolTip(action, agentName: kind.displayName)
            // The tint marks the row's one way forward; a button that cannot fire right now goes quiet.
            Theme.applyTintedStyle(to: button, color: button.isEnabled ? Theme.orange : Theme.mutedSecondary)
            button.setAccessibilityIdentifier("settings-coding-agents-action-\(kind.rawValue)")
            rowViews.append(button)
        }

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("settings-coding-agents-row-\(kind.rawValue)")
        return row
    }

    /// Every state short of `current` reads as "needs attention" exactly like a missing install,
    /// because they all mean the hooks are not reporting yet; the caption is what tells them apart and
    /// says who has to act.
    private func statusDotKind(available: Bool, installState: AgentHookInstallState) -> RowPrimitives.StatusKind {
        switch installState {
        case .current: .running
        case .awaitingTrust, .disabledByAgent, .outdated: .waiting
        case .notInstalled: available ? .waiting : .idle
        }
    }

    /// The step Spaces can take for a row.
    enum RowAction: Equatable {
        /// Write the hooks for the first time.
        case install
        /// Rewrite hooks that are not what this device writes: an older Spaces's, ones naming a
        /// `spaces` CLI that moved, or (for Codex) ones its `hooks` feature leaves off.
        case update
        /// Ask the agent to trust the hooks it has, after the user confirms the exact commands.
        case trust
    }

    /// A row action that failed, and the message the row explains itself with.
    struct RowFailure: Equatable {
        let action: RowAction
        let message: String
    }

    /// The failures that still explain their rows once a fresh `status` is in. A failure stands only
    /// while the row is still where the failed action left it: a refused trust while the hooks still
    /// await trust, and a failed install or update while the hooks are short of current. Anything else
    /// means the user got past it outside Spaces (trusted the hooks in the agent, untangled its config),
    /// and a failure kept past that would come back as the caption of some later, unrelated state. An
    /// agent the status does not cover keeps its failure, since nothing says it was fixed.
    static func standingFailures(_ failures: [CodingAgent: RowFailure], after status: [AgentHookStatus]) -> [CodingAgent: RowFailure] {
        failures.filter { kind, failure in
            guard let installState = status.first(where: { $0.kind == kind })?.installState else { return true }
            switch failure.action {
            case .trust: return installState == .awaitingTrust
            case .install, .update: return installState != .current
            }
        }
    }

    /// The one action a row offers, or nil when Spaces has nothing to do for it.
    ///
    /// A row shows a button only when there is something to do, because the state it is in has exactly
    /// one way forward. `current` needs nothing, and switched-off hooks are turned back on in the agent,
    /// never by Spaces, whose caption says so. An agent that is not detected has nothing to install into.
    static func rowAction(for status: AgentHookStatus?) -> RowAction? {
        guard let status, status.available else { return nil }
        switch status.installState {
        case .notInstalled: return .install
        case .outdated: return .update
        case .awaitingTrust: return .trust
        case .current, .disabledByAgent: return nil
        }
    }

    static func actionTitle(_ action: RowAction, agentName: String, inProgress: Bool) -> String {
        switch action {
        case .install: inProgress ? "Installing…" : "Install"
        case .update: inProgress ? "Updating…" : "Update"
        case .trust: inProgress ? "Trusting…" : "Trust in \(agentName)…"
        }
    }

    /// The detail a tinted action carries in place of a caption that repeats it.
    static func actionToolTip(_ action: RowAction, agentName: String) -> String {
        switch action {
        case .install: "Add Spaces' hooks to \(agentName)'s config."
        case .update: "Rewrite Spaces' hooks in \(agentName)'s config as this Spaces writes them."
        case .trust: "\(agentName) runs none of Spaces' hooks until they are trusted. Review the commands, then trust them."
        }
    }

    static func captionText(status: AgentHookStatus?, failureMessage: String?, isLoading: Bool) -> String {
        if isLoading { return "Checking availability and hooks" }
        if let failureMessage { return failureMessage }
        guard let status else { return "Status unavailable" }
        let detected = status.available ? "Detected" : "Not detected"
        let agentName = status.displayName
        switch status.installState {
        case .current: return "\(detected), hooks installed"
        case .awaitingTrust: return "\(detected), hooks installed but not yet trusted in \(agentName)"
        // No button fixes this one: Spaces never switches a hook the user switched off back on, so the
        // caption carries the step instead.
        case .disabledByAgent: return "\(detected), hooks switched off in \(agentName). Turn them back on in \(agentName) to restore agent status."
        case .outdated: return "\(detected), hooks out of date"
        case .notInstalled: return "\(detected), hooks not installed"
        }
    }

    /// The caption a row carries when the agent would not record a trust. The agent's own reason leads,
    /// and the two ways past it follow: a newer agent whose `app-server` Spaces can ask, or trusting
    /// inside the agent, which never depends on Spaces.
    static func trustFailureCaption(agentName: String, reason: String) -> String {
        let reason = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return "\(agentName) didn't record the trust: \(reason). Update \(agentName), or open it in a terminal and trust the hooks there."
    }

    /// Shown under a row this view just trusted. An agent reads its hooks when a session starts, so the
    /// sessions already running keep reporting nothing, and without this the row's green would claim
    /// otherwise.
    static func trustedNote(agentName: String) -> String { "\(agentName) sessions already running stay without Spaces status until they restart." }

    // MARK: - Actions

    @objc private func performRowAction(_ sender: NSButton) {
        guard inFlight == nil else { return }
        let kinds = CodingAgent.allCases
        guard kinds.indices.contains(sender.tag) else { return }
        let kind = kinds[sender.tag]
        switch Self.rowAction(for: status.first { $0.kind == kind }) {
        case .install, .update: installHooks(kind: kind)
        case .trust: confirmTrust(kind: kind)
        case nil: return
        }
    }

    private func installHooks(kind: CodingAgent) {
        guard let device = resolvedDevice()?.record, let action = Self.rowAction(for: status.first { $0.kind == kind }) else { return }
        let token = beginAction(kind: kind, action: action)
        let targetDeviceID = device.id
        let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SpacesDeviceClient.installAgentHooks([kind], context: DeviceRequestContext(device: device, profile: profile)) }
            await self?.applyInstall(result, token: token, deviceID: targetDeviceID, kind: kind, action: action)
        }
    }

    /// Marks `action` in flight for `kind` and returns the token its completion must still match.
    private func beginAction(kind: CodingAgent, action: RowAction) -> Int {
        reloadToken += 1  // an in-flight status fetch must not overwrite this action's result
        actionToken += 1
        inFlight = (kind, action)
        renderRows(message: nil, isLoading: false)
        return actionToken
    }

    /// An install request can succeed while the agent it targeted fails, so the per-agent failures are
    /// what decide whether the user sees an error.
    private func applyInstall(
        _ result: Result<AgentHookInstallOutcome, any Error>, token: Int, deviceID: String, kind: CodingAgent, action: RowAction
    ) {
        guard token == actionToken, deviceID == self.deviceID else { return }
        inFlight = nil
        switch result {
        case .success(let outcome):
            status = outcome.agents
            // Keep this agent's message in step with what just happened, so a row stops explaining a
            // problem the user has since fixed.
            failures[kind] = outcome.failures.first { $0.kind == kind }.map { RowFailure(action: action, message: $0.message) }
            failures = Self.standingFailures(failures, after: outcome.agents)
            renderRows(message: outcome.failures.first.map { "Install failed: \($0.message)" }, isLoading: false)
        case .failure(let error): renderRows(message: "Install failed: \(error.localizedDescription)", isLoading: false)
        }
        updateAgentConfigWatch()
        emitLocalStatusChangeIfLocal()
    }

    /// Shows the exact commands the agent has not trusted and trusts them only once the user confirms.
    /// The list comes from the status already on screen, which is the device's own report of what the
    /// trust would cover.
    private func confirmTrust(kind: CodingAgent) {
        guard let window = rowsContainer?.window, let device = resolvedDevice(),
            let entries = status.first(where: { $0.kind == kind })?.untrustedEntries, !entries.isEmpty
        else { return }
        let confirmation = AgentHookTrustConfirmation(agentName: kind.displayName, deviceName: device.label, entries: entries)
        let targetDeviceID = device.record.id
        confirmation.present(on: window) { [weak self] in
            // The rows may have moved on while the sheet was up: to another device, or into another action.
            guard let self, self.isActive, self.deviceID == targetDeviceID, self.inFlight == nil else { return }
            self.trustHooks(kind: kind, device: device.record)
        }
    }

    private func trustHooks(kind: CodingAgent, device: SpacesPairedDeviceRecord) {
        let token = beginAction(kind: kind, action: .trust)
        let targetDeviceID = device.id
        let profile = SpacesProfile.currentOrNilOnFailureFatalOnRefusal()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try SpacesDeviceClient.trustAgentHooks(kind, context: DeviceRequestContext(device: device, profile: profile)) }
            await self?.applyTrust(result, token: token, deviceID: targetDeviceID, kind: kind)
        }
    }

    /// The agent's refusal arrives as this agent's failure entry and reads in the row's caption, where
    /// the Trust button stays for another try; only a request that never reached the device reads under
    /// the rows.
    private func applyTrust(_ result: Result<AgentHookInstallOutcome, any Error>, token: Int, deviceID: String, kind: CodingAgent) {
        guard token == actionToken, deviceID == self.deviceID else { return }
        inFlight = nil
        let trustedRow = TrustedRow(deviceID: deviceID, kind: kind)
        switch result {
        case .success(let outcome):
            status = outcome.agents
            if let failure = outcome.failures.first(where: { $0.kind == kind }) {
                failures[kind] = RowFailure(action: .trust, message: Self.trustFailureCaption(agentName: kind.displayName, reason: failure.message))
                trustedRows.remove(trustedRow)
            } else {
                failures[kind] = nil
                trustedRows.insert(trustedRow)
            }
            failures = Self.standingFailures(failures, after: outcome.agents)
            renderRows(message: nil, isLoading: false)
        case .failure(let error): renderRows(message: "Trust failed: \(error.localizedDescription)", isLoading: false)
        }
        updateAgentConfigWatch()
        emitLocalStatusChangeIfLocal()
    }
}

/// One agent row on one device, for remembering which rows this view trusted.
private struct TrustedRow: Hashable {
    let deviceID: String
    let kind: CodingAgent
}

import AppKit
import Foundation
import spacesterminalcore
import spacesterminalghostty

@MainActor public final class TerminalSessionWindowController: NSWindowController, NSWindowDelegate {
    private enum VisibleRenderer {
        case ghosttyOwner
        case outputFallback
    }

    private let sessionID: String
    private let paths: TerminalSessionPaths
    private let launchConfiguration: TerminalSessionLaunchConfiguration?
    private let client: TerminalClient
    private let rendererMode: TerminalRendererMode
    private let backend: TerminalSessionBackendKind
    private var preferredAttachmentMode: TerminalAttachmentMode
    private let summaryLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let rendererLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField(string: "")
    private let inputStatusLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let interruptButton = NSButton(title: "Ctrl+C", target: nil, action: nil)
    private let newlineButton = NSButton(title: "Enter", target: nil, action: nil)
    private let takeoverButton = NSButton(title: "Take Over", target: nil, action: nil)
    private let inputRowStackView = NSStackView()
    private let actionButtonStackView = NSStackView()
    private let takeoverRowStackView = NSStackView()
    private let outputView = NSTextView(frame: NSRect(x: 0, y: 0, width: 880, height: 400))
    private let outputScrollView = NSScrollView()
    private let terminalContainer = NSView()
    private let bodyStackView = NSStackView()
    private let sendInputAction: @Sendable (String, Bool) throws -> TerminalControlResponse
    private let sendKeyAction: @Sendable (String) throws -> TerminalControlResponse
    private let takeoverAction: @Sendable (String) throws -> TerminalControlResponse
    private let attachClientAction: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void
    private let detachClientAction: @Sendable (String) throws -> Void
    private let onWindowClose: (@MainActor (String, String) -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var lastRenderedOutput = ""
    private var isClientAttached = false
    private var didCloseWindow = false
    private var lastObservedAttachmentMode: TerminalAttachmentMode?
    private var ghosttySessionHost: GhosttyEmbeddedSessionHost?
    private var visibleRenderer: VisibleRenderer = .outputFallback
    private var lastObservedOwnerClientID: String?

    public init(
        sessionID: String, paths: TerminalSessionPaths, preferredAttachmentMode: TerminalAttachmentMode = .owner,
        sendInputAction: (@Sendable (String, Bool) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)? = nil,
        detachClientAction: (@Sendable (String) throws -> Void)? = nil, onWindowClose: (@MainActor (String, String) -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.paths = paths
        self.preferredAttachmentMode = preferredAttachmentMode
        let resolvedLaunchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        launchConfiguration = resolvedLaunchConfiguration
        let resolvedBackend = resolvedLaunchConfiguration?.backend ?? .scriptPTY
        backend = resolvedBackend
        rendererMode = TerminalRendererResolver.resolveGhosttyEmbeddedMode(backend: resolvedBackend)
        let now = ISO8601DateFormatter().string(from: Date())
        client = TerminalClient(
            kind: .localWindow,
            identity: TerminalClientIdentity(label: "Spaces window", hostName: Host.current().name, deviceName: Host.current().localizedName),
            connectedAt: now)
        self.sendInputAction =
            sendInputAction ?? { [socketPath = paths.controlSocketPath, client] text, appendNewline in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(command: "send", text: text, clientID: client.id, appendNewline: appendNewline),
                    socketPath: socketPath)
            }
        self.sendKeyAction =
            sendKeyAction ?? { [socketPath = paths.controlSocketPath, client] key in
                try TerminalControlClient.send(request: TerminalControlRequest(command: "key", key: key, clientID: client.id), socketPath: socketPath)
            }
        self.takeoverAction =
            takeoverAction ?? { clientID in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(command: "takeover", clientID: clientID), socketPath: paths.controlSocketPath)
            }
        self.attachClientAction =
            attachClientAction ?? { client, mode in
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: ISO8601DateFormatter().string(from: Date()))
            }
        self.detachClientAction =
            detachClientAction ?? { clientID in
                try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date()))
            }
        self.onWindowClose = onWindowClose

        let contentRect = NSRect(x: 0, y: 0, width: 980, height: 640)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Terminal \(sessionID)"
        window.minSize = NSSize(width: 760, height: 420)
        super.init(window: window)
        window.delegate = self
        buildUI()
        refreshNow()
        startRefreshing()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show() {
        guard let window else { return }
        didCloseWindow = false
        attachLocalClientIfNeeded()
        startRefreshing()
        constrainWindowToVisibleFrame(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if backend == .ghosttyEmbedded { ensureGhosttyHostAttached() }
        refreshNow()
    }

    public func windowWillClose(_ notification: Notification) {
        didCloseWindow = true
        if backend == .ghosttyEmbedded { ghosttySessionHost?.setFocused(false, for: client.id) }
        detachLocalClientIfNeeded()
        refreshTask?.cancel()
        refreshTask = nil
        onWindowClose?(sessionID, client.id)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        guard backend == .ghosttyEmbedded else { return }
        if preferredAttachmentMode == .owner { ghosttySessionHost?.focusWindow(window) }
        ghosttySessionHost?.setFocused(preferredAttachmentMode == .owner, for: client.id)
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard backend == .ghosttyEmbedded else { return }
        ghosttySessionHost?.setFocused(false, for: client.id)
    }

    public func takeOverOwnership() {
        do {
            let response = try takeoverAction(client.id)
            guard response.ok else {
                updateInputStatus(message: response.message, isError: true)
                return
            }
            preferredAttachmentMode = .owner
            ensureGhosttyHostAttached()
            updateInputStatus(message: response.message, isError: false)
            refreshNow()
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func buildUI() {
        guard let window else { return }
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: sessionID)
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stateLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rendererLabel.font = .systemFont(ofSize: 12)
        rendererLabel.textColor = .tertiaryLabelColor
        rendererLabel.translatesAutoresizingMaskIntoConstraints = false
        rendererLabel.lineBreakMode = .byTruncatingTail
        rendererLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rendererLabel.stringValue = rendererMode.statusSummary

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        inputField.placeholderString = "Send input to the session"
        inputField.target = self
        inputField.action = #selector(submitInputFromField)

        inputStatusLabel.font = .systemFont(ofSize: 12)
        inputStatusLabel.textColor = .secondaryLabelColor
        inputStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        for button in [sendButton, interruptButton, newlineButton, takeoverButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
        }
        sendButton.target = self
        sendButton.action = #selector(submitInputFromButton)
        interruptButton.target = self
        interruptButton.action = #selector(sendInterrupt)
        newlineButton.target = self
        newlineButton.action = #selector(sendNewline)
        takeoverButton.target = self
        takeoverButton.action = #selector(takeoverOwnershipAction)

        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.isRichText = false
        outputView.importsGraphics = false
        outputView.usesFindPanel = true
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = .textBackgroundColor
        outputView.textColor = .textColor
        outputView.drawsBackground = true
        outputView.isHorizontallyResizable = true
        outputView.isVerticallyResizable = true
        outputView.autoresizingMask = [.width]
        outputView.minSize = .zero
        outputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.textContainerInset = NSSize(width: 8, height: 10)
        outputView.textContainer?.widthTracksTextView = true
        outputView.textContainer?.heightTracksTextView = false
        outputView.textContainer?.containerSize = NSSize(width: 880, height: CGFloat.greatestFiniteMagnitude)

        outputScrollView.translatesAutoresizingMaskIntoConstraints = false
        outputScrollView.borderType = .bezelBorder
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = true
        outputScrollView.autohidesScrollers = true
        outputScrollView.drawsBackground = false
        outputScrollView.documentView = outputView

        actionButtonStackView.translatesAutoresizingMaskIntoConstraints = false
        actionButtonStackView.orientation = .horizontal
        actionButtonStackView.alignment = .centerY
        actionButtonStackView.spacing = 8
        for button in [sendButton, interruptButton, newlineButton] {
            actionButtonStackView.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 72).isActive = true
        }

        inputRowStackView.translatesAutoresizingMaskIntoConstraints = false
        inputRowStackView.orientation = .horizontal
        inputRowStackView.alignment = .centerY
        inputRowStackView.spacing = 8
        inputRowStackView.addArrangedSubview(inputField)
        inputRowStackView.addArrangedSubview(actionButtonStackView)

        takeoverRowStackView.translatesAutoresizingMaskIntoConstraints = false
        takeoverRowStackView.orientation = .horizontal
        takeoverRowStackView.alignment = .leading
        takeoverRowStackView.spacing = 8
        takeoverRowStackView.addArrangedSubview(takeoverButton)
        takeoverButton.widthAnchor.constraint(equalToConstant: 92).isActive = true

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        terminalContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        bodyStackView.translatesAutoresizingMaskIntoConstraints = false
        bodyStackView.orientation = .vertical
        bodyStackView.alignment = .leading
        bodyStackView.distribution = .fill
        bodyStackView.spacing = 12
        bodyStackView.addArrangedSubview(terminalContainer)
        bodyStackView.addArrangedSubview(outputScrollView)
        outputScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        [titleLabel, summaryLabel, stateLabel, rendererLabel, inputRowStackView, takeoverRowStackView, inputStatusLabel, bodyStackView].forEach(
            contentView.addSubview)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            stateLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            stateLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            rendererLabel.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 6),
            rendererLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            rendererLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            inputRowStackView.topAnchor.constraint(equalTo: rendererLabel.bottomAnchor, constant: 12),
            inputRowStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            inputRowStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            takeoverRowStackView.topAnchor.constraint(equalTo: inputRowStackView.bottomAnchor, constant: 0),
            takeoverRowStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            takeoverRowStackView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

            inputStatusLabel.topAnchor.constraint(equalTo: takeoverRowStackView.bottomAnchor, constant: 6),
            inputStatusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            inputStatusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            bodyStackView.topAnchor.constraint(equalTo: inputStatusLabel.bottomAnchor, constant: 12),
            bodyStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bodyStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bodyStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        updateRendererVisibility()
    }

    private func ensureGhosttyHostAttached() {
        guard backend == .ghosttyEmbedded, let launchConfiguration else { return }
        do {
            let host = GhosttyEmbeddedSessionRegistry.shared.host(for: launchConfiguration, paths: paths)
            ghosttySessionHost = host
            try host.attach(client: client, mode: preferredAttachmentMode, into: preferredAttachmentMode == .owner ? terminalContainer : nil)
            host.setFocused(window?.isKeyWindow == true && preferredAttachmentMode == .owner, for: client.id)
            if preferredAttachmentMode == .owner { host.focusWindow(window) }
            updateRendererVisibility()
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refreshNow()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
    }

    private func refreshNow() {
        do {
            let currentLaunchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
            updateGhosttySessionHostReference(for: currentLaunchConfiguration)
            let output = (try? TerminalOutputTail.tail(path: paths.outputPath, lineCount: 200)) ?? ""
            let currentOwnerClient = activeOwnerClient(paths: paths)
            let isOwner = currentOwnerClient?.id == client.id || (currentOwnerClient == nil && preferredAttachmentMode == .owner)
            let currentTitle = currentWindowTitle(fallback: currentLaunchConfiguration.title, isOwner: isOwner)
            let currentWorkingDirectory = currentSummaryWorkingDirectory(fallback: currentLaunchConfiguration.workingDirectory)
            if let window { window.title = currentTitle }
            summaryLabel.stringValue = Self.summaryText(
                workingDirectory: currentWorkingDirectory, shell: currentLaunchConfiguration.shell, command: currentLaunchConfiguration.command)
            let stateText = runtimeStateText(runtimeState: runtimeState, ownerClient: currentOwnerClient, isOwner: isOwner)
            stateLabel.stringValue = stateText

            if backend == .ghosttyEmbedded {
                let activeAttachments = (try? TerminalSessionPersistence.activeAttachments(paths: paths)) ?? []
                let activeAttachment = activeAttachments.first { $0.clientID == client.id }
                if let activeAttachment {
                    preferredAttachmentMode = activeAttachment.mode
                    if lastObservedAttachmentMode != activeAttachment.mode {
                        lastObservedAttachmentMode = activeAttachment.mode
                        if activeAttachment.mode == .owner {
                            ensureGhosttyHostAttached()
                        } else {
                            ghosttySessionHost?.setFocused(false, for: client.id)
                        }
                    }
                }
                if lastObservedOwnerClientID != currentOwnerClient?.id {
                    lastObservedOwnerClientID = currentOwnerClient?.id
                    if isOwner { ghosttySessionHost?.focusWindow(window) }
                }
                visibleRenderer = resolveVisibleRenderer(isOwner: isOwner)
                updateRendererVisibility()
                updateInputOwnershipUI(isOwner: isOwner)
                rendererLabel.stringValue = rendererSummary(isOwner: isOwner)
            } else {
                visibleRenderer = .outputFallback
                updateRendererVisibility()
                rendererLabel.stringValue = rendererMode.statusSummary
            }

            guard visibleRenderer != .ghosttyOwner else { return }
            if output != lastRenderedOutput {
                outputView.string = output
                if let textContainer = outputView.textContainer { outputView.layoutManager?.ensureLayout(for: textContainer) }
                outputView.sizeToFit()
                lastRenderedOutput = output
                scrollOutputToBottom()
            }
        } catch {
            summaryLabel.stringValue = "Unable to load terminal session metadata."
            stateLabel.stringValue = String(describing: error)
            outputView.string = ""
            lastRenderedOutput = ""
        }
    }

    @objc private func submitInputFromButton() { submitInput() }
    @objc private func submitInputFromField() { submitInput() }
    @objc private func sendInterrupt() { sendKey("ctrl+c") }
    @objc private func sendNewline() { sendKey("enter") }
    @objc private func takeoverOwnershipAction() { takeOverOwnership() }

    private func submitInput() {
        guard preferredAttachmentMode == .owner else {
            updateInputStatus(message: "Viewer windows cannot send input. Take over ownership first.", isError: true)
            return
        }
        let text = inputField.stringValue.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else {
            updateInputStatus(message: "Enter text to send.", isError: false)
            return
        }

        do {
            let response = try sendInputAction(text, true)
            inputField.stringValue = ""
            updateInputStatus(message: response.message, isError: !response.ok)
            refreshNow()
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func sendKey(_ key: String) {
        guard preferredAttachmentMode == .owner else {
            updateInputStatus(message: "Viewer windows cannot send keys. Take over ownership first.", isError: true)
            return
        }
        do {
            let response = try sendKeyAction(key)
            updateInputStatus(message: response.message, isError: !response.ok)
            refreshNow()
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func updateInputStatus(message: String, isError: Bool) {
        inputStatusLabel.stringValue = message
        inputStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func attachLocalClientIfNeeded() {
        guard !isClientAttached else { return }
        do {
            try attachClientAction(client, preferredAttachmentMode)
            isClientAttached = true
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func detachLocalClientIfNeeded() {
        guard isClientAttached else { return }
        do {
            try detachClientAction(client.id)
            isClientAttached = false
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func updateRendererVisibility() {
        switch visibleRenderer {
        case .ghosttyOwner:
            terminalContainer.isHidden = false
            outputScrollView.isHidden = true
        case .outputFallback:
            outputScrollView.isHidden = false
            terminalContainer.isHidden = true
        }
        let isCompactOwnerChrome = visibleRenderer == .ghosttyOwner && preferredAttachmentMode == .owner
        rendererLabel.isHidden = isCompactOwnerChrome
    }

    private func updateInputOwnershipUI(isOwner: Bool) {
        let usesInlineControls = backend != .ghosttyEmbedded
        inputRowStackView.isHidden = !usesInlineControls
        takeoverRowStackView.isHidden = !(backend == .ghosttyEmbedded && !isOwner)
        inputField.isEnabled = usesInlineControls && isOwner
        sendButton.isEnabled = usesInlineControls && isOwner
        interruptButton.isEnabled = usesInlineControls && isOwner
        newlineButton.isEnabled = usesInlineControls && isOwner
        takeoverButton.isHidden = isOwner
        takeoverButton.isEnabled = !isOwner
        inputField.placeholderString = isOwner ? "Send input to the session" : "Viewer window"
    }

    private func scrollOutputToBottom() {
        let length = outputView.string.utf16.count
        outputView.scrollRangeToVisible(NSRange(location: length, length: 0))
    }

    private func constrainWindowToVisibleFrame(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        var frame = window.frame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    private func resolveVisibleRenderer(isOwner: Bool?) -> VisibleRenderer {
        guard backend == .ghosttyEmbedded, isOwner == true else { return .outputFallback }
        return .ghosttyOwner
    }

    private func rendererSummary(isOwner: Bool?) -> String {
        guard isOwner == true else { return "Renderer: viewer tail" }
        switch visibleRenderer {
        case .ghosttyOwner: return "Renderer: libghostty (owner)"
        case .outputFallback: return "Renderer: output tail (owner fallback)"
        }
    }

    private func currentWindowTitle(fallback: String, isOwner: Bool) -> String {
        guard backend == .ghosttyEmbedded else { return fallback }
        let baseTitle = ghosttySessionHost?.effectiveTitle ?? fallback
        return isOwner ? baseTitle : "\(baseTitle) (viewer)"
    }

    private func currentSummaryWorkingDirectory(fallback: String) -> String {
        guard backend == .ghosttyEmbedded else { return fallback }
        return ghosttySessionHost?.effectiveWorkingDirectory ?? fallback
    }

    private func runtimeStateText(runtimeState: TerminalSessionRuntimeState?, ownerClient: TerminalClient?, isOwner: Bool) -> String {
        guard let runtimeState else { return "state: unknown" }
        if backend == .ghosttyEmbedded && isOwner {
            let childText = runtimeState.childPID.map { "    child: \($0)" } ?? ""
            return "state: \(runtimeState.state.rawValue)\(childText)"
        }
        let clientLabel = client.identity.deviceName ?? client.identity.hostName ?? client.identity.label
        let ownerLabel = ownerClient.map(Self.displayLabel(for:)) ?? "-"
        return
            "backend: \(runtimeState.backend.rawValue)    state: \(runtimeState.state.rawValue)    child: \(runtimeState.childPID.map(String.init) ?? "-")    owner: \(ownerLabel)    client: \(clientLabel)    updated: \(runtimeState.updatedAt)"
    }

    private static func summaryText(for launchConfiguration: TerminalSessionLaunchConfiguration) -> String {
        summaryText(workingDirectory: launchConfiguration.workingDirectory, shell: launchConfiguration.shell, command: launchConfiguration.command)
    }

    private func updateGhosttySessionHostReference(for launchConfiguration: TerminalSessionLaunchConfiguration) {
        guard launchConfiguration.backend == .ghosttyEmbedded else { return }
        if let existingHost = GhosttyEmbeddedSessionRegistry.shared.existingHost(sessionID: launchConfiguration.sessionID) {
            ghosttySessionHost = existingHost
        }
    }

    private func activeOwnerClient(paths: TerminalSessionPaths) -> TerminalClient? {
        guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths),
            let ownerAttachment = snapshot.attachments.last(where: { $0.mode == .owner && $0.detachedAt == nil })
        else { return nil }
        return snapshot.clients.first(where: { $0.id == ownerAttachment.clientID })
    }

    private static func displayLabel(for client: TerminalClient) -> String {
        client.identity.deviceName ?? client.identity.hostName ?? client.identity.label
    }

    private static func summaryText(workingDirectory: String, shell: String, command: String?) -> String {
        let cwd = abbreviatedPath(workingDirectory)
        let shell = URL(fileURLWithPath: shell).lastPathComponent
        let command = summarizedCommand(command)
        return "cwd: \(cwd)    shell: \(shell)    command: \(command)"
    }

    private static func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func summarizedCommand(_ command: String?) -> String {
        guard let command, !command.isEmpty else { return "-" }
        let strippedSegments = command.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.hasPrefix("export ")
        }
        let cleaned = strippedSegments.isEmpty ? command : strippedSegments.joined(separator: "; ")
        if cleaned.count <= 140 { return cleaned }
        return "\(cleaned.prefix(72))…\(cleaned.suffix(48))"
    }

    var debugRenderedOutput: String { outputView.string }
    var debugRendererSummary: String { rendererLabel.stringValue }
    var debugSummary: String { summaryLabel.stringValue }
    var debugState: String { stateLabel.stringValue }
    var debugWindowTitle: String { window?.title ?? "" }
    public var attachmentMode: TerminalAttachmentMode { preferredAttachmentMode }
    public var didClose: Bool { didCloseWindow }
    var debugDidCloseWindow: Bool { didCloseWindow }
    func debugForceRefresh() { refreshNow() }
    public var clientID: String { client.id }
    var debugShowsInlineControls: Bool { !inputRowStackView.isHidden }
    var debugShowsTakeoverButton: Bool { !takeoverRowStackView.isHidden }
    var debugShowsRendererLabel: Bool { !rendererLabel.isHidden }
}

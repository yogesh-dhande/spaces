import AppKit
import Foundation
import spacesterminalcore
import spacesterminalghostty

extension TerminalSessionPaneViewController {
    func buildUI() {
        let contentView = view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        // Queryable regardless of the pane's window shell (owner-attached window pre-panel-rework,
        // or a pane inside a shared panel window today): UI automation and VoiceOver read the
        // pane's current owner/viewer attachment mode off this stable identifier's AXValue (kept
        // current by updateInputOwnershipUI) instead of inferring it from window title/identifier,
        // which no longer distinguishes attachment mode now that panes share one window.
        contentView.setAccessibilityIdentifier("terminal-pane-\(sessionID)")
        // A bare container NSView is otherwise treated as accessibility-uninteresting and
        // collapsed out of the AX tree entirely, so its identifier/value would never surface.
        contentView.setAccessibilityElement(true)

        titleLabel.stringValue = sessionID
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
        inputStatusLabel.isHidden = true

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
        outputView.isAutomaticQuoteSubstitutionEnabled = false
        outputView.isAutomaticDashSubstitutionEnabled = false
        outputView.isAutomaticTextReplacementEnabled = false
        outputView.isAutomaticSpellingCorrectionEnabled = false
        outputView.isContinuousSpellCheckingEnabled = false
        outputView.isGrammarCheckingEnabled = false
        outputView.isAutomaticTextCompletionEnabled = false
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = .activeTheme(\.terminal.background)
        outputView.textColor = .activeTheme(\.terminal.foreground)
        outputView.drawsBackground = true
        outputView.isHorizontallyResizable = true
        outputView.isVerticallyResizable = true
        outputView.autoresizingMask = [.width]
        outputView.minSize = .zero
        outputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.textContainerInset = NSSize(width: 8, height: 10)
        outputView.textContainer?.widthTracksTextView = false
        outputView.textContainer?.heightTracksTextView = false
        outputView.textContainer?.lineBreakMode = .byClipping
        outputView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.enclosingScrollView?.drawsBackground = false

        outputScrollView.translatesAutoresizingMaskIntoConstraints = false
        outputScrollView.borderType = .bezelBorder
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = true
        outputScrollView.autohidesScrollers = true
        outputScrollView.drawsBackground = false
        outputScrollView.documentView = outputView
        outputScrollView.borderType = .bezelBorder

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

        takeoverMessageLabel.font = .systemFont(ofSize: 13)
        takeoverMessageLabel.textColor = .secondaryLabelColor
        takeoverMessageLabel.alignment = .center
        takeoverMessageLabel.lineBreakMode = .byWordWrapping
        takeoverMessageLabel.maximumNumberOfLines = 0
        takeoverMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        takeoverMessageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        takeoverMessageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        Self.applyBrandPrimaryStyle(to: takeoverButton, title: "Take Over")

        takeoverRowStackView.translatesAutoresizingMaskIntoConstraints = false
        takeoverRowStackView.orientation = .vertical
        takeoverRowStackView.alignment = .centerX
        takeoverRowStackView.spacing = 14
        takeoverRowStackView.addArrangedSubview(takeoverMessageLabel)
        takeoverRowStackView.addArrangedSubview(takeoverButton)

        takeoverContainerView.translatesAutoresizingMaskIntoConstraints = false
        takeoverContainerView.addSubview(takeoverRowStackView)
        NSLayoutConstraint.activate([
            takeoverRowStackView.centerXAnchor.constraint(equalTo: takeoverContainerView.centerXAnchor),
            takeoverRowStackView.topAnchor.constraint(equalTo: takeoverContainerView.topAnchor),
            takeoverRowStackView.bottomAnchor.constraint(equalTo: takeoverContainerView.bottomAnchor),
        ])

        headerStackView.translatesAutoresizingMaskIntoConstraints = false
        headerStackView.orientation = .vertical
        headerStackView.alignment = .width
        headerStackView.distribution = .fill
        headerStackView.spacing = 6
        for view in [titleLabel, summaryLabel, stateLabel, rendererLabel, inputRowStackView, inputStatusLabel] {
            headerStackView.addArrangedSubview(view)
        }
        // The header rows are data holders for state the debug dump and tests read;
        // panes render the terminal surface only, so the header never shows.
        headerStackView.isHidden = true

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = NSColor.activeTheme(\.terminal.background).cgColor
        terminalContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        bodyStackView.translatesAutoresizingMaskIntoConstraints = false
        bodyStackView.orientation = .vertical
        bodyStackView.alignment = .width
        bodyStackView.distribution = .fill
        bodyStackView.spacing = 12
        bodyStackView.addArrangedSubview(terminalContainer)
        bodyStackView.addArrangedSubview(outputScrollView)
        outputScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        [headerStackView, bodyStackView, takeoverContainerView].forEach(contentView.addSubview)

        bodyTopToContentConstraint = bodyStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12)
        bodyBottomToContentConstraint = bodyStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        bodyBottomToTakeoverConstraint = bodyStackView.bottomAnchor.constraint(equalTo: takeoverContainerView.topAnchor, constant: -12)
        bodyLeadingConstraint = bodyStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        bodyTrailingConstraint = bodyStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        takeoverLeadingConstraint = takeoverContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        takeoverTrailingConstraint = takeoverContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        takeoverBottomConstraint = takeoverContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        takeoverCenterYConstraint = takeoverContainerView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)

        NSLayoutConstraint.activate([
            headerStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            headerStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            headerStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            bodyLeadingConstraint!, bodyTrailingConstraint!, takeoverLeadingConstraint!, takeoverTrailingConstraint!,
            takeoverContainerView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor), takeoverBottomConstraint!,
        ])

        // Realized after the content subviews so the banner overlays the pane it describes.
        _ = banner

        updateRendererVisibility()
    }

    /// Mirrors the pane's own state into the banner's persistent notice. Both facts it reports leave
    /// a frozen Ghostty render on screen that is otherwise indistinguishable from a live terminal —
    /// an exited or failed session, and a dropped state subscription to the owning device — so the
    /// banner is the only thing telling the user why their keystrokes go nowhere.
    func updatePersistentBanner(runtimeState: TerminalSessionRuntimeState?, isStateStreamDisconnected: Bool) {
        guard let notice = TerminalPaneBannerNotice.resolve(runtimeState: runtimeState?.state, isStateStreamDisconnected: isStateStreamDisconnected)
        else {
            banner.clearPersistent()
            return
        }
        banner.showPersistent(notice)
    }

    func updateInputStatus(message: String, isError: Bool) {
        inputStatusIsError = isError
        inputStatusLabel.stringValue = message
        inputStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        inputStatusLabel.isHidden = message.isEmpty
        updateHeaderLayoutVisibility()
    }

    func updateRendererVisibility() {
        switch visibleRenderer {
        case .ghosttyOwner, .ghosttyEndedFinalRender:
            terminalContainer.isHidden = false
            outputScrollView.isHidden = true
        case .ghosttyTakeoverStatus, .unavailable, .textView:
            outputScrollView.isHidden = false
            terminalContainer.isHidden = true
        }
        let isGhosttyOwner = visibleRenderer == .ghosttyOwner && preferredAttachmentMode == .owner
        let isGhosttyEndedFinalRender = visibleRenderer == .ghosttyEndedFinalRender
        let isFullBleedOwnerPreparation = isDeferringInitialOwnerPresentation && preferredAttachmentMode == .owner
        if isFullBleedOwnerPreparation { outputView.string = "" }
        let shouldCollapseOwnerChrome = isGhosttyOwner && !shouldShowOwnerStateLabel
        titleLabel.isHidden = isGhosttyOwner
        summaryLabel.isHidden = shouldCollapseOwnerChrome
        rendererLabel.isHidden = isGhosttyOwner
        stateLabel.isHidden = shouldCollapseOwnerChrome
        let isFullBleed = isGhosttyOwner || isGhosttyEndedFinalRender || isFullBleedOwnerPreparation
        outputScrollView.borderType = isFullBleed || (backend == .ghosttyEmbedded && visibleRenderer != .textView) ? .noBorder : .bezelBorder
        outputScrollView.drawsBackground = !isFullBleedOwnerPreparation
        outputView.drawsBackground = !isFullBleedOwnerPreparation
        bodyStackView.spacing = isFullBleed ? 0 : 12
        bodyLeadingConstraint?.constant = isFullBleed ? 0 : 16
        bodyTrailingConstraint?.constant = isFullBleed ? 0 : -16
        bodyTopToContentConstraint?.constant = isFullBleed ? 0 : 12
        bodyBottomToContentConstraint?.constant = isFullBleed ? 0 : -16
        outputView.textContainerInset =
            isFullBleedOwnerPreparation
            ? .zero : backend == .ghosttyEmbedded && visibleRenderer != .textView ? NSSize(width: 14, height: 14) : NSSize(width: 8, height: 10)
        outputView.textContainer?.lineFragmentPadding =
            isFullBleedOwnerPreparation ? 0 : backend == .ghosttyEmbedded && visibleRenderer != .textView ? 0 : 5
        updateHeaderLayoutVisibility()
    }

    func updateInputOwnershipUI(isOwner: Bool, isInteractive: Bool) {
        view.setAccessibilityValue(isOwner ? "owner" : "viewer")
        let usesInlineControls = visibleRenderer == .textView && isOwner
        inputRowStackView.isHidden = !usesInlineControls
        let isWaitingForRequestedOwnership = !isOwner && preferredAttachmentMode == .owner
        let showsTakeoverShell = visibleRenderer == .ghosttyTakeoverStatus && backend == .ghosttyEmbedded && !isWaitingForRequestedOwnership
        takeoverContainerView.isHidden = !(showsTakeoverShell && !isOwner)
        takeoverRowStackView.isHidden = takeoverContainerView.isHidden
        isViewerTakeoverShellActive = !takeoverContainerView.isHidden
        takeoverMessageLabel.isHidden = !isViewerTakeoverShellActive
        takeoverBottomConstraint?.isActive = !isViewerTakeoverShellActive
        takeoverCenterYConstraint?.isActive = isViewerTakeoverShellActive
        inputField.isEnabled = usesInlineControls && isInteractive
        sendButton.isEnabled = usesInlineControls && isInteractive
        interruptButton.isEnabled = usesInlineControls && isInteractive
        newlineButton.isEnabled = usesInlineControls && isInteractive
        takeoverButton.isHidden = isOwner || !isInteractive || isWaitingForRequestedOwnership
        takeoverButton.isEnabled = !isOwner && isInteractive && !isTakeoverAttemptPending && !isWaitingForRequestedOwnership
        if !isInteractive {
            inputField.placeholderString = "Session is not running"
        } else {
            inputField.placeholderString = isOwner ? "Send input to the session" : "Take over to send input"
        }
        if !usesInlineControls && isOwner && (isInteractive || (!inputStatusIsError && inputStatusLabel.stringValue.isEmpty == false)) {
            inputStatusLabel.stringValue = ""
            inputStatusLabel.isHidden = true
            inputStatusIsError = false
        }
        updateHeaderLayoutVisibility()
    }

    /// Publishes the pane's runtime-target name (the sidebar/tab title — e.g. "frontend",
    /// "codex") as the pane container's accessibility label. Post-panel-rework every session
    /// renders as a pane inside one shared window whose title no longer encodes which session
    /// is frontmost, so UI automation and VoiceOver identify the front window's selected-tab
    /// session by this label off the same `terminal-pane-<sessionID>` element that carries the
    /// owner/viewer AXValue. The panel coordinator keeps it current on every render pass.
    public func setAccessibilityRuntimeTargetName(_ name: String) { view.setAccessibilityLabel(name) }

    func updateHeaderLayoutVisibility() {
        // Session metadata remains available through debug accessors, but panes render
        // the terminal surface only — the header stack never shows.
        if isViewerTakeoverShellActive {
            bodyStackView.isHidden = true
            outputScrollView.isHidden = true
            bodyTopToContentConstraint?.isActive = true
            bodyBottomToTakeoverConstraint?.isActive = false
            bodyBottomToContentConstraint?.isActive = false
            return
        }
        bodyStackView.isHidden = false
        bodyTopToContentConstraint?.isActive = true
        bodyBottomToTakeoverConstraint?.isActive = !takeoverContainerView.isHidden
        bodyBottomToContentConstraint?.isActive = takeoverContainerView.isHidden
    }

    func assignPreferredFirstResponder() {
        guard let window else { return }
        switch visibleRenderer {
        case .ghosttyOwner: restoreGhosttyOwnerInputFocusIfReady()
        case .ghosttyEndedFinalRender: window.makeFirstResponder(nil)
        case .ghosttyTakeoverStatus, .unavailable, .textView:
            if !takeoverContainerView.isHidden, takeoverButton.isEnabled {
                window.makeFirstResponder(takeoverButton)
            } else if !inputRowStackView.isHidden, inputField.isEnabled {
                window.makeFirstResponder(inputField)
            } else {
                window.makeFirstResponder(outputView)
            }
        }
    }

    func scrollOutputToBottom() {
        let length = outputView.string.utf16.count
        outputView.scrollRangeToVisible(NSRange(location: length, length: 0))
    }

    func captureOutputViewportState() -> OutputViewportState {
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let documentHeight = outputView.bounds.height
        let offsetFromBottom = max(0, documentHeight - visibleRect.maxY)
        return OutputViewportState(
            wasPinnedToBottom: offsetFromBottom <= 24, horizontalOffset: max(0, visibleRect.minX), offsetFromBottom: offsetFromBottom,
            selectedRange: outputView.selectedRange())
    }

    func restoreOutputViewportState(_ state: OutputViewportState) {
        let outputLength = outputView.string.utf16.count
        let clampedLocation = min(state.selectedRange.location, outputLength)
        let remainingLength = max(0, outputLength - clampedLocation)
        let clampedLength = min(state.selectedRange.length, remainingLength)
        outputView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))

        guard let documentView = outputScrollView.documentView else {
            scrollOutputToBottom()
            return
        }
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let maxOriginX = max(0, documentView.bounds.width - visibleRect.width)
        let targetOriginX = max(0, min(state.horizontalOffset, maxOriginX))

        guard !state.wasPinnedToBottom else {
            scrollOutputToBottom()
            outputScrollView.contentView.scroll(to: NSPoint(x: targetOriginX, y: outputScrollView.contentView.documentVisibleRect.minY))
            outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
            return
        }

        let maxOriginY = max(0, documentView.bounds.height - visibleRect.height)
        let targetOriginY = max(0, maxOriginY - state.offsetFromBottom)
        outputScrollView.contentView.scroll(to: NSPoint(x: targetOriginX, y: min(targetOriginY, maxOriginY)))
        outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
    }

    func updateFinalRenderCopyBuffer() {
        if let snapshotText = ghosttyRendererHost?.snapshotText(), !snapshotText.isEmpty {
            updateOutputPlainText(snapshotText)
            return
        }
        guard let snapshot = ghosttyRendererHost?.snapshot() else { return }
        updateOutputPlainText(GhosttyTerminalSnapshotGrid.fullPlainText(for: snapshot))
    }

    func currentGhosttyStatusMessage(isOwner: Bool, runtimeState: TerminalSessionRuntimeState?, ownerClient: TerminalClient?) -> String {
        if runtimeState?.state == .starting { return "Preparing terminal...\nThe shell is still starting." }
        if runtimeState?.state.isInteractive == true {
            if isOwner { return "" }
            let ownerLabel = ownerClient.map(Self.displayLabel(for:)) ?? "another client"
            if isTakeoverAttemptPending || preferredAttachmentMode == .owner {
                return "Waiting for terminal ownership…\nCurrent owner: \(ownerLabel)"
            }
            return "Live terminal rendering is limited to the active owner.\nCurrent owner: \(ownerLabel)"
        }

        guard let runtimeState else { return "Terminal session state unavailable." }
        return "Terminal session \(runtimeState.state.rawValue)."
    }

    func updateOutputPlainText(_ text: String) {
        guard text != lastRenderedOutput else { return }
        outputView.string = text
        if let textContainer = outputView.textContainer { outputView.layoutManager?.ensureLayout(for: textContainer) }
        outputView.sizeToFit()
        lastRenderedOutput = text
    }

    func rendererSummary(isOwner: Bool?) -> String {
        guard isOwner == true else {
            switch visibleRenderer {
            case .ghosttyTakeoverStatus: return "Renderer: takeover status"
            case .ghosttyEndedFinalRender: return "Renderer: final Ghostty render"
            case .unavailable: return "Renderer: unavailable"
            case .textView: return "Renderer: render-frame text"
            case .ghosttyOwner: return "Renderer: ghostty-mirror"
            }
        }
        switch visibleRenderer {
        case .ghosttyOwner: return "Renderer: ghostty-mirror"
        case .ghosttyTakeoverStatus: return "Renderer: preparing owner surface"
        case .ghosttyEndedFinalRender: return "Renderer: final Ghostty render"
        case .unavailable: return "Renderer: unavailable"
        case .textView: return "Renderer: owner render unavailable"
        }
    }

    func currentDisplayTitle(fallback: String, isOwner: Bool) -> String {
        guard backend == .ghosttyEmbedded else { return fallback }
        let baseTitle = ghosttySessionInfoProvider?.effectiveTitle ?? lastObservedRuntimeState?.title ?? fallback
        return baseTitle
    }

    func currentSummaryWorkingDirectory(fallback: String) -> String {
        guard backend == .ghosttyEmbedded else { return fallback }
        return ghosttySessionInfoProvider?.effectiveWorkingDirectory ?? lastObservedRuntimeState?.workingDirectory ?? fallback
    }

    func currentRepresentedURL(workingDirectory: String) -> URL? {
        let url = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }

    func shouldShowCompactOwnerStateLabel(runtimeState: TerminalSessionRuntimeState?, isOwner: Bool) -> Bool {
        guard backend == .ghosttyEmbedded, isOwner else { return true }
        guard let runtimeState else { return true }
        return runtimeState.state != .running
    }

    func runtimeStateText(runtimeState: TerminalSessionRuntimeState?, ownerClient: TerminalClient?, isOwner: Bool) -> String {
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

    static func summaryText(for launchConfiguration: TerminalSessionLaunchConfiguration) -> String {
        summaryText(workingDirectory: launchConfiguration.workingDirectory, shell: launchConfiguration.shell, command: launchConfiguration.command)
    }

    static func displayLabel(for client: TerminalClient) -> String { client.identity.deviceName ?? client.identity.hostName ?? client.identity.label }

    static func summaryText(workingDirectory: String, shell: String, command: String?) -> String {
        let cwd = abbreviatedPath(workingDirectory)
        let shell = URL(fileURLWithPath: shell).lastPathComponent
        let command = summarizedCommand(command)
        return "cwd: \(cwd)    shell: \(shell)    command: \(command)"
    }

    static func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func summarizedCommand(_ command: String?) -> String {
        guard let command, !command.isEmpty else { return "-" }
        let strippedSegments = command.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.hasPrefix("export ")
        }
        let cleaned = strippedSegments.isEmpty ? command : strippedSegments.joined(separator: "; ")
        if cleaned.count <= 140 { return cleaned }
        return "\(cleaned.prefix(72))…\(cleaned.suffix(48))"
    }
}

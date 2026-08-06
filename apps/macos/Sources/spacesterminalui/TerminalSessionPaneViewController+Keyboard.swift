import AppKit
import Carbon
import Foundation
import spacesterminalcore
import spacesterminalghostty

extension TerminalSessionPaneViewController {
    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(NSText.copy(_:)):
            switch visibleRenderer {
            case .ghosttyOwner: return canPerformLiveTerminalReadOnlyAction
            case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable: return true
            case .textView: return true
            }
        case #selector(NSText.paste(_:)):
            switch visibleRenderer {
            case .ghosttyOwner: return canPerformLiveTerminalEditAction
            case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable: return false
            case .textView: return !inputRowStackView.isHidden && inputField.isEnabled
            }
        case #selector(selectAll(_:)): return visibleRenderer == .ghosttyOwner ? canPerformLiveTerminalReadOnlyAction : true
        case #selector(hideFind(_:)):
            switch visibleRenderer {
            case .ghosttyOwner, .ghosttyEndedFinalRender:
                return canPerformLiveTerminalReadOnlyAction && ghosttyRendererHost?.debugSearchState.isVisible == true
            case .ghosttyTakeoverStatus, .unavailable: return false
            case .textView: return true
            }
        case #selector(find(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(useSelectionForFind(_:)):
            switch visibleRenderer {
            case .ghosttyOwner: return canPerformLiveTerminalEditAction
            case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable: return false
            case .textView: return true
            }
        default: return true
        }
    }

    @objc public func copy(_ sender: Any?) {
        switch visibleRenderer {
        case .ghosttyOwner:
            guard preferredAttachmentMode == .owner else {
                updateInputStatus(message: "Only the active owner can copy from the live terminal.", isError: true)
                NSSound.beep()
                return
            }
            let copied =
                copySelectionAction?() ?? ghosttyRendererHost?.performBindingAction("copy_to_clipboard") ?? ghosttyRendererHost?
                .copySelectionToPasteboard() ?? false
            guard copied else {
                NSSound.beep()
                return
            }
        case .ghosttyEndedFinalRender:
            if canPerformLiveTerminalReadOnlyAction {
                let copied =
                    copySelectionAction?() ?? ghosttyRendererHost?.performBindingAction("copy_to_clipboard") ?? ghosttyRendererHost?
                    .copySelectionToPasteboard() ?? false
                if copied { return }
            }
            copyOutputViewSelection(sender)
        case .ghosttyTakeoverStatus, .unavailable, .textView: copyOutputViewSelection(sender)
        }
    }

    private func copyOutputViewSelection(_ sender: Any?) {
        guard let pasteboard = pasteboardOverrideForTesting else {
            outputView.copy(sender)
            return
        }
        pasteboard.clearContents()
        let selectedText = outputView.textStorage?.attributedSubstring(from: outputView.selectedRange()).string ?? ""
        pasteboard.writeObjects([selectedText as NSString])
    }

    @objc public func paste(_ sender: Any?) {
        switch visibleRenderer {
        case .ghosttyOwner:
            guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
                updateInputStatus(message: "Session is not running.", isError: true)
                NSSound.beep()
                return
            }
            guard preferredAttachmentMode == .owner else {
                updateInputStatus(message: "Only the active owner can paste into the terminal.", isError: true)
                NSSound.beep()
                return
            }
            if pasteImageFromPasteboardIfPresent() { return }
            let pasted = pasteClipboardAction?() ?? ghosttyRendererHost?.pasteClipboardContents() ?? false
            guard pasted else {
                // A paste that reached an unreachable device otherwise beeps and says nothing, which
                // on a pane still showing the device's last frame reads as the paste being ignored.
                // Cmd+V carries a modifier, so it never triggers the typing pulse below.
                if isStateStreamDisconnected { reportDisconnectedInputAttempt() }
                NSSound.beep()
                return
            }
        case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable:
            if isExplicitlyNonInteractiveRuntimeState(lastObservedRuntimeState) {
                updateInputStatus(message: "Session is not running.", isError: true)
                NSSound.beep()
                return
            }
            updateInputStatus(message: "Take over ownership before sending terminal input.", isError: true)
            NSSound.beep()
            return
        case .textView:
            guard !inputRowStackView.isHidden, inputField.isEnabled else {
                NSSound.beep()
                return
            }
            guard let text = (pasteboardOverrideForTesting ?? .general).string(forType: .string), !text.isEmpty else {
                NSSound.beep()
                return
            }
            window?.makeFirstResponder(inputField)
            inputField.stringValue.append(text)
        }
    }

    @objc public func selectAll(_ sender: Any?) {
        if visibleRenderer == .ghosttyOwner {
            guard performLiveTerminalReadOnlyBindingAction("select_all") else { return }
            return
        }
        if visibleRenderer == .ghosttyEndedFinalRender, canPerformLiveTerminalReadOnlyAction,
            ghosttyRendererHost?.performBindingAction("select_all") == true
        {
            return
        }
        window?.makeFirstResponder(outputView)
        outputView.selectAll(sender)
    }

    public func performShortcutForTesting(action: String, text: String? = nil) {
        switch action {
        case "paste": paste(nil)
        case "copy": copy(nil)
        case "select-all": selectAll(nil)
        case "find": find(nil)
        case "find-next": findNext(nil)
        case "find-previous": findPrevious(nil)
        case "escape": hideFind(nil)
        case "search":
            guard let text else { return }
            if visibleRenderer == .ghosttyOwner {
                _ = performLiveTerminalBindingAction("search:\(text)")
            } else {
                performOutputTextFinderAction(.showFindInterface)
            }
        default: break
        }
    }

    @objc func submitInputFromButton() { submitInput() }
    @objc func submitInputFromField() { submitInput() }
    @objc func sendInterrupt() { sendKey("ctrl+c") }
    @objc func sendNewline() { sendKey("enter") }
    func submitInput() {
        guard !inputRowStackView.isHidden else { return }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
            updateInputStatus(message: "Session is not running.", isError: true)
            return
        }
        guard preferredAttachmentMode == .owner else {
            updateInputStatus(message: "Take over ownership before sending input.", isError: true)
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
        guard !inputRowStackView.isHidden else { return }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
            updateInputStatus(message: "Session is not running.", isError: true)
            return
        }
        guard preferredAttachmentMode == .owner else {
            updateInputStatus(message: "Take over ownership before sending keys.", isError: true)
            return
        }
        do {
            let response = try sendKeyAction(key)
            updateInputStatus(message: response.message, isError: !response.ok)
            refreshNow()
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    /// Handles a key-down event bound for the terminal. Hosts call this from their
    /// key routing (the window's `sendEvent` today); returns true when the event
    /// was consumed by the live terminal.
    public func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, backend == .ghosttyEmbedded, preferredAttachmentMode == .owner else { return false }
        if Int(event.keyCode) == kVK_Escape, canPerformLiveTerminalReadOnlyAction, ghosttyRendererHost?.debugSearchState.isVisible == true {
            _ = ghosttyRendererHost?.performBindingAction("end_search")
            return true
        }
        if isTypingIntoEndedSession(event) {
            // The pane still shows the session's final render, so typing looks like it should work.
            // Pulse the banner that already explains why it doesn't, rather than swallowing the key:
            // the event stays unconsumed exactly as before, so nothing about routing changes.
            banner.flash()
            return false
        }
        if isTypingIntoDisconnectedSession(event) {
            // The pane shows the device's last frame, so typing looks like it should work while the
            // keystrokes go to a device the client cannot reach. Pulse the banner that already says
            // the connection dropped. Routing is untouched: the key still goes to the render host,
            // whose send is free to succeed the moment the link is back.
            reportDisconnectedInputAttempt()
        }
        guard visibleRenderer == .ghosttyOwner else { return false }
        if isFieldEditorFirstResponder { return false }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else { return false }
        if isImagePasteKeyEvent(event), pasteImageFromPasteboardIfPresent() { return true }
        return ghosttyRendererHost?.handleKeyEvent(event, for: client.id) ?? false
    }

    /// True when this key event is the user trying to type into a session that has already exited or
    /// failed. Command-modified keys are excluded: Cmd+C/Cmd+F still work on a final render, so they
    /// are legitimate actions on a dead pane rather than a mistake worth flagging.
    private func isTypingIntoEndedSession(_ event: NSEvent) -> Bool {
        guard isExplicitlyNonInteractiveRuntimeState(lastObservedRuntimeState) else { return false }
        guard !isFieldEditorFirstResponder else { return false }
        return !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    /// True when this key event is the user typing into a live session whose device the client has
    /// lost contact with. Mirrors `isTypingIntoEndedSession`'s exclusions: a command-modified key is
    /// a deliberate action (Cmd+C on the frozen frame still works), not a keystroke going nowhere.
    private func isTypingIntoDisconnectedSession(_ event: NSEvent) -> Bool {
        guard isStateStreamDisconnected, !isExplicitlyNonInteractiveRuntimeState(lastObservedRuntimeState) else { return false }
        guard !isFieldEditorFirstResponder else { return false }
        return !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    /// Reports an input attempt made while the device is unreachable. The banner already carries the
    /// notice, so the attempt pulses it rather than raising a second message; the input status row
    /// records the reason for the debug dump and tests.
    private func reportDisconnectedInputAttempt() {
        // Typing repeats this on every keystroke; re-stating an unchanged message would re-run the
        // header layout pass for nothing.
        if inputStatusLabel.stringValue != TerminalPaneBannerNotice.disconnected.message {
            updateInputStatus(message: TerminalPaneBannerNotice.disconnected.message, isError: true)
        }
        banner.flash()
    }

    /// Retires the message `reportDisconnectedInputAttempt` left behind once the link is back. The row
    /// holds one message at a time and every other writer owns its own, so this clears only its exact
    /// text: an unrelated status the user is looking at (a send error, an ownership refusal) says
    /// nothing about the connection and must survive a reconnect it had no part in.
    func clearDisconnectedInputStatusIfResolved() {
        guard !isStateStreamDisconnected, inputStatusLabel.stringValue == TerminalPaneBannerNotice.disconnected.message else { return }
        updateInputStatus(message: "", isError: false)
    }

    private func isImagePasteKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        return Int(event.keyCode) == kVK_ANSI_V && flags == [.control]
    }

    @discardableResult private func pasteImageFromPasteboardIfPresent() -> Bool {
        guard pasteImageAction != nil else { return false }
        switch pasteboardImageReadAction() {
        case .noImage: return false
        case .rejected(let message):
            updateInputStatus(message: message, isError: true)
            NSSound.beep()
            return true
        case .image(let image):
            Task { @MainActor [weak self] in
                guard let pasteImageAction = self?.pasteImageAction else { return }
                do {
                    let response = try await pasteImageAction(image)
                    guard let self else { return }
                    updateInputStatus(message: response.message, isError: !response.ok)
                    if !response.ok { NSSound.beep() }
                    refreshNow()
                } catch {
                    guard let self else { return }
                    updateInputStatus(message: String(describing: error), isError: true)
                    NSSound.beep()
                }
            }
            return true
        }
    }

    /// Handles a Command key equivalent (copy/paste/select-all/find family) for the
    /// terminal. Hosts call this from their `performKeyEquivalent` routing; returns
    /// true when the shortcut was consumed.
    public func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Zoom is a client-side display setting, not an act on the session, so it is claimed ahead of
        // the ownership and renderer guards below: a viewer watching a session another client owns, and
        // a pane showing the plain-text fallback for an ended session, both resize their text.
        //
        // Reaching this at all requires the pane to hold the key window's first responder, which is what
        // the app's key monitor resolves a focused pane from. A pane showing an ended session's frozen
        // final render deliberately holds none (`assignPreferredFirstResponder`), and a focused find or
        // input field is claimed by the monitor before pane routing, so a zoom is started from some other
        // pane and reaches those panes through the app-wide broadcast instead.
        //
        // A configurable app shortcut a user has assigned to one of these chords also runs ahead of this
        // and takes the key: accepted, and deliberately not special-cased. The shortcut recorder checks
        // no chord against any other, so every reserved key in the app (close pane, the numbered window
        // keys, a terminal's own command equivalents) yields to an assignment the same way. Hoisting zoom
        // above that chain would make it the one binding a user cannot reassign away from.
        if let zoomCommand = TerminalTextZoomKeyBinding.command(keyCode: Int(event.keyCode), modifierFlags: event.modifierFlags),
            let terminalTextZoomAction
        {
            terminalTextZoomAction(zoomCommand)
            return true
        }
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner,
            visibleRenderer == .ghosttyOwner || visibleRenderer == .ghosttyEndedFinalRender
        else { return false }
        // Caps lock is dropped alongside the function and numeric-pad bits: it describes the keyboard's
        // state rather than a modifier held for this chord, and the exact match below would otherwise
        // refuse every edit and find shortcut for as long as caps lock is on.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        guard flags == [.command] || flags == [.command, .shift] else { return false }
        let keyCode = Int(event.keyCode)
        if isFieldEditorFirstResponder, flags == [.command], keyCode == kVK_ANSI_C || keyCode == kVK_ANSI_V || keyCode == kVK_ANSI_A { return false }
        switch (keyCode, flags) {
        case (kVK_ANSI_C, [.command]):
            guard canPerformLiveTerminalReadOnlyAction else { return false }
            copy(nil)
            return true
        case (kVK_ANSI_V, [.command]):
            guard canPerformLiveTerminalEditAction else { return false }
            paste(nil)
            return true
        case (kVK_ANSI_A, [.command]):
            guard canPerformLiveTerminalReadOnlyAction else { return false }
            selectAll(nil)
            return true
        case (kVK_ANSI_F, [.command]):
            guard canPerformLiveTerminalEditAction else { return false }
            find(nil)
            return true
        case (kVK_ANSI_E, [.command]):
            guard canPerformLiveTerminalEditAction else { return false }
            useSelectionForFind(nil)
            return true
        case (kVK_ANSI_G, [.command]):
            guard canPerformLiveTerminalEditAction else { return false }
            findNext(nil)
            return true
        case (kVK_ANSI_G, [.command, .shift]):
            guard canPerformLiveTerminalEditAction else { return false }
            findPrevious(nil)
            return true
        default: return false
        }
    }

    private var isFieldEditorFirstResponder: Bool { (window?.firstResponder as? NSTextView)?.isFieldEditor == true }

    @discardableResult func performLiveTerminalBindingAction(_ action: String) -> Bool {
        guard canPerformLiveTerminalEditAction else {
            if preferredAttachmentMode != .owner {
                updateInputStatus(message: "Only the active owner can edit the live terminal.", isError: true)
            } else if !isInteractiveRuntimeState(lastObservedRuntimeState) {
                updateInputStatus(message: "Session is not running.", isError: true)
            }
            NSSound.beep()
            return false
        }
        guard ghosttyRendererHost?.performBindingAction(action) == true else {
            NSSound.beep()
            return false
        }
        return true
    }

    @discardableResult private func performLiveTerminalReadOnlyBindingAction(_ action: String) -> Bool {
        guard canPerformLiveTerminalReadOnlyAction else {
            if preferredAttachmentMode != .owner { updateInputStatus(message: "Only the active owner can edit the live terminal.", isError: true) }
            NSSound.beep()
            return false
        }
        guard ghosttyRendererHost?.performBindingAction(action) == true else {
            NSSound.beep()
            return false
        }
        return true
    }
}

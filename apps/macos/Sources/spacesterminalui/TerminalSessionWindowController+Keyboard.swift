import AppKit
import Carbon
import Foundation
import spacesterminalcore
import spacesterminalghostty

extension TerminalSessionWindowController {
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
            outputView.copy(sender)
        case .ghosttyTakeoverStatus, .unavailable, .textView: outputView.copy(sender)
        }
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
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                NSSound.beep()
                return
            }
            window?.makeFirstResponder(inputField)
            inputField.stringValue.append(text)
        }
    }

    public override func selectAll(_ sender: Any?) {
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

    func handleTerminalWindowKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, backend == .ghosttyEmbedded, preferredAttachmentMode == .owner else { return false }
        if Int(event.keyCode) == kVK_Escape, canPerformLiveTerminalReadOnlyAction, ghosttyRendererHost?.debugSearchState.isVisible == true {
            _ = ghosttyRendererHost?.performBindingAction("end_search")
            return true
        }
        guard visibleRenderer == .ghosttyOwner else { return false }
        if isFieldEditorFirstResponder { return false }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else { return false }
        if isImagePasteKeyEvent(event), pasteImageFromPasteboardIfPresent() { return true }
        return ghosttyRendererHost?.handleKeyEvent(event, for: client.id) ?? false
    }

    private func isImagePasteKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        return Int(event.keyCode) == kVK_ANSI_V && flags == [.control]
    }

    @discardableResult private func pasteImageFromPasteboardIfPresent() -> Bool {
        guard pasteImageAction != nil else { return false }
        switch pasteboardImageReadAction() {
        case .noImage:
            return false
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

    func handleTerminalWindowCommandKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, backend == .ghosttyEmbedded, preferredAttachmentMode == .owner,
            visibleRenderer == .ghosttyOwner || visibleRenderer == .ghosttyEndedFinalRender
        else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
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

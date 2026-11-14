import AppKit

/// What the user is told before a saved prompt is deleted.
struct SavedPromptDeleteConfirmation: Equatable {
    let title: String
    let message: String

    init(promptTitle: String, deviceName: String) {
        title = "Delete \u{201C}\(promptTitle)\u{201D}?"
        message = "Removes it from \(deviceName). This cannot be undone."
    }

    /// Whether the user chose Delete. Cancel is the default button, so Return never deletes.
    @MainActor func run() -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// What the user is told when leaving a prompt that has unsaved edits.
struct SavedPromptUnsavedConfirmation: Equatable {
    enum Choice { case save, discard, cancel }

    let title: String
    let message: String

    init(promptTitle: String, isNew: Bool) {
        let trimmed = promptTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew {
            title = trimmed.isEmpty ? "Save this new prompt?" : "Save \u{201C}\(trimmed)\u{201D}?"
            message = "It has not been saved yet. Discard throws it away."
        } else {
            title = "Save changes to \u{201C}\(trimmed)\u{201D}?"
            message = "Your edits are not saved. Discard keeps the saved prompt as it was; it does not delete the prompt."
        }
    }

    /// Asks with a modal alert rather than a sheet: the callers are synchronous navigation hooks that need
    /// the answer before they return.
    @MainActor func run() -> Choice {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        // Buttons lay out right to left, so Save is the default on the right and Discard sits farthest left.
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}

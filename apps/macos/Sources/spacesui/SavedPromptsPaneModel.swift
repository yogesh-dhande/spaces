import Foundation
import spacesdevicecore
import spacesterminalcore

/// A move inside the Prompts pane that leaves the current draft behind.
enum SavedPromptsPaneAction {
    /// Opens a prompt's editor, or closes it when it is the one already open.
    case select(SavedPromptLibrary.Entry)
    case collapse
    case beginNew(deviceID: String)
    /// Deleting the open prompt. It changes nothing in the model and never asks about unsaved edits: the
    /// delete confirmation is the only prompt, and Cancel leaves the draft open and still dirty.
    case delete

    var isDelete: Bool { if case .delete = self { true } else { false } }
}

enum SavedPromptsPaneTransition: Equatable {
    case applied
    /// The draft has unsaved edits and the model did not change; the caller asks Save / Discard / Cancel
    /// and then repeats the action.
    case needsUnsavedDecision
}

/// What the Prompts pane shows and holds, apart from any view: the search query, the open draft, and the
/// row flashing "Copied". The controller feeds it the merged library and renders its plan.
struct SavedPromptsPaneModel: Equatable {
    /// One table row, ready to draw.
    struct Row: Equatable {
        let key: String
        let title: String
        /// The prompt text on one line, for the Prompt column. Empty on the open row, whose text is in the editor below.
        let preview: String
        /// Nil when the table has no Device column.
        let deviceText: String?
        /// Empty for a draft that is not saved yet.
        let usedText: String
        let isExpanded: Bool
        let isNewDraft: Bool
        let showsCopied: Bool
        /// The open row has unsaved edits, so its Copy button copies the edited text.
        let isEdited: Bool

        var copyTitle: String { SavedPromptsPaneModel.copyTitle(showsCopied: showsCopied, isEdited: isEdited) }
    }

    static func copyTitle(showsCopied: Bool, isEdited: Bool) -> String { showsCopied ? "Copied" : (isEdited ? "Copy edited" : "Copy") }

    /// The Device column and the new-prompt device picker appear only when more than one device is paired.
    static func showsDeviceChoices(pairedDeviceCount: Int) -> Bool { pairedDeviceCount > 1 }

    /// New prompts go on this Mac when it is reachable, otherwise on the first reachable device.
    static func defaultDeviceID(reachableDeviceIDs: [String], localDeviceID: String) -> String? {
        reachableDeviceIDs.contains(localDeviceID) ? localDeviceID : reachableDeviceIDs.first
    }

    /// The longest preview kept: the Prompt column truncates to its width anyway, and a label holding a
    /// whole 100 KB prompt would be costly to lay out.
    private static let previewLimit = 240

    var query = ""
    private(set) var draft: SavedPromptDraft?
    private(set) var copiedKey: String?

    var expandedKey: String? { draft?.key }
    var hasUnsavedEdits: Bool { draft?.isDirty == true }

    // MARK: - Navigation

    mutating func attempt(_ action: SavedPromptsPaneAction) -> SavedPromptsPaneTransition {
        // Delete is exempt: its own confirmation says the prompt goes, and the edits with it.
        if hasUnsavedEdits, !action.isDelete { return .needsUnsavedDecision }
        switch action {
        case .select(let entry): draft = draft?.key == entry.id ? nil : SavedPromptDraft(editing: entry.prompt, deviceID: entry.deviceID)
        case .collapse: draft = nil
        case .beginNew(let deviceID): draft = SavedPromptDraft(newOn: deviceID)
        case .delete: break
        }
        return .applied
    }

    // MARK: - Editing

    mutating func setTitle(_ title: String) { editDraft { $0.title = title } }
    mutating func setText(_ text: String) { editDraft { $0.text = text } }
    mutating func setDevice(_ deviceID: String) { editDraft { if $0.isNew { $0.deviceID = deviceID } } }
    mutating func setError(_ message: String?) { draft?.error = message }

    private mutating func editDraft(_ edit: (inout SavedPromptDraft) -> Void) {
        guard var draft else { return }
        edit(&draft)
        // The message described the previous values.
        draft.error = nil
        self.draft = draft
    }

    /// An update landed. The prompt stays open and clean, except for anything typed since the request was
    /// sent. A result for a draft that is no longer the open one is ignored.
    mutating func saveSucceeded(promptID: String, deviceID: String, title: String, text: String) {
        guard var draft, draft.promptID == promptID, draft.deviceID == deviceID else { return }
        draft.markSaved(title: title, text: text)
        self.draft = draft
    }

    /// A create landed. A draft with nothing typed since the request was sent is finished, and its prompt
    /// appears in the table at the top. Otherwise the draft becomes an edit of the created prompt, keeping
    /// what was typed since as unsaved edits. `created` is nil only when the response lacks the prompt,
    /// which leaves nothing to edit.
    mutating func createSucceeded(created: SpacesDeviceSavedPrompt?, deviceID: String, title: String, text: String) {
        guard let draft, draft.isNew else { return }
        guard let created, draft.title != title || draft.text != text else {
            self.draft = nil
            return
        }
        var continued = SavedPromptDraft(editing: created, deviceID: deviceID)
        continued.title = draft.title
        continued.text = draft.text
        self.draft = continued
    }

    /// Drops the edits: a new draft closes, a saved prompt returns to what the library holds.
    mutating func discardDraft(entries: [SavedPromptLibrary.Entry]) {
        guard var draft else { return }
        if draft.isNew {
            self.draft = nil
            return
        }
        draft.revert()
        self.draft = draft
        libraryChanged(entries: entries)
    }

    /// Closes the editor of a prompt that was deleted. The user may have opened another prompt while the
    /// delete was in flight, and that one stays.
    mutating func closeDraft(promptID: String, deviceID: String) {
        guard draft?.promptID == promptID, draft?.deviceID == deviceID else { return }
        draft = nil
    }

    /// Whether the open draft is the given saved prompt, for results that arrive after the user moved on.
    func isOpen(promptID: String?, deviceID: String) -> Bool { draft?.promptID == promptID && draft?.deviceID == deviceID }

    // MARK: - Library changes

    /// Reconciles the open draft with the merged library after it changed. A prompt edited elsewhere
    /// refreshes a clean draft, and a dirty draft keeps the user's edits (last write wins). A prompt that
    /// is gone closes a clean draft; a dirty one stays open with an error so the edits can still be copied.
    mutating func libraryChanged(entries: [SavedPromptLibrary.Entry]) {
        guard var draft, !draft.isNew else { return }
        if let entry = entries.first(where: { $0.id == draft.key }) {
            guard !draft.isDirty else { return }
            guard draft.originalTitle != entry.prompt.title || draft.originalText != entry.prompt.text else { return }
            draft.refresh(from: entry.prompt)
            self.draft = draft
        } else if draft.isDirty {
            draft.error = "This prompt is no longer available."
            self.draft = draft
        } else {
            self.draft = nil
        }
    }

    // MARK: - Copied

    mutating func markCopied(_ key: String) { copiedKey = key }

    mutating func clearCopied(_ key: String) { if copiedKey == key { copiedKey = nil } }

    // MARK: - Rendering

    /// The rows to draw. `filtered` is the library under the current query and `all` the whole library in
    /// the same order. The open prompt stays listed even when the query hides it, so its editor does not
    /// vanish while the user types in the search field.
    func renderPlan(
        filtered: [SavedPromptLibrary.Entry], all: [SavedPromptLibrary.Entry], deviceNameForDraft: String?, showsDeviceColumn: Bool, now: Date
    ) -> [Row] {
        // The table requires a cell per column, and the draft's device can be gone from the device list.
        let draftDeviceText = showsDeviceColumn ? (deviceNameForDraft ?? "Unavailable device") : nil
        var rows: [Row] = []
        if let draft, draft.isNew {
            rows.append(
                Row(
                    key: draft.key, title: draft.title.isEmpty ? "New prompt" : draft.title, preview: "", deviceText: draftDeviceText, usedText: "",
                    isExpanded: true, isNewDraft: true, showsCopied: copiedKey == draft.key, isEdited: draft.isDirty))
        }
        let visibleIDs = Set(filtered.map(\.id))
        var openPromptListed = false
        for entry in all where visibleIDs.contains(entry.id) || entry.id == expandedKey {
            openPromptListed = openPromptListed || entry.id == expandedKey
            rows.append(row(for: entry, showsDeviceColumn: showsDeviceColumn, now: now))
        }
        // A dirty draft whose prompt left the library has no entry, but its editor must stay on screen.
        if let draft, !draft.isNew, !openPromptListed {
            rows.insert(
                Row(
                    key: draft.key, title: draft.title, preview: "", deviceText: draftDeviceText, usedText: "", isExpanded: true, isNewDraft: false,
                    showsCopied: copiedKey == draft.key, isEdited: draft.isDirty), at: 0)
        }
        return rows
    }

    private func row(for entry: SavedPromptLibrary.Entry, showsDeviceColumn: Bool, now: Date) -> Row {
        let usedAt = TerminalSessionTimestamp.date(from: entry.prompt.lastUsedAt)
        let isExpanded = entry.id == expandedKey
        return Row(
            key: entry.id, title: entry.prompt.title, preview: isExpanded ? "" : Self.preview(entry.prompt.text),
            deviceText: showsDeviceColumn ? entry.deviceName : nil,
            usedText: usedAt.map { AlertsAgeFormatting.abbreviatedAge(of: $0, relativeTo: now) } ?? "", isExpanded: isExpanded, isNewDraft: false,
            showsCopied: copiedKey == entry.id, isEdited: isExpanded && hasUnsavedEdits)
    }

    /// Whether `new` can be shown by updating the lines built for `old`: the same rows in the same order
    /// with the same layout. Only the Used text, the Copy button, and the open row's title may differ, since
    /// the open row's title cell is the live editor field and shows the draft itself. Rebuilding a line
    /// detaches that field and ends its editing session, so anything else that differs needs a rebuild.
    static func canApplyInPlace(from old: (rows: [Row], showsDeviceColumn: Bool), to new: (rows: [Row], showsDeviceColumn: Bool)) -> Bool {
        guard old.showsDeviceColumn == new.showsDeviceColumn, old.rows.count == new.rows.count else { return false }
        return zip(old.rows, new.rows).allSatisfy { before, after in
            before.key == after.key && before.isExpanded == after.isExpanded && before.isNewDraft == after.isNewDraft
                && before.deviceText == after.deviceText && before.preview == after.preview && (after.isExpanded || before.title == after.title)
        }
    }

    /// The text on one line: every run of whitespace, newlines included, becomes a single space.
    static func preview(_ text: String) -> String {
        let head = text.prefix(previewLimit * 4)
        let collapsed = head.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > previewLimit ? String(collapsed.prefix(previewLimit)) + "…" : collapsed
    }
}

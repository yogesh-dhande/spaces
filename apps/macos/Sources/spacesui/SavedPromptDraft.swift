import Foundation
import spacesdevicecore

/// The prompt being edited in the Prompts pane: an existing prompt opened for editing, or a new one that
/// has not been saved yet. It holds the typed values beside the values they were opened from, so "dirty"
/// is a comparison rather than a flag that can drift.
struct SavedPromptDraft: Equatable {
    /// Row key of a draft that is not a saved prompt yet.
    static let newKey = "draft:new"

    /// The existing prompt's id within its device, or nil for a new draft.
    let promptID: String?
    /// The device that owns the prompt, or that a new prompt will be saved on.
    var deviceID: String
    var title: String
    var text: String
    private(set) var originalTitle: String
    private(set) var originalText: String
    var error: String?

    init(editing prompt: SpacesDeviceSavedPrompt, deviceID: String) {
        promptID = prompt.id
        self.deviceID = deviceID
        title = prompt.title
        text = prompt.text
        originalTitle = prompt.title
        originalText = prompt.text
    }

    init(newOn deviceID: String) {
        promptID = nil
        self.deviceID = deviceID
        title = ""
        text = ""
        originalTitle = ""
        originalText = ""
    }

    var isNew: Bool { promptID == nil }

    /// The key of the table row this draft is shown under (`SavedPromptLibrary.Entry.id` for a saved prompt).
    var key: String { promptID.map { "\(deviceID)/\($0)" } ?? Self.newKey }

    var isDirty: Bool { title != originalTitle || text != originalText }

    /// Why the draft cannot be saved, or nil. The daemon enforces the same rules; checking here avoids a
    /// round trip, and the size message is the daemon's own so both read the same.
    var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the prompt a title." }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The prompt text cannot be empty." }
        if text.utf8.count > SpacesDeviceSavedPrompt.maximumTextBytes { return SpacesDeviceSavedPrompt.tooLongMessage }
        return nil
    }

    /// Makes the typed values the saved ones, as of the moment the save request was sent. Anything typed
    /// while the request was in flight stays an unsaved edit.
    mutating func markSaved(title savedTitle: String, text savedText: String) {
        originalTitle = savedTitle
        originalText = savedText
        error = nil
    }

    /// Replaces the typed and saved values with the library's current ones.
    mutating func refresh(from prompt: SpacesDeviceSavedPrompt) {
        title = prompt.title
        text = prompt.text
        originalTitle = prompt.title
        originalText = prompt.text
        error = nil
    }

    /// Drops the edits, back to the values the draft was opened from.
    mutating func revert() {
        title = originalTitle
        text = originalText
        error = nil
    }
}

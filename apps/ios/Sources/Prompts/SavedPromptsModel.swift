import Foundation
import UIKit
import spacesdevicecore

/// A device's connection for prompt calls: the paired device's API client and its command channel.
struct SavedPromptsConnection: Sendable {
    let client: SpacesDeviceAPIClient
    let channel: SpacesDeviceAPICommandChannel
}

/// The prompt being viewed or written on the detail screen. Held by the model, not the view, so the sheet
/// can refuse an interactive dismissal while it has edits the user has not saved.
struct SavedPromptDraft: Equatable {
    /// The device that owns the prompt, or will own it once a new prompt is saved.
    var deviceID: String
    /// Nil for a prompt that has not been saved yet.
    let promptID: String?
    var title: String
    var text: String
    private(set) var savedTitle: String
    private(set) var savedText: String
    var errorMessage: String?

    init(deviceID: String, promptID: String?, title: String, text: String) {
        self.deviceID = deviceID
        self.promptID = promptID
        self.title = title
        self.text = text
        savedTitle = title
        savedText = text
    }

    var isNew: Bool { promptID == nil }
    var isDirty: Bool { title != savedTitle || text != savedText }

    /// Records that `title` and `text` reached the device; anything typed since stays an unsaved edit.
    mutating func markSaved(title: String, text: String) {
        savedTitle = title
        savedText = text
        errorMessage = nil
    }

    mutating func discardEdits() {
        title = savedTitle
        text = savedText
        errorMessage = nil
    }
}

/// The prompts of every reachable paired device in one list, kept live while the app is in the
/// foreground, plus the copy, create, save, and delete actions the prompt screens perform.
///
/// Each device owns its prompts. The app model feeds `reconcile` the reachable devices whenever an
/// overview lands, a device goes offline, or the paired set changes; a device whose overview revision is
/// ahead of the list held for it is fetched again. A prompt of an offline or blocked device is not shown at
/// all, because it could not be edited or have its use recorded.
@MainActor @Observable final class SavedPromptsModel {
    /// How the model reaches a device. Set by the app model, which owns the connections.
    @ObservationIgnored var connectionForDevice: (String) -> SavedPromptsConnection? = { _ in nil }
    /// Unit tests inject a uniquely named pasteboard so a copy never touches `UIPasteboard.general`.
    @ObservationIgnored var pasteboard: UIPasteboard = .general

    private(set) var library = SavedPromptLibrary()
    private(set) var reachableDevices: [SavedPromptLibrary.Device] = []
    /// The device each new prompt defaults to when the user has not chosen one.
    private(set) var defaultDeviceID: String?
    /// The device part of a row's caption and the device picker show only with 2+ paired devices.
    private(set) var showsDeviceNames = false
    var draft: SavedPromptDraft?

    var isDraftDirty: Bool { draft?.isDirty == true }

    func entries(matching query: String) -> [SavedPromptLibrary.Entry] { library.entries(matching: query) }

    func reconcile(reachable: [SavedPromptLibrary.Device], pairedDeviceCount: Int, defaultDeviceID: String?) {
        showsDeviceNames = pairedDeviceCount > 1
        self.defaultDeviceID = defaultDeviceID
        let toFetch = library.reconcile(reachable: reachable)
        if reachable != reachableDevices { reachableDevices = reachable }
        refreshCleanDraft()
        for deviceID in toFetch { fetch(deviceID: deviceID) }
    }

    private func fetch(deviceID: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let connection = connectionForDevice(deviceID) else {
                library.fetchFailed(deviceID: deviceID)
                return
            }
            do {
                let result = try await connection.client.listSavedPrompts(commandChannel: connection.channel)
                apply(result, deviceID: deviceID)
                // An overview that advertised a newer revision while this fetch was in flight started no
                // fetch of its own, so the response may already be behind.
                for id in library.reconcile(reachable: reachableDevices) { fetch(deviceID: id) }
            } catch {
                // The next reconcile retries; nothing the user did failed.
                library.fetchFailed(deviceID: deviceID)
            }
        }
    }

    private func apply(_ result: SpacesDeviceSavedPromptsResult, deviceID: String) {
        library.apply(result, deviceID: deviceID)
        refreshCleanDraft()
    }

    /// A draft with no edits follows the prompt as another client changes it, so Copy never copies a stale
    /// text. A draft with edits is kept as typed: concurrent edits are last write wins.
    private func refreshCleanDraft() {
        guard let current = draft, let promptID = current.promptID, !current.isDirty else { return }
        guard let entry = library.entries(matching: "").first(where: { $0.deviceID == current.deviceID && $0.prompt.id == promptID }) else { return }
        if entry.prompt.title != current.title || entry.prompt.text != current.text {
            draft = SavedPromptDraft(deviceID: current.deviceID, promptID: promptID, title: entry.prompt.title, text: entry.prompt.text)
        }
    }

    // MARK: - Actions

    /// Copies `text` now and records the use on the owning device in the returned task, so a caller that
    /// closes its screen right away does not cancel the recording. A failed recording is ignored: the copy
    /// already worked, and the use only decides ordering. A prompt not saved yet has no use to record.
    @discardableResult func copy(deviceID: String, promptID: String?, text: String) -> Task<Void, Never> {
        pasteboard.string = text
        return Task { [weak self] in
            guard let self, let promptID, let connection = connectionForDevice(deviceID) else { return }
            if let result = try? await connection.client.recordSavedPromptUse(id: promptID, commandChannel: connection.channel) {
                apply(result, deviceID: deviceID)
            }
        }
    }

    func beginEditing(_ entry: SavedPromptLibrary.Entry) {
        draft = SavedPromptDraft(deviceID: entry.deviceID, promptID: entry.prompt.id, title: entry.prompt.title, text: entry.prompt.text)
    }

    /// Starts a new prompt; false when no device is reachable to own it.
    @discardableResult func beginNewPrompt() -> Bool {
        guard let deviceID = defaultDeviceID ?? reachableDevices.first?.id else { return false }
        draft = SavedPromptDraft(deviceID: deviceID, promptID: nil, title: "", text: "")
        return true
    }

    func endEditing() { draft = nil }

    enum SaveOutcome: Equatable { case created, updated, failed }

    /// Saves the draft to its device. The device's own message is shown on failure, for instance when the
    /// text is over the size cap.
    func saveDraft() async -> SaveOutcome {
        guard let current = draft else { return .failed }
        guard let connection = connectionForDevice(current.deviceID) else {
            draft?.errorMessage = "This device is not reachable."
            return .failed
        }
        do {
            let result: SpacesDeviceSavedPromptsResult
            if let promptID = current.promptID {
                result = try await connection.client.updateSavedPrompt(
                    id: promptID, title: current.title, text: current.text, commandChannel: connection.channel)
            } else {
                result = try await connection.client.createSavedPrompt(title: current.title, text: current.text, commandChannel: connection.channel)
            }
            return finishSave(result, sent: current)
        } catch {
            if isOpen(current) { draft?.errorMessage = Self.message(for: error) }
            return .failed
        }
    }

    /// Installs a save's response. `.created` means the new prompt is saved exactly as sent and the screen
    /// can close. Anything typed while the request was in flight keeps the screen open on the saved prompt
    /// with those edits unsaved, so the outcome is then `.updated`.
    func finishSave(_ result: SpacesDeviceSavedPromptsResult, sent: SavedPromptDraft) -> SaveOutcome {
        apply(result, deviceID: sent.deviceID)
        guard isOpen(sent), let open = draft else { return .failed }
        if !sent.isNew {
            draft?.markSaved(title: sent.title, text: sent.text)
            return .updated
        }
        guard open.title != sent.title || open.text != sent.text, let createdID = result.createdPromptID else { return .created }
        var continued = SavedPromptDraft(deviceID: sent.deviceID, promptID: createdID, title: sent.title, text: sent.text)
        continued.title = open.title
        continued.text = open.text
        draft = continued
        return .updated
    }

    /// Whether the open draft is `other`'s prompt, for results that arrive after the user moved on. A new
    /// draft's device is not compared because the picker can change it while the save is in flight.
    private func isOpen(_ other: SavedPromptDraft) -> Bool { draft?.promptID == other.promptID && (other.isNew || draft?.deviceID == other.deviceID) }

    func discardEdits() { draft?.discardEdits() }

    /// Deletes the draft's prompt; true when it is gone and still the open draft, so the screen should close.
    func deleteDraft() async -> Bool {
        guard let current = draft, let promptID = current.promptID else { return false }
        guard let connection = connectionForDevice(current.deviceID) else {
            draft?.errorMessage = "This device is not reachable."
            return false
        }
        do {
            let result = try await connection.client.deleteSavedPrompt(id: promptID, commandChannel: connection.channel)
            return finishDelete(result, deleted: current)
        } catch {
            if isOpen(current) { draft?.errorMessage = Self.message(for: error) }
            return false
        }
    }

    /// Installs a delete's response. The user may have opened another prompt while the delete was in
    /// flight; closing the screen would then discard that prompt's edits.
    func finishDelete(_ result: SpacesDeviceSavedPromptsResult, deleted: SavedPromptDraft) -> Bool {
        apply(result, deviceID: deleted.deviceID)
        return isOpen(deleted)
    }

    private static func message(for error: Error) -> String {
        if case SpacesDeviceAPIClientError.requestFailed(let message, _) = error { return message }
        return error.localizedDescription
    }
}

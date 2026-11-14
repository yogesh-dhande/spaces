import SwiftUI
import spacesdevicecore

/// One prompt: its title and text, editable, with Copy, Save, Discard, and Delete.
///
/// Edits are held in `SavedPromptsModel.draft` until Save or Discard. Copy takes the text as it is on
/// screen, unsaved edits included, and never saves. While the draft is dirty the system back button is
/// replaced with one that asks Save / Discard / Cancel, so an edit cannot be lost by a stray swipe.
struct SavedPromptDetailView: View {
    let appModel: SpacesMobileAppModel
    /// Leaves the detail screen: after a create, a delete, or the user's choice on the unsaved-changes dialog.
    let onFinished: () -> Void

    @State private var showsCopied = false
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var isConfirmingDelete = false
    @State private var isAskingAboutUnsavedChanges = false
    @State private var isWorking = false

    private var model: SavedPromptsModel { appModel.savedPrompts }

    var body: some View {
        if let draft = model.draft {
            content(draft).navigationBarTitleDisplayMode(.inline).navigationTitle(draft.isNew ? "New prompt" : "Prompt")
                .navigationBarBackButtonHidden(draft.isDirty).toolbar {
                    if draft.isDirty {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                isAskingAboutUnsavedChanges = true
                            } label: {
                                Label("Back", systemImage: "chevron.backward")
                            }.accessibilityIdentifier("prompts.detail.back")
                        }
                    }
                    if !draft.isNew {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .destructive) {
                                isConfirmingDelete = true
                            } label: {
                                Image(systemName: "trash")
                            }.foregroundStyle(Theme.red).accessibilityLabel("Delete prompt").accessibilityIdentifier("prompts.detail.delete")
                        }
                    }
                }.confirmationDialog("Delete \u{201C}\(draft.title)\u{201D}?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { Task { await delete() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the prompt from \(deviceName(draft)).")
                }.confirmationDialog("Save your changes?", isPresented: $isAskingAboutUnsavedChanges, titleVisibility: .visible) {
                    Button("Save") { Task { await save(thenLeave: true) } }
                    Button("Discard", role: .destructive) {
                        model.discardEdits()
                        onFinished()
                    }
                    Button("Cancel", role: .cancel) {}
                }.onDisappear { model.endEditing() }
        }
    }

    private func content(_ draft: SavedPromptDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if draft.isNew, model.reachableDevices.count > 1 {
                    Picker("Device", selection: Binding(get: { draft.deviceID }, set: { model.draft?.deviceID = $0 })) {
                        ForEach(model.reachableDevices, id: \.id) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.menu).tint(Theme.accent).accessibilityIdentifier("prompts.detail.device")
                }
                TextField("Title", text: Binding(get: { draft.title }, set: { model.draft?.title = $0 })).font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 44).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("prompts.detail.title")
                TextEditor(text: Binding(get: { draft.text }, set: { model.draft?.text = $0 })).font(.system(size: 15)).scrollContentBackground(
                    .hidden
                ).padding(8).frame(minHeight: 220).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("prompts.detail.text")
                if draft.isDirty {
                    Text("Edited \u{00B7} not saved").font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).accessibilityIdentifier(
                        "prompts.detail.dirty")
                }
                actions(draft)
                if let message = draft.errorMessage {
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.red).accessibilityIdentifier("prompts.detail.error")
                }
            }.padding(16)
        }.background(Theme.bg).scrollDismissesKeyboard(.interactively)
    }

    private func actions(_ draft: SavedPromptDraft) -> some View {
        HStack(spacing: 10) {
            if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    copy(draft)
                } label: {
                    Label(showsCopied ? "Copied" : "Copy", systemImage: showsCopied ? "checkmark" : "doc.on.doc").font(.system(size: 14)).padding(
                        .horizontal, 14
                    ).frame(height: 34).overlay(Capsule().strokeBorder(Theme.borderStrong, lineWidth: 1))
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).accessibilityIdentifier("prompts.detail.copy")
            }
            Spacer(minLength: 0)
            if draft.isDirty {
                Button("Discard") { model.discardEdits() }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.muted).padding(
                    .horizontal, 12
                ).frame(height: 34).accessibilityIdentifier("prompts.detail.discard")
                Button {
                    Task { await save() }
                } label: {
                    Text("Save").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryButtonText).padding(.horizontal, 18).frame(
                        height: 34
                    ).background(Theme.primaryButtonFill, in: Capsule())
                }.buttonStyle(.plain).disabled(isWorking).accessibilityIdentifier("prompts.detail.save")
            }
        }
    }

    private func deviceName(_ draft: SavedPromptDraft) -> String { model.reachableDevices.first { $0.id == draft.deviceID }?.name ?? "this device" }

    private func copy(_ draft: SavedPromptDraft) {
        model.copy(deviceID: draft.deviceID, promptID: draft.promptID, text: draft.text)
        showsCopied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { showsCopied = false }
        }
    }

    private func save(thenLeave: Bool = false) async {
        isWorking = true
        defer { isWorking = false }
        switch await model.saveDraft() {
        case .created: onFinished()
        // Edits typed while the save was in flight stay open to be saved or discarded.
        case .updated: if thenLeave, !model.isDraftDirty { onFinished() }
        case .failed: break
        }
    }

    private func delete() async {
        isWorking = true
        defer { isWorking = false }
        if await model.deleteDraft() { onFinished() }
    }
}

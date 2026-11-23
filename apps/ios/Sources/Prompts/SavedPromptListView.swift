import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// How a prompt row's second line reads: the owning device (only when there are 2+ paired devices, so it
/// answers a question the user actually has) and when the prompt was last copied or created.
enum SavedPromptRowCaption {
    static func text(for entry: SavedPromptLibrary.Entry, showsDeviceName: Bool, relativeTo now: Date) -> String {
        let used = TerminalSessionTimestamp.date(from: entry.prompt.lastUsedAt).map { AlertsAgeFormatting.abbreviatedAge(of: $0, relativeTo: now) }
        return [showsDeviceName ? entry.deviceName : nil, used].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The search field and the merged prompt rows. Each row has a Copy button; tapping the row opens the
/// prompt's detail screen, and swiping it deletes the prompt after a confirmation.
struct SavedPromptListView: View {
    let appModel: SpacesMobileAppModel
    let onCopied: () -> Void
    let onOpen: (SavedPromptLibrary.Entry) -> Void
    let onNew: () -> Void
    @State private var query = ""
    @State private var pendingDelete: SavedPromptLibrary.Entry?
    @State private var deleteError: String?

    private var model: SavedPromptsModel { appModel.savedPrompts }

    var body: some View {
        let entries = model.entries(matching: query)
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.mutedSecondary)
                TextField("Search prompts", text: $query).font(.system(size: 16)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("prompts.search")
            }.padding(.horizontal, 10).frame(height: 38).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16).padding(.bottom, 8)
            if entries.isEmpty {
                emptyState
            } else {
                List(entries) { entry in row(entry) }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.prompt.title ?? "")\u{201D}?", isPresented: deleteDialogBinding, titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) { Task { deleteError = await model.delete(entry) } }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("This removes the prompt from \(entry.deviceName).")
        }.alert("Could not delete the prompt", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView {
                Label("No saved prompts", systemImage: "text.quote")
            } description: {
                Text("Save prompts you reuse, then copy one into any terminal.")
            } actions: {
                Button("Create a prompt", action: onNew).disabled(model.reachableDevices.isEmpty).accessibilityIdentifier("prompts.create")
            }.accessibilityIdentifier("prompts.empty")
        } else {
            ContentUnavailableView {
                Label("No matching prompts", systemImage: "magnifyingglass")
            }.accessibilityIdentifier("prompts.noMatch")
        }
    }

    private var deleteDialogBinding: Binding<Bool> { Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }) }

    private var deleteErrorBinding: Binding<Bool> { Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }) }

    private func row(_ entry: SavedPromptLibrary.Entry) -> some View {
        let caption = SavedPromptRowCaption.text(for: entry, showsDeviceName: model.showsDeviceNames, relativeTo: appModel.relativeTimeReference)
        return HStack(spacing: 12) {
            Button {
                onOpen(entry)
            } label: {
                rowLabel(entry, caption: caption).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("prompts.row.\(entry.prompt.id)")
            Button("Copy") {
                model.copy(deviceID: entry.deviceID, promptID: entry.prompt.id, text: entry.prompt.text)
                onCopied()
            }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.accent).padding(.horizontal, 14).frame(height: 34).overlay(
                Capsule().strokeBorder(Theme.borderStrong, lineWidth: 1)
            ).accessibilityIdentifier("prompts.copy.\(entry.prompt.id)")
        }.listRowBackground(Color.clear).listRowSeparator(.hidden).swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }.accessibilityIdentifier("prompts.delete.\(entry.prompt.id)")
        }
    }

    private func rowLabel(_ entry: SavedPromptLibrary.Entry, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.prompt.title).font(.system(size: 16)).foregroundStyle(Theme.text).lineLimit(1)
            Text(caption).font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
    }
}

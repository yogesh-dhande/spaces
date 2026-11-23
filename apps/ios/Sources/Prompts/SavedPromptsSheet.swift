import SwiftUI

/// The prompt picker over a terminal: search, Copy per row, a "+" for a new prompt, and each prompt's
/// detail screen for editing. Copy closes the sheet so the user can paste into the composer or the
/// terminal.
///
/// The sheet refuses an interactive dismissal while the detail screen holds unsaved edits; the
/// detail screen's own back button asks what to do with them.
struct SavedPromptsSheet: View {
    enum Route: Hashable {
        case detail
    }

    let appModel: SpacesMobileAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            SavedPromptListView(
                appModel: appModel, onCopied: { dismiss() },
                onOpen: { entry in
                    appModel.savedPrompts.beginEditing(entry)
                    path.append(.detail)
                }, onNew: newPrompt
            ).background(Theme.bg).navigationTitle("Prompts").toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.accent).accessibilityIdentifier("prompts.done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: newPrompt) { Image(systemName: "plus") }.disabled(appModel.savedPrompts.reachableDevices.isEmpty)
                        .accessibilityLabel("New prompt").accessibilityIdentifier("prompts.new")
                }
            }.navigationDestination(for: Route.self) { _ in
                SavedPromptDetailView(appModel: appModel, onFinished: { path.removeAll() })
            }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationBackground(Theme.bg).interactiveDismissDisabled(
            appModel.savedPrompts.isDraftDirty
        ).accessibilityElement(children: .contain).accessibilityIdentifier("prompts.sheet").tint(Theme.accent)
    }

    private func newPrompt() { if appModel.savedPrompts.beginNewPrompt() { path.append(.detail) } }
}

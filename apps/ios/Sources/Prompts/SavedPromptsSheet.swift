import SwiftUI

/// The prompt picker over a terminal: search, Copy per row, and a Library link to the full list and the
/// editor. Copy closes the sheet so the user can paste into the composer or the terminal.
///
/// The sheet refuses an interactive dismissal while the detail screen holds unsaved edits; the
/// detail screen's own back button asks what to do with them.
struct SavedPromptsSheet: View {
    enum Route: Hashable {
        case library
        case detail
    }

    let appModel: SpacesMobileAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            SavedPromptListView(appModel: appModel, style: .sheet(onCopied: { dismiss() })).background(Theme.bg).navigationTitle("Prompts")
                .navigationBarTitleDisplayMode(.inline).toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Library") { path.append(.library) }.foregroundStyle(Theme.accent).accessibilityIdentifier("prompts.library")
                    }
                }.navigationDestination(for: Route.self) { route in
                    switch route {
                    case .library: library
                    case .detail: SavedPromptDetailView(appModel: appModel, onFinished: { path.removeAll { $0 == .detail } })
                    }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationBackground(Theme.bg).interactiveDismissDisabled(
            appModel.savedPrompts.isDraftDirty
        ).accessibilityElement(children: .contain).accessibilityIdentifier("prompts.sheet").tint(Theme.accent)
    }

    private var library: some View {
        SavedPromptListView(
            appModel: appModel,
            style: .library(onOpen: { entry in
                appModel.savedPrompts.beginEditing(entry)
                path.append(.detail)
            })
        ).background(Theme.bg).navigationTitle("Library").navigationBarTitleDisplayMode(.inline).toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if appModel.savedPrompts.beginNewPrompt() { path.append(.detail) }
                } label: {
                    Image(systemName: "plus")
                }.disabled(appModel.savedPrompts.reachableDevices.isEmpty).accessibilityLabel("New prompt").accessibilityIdentifier("prompts.new")
            }
        }
    }
}

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

/// The search field and the merged prompt rows. The prompt sheet shows a Copy button on each row; the
/// library shows the same rows as links into the detail screen.
struct SavedPromptListView: View {
    enum Style {
        case sheet(onCopied: () -> Void)
        case library(onOpen: (SavedPromptLibrary.Entry) -> Void)
    }

    let appModel: SpacesMobileAppModel
    let style: Style
    @State private var query = ""

    private var model: SavedPromptsModel { appModel.savedPrompts }

    var body: some View {
        let entries = model.entries(matching: query)
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.mutedSecondary)
                TextField("Search", text: $query).font(.system(size: 16)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("prompts.search")
            }.padding(.horizontal, 10).frame(height: 38).background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16).padding(.bottom, 8)
            if entries.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "No saved prompts yet." : "No prompts match.").font(.system(size: 14))
                    .foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).accessibilityIdentifier(
                        "prompts.empty")
            } else {
                List(entries) { entry in row(entry) }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder private func row(_ entry: SavedPromptLibrary.Entry) -> some View {
        let caption = SavedPromptRowCaption.text(for: entry, showsDeviceName: model.showsDeviceNames, relativeTo: appModel.relativeTimeReference)
        switch style {
        case .sheet(let onCopied):
            HStack(spacing: 12) {
                rowLabel(entry, caption: caption)
                Button("Copy") {
                    model.copy(deviceID: entry.deviceID, promptID: entry.prompt.id, text: entry.prompt.text)
                    onCopied()
                }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.accent).padding(.horizontal, 14).frame(height: 34).overlay(
                    Capsule().strokeBorder(Theme.borderStrong, lineWidth: 1)
                ).accessibilityIdentifier("prompts.copy.\(entry.prompt.id)")
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
        case .library(let onOpen):
            Button {
                onOpen(entry)
            } label: {
                HStack(spacing: 12) {
                    rowLabel(entry, caption: caption)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedSecondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("prompts.row.\(entry.prompt.id)").listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
    }

    private func rowLabel(_ entry: SavedPromptLibrary.Entry, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.prompt.title).font(.system(size: 16)).foregroundStyle(Theme.text).lineLimit(1)
            Text(caption).font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
    }
}

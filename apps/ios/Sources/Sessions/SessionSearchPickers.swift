import SwiftUI
import spacesterminalcore

/// The paired devices; picking one searches it and returns to the search screen.
struct SessionSearchDeviceList: View {
    let model: SessionSearchModel
    let appModel: SpacesMobileAppModel
    let onPicked: () -> Void

    var body: some View {
        List(model.devices) { device in
            Button {
                Task { await model.selectDevice(device.id) }
                onPicked()
            } label: {
                HStack {
                    Text(device.name).foregroundStyle(Theme.text)
                    if appModel.offlineDeviceIDs.contains(device.id) { Text("Offline").font(.footnote).foregroundStyle(Theme.mutedSecondary) }
                    Spacer(minLength: 0)
                    if device.id == model.deviceID { Image(systemName: "checkmark").foregroundStyle(Theme.accent).accessibilityHidden(true) }
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).listRowBackground(Color.clear).accessibilityAddTraits(device.id == model.deviceID ? .isSelected : [])
                .accessibilityIdentifier("sessions.device.\(device.id)")
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.bg).navigationTitle("Device").navigationBarTitleDisplayMode(.inline)
    }
}

/// The agents the device has conversations for, as a multi-select. Nothing ticked means all of them.
struct SessionSearchAgentList: View {
    let model: SessionSearchModel

    var body: some View {
        List {
            row(title: "All agents", isSelected: model.effectiveAgents.isEmpty, id: "sessions.agent.all") { await model.clearAgents() }
            ForEach(model.availableAgents, id: \.self) { agent in
                row(title: agent.displayName, isSelected: model.effectiveAgents.contains(agent), id: "sessions.agent.\(agent.rawValue)") {
                    await model.toggleAgent(agent)
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.bg).navigationTitle("Agents").navigationBarTitleDisplayMode(.inline)
    }

    private func row(title: String, isSelected: Bool, id: String, action: @escaping () async -> Void) -> some View {
        SessionSearchChoiceRow(title: title, isSelected: isSelected, id: id, action: action)
    }
}

/// The project the search is limited to, as a single select: all projects, the device's projects in its
/// order, then home.
struct SessionSearchProjectList: View {
    let model: SessionSearchModel
    let onPicked: () -> Void

    var body: some View {
        List {
            SessionSearchChoiceRow(title: "All projects", isSelected: model.effectiveProjectID == nil, id: "sessions.project.all") {
                onPicked()
                await model.selectProject(nil)
            }
            ForEach(model.availableProjects, id: \.id) { project in
                SessionSearchChoiceRow(
                    title: SessionSearchRowText.projectName(project), isSelected: model.effectiveProjectID == project.id,
                    id: "sessions.project.\(project.id)"
                ) {
                    onPicked()
                    await model.selectProject(project.id)
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.bg).navigationTitle("Projects").navigationBarTitleDisplayMode(.inline)
    }
}

private struct SessionSearchChoiceRow: View {
    let title: String
    let isSelected: Bool
    let id: String
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark").foregroundStyle(Theme.accent).accessibilityHidden(true) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).listRowBackground(Color.clear).accessibilityAddTraits(isSelected ? .isSelected : []).accessibilityIdentifier(id)
    }
}

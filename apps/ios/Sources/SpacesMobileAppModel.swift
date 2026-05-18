import Foundation
import Observation
import spacesmobilecore

private enum SpacesMobileSettingsStore {
    static let settingsKey = "spaces.mobile.connection-settings"

    static func load() -> SpacesMobileConnectionSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(SpacesMobileConnectionSettings.self, from: data) else {
            return SpacesMobileConnectionSettings()
        }
        return decoded
    }

    static func save(_ settings: SpacesMobileConnectionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }
}

enum SpacesMobileWorkspaceSelection: Hashable {
    case all
    case workspace(String)
}

struct SpacesMobileWorkspaceSection: Identifiable {
    let id: String
    let projectName: String
    let workspaces: [SpacesMobileWorkspaceSummary]
}

@MainActor @Observable final class SpacesMobileAppModel {
    var settings: SpacesMobileConnectionSettings
    var overview: SpacesMobileOverviewPayload?
    var selectedWorkspace = SpacesMobileWorkspaceSelection.all
    var selectedSessionID: String?
    var isLoading = false
    var isShowingConnectionSettings = false
    var errorMessage: String?

    init() {
        let loadedSettings = SpacesMobileSettingsStore.load()
        settings = loadedSettings
        SpacesMobileSettingsStore.save(loadedSettings)
    }

    var workspaceSections: [SpacesMobileWorkspaceSection] {
        let grouped = Dictionary(grouping: overview?.workspaces ?? [], by: \.projectName)
        return grouped.keys.sorted().map { projectName in
            let workspaces = grouped[projectName, default: []].sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return SpacesMobileWorkspaceSection(id: projectName, projectName: projectName, workspaces: workspaces)
        }
    }

    var filteredSessions: [SpacesMobileTerminalSessionSummary] {
        let sessions = overview?.sessions ?? []
        return switch selectedWorkspace {
        case .all:
            sessions
        case .workspace(let workspaceID):
            sessions.filter { $0.workspaceID == workspaceID }
        }
    }

    var selectedSession: SpacesMobileTerminalSessionSummary? {
        guard let selectedSessionID else { return filteredSessions.first }
        return (overview?.sessions ?? []).first { $0.id == selectedSessionID }
    }

    var connectionSummary: String { "\(settings.trimmedHost):\(settings.port)" }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let overview = try await SpacesMobileBridgeClient(settings: settings).fetchOverview()
            self.overview = overview
            errorMessage = nil
            if let selectedSessionID, !overview.sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = overview.sessions.first?.id
            } else if self.selectedSessionID == nil {
                self.selectedSessionID = overview.sessions.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyConnectionSettings(_ settings: SpacesMobileConnectionSettings) {
        self.settings = settings
        SpacesMobileSettingsStore.save(settings)
        overview = nil
        selectedSessionID = nil
        selectedWorkspace = .all
    }

    func dismissError() { errorMessage = nil }
}

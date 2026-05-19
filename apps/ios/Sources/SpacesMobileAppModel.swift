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

struct SpacesMobileTerminalWorkspaceGroup: Identifiable {
    let id: String
    let projectName: String
    let workspaceTitle: String
    let workspaceDirectory: String
    let sessions: [SpacesMobileTerminalSessionSummary]
}

@MainActor @Observable final class SpacesMobileAppModel {
    var settings: SpacesMobileConnectionSettings
    var overview: SpacesMobileOverviewPayload?
    var isLoading = false
    var isShowingConnectionSettings = false
    var connectionNotice: String?
    var errorMessage: String?

    init() {
        let loadedSettings = SpacesMobileSettingsStore.load()
        settings = loadedSettings
        SpacesMobileSettingsStore.save(loadedSettings)
    }

    var terminalGroups: [SpacesMobileTerminalWorkspaceGroup] {
        let workspaceByID = Dictionary(uniqueKeysWithValues: (overview?.workspaces ?? []).map { ($0.id, $0) })
        let grouped = Dictionary(grouping: overview?.sessions ?? []) { session in
            session.workspaceID ?? "unassigned::\(session.projectID ?? session.projectName ?? "none")::\(session.workingDirectory)"
        }

        return grouped.values.compactMap { sessions in
            guard let firstSession = sessions.first else { return nil }
            let workspace = firstSession.workspaceID.flatMap { workspaceByID[$0] }
            let projectName = workspace?.projectName ?? firstSession.projectName ?? "Unassigned"
            let workspaceTitle = workspace?.title ?? firstSession.workspaceTitle ?? "Unassigned"
            let workspaceDirectory = workspace?.dir ?? firstSession.workingDirectory
            let orderedSessions = sessions.sorted(by: sessionSort)

            return SpacesMobileTerminalWorkspaceGroup(
                id: workspace?.id ?? "unassigned::\(projectName)::\(workspaceDirectory)",
                projectName: projectName,
                workspaceTitle: workspaceTitle,
                workspaceDirectory: workspaceDirectory,
                sessions: orderedSessions
            )
        }
        .sorted(by: groupSort)
    }

    var connectionSummary: String { "\(settings.trimmedHost):\(settings.port)" }

    func session(id: String) -> SpacesMobileTerminalSessionSummary? {
        overview?.sessions.first(where: { $0.id == id })
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let overview = try await SpacesMobileBridgeClient(settings: settings).fetchOverview()
            self.overview = overview
            connectionNotice = nil
            errorMessage = nil
        } catch {
            if let recoveryMessage = SpacesMobileBridgeAuthentication.recoveryMessage(for: error) {
                handleAuthenticationFailure(message: recoveryMessage)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func applyConnectionSettings(_ settings: SpacesMobileConnectionSettings) {
        self.settings = settings
        SpacesMobileSettingsStore.save(settings)
        overview = nil
        connectionNotice = nil
    }

    func dismissError() { errorMessage = nil }

    func handleAuthenticationFailure(message: String) {
        settings.authToken = ""
        SpacesMobileSettingsStore.save(settings)
        overview = nil
        connectionNotice = message
        errorMessage = nil
        isShowingConnectionSettings = true
    }

    private func groupSort(_ lhs: SpacesMobileTerminalWorkspaceGroup, _ rhs: SpacesMobileTerminalWorkspaceGroup) -> Bool {
        if lhs.projectName.localizedStandardCompare(rhs.projectName) != .orderedSame {
            return lhs.projectName.localizedStandardCompare(rhs.projectName) == .orderedAscending
        }
        return lhs.workspaceTitle.localizedStandardCompare(rhs.workspaceTitle) == .orderedAscending
    }

    private func sessionSort(_ lhs: SpacesMobileTerminalSessionSummary, _ rhs: SpacesMobileTerminalSessionSummary) -> Bool {
        if lhs.state != rhs.state {
            return lhs.state == .running && rhs.state != .running
        }
        if lhs.title.localizedStandardCompare(rhs.title) != .orderedSame {
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return lhs.createdAt < rhs.createdAt
    }
}

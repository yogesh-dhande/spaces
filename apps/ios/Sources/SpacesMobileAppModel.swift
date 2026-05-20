import Foundation
import Observation
import spacesmobilecore

private enum SpacesMobileSettingsStore {
    static let settingsKey = "spaces.mobile.connection-settings"

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> SpacesMobileConnectionSettings {
        let storedSettings: SpacesMobileConnectionSettings
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(SpacesMobileConnectionSettings.self, from: data)
        {
            storedSettings = decoded
        } else {
            storedSettings = SpacesMobileConnectionSettings()
        }

        return appliedTestOverrides(to: storedSettings, environment: environment)
    }

    static func save(_ settings: SpacesMobileConnectionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    private static func appliedTestOverrides(
        to settings: SpacesMobileConnectionSettings,
        environment: [String: String]
    ) -> SpacesMobileConnectionSettings {
        var resolved = settings

        if let host = trimmed(environment["SPACES_MOBILE_TEST_HOST"]) {
            resolved.host = host
        }
        if let port = trimmed(environment["SPACES_MOBILE_TEST_PORT"]).flatMap(Int.init), (1...65535).contains(port) {
            resolved.port = port
        }
        if let authToken = trimmed(environment["SPACES_MOBILE_TEST_AUTH_TOKEN"]) {
            resolved.authToken = authToken
        }
        if let installationID = trimmed(environment["SPACES_MOBILE_TEST_INSTALLATION_ID"]) {
            resolved.installationID = installationID
        }

        return resolved
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct SpacesMobileE2EConfig {
    static let shared = Self(environment: ProcessInfo.processInfo.environment)

    let targetSessionID: String?
    let renderDumpPath: String?
    let eventLogPath: String?
    let commandMarkerPath: String?
    let commandText: String?

    init(environment: [String: String]) {
        targetSessionID = Self.trimmed(environment["SPACES_MOBILE_E2E_TARGET_SESSION_ID"])
        renderDumpPath = Self.trimmed(environment["SPACES_MOBILE_E2E_RENDER_DUMP_PATH"])
        eventLogPath = Self.trimmed(environment["SPACES_MOBILE_E2E_EVENT_LOG_PATH"])
        commandMarkerPath = Self.trimmed(environment["SPACES_MOBILE_E2E_COMMAND_MARKER_PATH"])
        commandText = Self.trimmed(environment["SPACES_MOBILE_E2E_COMMAND_TEXT"])
    }

    var isEnabled: Bool { targetSessionID != nil || renderDumpPath != nil || eventLogPath != nil }

    func matches(sessionID: String) -> Bool {
        guard let targetSessionID else { return true }
        return targetSessionID == sessionID
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

}

struct SpacesMobileE2ERenderDump: Codable, Equatable {
    let sessionID: String
    let title: String
    let isOwner: Bool
    let isConnecting: Bool
    let isBusy: Bool
    let isSynchronizingOwnership: Bool
    let isInputSurfaceReady: Bool
    let viewportColumns: Int?
    let viewportRows: Int?
    let lastSentResizeColumns: Int?
    let lastSentResizeRows: Int?
    let runtimeColumns: Int?
    let runtimeRows: Int?
    let snapshotColumns: Int?
    let snapshotRows: Int?
    let errorMessage: String?
    let visibleText: String
    let renderedText: String
    let replayStateKey: String
    let emittedAt: String
}

struct SpacesMobileE2EEvent: Codable, Equatable {
    let sessionID: String
    let kind: String
    let detail: String?
    let emittedAt: String
}

enum SpacesMobileE2EDumpWriter {
    static func writeCurrentDump(_ dump: SpacesMobileE2ERenderDump, config: SpacesMobileE2EConfig = .shared) {
        if let renderDumpPath = config.renderDumpPath { writeJSON(dump, to: renderDumpPath) }
        if let eventLogPath = config.eventLogPath { appendJSONLine(dump, to: eventLogPath) }
    }

    static func appendEvent(_ event: SpacesMobileE2EEvent, config: SpacesMobileE2EConfig = .shared) {
        guard let eventLogPath = config.eventLogPath else { return }
        appendJSONLine(event, to: eventLogPath)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {}
    }

    private static func appendJSONLine<T: Encodable>(_ value: T, to path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            var data = try encoder.encode(value)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: [.atomic])
            }
        } catch {}
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
    @ObservationIgnored private var bridgeClient: SpacesMobileBridgeClient
    @ObservationIgnored private var commandChannel: SpacesMobileBridgeCommandChannel

    init() {
        let loadedSettings = SpacesMobileSettingsStore.load()
        let bridgeClient = SpacesMobileBridgeClient(settings: loadedSettings)
        settings = loadedSettings
        self.bridgeClient = bridgeClient
        commandChannel = bridgeClient.makeCommandChannel()
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

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let overview = try await bridgeClient.fetchOverview(commandChannel: commandChannel)
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
        let previousCommandChannel = commandChannel
        self.settings = settings
        bridgeClient = SpacesMobileBridgeClient(settings: settings)
        commandChannel = bridgeClient.makeCommandChannel()
        SpacesMobileSettingsStore.save(settings)
        overview = nil
        connectionNotice = nil
        Task { await previousCommandChannel.close() }
    }

    func dismissError() { errorMessage = nil }

    func handleAuthenticationFailure(message: String) {
        let previousCommandChannel = commandChannel
        settings.authToken = ""
        bridgeClient = SpacesMobileBridgeClient(settings: settings)
        commandChannel = bridgeClient.makeCommandChannel()
        SpacesMobileSettingsStore.save(settings)
        overview = nil
        connectionNotice = message
        errorMessage = nil
        isShowingConnectionSettings = true
        Task { await previousCommandChannel.close() }
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

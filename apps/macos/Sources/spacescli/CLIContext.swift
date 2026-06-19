import Foundation
import systembridge
import workspacecore

struct CLIContext {
    let output = CLITextOrJSONOutput()
    private let storeFactory: () throws -> SQLiteStore
    init(
        storeFactory: @escaping () throws -> SQLiteStore = {
            let db = try DatabaseLocator.defaultPath()
            return try SQLiteStore(path: db)
        }
    ) { self.storeFactory = storeFactory }

    func makeOrchestrator() throws -> WorkspaceOrchestrator {
        let store = try storeFactory()
        let orchestrator = WorkspaceOrchestrator(store: store)
        _ = try orchestrator.syncConfig()
        return orchestrator
    }

    func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    func currentDirectoryPath() -> String { FileManager.default.currentDirectoryPath }

    func environment() -> [String: String] { ProcessInfo.processInfo.environment }

    func currentYabaiWindowID() -> Int? {
        guard let json = try? Shell.runAndCapture(["yabai", "-m", "query", "--windows", "--window"]), let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? Int
        else { return nil }

        return id
    }

    func fireAgentEventNotification() {
        #if os(macOS)
            try? IPCNotification.post(IPCNotification.agentEventFired)
        #endif
    }
}

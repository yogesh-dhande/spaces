import Foundation
import appctl
import streamctl

struct CLIContext {
    let output = CLITextOrJSONOutput()

    func makeOrchestrator() throws -> MuxyOrchestrator {
        let db = try DatabaseLocator.defaultPath()
        let store = try SQLiteStore(path: db)
        let orchestrator = MuxyOrchestrator(store: store)
        _ = try orchestrator.syncConfig()
        return orchestrator
    }

    func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func currentDirectoryPath() -> String {
        FileManager.default.currentDirectoryPath
    }

    func environment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    func currentYabaiWindowID() -> Int? {
        guard
            let json = try? Shell.runAndCapture(["yabai", "-m", "query", "--windows", "--window"]),
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? Int
        else {
            return nil
        }

        return id
    }

    func fireAgentEventNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.agentEventFired,
            object: nil,
            userInfo: nil,
            options: [.deliverImmediately]
        )
    }
}

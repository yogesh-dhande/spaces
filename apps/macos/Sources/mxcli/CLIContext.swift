import Foundation
import appctl
import streamctl

struct CLIContext {
    let output = CLITextOrJSONOutput()
    private let storeFactory: () throws -> SQLiteStore
    private let itermFactory: () -> Iterm2Adapter

    init(
        storeFactory: @escaping () throws -> SQLiteStore = {
            let db = try DatabaseLocator.defaultPath()
            return try SQLiteStore(path: db)
        },
        itermFactory: @escaping () -> Iterm2Adapter = {
            Iterm2Adapter(scheduleVerificationWork: { work in
                // Short-lived CLI commands can exit immediately after focus returns, so keep
                // iTerm's exact-session verification on the current process lifetime.
                work()
            })
        }
    ) {
        self.storeFactory = storeFactory
        self.itermFactory = itermFactory
    }

    func makeOrchestrator() throws -> MuxyOrchestrator {
        let store = try storeFactory()
        let iterm = itermFactory()
        let orchestrator = MuxyOrchestrator(store: store, iterm: iterm)
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

    func currentTmuxWindowID(environment: [String: String]) -> String? {
        guard let tmuxEnv = environment["TMUX"], !tmuxEnv.isEmpty else { return nil }
        guard let window = try? TmuxAdapter().currentWindow() else { return tmuxEnv }
        return window.id
    }

    func fireAgentEventNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.agentEventFired, object: nil, userInfo: nil, options: [.deliverImmediately])
    }
}

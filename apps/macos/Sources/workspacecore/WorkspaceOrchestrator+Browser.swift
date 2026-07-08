import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    func resolvedBrowserSessionsForFocusNames(workspaceID: String, browserSessions: [BrowserSession]? = nil) throws -> [(
        name: String, targetURL: String
    )] {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let sessions = try browserSessions ?? store.workspaceBrowserSessions(workspaceID: workspace.id)
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) }, runtimeManifest: runtimeManifest
        )
        return try resolveBrowserSessions(sessions, env: env).compactMap { resolved in
            guard let targetURL = sanitizedFocusName(resolved.prefix) else { return nil }
            let name = try requiredConfiguredFocusName(resolved.session.name, kind: "Browser session")
            return (name, targetURL)
        }
    }

    func resolveBrowserSessions(_ sessions: [BrowserSession], env: [String: String]) -> [ResolvedBrowserSession] {
        var resolved: [ResolvedBrowserSession] = []
        var seen = Set<String>()
        for (index, session) in sessions.enumerated() {
            guard let rawURL = session.url?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty else { continue }
            let prefix = applyEnvVars(rawURL, env: env)
            guard !prefix.isEmpty, !seen.contains(prefix) else { continue }
            seen.insert(prefix)
            resolved.append(ResolvedBrowserSession(index: index, prefix: prefix, session: session))
        }
        return resolved
    }
}

import Foundation

/// Installs the Spaces lifecycle hooks for GitHub Copilot CLI.
///
/// Copilot loads every `*.json` file in `~/.copilot/hooks/` at startup and runs the user-level ones
/// without a trust or approval prompt (verified against copilot 1.0.91 to 1.0.95). Spaces owns exactly
/// one of them, `spaces.json`, and writes it wholesale, so installation is inherently idempotent and
/// never merges into a file the user keeps:
///
/// ```
/// { "version": 1, "hooks": { "<event>": [ { "type": "command", "bash": "…", "timeoutSec": 10 } ] } }
/// ```
///
/// Copilot's entries are flat (no matcher group) and name their shell command under `bash`. A
/// non-zero exit from a `preToolUse` hook denies the tool, which is why every Spaces hook command
/// swallows its own failures and always exits 0 (see `AgentHookCommand.signalCommand`).
enum AgentHookCopilotHooksWriter {
    static let hooksFileName = "spaces.json"

    /// The longest a hook may run before Copilot abandons it. A signal is one local socket round trip.
    private static let timeoutSeconds = 10

    struct UnmanagedHooksFileError: LocalizedError {
        let path: String
        var errorDescription: String? { "\(path) already exists and is not managed by Spaces; refusing to overwrite it." }
    }

    static func hooksFileURL(copilotHome: URL) -> URL { copilotHome.appendingPathComponent("hooks/\(hooksFileName)") }

    static func install(
        fileURL: URL, bindings: [AgentHookJSONWriter.EventBinding], spacesExecutablePath: String, fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            let existing = try String(contentsOf: fileURL, encoding: .utf8)
            guard AgentHookCommand.isSpacesOwned(existing) else { throw UnmanagedHooksFileError(path: fileURL.path) }
        }
        var hooks: [String: Any] = [:]
        for binding in bindings {
            hooks[binding.eventName] = [
                [
                    "type": "command", "timeoutSec": timeoutSeconds,
                    "bash": AgentHookCommand.signalCommand(event: binding.event, spacesExecutablePath: spacesExecutablePath, agent: .copilot),
                ] as [String: Any]
            ]
        }
        var data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "hooks": hooks] as [String: Any], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try AgentHookConfigFile.write(data, to: fileURL, fileManager: fileManager)
    }

    /// How completely `fileURL` carries the hooks `bindings` describe: `.notInstalled` without a
    /// Spaces-owned file, `.outdated` when an event has no current entry or an entry names a `spaces`
    /// other than `spacesExecutablePath` (the same rule as `AgentHookJSONWriter.installState`).
    static func installState(fileURL: URL, bindings: [AgentHookJSONWriter.EventBinding], spacesExecutablePath: String?) -> AgentHookInstallState {
        guard let data = try? Data(contentsOf: fileURL), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else { return .notInstalled }
        let ownedCommandsPerBinding = bindings.map { binding in
            ((hooks[binding.eventName] as? [[String: Any]]) ?? []).compactMap { $0["bash"] as? String }.filter(AgentHookCommand.isSpacesOwned)
        }
        guard ownedCommandsPerBinding.contains(where: { !$0.isEmpty }) else { return .notInstalled }
        let commandIsCurrent: (String) -> Bool = { command in
            guard AgentHookCommand.isCurrent(command), let spacesExecutablePath else { return false }
            return AgentHookCommand.embeddedExecutablePath(in: command) == spacesExecutablePath
        }
        let everyEventBound = ownedCommandsPerBinding.allSatisfy { !$0.isEmpty }
        let everyCommandCurrent = ownedCommandsPerBinding.allSatisfy { $0.allSatisfy(commandIsCurrent) }
        return everyEventBound && everyCommandCurrent ? .current : .outdated
    }

    /// Whether the user switched every Copilot hook off with `disableAllHooks: true` in
    /// `~/.copilot/settings.json`, the file `copilot config disableAllHooks true` writes (verified
    /// against copilot 1.0.95). A repo-level settings file can set it too, but that applies to one
    /// repository, so it says nothing about whether this device's hooks run and is not read.
    static func hooksDisabled(settingsURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return root["disableAllHooks"] as? Bool == true
    }
}

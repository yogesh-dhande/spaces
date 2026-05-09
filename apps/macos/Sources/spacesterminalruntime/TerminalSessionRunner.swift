import Foundation
import spacesterminalcore
import spacesterminalghostty

public enum TerminalSessionRunner {
    public static func makeRuntime(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) throws -> any TerminalSessionBackendRuntime {
        switch launchConfiguration.backend {
        case .scriptPTY: return ScriptPTYTerminalSessionRuntime(launchConfiguration: launchConfiguration, paths: paths, now: now)
        case .ghosttyEmbedded: return GhosttyEmbeddedTerminalSessionRuntime(launchConfiguration: launchConfiguration, paths: paths)
        }
    }

    public static func run(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) throws -> Never {
        let runtime = try makeRuntime(launchConfiguration: launchConfiguration, paths: paths, now: now)
        try runtime.run()
    }
}

import Foundation

/// One `terminal_sessions` row paired with the `terminal_runtime_states` row stored under the same
/// `root_directory`, plus that root itself.
///
/// It carries the root rather than a `TerminalSessionPaths` because building the paths is the
/// expensive half — it resolves the profile, canonicalises its runtime root and materialises the
/// secure socket root — and liveness can be decided without it. Callers that keep a row build the
/// paths for that row only.
public struct KnownTerminalSessionRuntime: Sendable, Equatable {
    public let launchConfiguration: TerminalSessionLaunchConfiguration
    public let rootDirectory: String
    public let runtimeState: TerminalSessionRuntimeState

    public init(launchConfiguration: TerminalSessionLaunchConfiguration, rootDirectory: String, runtimeState: TerminalSessionRuntimeState) {
        self.launchConfiguration = launchConfiguration
        self.rootDirectory = rootDirectory
        self.runtimeState = runtimeState
    }

    public var sessionID: String { launchConfiguration.sessionID }
}

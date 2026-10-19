import Foundation

/// Runs the short commands the daemon's self-update service needs (`curl` for the feed, `systemd-run`,
/// `systemctl`) through the raw `posix_spawn` + `waitpid` helper. Foundation `Process` is deliberately
/// avoided: inside the Linux daemon its exit monitor can miss the child's exit and wedge the waiting
/// thread forever (see `DaemonHandoffPreflight`). Each run is bounded by its own deadline.
public enum DaemonSelfUpdateCommand {
    public struct Output: Sendable {
        public let status: Int32
        /// Standard output and standard error, interleaved.
        public let output: Data
    }

    /// Nil when the command could not be launched or outlived `timeoutSeconds` (it is then killed).
    public static func run(_ arguments: [String], timeoutSeconds: TimeInterval) -> Output? {
        // iOS also compiles this target but has no subprocesses, so it gets nil.
        #if os(macOS) || os(Linux)
            // `env` resolves `curl` and `systemd-run` through PATH instead of hardcoding their locations.
            guard
                let result = try? AgentHookSubprocess.run(
                    executablePath: "/usr/bin/env", arguments: arguments, environment: ProcessInfo.processInfo.environment,
                    timeoutSeconds: timeoutSeconds)
            else { return nil }
            return Output(status: result.terminationStatus, output: result.output)
        #else
            return nil
        #endif
    }
}

import Foundation

/// The shared background `codex app-server` that Codex 0.157 and later keeps per `CODEX_HOME`, observed
/// and stopped through Codex's own `app-server daemon` commands.
///
/// Sessions attached to that server cannot report to Spaces: their hooks and MCP calls run outside any
/// Spaces terminal and are ignored. The user is told when one is running and can stop it. Stopping ends the Codex sessions running on the server;
/// their conversations are kept and can be resumed.
enum AgentHookCodexSharedServer {
    /// `daemon version` answers from the running server's socket, so a healthy server replies at once.
    static let probeTimeoutSeconds: TimeInterval = 3
    /// `daemon stop` waits for the server to shut down.
    static let stopTimeoutSeconds: TimeInterval = 15

    struct StopError: LocalizedError, Equatable {
        let detail: String

        var errorDescription: String? {
            detail.isEmpty ? "Codex could not stop its shared server" : "Codex could not stop its shared server (\(detail))"
        }
    }

    /// Whether a shared server is running for `codexHome`. `daemon version` never starts one: it prints a
    /// JSON line with `"status":"running"` and exits 0 when it reaches the server, and exits 1 with
    /// `failed to connect to <socket>` when there is none. A Codex without the `daemon` command, or one
    /// that does not answer in time, reads as not running.
    static func isRunning(executablePath: String, codexHome: URL, timeoutSeconds: TimeInterval = probeTimeoutSeconds) -> Bool {
        #if os(macOS) || os(Linux)
            guard
                let result = try? AgentHookSubprocess.run(
                    executablePath: executablePath, arguments: ["app-server", "daemon", "version"],
                    environment: AgentHookCodexCLI.environment(executablePath: executablePath, codexHome: codexHome), timeoutSeconds: timeoutSeconds),
                result.terminationStatus == 0
            else { return false }
            return String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline).contains { line in
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                return object?["status"] as? String == "running"
            }
        #else
            return false
        #endif
    }

    /// Stops the shared server for `codexHome`. With nothing running, `daemon stop` reports
    /// `{"status":"notRunning"}` and exits 0, so stopping is idempotent.
    static func stop(executablePath: String, codexHome: URL, timeoutSeconds: TimeInterval = stopTimeoutSeconds) throws {
        #if os(macOS) || os(Linux)
            let result: AgentHookSubprocess.Result
            do {
                result = try AgentHookSubprocess.run(
                    executablePath: executablePath, arguments: ["app-server", "daemon", "stop"],
                    environment: AgentHookCodexCLI.environment(executablePath: executablePath, codexHome: codexHome), timeoutSeconds: timeoutSeconds)
            } catch AgentHookSubprocess.RunError.timedOut { throw StopError(detail: "it did not stop in time") } catch {
                throw StopError(detail: error.localizedDescription)
            }
            guard result.terminationStatus == 0 else {
                let output = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw StopError(detail: output.isEmpty ? "exit status \(result.terminationStatus)" : AgentHookCodexAppServer.summary(output))
            }
        #else
            throw StopError(detail: "unavailable on this platform")
        #endif
    }
}

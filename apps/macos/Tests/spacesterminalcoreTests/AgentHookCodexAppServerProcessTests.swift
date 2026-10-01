#if os(macOS) || os(Linux)
    import Foundation
    import Testing

    @testable import spacesterminalcore

    #if os(Linux)
        import Glibc
    #else
        import Darwin
    #endif

    /// Opt-in: set `SPACES_CODEX_APP_SERVER_TEST_EXECUTABLE` to a `codex` binary to also run the tests
    /// against a real Codex. They run in a scratch `HOME` and `CODEX_HOME`, so the fake's model of Codex is
    /// checked against the real one without touching anyone's own config.
    private let realCodexExecutable = ProcessInfo.processInfo.environment["SPACES_CODEX_APP_SERVER_TEST_EXECUTABLE"]

    /// The stdio transport to a real child process, driven by small shell stand-ins for `codex app-server`
    /// so no test depends on a Codex being installed. What these pin: a session runs over the child's
    /// stdio with `CODEX_HOME` set, and every way the child can fail to answer (it exits, it never
    /// answers, it cannot start) ends in a bounded wait, the child stopped, and the reason it gave.
    @Suite(.serialized) struct AgentHookCodexAppServerProcessTests {
        private func makeDirectory() throws -> URL {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-app-server-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @discardableResult private func makeServer(_ script: String, in directory: URL) throws -> String {
            let executable = directory.appendingPathComponent("codex")
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            return executable.path
        }

        private func session<Result>(
            _ executablePath: String, codexHome: URL, timeoutSeconds: TimeInterval = 5, _ body: (AgentHookCodexAppServer) throws -> Result
        ) throws -> Result {
            try AgentHookCodexAppServer.withSession(
                executablePath: executablePath, codexHome: codexHome, timeoutSeconds: timeoutSeconds, launcher: AgentHookCodexAppServer.launchProcess,
                body)
        }

        /// Answers `initialize` and `hooks/list` the way Codex does, with a notification of its own ahead
        /// of the first reply, and records how it was started.
        private static let answeringServer = #"""
            #!/bin/sh
            printf '%s|%s\n' "$*" "$CODEX_HOME" > "$CODEX_HOME/invocation"
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
              case "$line" in
                *'"method":"initialize"'*)
                  printf '{"method":"remoteControl/status/changed","params":{"status":"disabled"}}\n'
                  printf '{"id":%s,"result":{"userAgent":"stand-in"}}\n' "$id" ;;
                *'"method":"hooks/list"'*)
                  printf '{"id":%s,"result":{"data":[{"cwd":"/","hooks":[{"key":"/h/hooks.json:stop:0:0","eventName":"stop","handlerType":"command","command":"say done","sourcePath":"/h/hooks.json","source":"user","enabled":true,"isManaged":false,"currentHash":"sha256:1","trustStatus":"untrusted"}]}]}}\n' "$id" ;;
              esac
            done
            """#

        @Test func aSessionRunsOverTheServersStdioWithItsCodexHome() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let server = try makeServer(Self.answeringServer, in: directory)

            let hooks = try session(server, codexHome: directory) { try $0.listHooks() }

            #expect(
                hooks == [
                    AgentHookCodexListedHook(
                        key: "/h/hooks.json:stop:0:0", eventName: "stop", command: "say done", sourcePath: "/h/hooks.json", source: "user",
                        enabled: true, currentHash: "sha256:1", trustStatus: "untrusted")
                ])
            let invocation = try String(contentsOf: directory.appendingPathComponent("invocation"), encoding: .utf8)
            #expect(invocation == "app-server|\(directory.path)\n")
        }

        /// A Codex too old to know `app-server` exits at once and says why on stderr. The reason that
        /// reaches the user is that first line, with the exit status.
        @Test func aServerThatExitsReportsItsStatusAndFirstErrorLine() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let server = try makeServer(
                "#!/bin/sh\nprintf \"error: unrecognized subcommand 'app-server'\\n\\nUsage: codex [OPTIONS]\\n\" >&2\nexit 2\n", in: directory)

            #expect(throws: AgentHookCodexAppServer.Failure.exited(status: 2, detail: "error: unrecognized subcommand 'app-server'")) {
                try session(server, codexHome: directory) { try $0.listHooks() }
            }
        }

        /// A wedged server costs the caller the session's deadline and no more, and is stopped along with
        /// anything it started, so a status read never leaves a Codex behind.
        @Test func aServerThatNeverAnswersIsStoppedAtTheDeadline() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let childPIDFile = directory.appendingPathComponent("child.pid")
            let server = try makeServer("#!/bin/sh\nsleep 30 &\nprintf '%s\\n' \"$!\" > \"$CODEX_HOME/child.pid\"\nwait\n", in: directory)
            let startedAt = AgentHookSubprocess.monotonicNow()

            #expect(throws: AgentHookCodexAppServer.Failure.timedOut) {
                try session(server, codexHome: directory, timeoutSeconds: 0.5) { try $0.listHooks() }
            }

            #expect(AgentHookSubprocess.monotonicNow() - startedAt < 5_000_000_000)
            let childPID = try #require(pid_t(try String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            defer { _ = kill(childPID, SIGKILL) }
            let deadline = AgentHookSubprocess.monotonicDeadline(after: 3)
            while AgentHookProcessTree.processExists(childPID), AgentHookSubprocess.monotonicNow() < deadline { usleep(20_000) }
            #expect(!AgentHookProcessTree.processExists(childPID), "The server's own child is stopped with it")
        }

        @Test func aServerThatCannotStartSaysWhy() throws {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let error = #expect(throws: AgentHookCodexAppServer.Failure.self) {
                try session(directory.appendingPathComponent("missing-codex").path, codexHome: directory) { try $0.listHooks() }
            }
            guard case .launch(let detail) = error else {
                Issue.record("Expected a launch failure, got \(String(describing: error))")
                return
            }
            #expect(!detail.isEmpty)
        }

        /// Writing to a server that has already exited fails with its exit rather than raising `SIGPIPE`,
        /// which would take the whole daemon down with it.
        @Test func writingToAServerThatAlreadyExitedReportsTheExit() throws {
            let server = try AgentHookCodexAppServerProcess.launch(
                executablePath: "/bin/sh", arguments: ["-c", "echo bye; exit 3"], environment: ProcessInfo.processInfo.environment)
            defer { server.close() }
            let deadline = AgentHookSubprocess.monotonicDeadline(after: 5)

            #expect(try server.receiveLine(deadline: deadline) == Data("bye".utf8))
            #expect(throws: AgentHookCodexAppServer.Failure.exited(status: 3, detail: "")) { try server.receiveLine(deadline: deadline) }
            #expect(throws: AgentHookCodexAppServer.Failure.exited(status: 3, detail: "")) {
                try server.send(Data(String(repeating: "x", count: 1 << 20).utf8), deadline: deadline)
            }
        }

        // MARK: - Against a real Codex

        /// Runs `body` with a scratch home whose Codex has the `hooks` feature on, set as this process's
        /// `HOME` meanwhile, and a `spaces` path inside it.
        private func withRealCodexHome(_ body: (_ codex: String, _ codexHome: URL, _ spacesPath: String) throws -> Void) throws {
            let codex = try #require(realCodexExecutable)
            let home = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            let previousHome = getenv("HOME").map { String(cString: $0) }
            setenv("HOME", home.path, 1)
            defer { if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") } }
            try "[features]\nhooks = true\n".write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            try body(codex, codexHome, home.appendingPathComponent("bin/spaces").path)
        }

        private func realReading(_ codex: String, codexHome: URL, spacesPath: String) -> AgentHookCodexTrust.Reading {
            AgentHookCodexTrust.status(
                codexExecutablePath: codex, codexHome: codexHome, spacesExecutablePath: spacesPath, launcher: AgentHookCodexAppServer.launchProcess)
        }

        @Test(.enabled(if: realCodexExecutable != nil)) func aRealCodexTrustsExactlyTheSpacesEntries() throws {
            try withRealCodexHome { codex, codexHome, spacesPath in
                try JSONSerialization.data(withJSONObject: [
                    "hooks": ["PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": "echo other-tool"]]]]]
                ]).write(to: codexHome.appendingPathComponent("hooks.json"))
                try AgentHookJSONWriter.install(
                    fileURL: codexHome.appendingPathComponent("hooks.json"), bindings: CodingAgent.codex.jsonEventBindings,
                    spacesExecutablePath: spacesPath)

                #expect(realReading(codex, codexHome: codexHome, spacesPath: spacesPath).installState == .awaitingTrust)
                #expect(
                    realReading(codex, codexHome: codexHome, spacesPath: spacesPath).untrustedEntries.count
                        == CodingAgent.codex.jsonEventBindings.count)

                try AgentHookCodexTrust.trust(
                    codexExecutablePath: codex, codexHome: codexHome, spacesExecutablePath: spacesPath,
                    launcher: AgentHookCodexAppServer.launchProcess)

                #expect(realReading(codex, codexHome: codexHome, spacesPath: spacesPath) == .init(installState: .current, untrustedEntries: []))
                let listed = try session(codex, codexHome: codexHome) { try $0.listHooks() }
                #expect(listed.first { $0.command == "echo other-tool" }?.isTrusted == false, "Another tool's hook stays untrusted")
                #expect(listed.filter { $0.isTrusted }.count == CodingAgent.codex.jsonEventBindings.count)
            }
        }

        /// What a Spaces update does to hooks Codex already knows: the rewrite changes every command, Codex
        /// reads each one as untrusted because its recorded hash no longer matches, and a hook the user
        /// switched off in Codex stays off, since the switch-off lives in the record the update leaves alone.
        @Test(.enabled(if: realCodexExecutable != nil)) func aRealCodexKeepsASwitchedOffHookOffAcrossAHookUpdate() throws {
            try withRealCodexHome { codex, codexHome, spacesPath in
                let hooksFileURL = codexHome.appendingPathComponent("hooks.json")
                let configURL = codexHome.appendingPathComponent("config.toml")
                func spacesListed() throws -> [AgentHookCodexListedHook] {
                    try session(codex, codexHome: codexHome) { try $0.listHooks() }.filter { AgentHookCommand.isSpacesOwned($0.command ?? "") }
                }

                // A previous release's hooks, trusted in Codex, with the Stop hook then switched off the way
                // Codex records a switch-off.
                try AgentHookJSONWriter.install(
                    fileURL: hooksFileURL, bindings: CodingAgent.codex.jsonEventBindings, spacesExecutablePath: spacesPath)
                try String(contentsOf: hooksFileURL, encoding: .utf8).replacingOccurrences(
                    of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(AgentHookCommand.hookVersion - 1)
                ).write(to: hooksFileURL, atomically: true, encoding: .utf8)
                try session(codex, codexHome: codexHome) { session in
                    try session.recordTrust(try session.listHooks().filter { AgentHookCommand.isSpacesOwned($0.command ?? "") })
                }
                #expect(try spacesListed().allSatisfy { $0.isTrusted })
                let stopKey = try #require(try spacesListed().first { $0.eventName == "stop" }?.key)
                let stopTable = "[hooks.state.\"\(stopKey)\"]\n"
                let trustedConfig = try String(contentsOf: configURL, encoding: .utf8)
                try #require(trustedConfig.contains(stopTable))
                try trustedConfig.replacingOccurrences(of: stopTable, with: stopTable + "enabled = false\n").write(
                    to: configURL, atomically: true, encoding: .utf8)

                // This release's rewrite.
                try AgentHookJSONWriter.install(
                    fileURL: hooksFileURL, bindings: CodingAgent.codex.jsonEventBindings, spacesExecutablePath: spacesPath)

                let updated = try spacesListed()
                #expect(updated.count == CodingAgent.codex.jsonEventBindings.count)
                #expect(updated.allSatisfy { AgentHookCommand.isCurrent($0.command ?? "") })
                #expect(updated.allSatisfy { !$0.isTrusted }, "Codex reads every rewritten hook as untrusted")
                #expect(updated.first { $0.key == stopKey }?.enabled == false, "The switch-off outlasts the update")
                #expect(updated.filter { $0.key != stopKey }.allSatisfy { $0.enabled })
                #expect(
                    realReading(codex, codexHome: codexHome, spacesPath: spacesPath) == .init(installState: .disabledByAgent, untrustedEntries: []))

                // Switched back on in Codex, the rewritten hooks wait for a trust, and trusting them is all
                // it takes.
                try String(contentsOf: configURL, encoding: .utf8).replacingOccurrences(of: "enabled = false\n", with: "").write(
                    to: configURL, atomically: true, encoding: .utf8)
                let awaiting = realReading(codex, codexHome: codexHome, spacesPath: spacesPath)
                #expect(awaiting.installState == .awaitingTrust)
                #expect(awaiting.untrustedEntries.count == CodingAgent.codex.jsonEventBindings.count)
                try AgentHookCodexTrust.trust(
                    codexExecutablePath: codex, codexHome: codexHome, spacesExecutablePath: spacesPath,
                    launcher: AgentHookCodexAppServer.launchProcess)
                #expect(realReading(codex, codexHome: codexHome, spacesPath: spacesPath).installState == .current)
            }
        }
    }
#endif

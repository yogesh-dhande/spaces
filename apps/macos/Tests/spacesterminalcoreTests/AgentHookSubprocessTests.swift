#if os(macOS) || os(Linux)
    import Dispatch
    import Foundation
    import Testing

    @testable import spacesterminalcore

    #if os(Linux)
        import Glibc
    #else
        import Darwin
    #endif

    @Suite(.serialized) struct AgentHookSubprocessTests {
        @Test func drainsOutputLargerThanThePipeBeforeReaping() throws {
            let result = try AgentHookSubprocess.run(
                executablePath: "/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=65536 count=2 2>/dev/null; printf finished"],
                environment: ProcessInfo.processInfo.environment, timeoutSeconds: 2)

            #expect(result.terminationStatus == 0)
            #expect(result.output.count == 131_080)
            #expect(result.output.suffix(8) == Data("finished".utf8))
        }

        @Test func continuousOutputCannotOutrunTheTimeout() {
            let startedAt = DispatchTime.now().uptimeNanoseconds

            #expect(throws: AgentHookSubprocess.RunError.timedOut) {
                try AgentHookSubprocess.run(
                    executablePath: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do printf 0123456789abcdef; done"],
                    environment: ProcessInfo.processInfo.environment, timeoutSeconds: 0.2)
            }

            let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
            #expect(elapsedSeconds < 4)
        }

        @Test func successfulCommandDoesNotWaitForAHelperThatInheritedOutput() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "agent-hook-subprocess-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let childPIDFile = directory.appendingPathComponent("child.pid")
            var environment = ProcessInfo.processInfo.environment
            environment["CHILD_PID_FILE"] = childPIDFile.path

            let result = try AgentHookSubprocess.run(
                executablePath: "/bin/sh",
                arguments: ["-c", #"sleep 30 & printf '%s\n' "$!" > "$CHILD_PID_FILE""#],
                environment: environment, timeoutSeconds: 2)

            let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let childPID = try #require(pid_t(childPIDText))
            defer { _ = kill(childPID, SIGKILL) }
            #expect(result.terminationStatus == 0)
        }

        @Test func childDoesNotInheritUnrelatedFileDescriptors() throws {
            var sentinelPipe: [Int32] = [-1, -1]
            #expect(pipe(&sentinelPipe) == 0)
            defer {
                close(sentinelPipe[0])
                close(sentinelPipe[1])
            }
            var environment = ProcessInfo.processInfo.environment
            environment["SENTINEL_FD"] = String(sentinelPipe[0])

            let result = try AgentHookSubprocess.run(
                executablePath: "/bin/sh", arguments: ["-c", #"[ ! -e "/dev/fd/$SENTINEL_FD" ]"#], environment: environment,
                timeoutSeconds: 2)

            #expect(result.terminationStatus == 0)
        }

        @Test func childResetsIgnoredSignalsAndTheCallingThreadsSignalMask() throws {
            let originalHandler = signal(SIGUSR1, SIG_IGN)
            defer { _ = signal(SIGUSR1, originalHandler) }

            let ignoredSignalResult = try AgentHookSubprocess.run(
                executablePath: "/bin/sh", arguments: ["-c", "kill -USR1 $$; exit 42"],
                environment: ProcessInfo.processInfo.environment, timeoutSeconds: 2)

            var blockedSignal = sigset_t()
            sigemptyset(&blockedSignal)
            sigaddset(&blockedSignal, SIGUSR2)
            var originalMask = sigset_t()
            #expect(pthread_sigmask(SIG_BLOCK, &blockedSignal, &originalMask) == 0)
            defer { _ = pthread_sigmask(SIG_SETMASK, &originalMask, nil) }
            let blockedSignalResult = try AgentHookSubprocess.run(
                executablePath: "/bin/sh", arguments: ["-c", "kill -USR2 $$; exit 43"],
                environment: ProcessInfo.processInfo.environment, timeoutSeconds: 2)

            #expect(ignoredSignalResult.terminationStatus == 128 + SIGUSR1)
            #expect(blockedSignalResult.terminationStatus == 128 + SIGUSR2)
        }

        @Test func timeoutKillsAWrapperAndItsChild() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "agent-hook-subprocess-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let childPIDFile = directory.appendingPathComponent("child.pid")
            var environment = ProcessInfo.processInfo.environment
            environment["CHILD_PID_FILE"] = childPIDFile.path

            #expect(throws: AgentHookSubprocess.RunError.timedOut) {
                try AgentHookSubprocess.run(
                    executablePath: "/bin/sh",
                    arguments: [
                        "-c",
                        #"sh -c 'trap "" TERM; exec >/dev/null 2>&1; sleep 30' & child=$!; printf '%s\n' "$child" > "$CHILD_PID_FILE"; wait "$child""#,
                    ], environment: environment, timeoutSeconds: 2)
            }

            let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let childPID = try #require(pid_t(childPIDText))
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while processExists(childPID), DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
            #expect(!processExists(childPID))
        }

        private func processExists(_ processID: pid_t) -> Bool {
            errno = 0
            return kill(processID, 0) == 0 || errno != ESRCH
        }
    }
#endif

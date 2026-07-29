#if os(Linux)
    import Foundation
    import Glibc
    import spacesterminalcore

    /// Failure-time evidence for the Linux headless PTY suites (issue #371). In the x86_64 artifact lane a
    /// wait occasionally expires with the PTY child still alive but not one byte in the transcript, while
    /// the same suites finish in well under a second everywhere else. A bare `#expect` failure reports only
    /// that the marker never arrived, so every poller in these suites prints this block just before it
    /// fails: what the child processes are doing, what the machine is doing, what the transcript holds, and
    /// whether the terminal engine actor is still answering.
    ///
    /// Nothing here runs on the success path — a poller calls `report` only after its deadline expires.
    enum GhosttyLinuxHeadlessHangDiagnostics {
        /// The engine probe gets its own short deadline so a stalled engine actor is reported as such
        /// rather than hanging the diagnostics that exist to describe the stall.
        private static let engineProbeTimeout: TimeInterval = 2

        /// Renders the whole block as one string and prints it in a single write, so parallel writers in the
        /// suite's log cannot interleave lines of it.
        static func report(wait description: String, elapsed: TimeInterval, timeout: TimeInterval, transcriptPath: String?) async {
            var lines: [String] = ["===== spaces linux headless hang diagnostics (issue #371) ====="]
            lines.append("time: \(ISO8601DateFormatter().string(from: Date()))  test pid: \(getpid())")
            lines.append("wait: \(description)")
            lines.append(String(format: "elapsed: %.3fs  timeout: %.3fs", elapsed, timeout))
            lines.append(contentsOf: childProcessLines())
            lines.append(contentsOf: systemLines())
            lines.append(contentsOf: transcriptLines(path: transcriptPath))
            lines.append("engine: \(await engineProbeLine())")
            lines.append("===== end diagnostics =====")
            print(lines.joined(separator: "\n"))
            // `nil` flushes every open stream: Swift 6 rejects naming `stdout`, a shared mutable global.
            fflush(nil)
        }

        // MARK: - Child processes

        /// Walks `/proc` for entries whose parent is this process. The PTY child is forked by the session
        /// core, so it is always a direct child of the test runner; a child that exists but has burned no
        /// CPU and parks in an uninformative `wchan` is the shape the issue describes.
        private static func childProcessLines() -> [String] {
            let selfPID = getpid()
            let ticksPerSecond = Double(sysconf(Int32(_SC_CLK_TCK)))
            var lines = ["direct children of \(selfPID):"]
            let entries = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { Int32($0) }.sorted()
            var found = false
            for pid in entries {
                guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let commClose = stat.lastIndex(of: ")"),
                    let commOpen = stat.firstIndex(of: "(")
                else { continue }
                let fields = stat[stat.index(after: commClose)...].split(separator: " ").map(String.init)
                guard fields.count > 12, fields[1] == String(selfPID) else { continue }
                found = true
                let comm = String(stat[stat.index(after: commOpen)..<commClose])
                let utime = (Double(fields[11]) ?? 0) / ticksPerSecond
                let stime = (Double(fields[12]) ?? 0) / ticksPerSecond
                lines.append("  pid \(pid) comm=\(comm) stat-state=\(fields[0])")
                lines.append(String(format: "    utime=%.3fs stime=%.3fs", utime, stime))
                lines.append("    status: \(statusSummary(pid: pid))")
                lines.append("    wchan: \(readTrimmed("/proc/\(pid)/wchan") ?? "(unavailable)")")
                lines.append("    cmdline: \(cmdline(pid: pid))")
            }
            if !found { lines.append("  (none)") }
            return lines
        }

        private static func statusSummary(pid: Int32) -> String {
            guard let status = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8) else { return "(unavailable)" }
            let wanted = ["State:", "Threads:"]
            let matched = status.split(separator: "\n").filter { line in wanted.contains { line.hasPrefix($0) } }.map {
                $0.replacingOccurrences(of: "\t", with: " ")
            }
            return matched.isEmpty ? "(no State/Threads lines)" : matched.joined(separator: "  ")
        }

        private static func cmdline(pid: Int32) -> String {
            guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !data.isEmpty else { return "(empty)" }
            return String(decoding: data, as: UTF8.self).split(separator: "\0").joined(separator: " ")
        }

        // MARK: - System state

        private static func systemLines() -> [String] {
            var lines = ["system:"]
            lines.append("  nproc: \(sysconf(Int32(_SC_NPROCESSORS_ONLN)))")
            lines.append("  loadavg: \(readTrimmed("/proc/loadavg") ?? "(unavailable)")")
            // The pressure-stall files exist only when the kernel is built with PSI and the container
            // exposes /proc/pressure; when they are there they say directly whether tasks are stalled
            // waiting for CPU or IO.
            for resource in ["cpu", "io"] {
                if let pressure = readTrimmed("/proc/pressure/\(resource)") {
                    lines.append("  pressure/\(resource): \(pressure.split(separator: "\n").joined(separator: " | "))")
                }
            }
            return lines
        }

        // MARK: - Transcript

        private static let transcriptTailByteCount = 256

        private static func transcriptLines(path: String?) -> [String] {
            guard let path else { return ["transcript: (not provided by this wait)"] }
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return ["transcript: \(path) (unreadable)"] }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > UInt64(transcriptTailByteCount) ? size - UInt64(transcriptTailByteCount) : 0
            try? handle.seek(toOffset: offset)
            let tail = (try? handle.read(upToCount: transcriptTailByteCount)) ?? Data()
            return ["transcript: \(path)", "  bytes: \(size)", "  last \(tail.count) bytes: \(escaped(tail))"]
        }

        /// Renders raw PTY bytes so control characters and the escape sequences the suites assert on stay
        /// legible in a CI log.
        private static func escaped(_ data: Data) -> String {
            var rendered = ""
            for byte in data {
                if byte >= 0x20, byte < 0x7F { rendered.append(Character(UnicodeScalar(byte))) } else { rendered += String(format: "\\x%02X", byte) }
            }
            return rendered
        }

        // MARK: - Engine responsiveness

        /// Distinguishes "the engine actor stopped answering" from "the child never wrote anything": the
        /// hop is enqueued from a detached task and awaited with its own timeout, so a wedged engine turns
        /// into a reported line rather than a second hang.
        private static func engineProbeLine() async -> String {
            let outcome = ProbeOutcome()
            let started = Date()
            Task.detached {
                await TerminalEngineActor.run {}
                outcome.complete(Date().timeIntervalSince(started))
            }
            let deadline = Date().addingTimeInterval(engineProbeTimeout)
            while Date() < deadline {
                if let seconds = outcome.seconds { return String(format: "TerminalEngineActor hop answered in %.3fs", seconds) }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return String(format: "TerminalEngineActor hop did not answer within %.1fs", engineProbeTimeout)
        }

        private final class ProbeOutcome: @unchecked Sendable {
            private let lock = NSLock()
            private var value: TimeInterval?

            func complete(_ seconds: TimeInterval) {
                lock.lock()
                defer { lock.unlock() }
                value = seconds
            }

            var seconds: TimeInterval? {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        // MARK: - Shared

        private static func readTrimmed(_ path: String) -> String? {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
#endif

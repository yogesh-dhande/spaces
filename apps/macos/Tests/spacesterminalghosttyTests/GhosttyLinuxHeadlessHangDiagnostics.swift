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
    ///
    /// Known boundary, accepted: a wait whose condition itself hops onto a wedged engine actor blocks
    /// inside the condition and never reaches its deadline, so this report does not print in that one
    /// scenario. Restructuring every suite's poller into an independent watchdog is not worth it for a
    /// stall that has never been observed here — from outside, the suite invocation stops producing
    /// output, the lane's per-suite duration stamps and failure-time process dump still describe it,
    /// and the loop workflow bounds each iteration so a wedged invocation is recorded rather than
    /// hanging the loop.
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
                lines.append(contentsOf: syscallLines(pid: pid))
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

        // MARK: - Where the child is blocked

        /// The child's userspace program counter, resolved to a mapped file. `wchan` names the kernel
        /// function a task is parked in (`futex_do_wait` for every lock wait alike); the pc names the
        /// *library* whose lock it is, which is what separates a glibc allocator/loader lock from a Swift
        /// runtime or libdispatch one in the fork-without-exec shape this issue keeps hitting.
        ///
        /// `/proc/<pid>/syscall` is a ptrace-mode read, and Yama's default `ptrace_scope=1` grants it to
        /// the target's parent — which the test process is for every child it reports — so no capability
        /// or ptrace attach is needed.
        ///
        /// The pc lands mid-function, so the printed `path+0x<offset>` is deliberately relative to the
        /// mapping start with the mapping's own file offset folded in: that is the file-relative virtual
        /// address to hand to `addr2line -e <path>` / `nm` against the same build, offline.
        private static func syscallLines(pid: Int32) -> [String] {
            guard let contents = readProcFile("/proc/\(pid)/syscall") else {
                return ["    syscall: (unreadable: \(String(cString: strerror(errno))))"]
            }
            let raw = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = ["    syscall: \(raw)"]
            // Blocked in a syscall the kernel prints as "<nr> <arg1..arg6> <sp> <pc>". A task that is on
            // a CPU prints "running", and one whose registers are unavailable prints a three-field
            // "-1 <sp> <pc>" form; neither carries the arguments, so those stop at the raw line.
            let fields = raw.split(separator: " ").map(String.init)
            guard fields.count == 9, let pc = hexValue(fields[8]), let argument = hexValue(fields[1]) else {
                return lines + ["    syscall-resolved: (no argument frame: \(fields.count == 1 ? raw : "\(fields.count)-field form"))"]
            }
            let mappings = memoryMappings(pid: pid)
            // arg0 is the futex word address when the child is in a futex wait (the shape issue #371
            // captures), which tells apart a lock inside a mapped library from one on the heap or stack.
            var resolved =
                lines + [
                    "    syscall-resolved: nr=\(fields[0]) pc=\(describe(address: pc, in: mappings))"
                        + "  arg0=\(describe(address: argument, in: mappings))"
                ]
            // A pc outside every mapping is either genuine (a JIT/translation region the kernel reports
            // as anonymous) or the signature of a maps read that stopped early, which would silently
            // drop exactly the high-address library mappings a lock is most likely to sit in. Printing
            // the table's size and ceiling makes the difference between the two readable in the log.
            if mapping(containing: pc, in: mappings) == nil {
                let highest = mappings.map(\.end).max().map { "0x" + String($0, radix: 16) } ?? "(none)"
                resolved.append("    maps: \(mappings.count) mappings parsed, highest end \(highest)")
            }
            return resolved
        }

        /// One `/proc/<pid>/maps` row, reduced to what address resolution needs.
        private struct MemoryMapping {
            let start: UInt64
            let end: UInt64
            let fileOffset: UInt64
            let name: String
        }

        private static func memoryMappings(pid: Int32) -> [MemoryMapping] {
            guard let contents = readProcFile("/proc/\(pid)/maps") else { return [] }
            return contents.split(separator: "\n").compactMap { line in
                // "<start>-<end> <perms> <file offset> <dev> <inode> <pathname>", the pathname column
                // blank-padded and absent for anonymous mappings.
                let fields = line.split(separator: " ").map(String.init)
                guard fields.count >= 5 else { return nil }
                let bounds = fields[0].split(separator: "-").map(String.init)
                guard bounds.count == 2, let start = UInt64(bounds[0], radix: 16), let end = UInt64(bounds[1], radix: 16),
                    let fileOffset = UInt64(fields[2], radix: 16)
                else { return nil }
                return MemoryMapping(
                    start: start, end: end, fileOffset: fileOffset, name: fields.count > 5 ? fields[5...].joined(separator: " ") : "[anon]")
            }
        }

        private static func describe(address: UInt64, in mappings: [MemoryMapping]) -> String {
            let raw = "0x" + String(address, radix: 16)
            guard let mapping = mapping(containing: address, in: mappings) else {
                return mappings.isEmpty ? "\(raw) -> (maps unavailable)" : "\(raw) -> (unmapped)"
            }
            let offset = address - mapping.start
            return "\(raw) -> \(mapping.name)+0x\(String(offset, radix: 16)) (file off 0x\(String(mapping.fileOffset + offset, radix: 16)))"
        }

        private static func mapping(containing address: UInt64, in mappings: [MemoryMapping]) -> MemoryMapping? {
            mappings.first { address >= $0.start && address < $0.end }
        }

        private static func hexValue(_ field: String) -> UInt64? { UInt64(field.hasPrefix("0x") ? String(field.dropFirst(2)) : field, radix: 16) }

        /// Reads a `/proc` file to EOF with an explicit read loop. These files are generated per read
        /// rather than stored, and a single read returns only what the kernel produced for that call, so
        /// a one-shot convenience read of a large one truncates. `maps` is where that bites: a forked
        /// child inherits the test runner's whole address space (hundreds of mappings), and a short read
        /// drops the tail — the high-address library mappings that a blocked pc is most likely to land
        /// in — leaving the resolution silently reporting "unmapped" rather than naming the library.
        private static func readProcFile(_ path: String) -> String? {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var contents = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    contents.append(contentsOf: buffer[0..<count])
                } else if count == 0 {
                    return String(decoding: contents, as: UTF8.self)
                } else if errno != EINTR {
                    return nil
                }
            }
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

import Foundation

enum ResourceUsage {
    /// User plus system CPU time of every thread of this process, in seconds.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        #if os(Linux)
            getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
        #else
            getrusage(RUSAGE_SELF, &usage)
        #endif
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// The process's peak physical footprint (memory it owns, excluding shared library pages and freed pages
    /// the allocator has not returned), in bytes. macOS only; 0 elsewhere, where resident memory is the measure.
    static func peakFootprintBytes() -> Int64 {
        #if os(Linux)
            return 0
        #else
            var info = rusage_info_current()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
            }
            return status == 0 ? Int64(info.ri_lifetime_max_phys_footprint) : 0
        #endif
    }

    /// The process's peak resident memory so far, in bytes. A high-water mark that never decreases.
    static func peakMemoryBytes() -> Int64 {
        #if os(Linux)
            // VmHWM is the kernel's peak resident set, in kB.
            guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return 0 }
            for line in status.split(separator: "\n") where line.hasPrefix("VmHWM:") {
                let digits = line.split(whereSeparator: { !$0.isNumber })
                return Int64(digits.first ?? "0").map { $0 * 1024 } ?? 0
            }
            return 0
        #else
            // macOS reports ru_maxrss in bytes.
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Int64(usage.ru_maxrss)
        #endif
    }

    static func wallSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    /// Wall and CPU time of `body`.
    static func measure<T>(_ body: () async throws -> T) async rethrows -> (value: T, wall: Double, cpu: Double) {
        let wallStart = wallSeconds()
        let cpuStart = cpuSeconds()
        let value = try await body()
        return (value, wallSeconds() - wallStart, cpuSeconds() - cpuStart)
    }
}

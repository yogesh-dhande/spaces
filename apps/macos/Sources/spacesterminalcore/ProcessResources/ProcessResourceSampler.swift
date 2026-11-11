import Foundation

#if os(Linux)
    import Glibc
#elseif os(macOS)
    import Darwin
#endif

/// CPU and memory of one caller-defined group of processes over a sampling interval.
public struct ProcessGroupUsage: Sendable, Equatable {
    /// Share of one core, so a group keeping four cores busy reads 400.
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    /// Processes of the group that could be read at the sample.
    public let processCount: Int

    public init(cpuPercent: Double, memoryBytes: UInt64, processCount: Int) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.processCount = processCount
    }
}

/// Turns cumulative per-process CPU time into per-interval CPU percentages for named process groups.
///
/// The sampler owns the only state a rate needs (each pid's CPU time at the previous sample), so a caller
/// keeps one sampler alive for as long as it wants continuous rates and drops it to stop measuring.
public struct ProcessResourceSampler {
    private let reader: (pid_t) -> ProcessResourceReading?
    private var previousCPUTimes: [pid_t: UInt64] = [:]
    private var previousUptimeNanoseconds: UInt64?

    public init() { self.init(reader: ProcessResourceReader.read(processID:)) }

    /// Internal so tests can feed deterministic readings; production always reads the real processes.
    init(reader: @escaping (pid_t) -> ProcessResourceReading?) { self.reader = reader }

    /// Usage per group over the interval since the previous call, or nil on the first call, which only
    /// records the baseline. `uptimeNanoseconds` is a monotonic clock reading taken by the caller at the
    /// sample.
    ///
    /// A pid first seen after the baseline counts its whole CPU time: it started inside the interval, so
    /// everything it has used belongs to it. A pid that is gone, or unreadable, contributes nothing and its
    /// state is dropped.
    public mutating func sample(groups: [String: [pid_t]], uptimeNanoseconds: UInt64) -> [String: ProcessGroupUsage]? {
        var readings: [pid_t: ProcessResourceReading] = [:]
        for pid in Set(groups.values.joined()) {
            if let reading = reader(pid) { readings[pid] = reading }
        }
        let previousCPUTimes = previousCPUTimes
        let previousUptime = previousUptimeNanoseconds
        self.previousCPUTimes = readings.mapValues(\.cpuTimeNanoseconds)
        self.previousUptimeNanoseconds = uptimeNanoseconds
        guard let previousUptime, uptimeNanoseconds > previousUptime else { return nil }

        let intervalNanoseconds = Double(uptimeNanoseconds - previousUptime)
        var result: [String: ProcessGroupUsage] = [:]
        for (name, pids) in groups {
            var cpuNanoseconds: UInt64 = 0
            var memoryBytes: UInt64 = 0
            var processCount = 0
            for pid in Set(pids) {
                guard let reading = readings[pid] else { continue }
                processCount += 1
                memoryBytes += reading.memoryBytes
                let previous = previousCPUTimes[pid] ?? 0
                // A cumulative time that went backwards is a recycled pid: the new process's whole time is
                // its own.
                cpuNanoseconds += reading.cpuTimeNanoseconds >= previous ? reading.cpuTimeNanoseconds - previous : reading.cpuTimeNanoseconds
            }
            result[name] = ProcessGroupUsage(
                cpuPercent: Double(cpuNanoseconds) / intervalNanoseconds * 100, memoryBytes: memoryBytes, processCount: processCount)
        }
        return result
    }
}

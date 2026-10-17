import Foundation

#if os(Linux)
    import Glibc
#elseif os(macOS)
    import Darwin
#endif

/// One process's cumulative CPU time and current memory.
public struct ProcessResourceReading: Sendable, Equatable {
    /// User plus system CPU time since the process started, in nanoseconds.
    public let cpuTimeNanoseconds: UInt64
    /// Physical footprint on macOS (the figure Activity Monitor shows, which counts compressed and
    /// swapped-out dirty pages that a resident-set number would miss); resident set on Linux, which has no
    /// footprint equivalent.
    public let memoryBytes: UInt64

    public init(cpuTimeNanoseconds: UInt64, memoryBytes: UInt64) {
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.memoryBytes = memoryBytes
    }
}

public enum ProcessResourceReader {
    /// The process's reading, or nil when it is gone or its accounting is not readable by this user.
    public static func read(processID: pid_t) -> ProcessResourceReading? {
        #if os(macOS)
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(processID, RUSAGE_INFO_V2, $0) }
            }
            guard status == 0 else { return nil }
            // ri_user_time/ri_system_time are Mach absolute time units, which are not nanoseconds on
            // Apple Silicon (numer/denom is not 1/1).
            let machTicks = info.ri_user_time &+ info.ri_system_time
            return ProcessResourceReading(
                cpuTimeNanoseconds: machTicks &* UInt64(timebase.numer) / UInt64(timebase.denom), memoryBytes: info.ri_phys_footprint)
        #else
            guard let stat = try? String(contentsOfFile: "/proc/\(processID)/stat", encoding: .utf8),
                let statm = try? String(contentsOfFile: "/proc/\(processID)/statm", encoding: .utf8)
            else { return nil }
            // The comm field may contain spaces and parentheses, so fields are counted from the last ')'.
            guard let commEnd = stat.lastIndex(of: ")") else { return nil }
            let fields = stat[stat.index(after: commEnd)...].split(separator: " ")
            // Fields after comm start at `state` (stat field 3); utime and stime are stat fields 14 and 15.
            guard fields.count > 12, let userTicks = UInt64(fields[11]), let systemTicks = UInt64(fields[12]) else { return nil }
            let memoryFields = statm.split(separator: " ")
            guard memoryFields.count > 1, let residentPages = UInt64(memoryFields[1]) else { return nil }
            return ProcessResourceReading(
                cpuTimeNanoseconds: (userTicks + systemTicks) * 1_000_000_000 / UInt64(clockTicksPerSecond),
                memoryBytes: residentPages * UInt64(pageSize))
        #endif
    }

    #if os(macOS)
        private static let timebase: mach_timebase_info_data_t = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return info
        }()
    #else
        private static let clockTicksPerSecond = max(1, sysconf(Int32(_SC_CLK_TCK)))
        private static let pageSize = max(1, sysconf(Int32(_SC_PAGESIZE)))
    #endif
}

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// When the machine running this process last booted, read from the kernel.
public enum HostBootTime {
    /// Nil when the kernel does not report it.
    public static func current() -> Date? {
        #if os(macOS)
            var bootTime = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
        #else
            guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else { return nil }
            return bootTime(procStat: stat)
        #endif
    }

    /// The `btime` line of `/proc/stat`, seconds since the epoch.
    static func bootTime(procStat: String) -> Date? {
        for line in procStat.split(separator: "\n") where line.hasPrefix("btime ") {
            guard let seconds = TimeInterval(line.dropFirst("btime ".count).trimmingCharacters(in: .whitespaces)), seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

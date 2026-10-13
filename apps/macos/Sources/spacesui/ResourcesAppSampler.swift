import Darwin
import Foundation
import spacesdevicecore
import spacesterminalcore

/// Measures the Spaces app on this Mac: the app process, its descendants (except a `spacesd` it
/// launched, with everything beneath it), and the WebKit services that
/// act for it (the editor pane's web content, GPU, and networking processes).
///
/// WebKit's services are launchd-owned rather than children of the app, so they are found the way the
/// kernel groups them: macOS puts an app and the XPC services working for it in one process coalition.
/// Matching on the coalition id, with the service's path as a cheap pre-filter, finds exactly this app's
/// services and never another WebKit client's, such as a browser.
///
/// Finding them means reading the path of every process on the machine, which is too heavy for every
/// 2 s sample. Services appear only when the editor pane opens and leave when it closes, so the scan
/// reruns every `scanInterval` samples and the pids it found are reused in between. A cached pid that
/// has since exited reads as unreadable and contributes nothing.
struct ResourcesAppSampler {
    static let scanInterval = 5

    private var sampler = ProcessResourceSampler()
    private var webKitProcessIDs: [pid_t] = []
    /// WebKit services that have been through one sample, so the sampler holds their CPU time baseline.
    private var baselinedWebKitProcessIDs: Set<pid_t> = []
    private var samplesSinceScan = Self.scanInterval

    /// Usage since the previous call, or nil on the first call, which only records the baseline.
    mutating func sample(uptimeNanoseconds: UInt64) -> SpacesDeviceResourceUsage? {
        if samplesSinceScan >= Self.scanInterval {
            webKitProcessIDs = Self.webKitProcessIDs(inCoalitionOf: getpid())
            samplesSinceScan = 0
        }
        samplesSinceScan += 1
        let appProcessIDs = ProcessTree.processIDs(rootProcessID: getpid(), excludingSubtreesWhere: Self.isDaemon)
        // A service is found up to `scanInterval` samples after it started, and possibly long after: the
        // sampler would charge a never-seen pid's whole lifetime CPU to this one interval. A newly found
        // service is therefore sampled once in a group whose figure is discarded, which records its
        // baseline, and joins the app's figure from the next sample on.
        let counted = webKitProcessIDs.filter { baselinedWebKitProcessIDs.contains($0) }
        let newlyFound = webKitProcessIDs.filter { !baselinedWebKitProcessIDs.contains($0) }
        baselinedWebKitProcessIDs = Set(webKitProcessIDs)
        let groups = ["app": appProcessIDs + counted, "baseline": newlyFound]
        guard let usage = sampler.sample(groups: groups, uptimeNanoseconds: uptimeNanoseconds)?["app"] else { return nil }
        return SpacesDeviceResourceUsage(cpuPercent: usage.cpuPercent, memoryBytes: usage.memoryBytes)
    }

    /// Mirrors `struct proc_pidcoalitioninfo` (`PROC_PIDCOALITIONINFO`): the process's resource and jetsam
    /// coalition ids, then reserved space.
    private struct CoalitionInfo {
        var coalitionIDs: (UInt64, UInt64) = (0, 0)
        var reserved: (UInt64, UInt64, UInt64) = (0, 0, 0)
    }

    /// A daemon the app launched directly (development profiles, or an installed one whose LaunchAgent
    /// start failed) is its child, but it and the terminals beneath it are measured by their own
    /// streams. Identified by executable name; every launch path runs a binary called `spacesd`.
    private static func isDaemon(_ processID: pid_t) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: pathBufferSize)
        guard proc_pidpath(processID, &pathBuffer, UInt32(pathBufferSize)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: pathBuffer)).lastPathComponent == "spacesd"
    }

    private static let coalitionInfoFlavor: Int32 = 20
    private static let pathBufferSize = 4096

    private static func coalitionIDs(of processID: pid_t) -> [UInt64]? {
        var info = CoalitionInfo()
        let size = Int32(MemoryLayout<CoalitionInfo>.size)
        guard proc_pidinfo(processID, coalitionInfoFlavor, 0, &info, size) == size else { return nil }
        return [info.coalitionIDs.0, info.coalitionIDs.1]
    }

    private static func webKitProcessIDs(inCoalitionOf appProcessID: pid_t) -> [pid_t] {
        guard let appCoalition = coalitionIDs(of: appProcessID) else { return [] }
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&processIDs, Int32(capacity * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }
        var pathBuffer = [CChar](repeating: 0, count: pathBufferSize)
        return processIDs.prefix(count).filter { processID in
            guard processID > 0, processID != appProcessID, proc_pidpath(processID, &pathBuffer, UInt32(pathBufferSize)) > 0 else { return false }
            return String(cString: pathBuffer).contains("/com.apple.WebKit.") && coalitionIDs(of: processID) == appCoalition
        }
    }
}

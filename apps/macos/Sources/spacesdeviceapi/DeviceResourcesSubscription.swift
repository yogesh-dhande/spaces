import Dispatch
import Foundation
import spacesdevicecore
import spacesterminalcore

/// Producer for the device-wide `subscribeDeviceResources` stream: a Unix-socket server the transport
/// relays plus a 2 s timer that measures this machine and broadcasts one frame per tick.
///
/// The measuring exists only while this object does. `SpacesDeviceAPIServer` creates it for the first
/// subscriber and stops it when the last relay closes, which drops the sampler's per-process state too,
/// so a daemon nobody is watching does no sampling work at all. A frame goes out every tick even when
/// the figures are unchanged: the write is also what surfaces a dead Linux peer.
final class DeviceResourcesSubscription: @unchecked Sendable {
    typealias LiveSessionsProvider = @Sendable () -> [(sessionID: String, shellProcessID: pid_t)]

    private static let daemonGroup = "daemon"
    private static let terminalGroupPrefix = "terminal:"

    /// Holds the latest encoded frame for a client that connects between ticks.
    private final class LatestLineBox: @unchecked Sendable { var line: Data? }

    let socketPath: String
    private let server: DeviceOverviewStreamServer
    private let timer: DispatchSourceTimer
    private let queue: DispatchQueue
    private let liveSessions: LiveSessionsProvider
    private let latestLineBox = LatestLineBox()
    /// The sampler and router locator are confined to `queue`, which both the timer and the priming
    /// sample run on.
    private var sampler = ProcessResourceSampler()
    #if os(macOS)
        private let routerLocator = CaddyRouterProcessLocator()
    #endif
    /// Confined to the owning `SpacesDeviceAPIServer`'s queue.
    var subscriberCount = 0

    init(socketPath: String, queue: DispatchQueue, liveSessions: @escaping LiveSessionsProvider) {
        self.socketPath = socketPath
        self.queue = queue
        self.liveSessions = liveSessions
        let latestLineBox = latestLineBox
        server = DeviceOverviewStreamServer(socketPath: socketPath, queue: queue, lineProvider: { latestLineBox.line })
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = SpacesDeviceResourcesFrame.samplingInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.tick() }
    }

    func start() throws {
        do { try server.start() } catch {
            // A dispatch source must not be released while suspended, so arm then cancel it.
            timer.resume()
            timer.cancel()
            throw error
        }
        // The first sample only records the baseline CPU times. Taking it now, ahead of the timer's
        // first fire on the same queue, makes that first fire produce a frame covering a full interval.
        queue.async { [weak self] in _ = self?.sampleFrame() }
        timer.resume()
    }

    func stop() {
        timer.cancel()
        server.stop()
    }

    private func tick() {
        guard let frame = sampleFrame(), let line = try? SpacesDeviceResourcesStreamCodec.encodeLine(frame) else { return }
        latestLineBox.line = line
        server.broadcast(data: line)
    }

    private func sampleFrame() -> SpacesDeviceResourcesFrame? {
        var groups: [String: [pid_t]] = [:]
        for session in liveSessions() where session.shellProcessID > 0 {
            groups[Self.terminalGroupPrefix + session.sessionID] = ProcessTree.processIDs(rootProcessID: session.shellProcessID)
        }
        // The daemon's figure is spacesd and its router only. Their descendants are terminals, which are
        // reported separately, so the process tree is deliberately not expanded here.
        var daemonProcessIDs = [getpid()]
        #if os(macOS)
            if let routerProcessID = routerLocator.currentProcessID() { daemonProcessIDs.append(routerProcessID) }
        #endif
        groups[Self.daemonGroup] = daemonProcessIDs

        guard let usage = sampler.sample(groups: groups, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) else { return nil }
        let daemon = usage[Self.daemonGroup]
        let terminals = usage.compactMap { name, groupUsage -> SpacesDeviceTerminalResourceUsage? in
            guard name.hasPrefix(Self.terminalGroupPrefix), groupUsage.processCount > 0 else { return nil }
            return SpacesDeviceTerminalResourceUsage(
                sessionID: String(name.dropFirst(Self.terminalGroupPrefix.count)),
                usage: SpacesDeviceResourceUsage(cpuPercent: groupUsage.cpuPercent, memoryBytes: groupUsage.memoryBytes),
                processCount: groupUsage.processCount)
        }.sorted { $0.sessionID < $1.sessionID }
        return SpacesDeviceResourcesFrame(
            sampledAt: Date(), processorCount: MachineResources.processorCount, physicalMemoryBytes: MachineResources.physicalMemoryBytes,
            daemon: SpacesDeviceResourceUsage(cpuPercent: daemon?.cpuPercent ?? 0, memoryBytes: daemon?.memoryBytes ?? 0), terminals: terminals)
    }
}

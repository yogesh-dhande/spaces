import Foundation

#if canImport(Darwin)
    import Darwin
#endif
#if canImport(Glibc)
    import Glibc
#endif
#if canImport(Network)
    import Network
#endif

/// The TCP keepalive policy every pinned-TLS Spaces endpoint uses, on both the dialing and the
/// accepting side.
///
/// The Device API's device-overview subscription is a long-lived stream that legitimately sits idle
/// for minutes and carries no application-level heartbeat. Without keepalive probes, a path that
/// dies silently — a relay or VPN flap, a sleeping peer, a NAT rebind — leaves both ends parked in
/// their receive call indefinitely, so a client keeps reporting a last-known "online" verdict over
/// permanently frozen data. Probes turn a dead path into a real connection error that feeds the
/// existing disconnect-and-reconnect path.
///
/// Sizing: `idleSeconds` before the first probe, then `probeCount` probes `intervalSeconds` apart,
/// so a dead path surfaces roughly 60–90 seconds after the last byte.
public enum SpacesTCPKeepalive {
    /// Seconds a connection may sit idle before the first keepalive probe.
    public static let idleSeconds = 60
    /// Seconds between keepalive probes once probing starts.
    public static let intervalSeconds = 10
    /// Unanswered probes before the connection is reported as failed.
    public static let probeCount = 3
}

#if canImport(Network)
    extension SpacesTCPKeepalive {
        /// TCP options carrying the shared keepalive policy, for every `NWParameters` Spaces builds.
        public static func makeTCPOptions() -> NWProtocolTCP.Options {
            let options = NWProtocolTCP.Options()
            options.enableKeepalive = true
            options.keepaliveIdle = idleSeconds
            options.keepaliveInterval = intervalSeconds
            options.keepaliveCount = probeCount
            return options
        }
    }
#endif

#if os(Linux)
    extension SpacesTCPKeepalive {
        /// Applies the shared keepalive policy to a connected or accepted socket.
        public static func apply(to fileDescriptor: Int32) {
            var enabled: Int32 = 1
            setsockopt(fileDescriptor, SOL_SOCKET, SO_KEEPALIVE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var idle = Int32(idleSeconds)
            setsockopt(fileDescriptor, Int32(IPPROTO_TCP), TCP_KEEPIDLE, &idle, socklen_t(MemoryLayout<Int32>.size))
            var interval = Int32(intervalSeconds)
            setsockopt(fileDescriptor, Int32(IPPROTO_TCP), TCP_KEEPINTVL, &interval, socklen_t(MemoryLayout<Int32>.size))
            var count = Int32(probeCount)
            setsockopt(fileDescriptor, Int32(IPPROTO_TCP), TCP_KEEPCNT, &count, socklen_t(MemoryLayout<Int32>.size))
        }
    }
#endif

import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// Holds placeholder TCP sockets on workspace service ports so nothing else claims a stopped
/// workspace's pinned ports before its next launch. The sockets are bound and never listened on, with
/// `SO_REUSEPORT` so the workspace's own server can take the port over once the placeholder is closed.
///
/// Keyed by port, because the port is the resource being held. The workspace record that justifies a
/// reservation can be deleted, stopped, started, or re-assigned a different port from any process (the
/// app, the CLI, a remote client), while only `spacesd` ever holds these descriptors, so a
/// workspace-keyed map cannot answer the only question that matters here: is this port still wanted.
/// `PortReservationReconciler` derives the wanted set from the database and drives `sync`.
///
/// A launching workspace does not just release its ports, it takes a **runtime-start hold** on them.
/// Closing the placeholder alone is not enough: a workspace is marked running only after its processes
/// are launched, and the launch itself writes rows (terminal sessions, running processes) that each
/// raise `databaseDidChange`, so a reconcile pass can run mid-launch, still see the workspace as
/// stopped, and rebind the placeholder before the child server binds the port — a dev server can take
/// seconds to come up. The rebound placeholder is exactly the `EADDRINUSE` the release was meant to
/// avoid. The hold makes `sync` skip those ports until the launch resolves.
///
/// Holds are in-process state rather than derived from the database because launches and the
/// reconciler both run inside the daemon, so nothing outside this process can take or need one.
///
/// `sync` drops the hold on any port outside the desired set, which is what makes holds self-healing: a
/// port leaving the desired set means the launch marked the workspace running, or the record went away,
/// so the hold has done its job and later stopped-state passes must be free to rebind. Stopping a
/// workspace clears the holds on its ports for the same reason, which is what covers the running state a
/// pass never observes. A hold left behind by a launch that never marked the workspace running degrades
/// only to "port not held while the workspace is stopped" and clears on the next running transition, the
/// next stop, or daemon restart, never to `EADDRINUSE` for the workspace's own server.
public final class PortReserver: Sendable {
    public static let shared = PortReserver()

    private let lock = NSLock()
    private nonisolated(unsafe) let _reservedSockets = UnsafeMutablePointer<[Int: Int32]>.allocate(capacity: 1)
    private nonisolated(unsafe) let _heldPorts = UnsafeMutablePointer<Set<Int>>.allocate(capacity: 1)

    private init() {
        _reservedSockets.initialize(to: [:])
        _heldPorts.initialize(to: [])
    }

    deinit {
        lock.lock()
        let all = _reservedSockets.pointee
        lock.unlock()
        for (_, fd) in all { close(fd) }
        _reservedSockets.deinitialize(count: 1)
        _reservedSockets.deallocate()
        _heldPorts.deinitialize(count: 1)
        _heldPorts.deallocate()
    }

    /// Makes the held placeholders exactly `desiredPorts`, minus the ports under a runtime-start hold:
    /// closes every socket whose port is no longer wanted, releases holds on ports that left the desired
    /// set, and binds every wanted port that is neither already bound nor held.
    public func sync(desiredPorts: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        for (port, fd) in _reservedSockets.pointee where !desiredPorts.contains(port) {
            close(fd)
            _reservedSockets.pointee[port] = nil
        }
        _heldPorts.pointee.formIntersection(desiredPorts)
        for port in desiredPorts where _reservedSockets.pointee[port] == nil && !_heldPorts.pointee.contains(port) { bindAndTrackLocked(port: port) }
    }

    /// Frees these ports for a workspace runtime that is starting and keeps them free: closes whatever
    /// placeholder holds each one, and marks it held so a reconcile pass firing on the launch's own
    /// database writes cannot rebind it while the workspace record still says stopped.
    public func beginRuntimeStartHold(ports: some Sequence<Int>) {
        lock.lock()
        defer { lock.unlock() }
        for port in ports {
            if let fd = _reservedSockets.pointee.removeValue(forKey: port) { close(fd) }
            _heldPorts.pointee.insert(port)
        }
    }

    /// Ends the hold and rebinds a placeholder on each port that does not already have one. This is the
    /// failed-launch path: no server took the port, and the workspace is still stopped, so its pinned
    /// ports go back to being held rather than left open until the next reconcile pass.
    public func endRuntimeStartHold(ports: some Sequence<Int>) {
        lock.lock()
        defer { lock.unlock() }
        for port in ports {
            _heldPorts.pointee.remove(port)
            if _reservedSockets.pointee[port] == nil { bindAndTrackLocked(port: port) }
        }
    }

    /// Ends the hold on each port without binding anything, for the two cases where a hold has outlived
    /// its launch but this process must not put a placeholder back itself.
    ///
    /// A launch that fails on a workspace that was already running: its record excludes its ports from the
    /// reconciler's desired set, so dropping the hold with no placeholder is the state the reconciler
    /// already wants, and rebinding would be wrong because sibling servers may already own these ports or
    /// still be starting on them.
    ///
    /// A workspace being marked stopped: the stop ends whatever launch was in progress, and the write that
    /// records it raises the pass that binds the placeholders, so binding here would only race that pass.
    ///
    /// Either way, clearing is what lets the next stopped-state pass hold the ports again.
    public func clearRuntimeStartHold(ports: some Sequence<Int>) {
        lock.lock()
        defer { lock.unlock() }
        for port in ports { _heldPorts.pointee.remove(port) }
    }

    /// The ports this process currently holds placeholders on.
    public func reservedPorts() -> Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(_reservedSockets.pointee.keys)
    }

    private func bindAndTrackLocked(port: Int) {
        guard let fd = bindSocket(port: port) else { return }
        _reservedSockets.pointee[port] = fd
    }

    private func bindSocket(port: Int) -> Int32? {
        #if os(Linux)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return nil }
        // The daemon replaces its own image with `execv` to apply an update. An inherited placeholder
        // descriptor would keep its port bound in the successor with nothing tracking it, so it could
        // never be released again.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            close(fd)
            return nil
        }
        return fd
    }
}

import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// A process with a TCP socket on a port.
public struct PortHolder: Equatable, Sendable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// Finds a process with a TCP socket listening on (macOS also: bound to) a port, to name it in the
/// notice a workspace start raises for a port something else holds.
///
/// Only processes this user may inspect are visible, so a port held by another user's process yields nil
/// and the notice says "another program". There is no fallback to `lsof` or to anything else.
enum PortHolderLookup {
    static func holder(ofPort port: Int) -> PortHolder? {
        guard (1...Int(UInt16.max)).contains(port) else { return nil }
        #if os(Linux)
            return linuxHolder(ofPort: port)
        #else
            return darwinHolder(ofPort: port)
        #endif
    }

    #if os(Linux)
        /// `/proc/net/tcp{,6}` rows are `sl local_address rem_address st ... uid timeout inode`, with the
        /// local port in hex and state `0A` for LISTEN. The inode is then matched against each process's
        /// `socket:[inode]` descriptor links.
        private static func linuxHolder(ofPort port: Int) -> PortHolder? {
            var inodes = Set<String>()
            for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
                guard let contents = try? String(contentsOfFile: table, encoding: .utf8) else { continue }
                for line in contents.split(separator: "\n").dropFirst() {
                    let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard columns.count > 9, columns[3] == "0A",
                        let localPort = columns[1].split(separator: ":").last.flatMap({ Int($0, radix: 16) }), localPort == port
                    else { continue }
                    inodes.insert(String(columns[9]))
                }
            }
            guard !inodes.isEmpty, let processes = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
            for entry in processes {
                guard let pid = Int32(entry), let descriptors = try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(entry)/fd")
                else { continue }
                for descriptor in descriptors {
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(entry)/fd/\(descriptor)"),
                        target.hasPrefix("socket:["), target.hasSuffix("]"), inodes.contains(String(target.dropFirst(8).dropLast()))
                    else { continue }
                    let name = (try? String(contentsOfFile: "/proc/\(entry)/comm", encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return PortHolder(pid: pid, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "pid \(pid)")
                }
            }
            return nil
        }
    #else
        /// Walks every process's socket descriptors through libproc. `insi_lport` holds the port in network
        /// byte order in the low 16 bits.
        private static func darwinHolder(ofPort port: Int) -> PortHolder? {
            let wantedPort = Int32(UInt16(port).bigEndian)
            let pidCount = proc_listallpids(nil, 0)
            guard pidCount > 0 else { return nil }
            var pids = [pid_t](repeating: 0, count: Int(pidCount) + 16)
            let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard filled > 0 else { return nil }
            for pid in pids.prefix(Int(filled)) where pid > 0 {
                let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
                guard listSize > 0 else { continue }
                var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(listSize) / MemoryLayout<proc_fdinfo>.size)
                let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, listSize)
                guard written > 0 else { continue }
                for descriptor in descriptors.prefix(Int(written) / MemoryLayout<proc_fdinfo>.size)
                where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                    var info = socket_fdinfo()
                    let infoSize = proc_pidfdinfo(
                        pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                    guard infoSize == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
                    let tcp = info.psi.soi_proto.pri_tcp
                    let state = tcp.tcpsi_state
                    guard tcp.tcpsi_ini.insi_lport & 0xFFFF == wantedPort & 0xFFFF,
                        state == Int32(TSI_S_LISTEN) || state == Int32(TSI_S_CLOSED)
                    else { continue }
                    var nameBuffer = [CChar](repeating: 0, count: 256)
                    let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
                    let name = nameLength > 0 ? String(cString: nameBuffer) : "pid \(pid)"
                    return PortHolder(pid: pid, name: name)
                }
            }
            return nil
        }
    #endif
}

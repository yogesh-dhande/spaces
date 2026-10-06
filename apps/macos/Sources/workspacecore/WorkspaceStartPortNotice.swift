import Foundation

/// The notice a workspace start returns when one of the workspace's assigned ports is held by something
/// else at the moment its placeholders are released.
///
/// The start proceeds regardless: an assignment belongs to the workspace until it is deleted, so the
/// port is never moved, and the user is told instead. The sentence says "may reach" because the
/// holder's own server, not the workspace's, then answers on that port.
enum WorkspaceStartPortNotice {
    /// One sentence per held port, in assignment order; nil when every port is free.
    ///
    /// Must run after the workspace's own placeholders are released: a placeholder is a bound socket, so
    /// it would count as the holder.
    static func make(assignedPorts: [(name: String, port: Int)]) -> String? {
        let sentences = assignedPorts.compactMap { assigned -> String? in
            guard PortProbe.isInUse(port: assigned.port) else { return nil }
            let holder =
                PortHolderLookup.holder(ofPort: assigned.port).map { "\($0.name) (pid \($0.pid))" } ?? "another program"
            return "\(assigned.name)'s port \(assigned.port) is in use by \(holder), so \(assigned.name)'s requests may reach that program instead."
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

/// What a workspace start reports beyond having started.
public struct WorkspaceStartOutcome: Sendable {
    public let notice: String?

    public init(notice: String?) { self.notice = notice }
}

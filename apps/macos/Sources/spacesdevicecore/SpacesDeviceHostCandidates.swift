import Foundation

/// The shared policy for a device's list of candidate Device API addresses: how many are worth keeping,
/// and what a usable list looks like.
///
/// One number, because the same bound has to hold everywhere a candidate list is built or grown: the
/// stored record (`SpacesPairedDeviceRecord.maxHostCandidates`), the advertised-host merge, and the
/// pairing link a client redeems. The bound exists because every candidate is something a connect may
/// have to walk: a race stages its attempts, and a stream rotates through them one reconnect at a time,
/// so an unbounded list is an unbounded connect.
public enum SpacesDeviceHostCandidates {
    /// Upper bound on the candidates kept for one device. Six covers the real shapes with room to spare
    /// (a LAN address per interface, plus a tailnet address) and is small enough that walking the whole
    /// list stays bounded and quick.
    public static let maxCount = 6

    /// A candidate list reduced to what is worth dialing: each entry trimmed, empties dropped, duplicates
    /// removed keeping the first occurrence, and the whole thing capped from the tail so the
    /// most-preferred addresses are the ones that survive.
    public static func normalized(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for host in hosts {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
            if normalized.count == maxCount { break }
        }
        return normalized
    }
}

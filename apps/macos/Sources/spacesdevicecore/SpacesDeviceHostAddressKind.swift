import Foundation

/// Classifies a pairing-link candidate address for display, so the Mac Devices pane and the iOS
/// pairing sheet/device list can label each candidate the same way: "Local network" or "Tailscale".
///
/// Detection mirrors the address-range half of the daemon's own
/// `SpacesDeviceAPINetworkInterfaces.isTailnetInterfaceAddress`: an IPv4 in the Tailscale/CGNAT range
/// (`100.64.0.0/10`) is the tailnet candidate. The daemon additionally requires the interface to look
/// like a tunnel before it ever advertises a tailnet candidate in a pairing link, so a client
/// classifying a host it already received in a link needs only the range check — anything in that
/// range reaching a client this way is the daemon's Tailscale address, not a coincidental LAN address.
public enum SpacesDeviceHostAddressKind: Sendable, Equatable {
    case localNetwork
    case tailscale

    public init(host: String) {
        self = Self.isTailscaleRangeAddress(host) ? .tailscale : .localNetwork
    }

    /// Short label for pairing UI, e.g. "Local network · 192.168.1.24" / "Tailscale · 100.86.197.104".
    public var label: String {
        switch self {
        case .localNetwork: "Local network"
        case .tailscale: "Tailscale"
        }
    }

    private static func isTailscaleRangeAddress(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}

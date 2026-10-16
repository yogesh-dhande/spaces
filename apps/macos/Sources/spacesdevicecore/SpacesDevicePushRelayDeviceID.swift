import Foundation

/// The identifier a daemon files its counts under at the push relay: the same id the iPhone app keeps for
/// that daemon as its paired-device id, so the phone can unregister a daemon it unpairs without asking it.
/// The phone derives its id from the daemon's pinned certificate fingerprint and port (`deviceID` in
/// `SpacesMobileDeviceStore`), deliberately not from an address, which moves between LAN and Tailscale.
public enum SpacesDevicePushRelayDeviceID {
    /// `"device-"` plus the first 48 characters of `"<fingerprint>|<port>"` lowercased, with each run of
    /// non-alphanumerics collapsed to one `-` and edge dashes trimmed. The relay accepts 1 to 128 characters.
    public static func make(certificateFingerprint: String, port: Int) -> String {
        let source = "\(certificateFingerprint)|\(port)".lowercased()
        let slug = source.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(
            in: CharacterSet(charactersIn: "-"))
        return "device-\(slug.prefix(48))"
    }
}

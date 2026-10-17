import Foundation

/// The pure rules for finding out which release a self-updating daemon could move to. The daemon does
/// the fetching; this decides where to look and what the answer means.
public enum DaemonSelfUpdateFeed {
    /// The website serves one newest-version file per channel, written when a release is staged for the
    /// site: `stable` is the version GitHub marks latest, `prerelease` is the newest tagged release.
    public static func url(for channel: DaemonUpdateChannel) -> URL {
        switch channel {
        case .stable: URL(string: "https://usespaces.dev/releases/linux-latest.json")!
        case .prerelease: URL(string: "https://usespaces.dev/releases/prerelease/linux-latest.json")!
        }
    }

    /// The version a feed body names (`{"version":"0.24.0"}`), or nil when the body is not a feed. A
    /// malformed body is a failed check, never a version, so a captive portal's HTML page cannot
    /// become an "available" update.
    public static func parseVersion(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = object["version"] as? String
        else { return nil }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }), version.first != ".", version.last != "." else { return nil }
        return version
    }

    /// The feed's version when it is newer than the running one, else nil. Equal or older means the
    /// daemon is current on that channel, including a prerelease daemon looking at the stable feed.
    public static func availableVersion(runningVersion: String, feedVersion: String) -> String? {
        SpacesWireProtocol.isVersion(runningVersion, olderThan: feedVersion) ? feedVersion : nil
    }

    /// The channel a daemon with no stored choice picks for itself: `prerelease` when it runs a build
    /// newer than the stable feed's version (it was installed from a pre-release), otherwise `stable`.
    /// An install from before this feature therefore counts as stable. Nil when the stable feed has not
    /// been read yet, so the daemon decides on a later check instead of persisting a guess.
    public static func defaultChannel(runningVersion: String, stableFeedVersion: String?) -> DaemonUpdateChannel? {
        guard let stableFeedVersion else { return nil }
        return SpacesWireProtocol.isVersion(stableFeedVersion, olderThan: runningVersion) ? .prerelease : .stable
    }
}

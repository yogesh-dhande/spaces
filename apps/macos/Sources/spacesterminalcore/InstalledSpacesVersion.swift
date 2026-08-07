import Foundation

/// The version of the Spaces build currently installed on this device — the build that takes effect
/// the next time `spacesd` restarts.
///
/// A daemon's own version is compiled in (`AppVersion`), so a running process can never notice an
/// update that lands after it started. Both platforms install a new build beside the running one and
/// leave the old process alive until it restarts, so this has to be read from disk every time a status
/// is built rather than cached at launch — caching it would report the value that was current when the
/// daemon started, which is exactly the value `AppVersion` already gives.
public enum InstalledSpacesVersion {
    /// Returns `nil` when no installed build can be identified, which means "no update is staged"
    /// rather than "unknown": a daemon running straight from a development build directory has no
    /// installed app bundle or release directory to read, and there is nothing for it to update to.
    public static func current() -> String? {
        #if os(macOS)
            return installedAppBundleVersion()
        #else
            return installedReleaseVersion()
        #endif
    }

    #if os(macOS)
        /// A Sparkle update replaces `Spaces.app` in place while the old daemon keeps running, and
        /// `~/.spaces/bin/spacesd` is a symlink into `Contents/Resources`, so the daemon finds the new
        /// version by resolving its own executable path back into the bundle that now contains it and
        /// reading that bundle's `Info.plist`.
        static func installedAppBundleVersion(executableURL: URL? = Bundle.main.executableURL) -> String? {
            guard let executableURL, let bundleURL = enclosingAppBundleURL(of: executableURL.resolvingSymlinksInPath()) else { return nil }
            let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
            guard let data = try? Data(contentsOf: infoPlistURL),
                let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return info["CFBundleShortVersionString"] as? String
        }

        /// The nearest ancestor directory with an `.app` extension, or `nil` for an executable that is
        /// not inside an app bundle at all (a development build).
        static func enclosingAppBundleURL(of executableURL: URL) -> URL? {
            var candidate = executableURL.deletingLastPathComponent()
            while candidate.path != "/" {
                if candidate.pathExtension == "app" { return candidate }
                candidate = candidate.deletingLastPathComponent()
            }
            return nil
        }
    #else
        /// The Linux installer unpacks each build into `<daemon root>/releases/<version>/` and repoints
        /// the `current` symlink at it, leaving the old daemon running from its own release directory
        /// until the service restarts. The daemon root is resolved from the running executable's own
        /// path — `<root>/releases/<version>/bin/<name>` — because a daemon may serve any profile
        /// (installed or development) and each profile has its own release tree: reading a fixed
        /// home-relative path would report another profile's installed build as this daemon's staged
        /// update. Each release carries the `manifest.json` it was built with, so `current`'s manifest
        /// names the installed version. An executable outside a release tree is a development build
        /// with nothing to update to.
        static func installedReleaseVersion(executableURL: URL? = Bundle.main.executableURL) -> String? {
            guard let executableURL else { return nil }
            let binDir = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            let releasesDir = binDir.deletingLastPathComponent().deletingLastPathComponent()
            guard binDir.lastPathComponent == "bin", releasesDir.lastPathComponent == "releases" else { return nil }
            let manifestURL = releasesDir.deletingLastPathComponent().appendingPathComponent("current/manifest.json", isDirectory: false)
            guard let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return manifest["app_version"] as? String
        }
    #endif
}

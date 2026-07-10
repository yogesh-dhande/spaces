import Foundation

/// Maps a workspace's resolved browser-session URLs to the assigned service each one addresses, so a
/// thin client (the iOS app's on-device proxy) can route a browser session without owning an SSH/Caddy
/// forward the way the Mac client does.
///
/// The matching contract mirrors `BrowserSSHForwardManager.routePlan(targetURL:assignedPorts:)` in
/// `apps/macos/Sources/spacesui/BrowserSSHForwardManager.swift` on the Mac client: a browser-session URL
/// matches an assigned port when either
///   (a) its host equals the assigned port's identity-URL host and its port equals the identity URL's
///       port, or
///   (b) its host is loopback (`localhost`, `127.0.0.1`, `::1`) and its port equals the assigned port's
///       `port` field.
/// Both clients need this so a workspace whose services are only reachable through the daemon/router
/// still resolves plain `localhost:<port>` browser sessions the same way an identity-URL session does.
public struct SpacesDeviceBrowserSessionRoute: Sendable, Equatable {
    /// `resolvedBrowserSessions[i].name`, if the session was named.
    public let sessionName: String?
    /// The resolved (env-expanded) browser-session URL string this route was matched from.
    public let originalURL: String
    /// The matched `SpacesDeviceAssignedPort.name`.
    public let serviceName: String
    /// Host of the matched assigned port's identity URL, e.g. `"web.slug.localhost"`.
    public let identityHost: String
    /// Path, query, and fragment from `originalURL`, percent-encoded and concatenated (e.g.
    /// `"/a/b?x=1#y"`), or `""` when the original URL has none. An original path of `"/"` is preserved
    /// as `"/"` rather than collapsed to `""`.
    public let pathQueryFragment: String

    /// Builds one route per `resolvedBrowserSessions` entry that has a parseable `http` URL matching a
    /// service in `assignedPorts`. Sessions with a `nil`/unparseable URL, a non-`http` scheme, or no
    /// matching service are dropped. Result order follows `resolvedBrowserSessions` order.
    public static func routes(resolvedBrowserSessions: [SpacesDeviceBrowserSession], assignedPorts: [SpacesDeviceAssignedPort])
        -> [SpacesDeviceBrowserSessionRoute]
    {
        resolvedBrowserSessions.compactMap { session in
            guard let urlString = session.url, let target = URLComponents(string: urlString), target.scheme?.lowercased() == "http" else {
                return nil
            }
            let targetHost = target.host?.lowercased()
            let targetPort = target.port

            for assignedPort in assignedPorts {
                guard assignedPort.port > 0, let identityURL = URLComponents(string: assignedPort.url), let identityHost = identityURL.host,
                    identityURL.scheme?.lowercased() == "http"
                else { continue }

                let matchesIdentity = targetHost == identityHost.lowercased() && targetPort == identityURL.port
                let matchesLoopback = isLoopbackHost(targetHost) && targetPort == assignedPort.port
                guard matchesIdentity || matchesLoopback else { continue }

                return SpacesDeviceBrowserSessionRoute(
                    sessionName: session.name, originalURL: urlString, serviceName: assignedPort.name, identityHost: identityHost,
                    pathQueryFragment: pathQueryFragment(of: target))
            }
            return nil
        }
    }

    /// Rebuilds the browser-session URL against a proxy listening on `proxyPort` at `identityHost`,
    /// preserving `pathQueryFragment`. Returns `nil` only if the resulting string is not a valid URL.
    public func proxyURL(proxyPort: Int) -> URL? { URLComponents(string: "http://\(identityHost):\(proxyPort)\(pathQueryFragment)")?.url }

    /// Loopback hosts that route to the assigned port's raw `port` rather than the identity URL's
    /// host/port. `URLComponents.host` already strips the brackets `URL(string:)` uses to delimit an
    /// IPv6 literal, so `"::1"` covers both `http://[::1]:1234` and `http://::1:1234` inputs.
    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Concatenates `components`' path, query, and fragment into one percent-encoded relative string.
    /// Use the percent-encoded fields directly so bytes such as `%2F` and `%2B` keep addressing the
    /// same resource after the URL is rewritten through the local proxy.
    private static func pathQueryFragment(of components: URLComponents) -> String {
        var pathQueryFragment = components.percentEncodedPath
        if let query = components.percentEncodedQuery { pathQueryFragment += "?\(query)" }
        if let fragment = components.percentEncodedFragment { pathQueryFragment += "#\(fragment)" }
        return pathQueryFragment
    }
}

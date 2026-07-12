import Foundation
import Security
import spacesdevicecore

/// The authenticated loopback URL the embedded browser should load for a workspace browser session.
/// The cookie gates access to the in-process proxy; the proxy strips it before replaying the request
/// to the workspace service.
struct BrowserProxyRequest: Sendable, Equatable, Hashable {
    static let cookieName = "SpacesBrowserProxyAuth"

    let url: URL
    let authToken: String

    init?(url: URL, authToken: String) {
        guard url.host != nil else { return nil }
        self.url = url
        self.authToken = authToken
    }

    var urlRequest: URLRequest {
        URLRequest(url: url)
    }

    var httpCookie: HTTPCookie {
        guard let host = url.host,
              let cookie = HTTPCookie(properties: [
                  .domain: host,
                  .path: "/",
                  .name: Self.cookieName,
                  .value: authToken,
                  .discard: "TRUE",
                  HTTPCookiePropertyKey(rawValue: "HttpOnly"): "TRUE",
              ])
        else {
            preconditionFailure("Browser proxy requests are created only for host-bearing URLs.")
        }
        return cookie
    }

}

/// The daemon and workspace service a browser `Host` resolves to. The display names are carried so
/// the proxy's error pages can name the service, workspace, and device without a second lookup.
struct BrowserProxyRouteTarget: Sendable, Equatable {
    let deviceID: String
    let host: String
    let port: Int
    let certificateFingerprint: String
    let workspaceID: String
    let serviceName: String
    let workspaceName: String
    let deviceName: String
    let proxyAuthToken: String
}

/// Maps lowercased browser hosts (`<service>.<workspace-slug>.localhost`, without port) to the
/// daemon-side tunnel target that owns them. Built by merging each paired device's overview: the
/// daemon computes every workspace service's URL, and its host is the routing key WKWebView will
/// present in the `Host` header.
///
/// The table is last-writer-wins across devices: if two paired daemons ever advertise the same host,
/// the most recent merge owns it. `merge` reports any host it reassigned to a different
/// device/workspace so the caller can log the collision.
struct BrowserProxyRoutingTable: Sendable, Equatable {
    private(set) var targets: [String: BrowserProxyRouteTarget] = [:]

    /// Replaces one device's routes from its latest overview, keying each workspace service on its URL host.
    /// Routes owned by this device but absent from the refresh are removed.
    /// Returns the hosts whose owning `(deviceID, workspaceID)` changed as a result, so the caller
    /// can surface the reassignment.
    @discardableResult
    mutating func merge(
        deviceID: String,
        deviceName: String,
        host: String,
        port: Int,
        certificateFingerprint: String,
        overview: SpacesDeviceOverviewPayload
    ) -> [String] {
        var refreshedKeys = Set<String>()
        for workspace in overview.workspaces {
            for assignedPort in workspace.assignedPorts {
                guard let key = Self.routingKey(forURL: assignedPort.url) else { continue }
                refreshedKeys.insert(key)
            }
        }
        targets = targets.filter { key, target in
            target.deviceID != deviceID || refreshedKeys.contains(key)
        }

        var replacedHosts: [String] = []
        for workspace in overview.workspaces {
            for assignedPort in workspace.assignedPorts {
                guard let key = Self.routingKey(forURL: assignedPort.url) else { continue }
                let existing = targets[key]
                if let existing, existing.deviceID != deviceID || existing.workspaceID != workspace.id {
                    replacedHosts.append(key)
                }
                let proxyAuthToken =
                    if let existing, existing.deviceID == deviceID, existing.workspaceID == workspace.id,
                       existing.serviceName == assignedPort.name
                    {
                        existing.proxyAuthToken
                    } else {
                        Self.makeProxyAuthToken()
                    }
                targets[key] = BrowserProxyRouteTarget(
                    deviceID: deviceID,
                    host: host,
                    port: port,
                    certificateFingerprint: certificateFingerprint,
                    workspaceID: workspace.id,
                    serviceName: assignedPort.name,
                    workspaceName: workspace.displayName,
                    deviceName: deviceName,
                    proxyAuthToken: proxyAuthToken
                )
            }
        }
        return replacedHosts
    }

    /// Drops every route owned by a device (e.g. after it is unpaired or its overview goes away).
    mutating func removeDevice(deviceID: String) {
        targets = targets.filter { $0.value.deviceID != deviceID }
    }

    /// Looks up the target for a browser `Host`. The host is lowercased to match the stored keys.
    func target(forHost host: String) -> BrowserProxyRouteTarget? {
        targets[host.lowercased()]
    }

    /// Extracts the lowercased host from a workspace service URL, or nil if the URL has no host.
    static func routingKey(forURL urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    private static func makeProxyAuthToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Unable to generate browser proxy authentication token.")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

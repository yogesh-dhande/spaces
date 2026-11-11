import Foundation

/// Which APNs environment this build's device tokens belong to. The relay needs it because a sandbox token
/// is rejected by the production endpoint and the reverse.
enum PushEnvironment: String, Sendable {
    case sandbox
    case production

    /// The APNs environment the running build's tokens belong to, read from the provisioning profile the
    /// app was signed with rather than from a build setting. The release archive is signed for
    /// development and `-exportArchive` re-signs it for distribution, and the user also stages Release
    /// builds on a real iPhone signed for development (their tokens are sandbox), so no build-time label
    /// can be right for every Release build.
    ///
    /// A device build with a profile reports the profile's `aps-environment`. One without a profile is an
    /// App Store or TestFlight build, which is production. The simulator never embeds a profile but gets
    /// sandbox tokens, so it is answered explicitly instead of falling into the production case.
    static func current(bundle: Bundle = .main) -> PushEnvironment {
        #if targetEnvironment(simulator)
            return .sandbox
        #else
            guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"), let profile = try? Data(contentsOf: url) else {
                return .production
            }
            return environment(provisioningProfile: profile) ?? .production
        #endif
    }

    /// `Entitlements.aps-environment` of a provisioning profile, which is an XML plist inside a CMS
    /// envelope: the plist is the `<?xml` ... `</plist>` span. Nil when the profile has no readable
    /// push environment.
    static func environment(provisioningProfile: Data) -> PushEnvironment? {
        guard let start = provisioningProfile.range(of: Data("<?xml".utf8)),
            let end = provisioningProfile.range(of: Data("</plist>".utf8), in: start.lowerBound..<provisioningProfile.endIndex),
            let plist = try? PropertyListSerialization.propertyList(from: provisioningProfile[start.lowerBound..<end.upperBound], format: nil)
                as? [String: Any], let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        switch entitlements["aps-environment"] as? String {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }
}

/// The phone's side of the push relay contract (`docs/implementation.md`, "Push Relay"): the relay seals
/// the APNs token into a capability that this phone hands to its paired devices.
protocol PushRelayClient: Sendable {
    /// Exchanges the APNs token for a capability and tells the relay which devices the phone is paired
    /// with. Only those may report, and a device missing from the list loses its counts, which is how an
    /// unpaired device stays out of the badge even when it was offline to hear about it.
    func register(apnsToken: String, environment: PushEnvironment, installID: String, deviceIDs: [String]) async throws -> String
}

enum PushRelayClientError: Error { case rejected(status: Int) }

struct URLSessionPushRelayClient: PushRelayClient {
    static let baseURL = URL(string: "https://push.usespaces.dev")!

    var session: URLSession = .shared
    var baseURL: URL = Self.baseURL

    func register(apnsToken: String, environment: PushEnvironment, installID: String, deviceIDs: [String]) async throws -> String {
        struct Body: Encodable {
            let apnsToken: String
            let environment: String
            let installID: String
            let deviceIDs: [String]
        }
        struct Response: Decodable { let capability: String }
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/register"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Body(apnsToken: apnsToken, environment: environment.rawValue, installID: installID, deviceIDs: deviceIDs))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw PushRelayClientError.rejected(status: status) }
        return try JSONDecoder().decode(Response.self, from: data).capability
    }
}

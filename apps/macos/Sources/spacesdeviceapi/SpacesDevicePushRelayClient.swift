import Foundation
import spacesdevicecore

/// One call to the push relay (`docs/implementation.md`, "Push Relay"). The capability is a bearer secret for
/// a phone's APNs token, so it travels only in the request body.
enum SpacesDevicePushRelayRequest: Equatable, Sendable {
    case report(capability: String, deviceID: String, counts: SpacesDeviceAlertCounts, notify: Bool)
    case unregister(capability: String, deviceID: String)

    var path: String {
        switch self {
        case .report: "/v1/report"
        case .unregister: "/v1/unregister"
        }
    }

    var body: Data {
        let object: [String: Any]
        switch self {
        case .report(let capability, let deviceID, let counts, let notify):
            object = ["capability": capability, "deviceID": deviceID, "total": counts.total, "blockedAgents": counts.blockedAgents, "notify": notify]
        case .unregister(let capability, let deviceID): object = ["capability": capability, "deviceID": deviceID]
        }
        // Every value above is JSON-representable, so serialization cannot fail.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// What a relay call means for the daemon, independent of how it was transported.
enum SpacesDevicePushRelayOutcome: Equatable, Sendable {
    case delivered
    /// 401 (the capability no longer unseals) or 410 (APNs dropped the token): the registration can never
    /// work again, so the daemon forgets it.
    case registrationDead
    /// 5xx, a timeout, or no network: worth retrying with the same state.
    case transientFailure
    /// Any other answer (a 400): retrying the same request cannot change it.
    case rejected

    static func outcome(forHTTPStatus status: Int) -> SpacesDevicePushRelayOutcome {
        switch status {
        case 200..<300: .delivered
        case 401, 410: .registrationDead
        case 500..<600, 0: .transientFailure
        default: .rejected
        }
    }
}

protocol SpacesDevicePushRelayClient: Sendable {
    /// Sends `request` and calls `completion` exactly once, on any queue.
    func send(_ request: SpacesDevicePushRelayRequest, completion: @escaping @Sendable (SpacesDevicePushRelayOutcome) -> Void)
}

/// Sends relay calls through the system `curl`, which brings TLS, proxy settings, and the platform trust
/// store without a second networking stack in the daemon (the Linux daemon cannot use URLSession
/// uniformly). The JSON body goes on stdin (`--data-binary @-`): argv is visible to every local user in
/// `ps`, and the body holds the capability.
struct SpacesDevicePushRelayCurlClient: SpacesDevicePushRelayClient {
    static let baseURL = "https://push.usespaces.dev"
    static let maxTimeSeconds = 15

    /// Relay calls are rare, small, and independent across phones, so a concurrent utility queue gives each
    /// its own blocked thread without a pool of workers to manage.
    private static let queue = DispatchQueue(label: "spaces.device.push.relay", qos: .utility, attributes: .concurrent)

    func send(_ request: SpacesDevicePushRelayRequest, completion: @escaping @Sendable (SpacesDevicePushRelayOutcome) -> Void) {
        Self.queue.async { completion(Self.run(request)) }
    }

    /// Everything after the executable. Carries no request content beyond the URL.
    static func arguments(for request: SpacesDevicePushRelayRequest) -> [String] {
        [
            "--silent", "--show-error", "--max-time", String(maxTimeSeconds), "--request", "POST", "--header", "Content-Type: application/json",
            "--data-binary", "@-", "--output", "/dev/null", "--write-out", "%{http_code}", baseURL + request.path,
        ]
    }

    private static func run(_ request: SpacesDevicePushRelayRequest) -> SpacesDevicePushRelayOutcome {
        let process = Process()
        #if canImport(Darwin)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = arguments(for: request)
        #else
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["curl"] + arguments(for: request)
        #endif
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        #if canImport(Darwin)
            // curl can exit (name resolution failed) before reading stdin; without this the write below would
            // raise SIGPIPE in the daemon. The Linux daemon ignores SIGPIPE process-wide.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        do { try process.run() } catch { return .transientFailure }
        try? input.fileHandleForWriting.write(contentsOf: request.body)
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let status = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .transientFailure }
        return SpacesDevicePushRelayOutcome.outcome(forHTTPStatus: status)
    }
}

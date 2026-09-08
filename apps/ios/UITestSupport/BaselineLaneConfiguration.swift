import Foundation

/// Config for one scenario x profile UI test run of the iOS performance baseline lane
/// (`SpacesMobileBaselineUITests`), written by `apps/macos/Tests/e2e_mobile_baseline.sh` per
/// `xcodebuild ... test-without-building -only-testing:` invocation and read from
/// `SPACES_MOBILE_BASELINE_CONFIG_PATH`. This mirrors exactly how `SPACES_MOBILE_UI_TEST_CONFIG_PATH`
/// reaches `SpacesMobileUITests` (see `UITestConfiguration.load` there and the runner's `run_ui_test` in
/// `e2e_mobile.sh`): the variable is exported in the shell before invoking `xcodebuild`, and `xcodebuild`
/// carries a shell environment variable set before the invocation through to the XCTest process it
/// launches inside the simulator's runner app, so no extra plumbing on the `xcodebuild` command line
/// itself is needed to get the path to the test process.
struct BaselineLaneConfiguration: Decodable {
    static let defaultConfigPath = "/tmp/spaces-mobile-baseline-config.json"

    /// One of "good", "constrained", "poor" — which network profile the runner already started the
    /// shaping proxy for. Carried through only to stamp lane markers; this test never talks to the proxy
    /// itself except via `shaperControlPort` in the reconnect scenario.
    let profile: String
    /// One of the nine scenario names (`cold-open`, `back-and-forth`, ...), matching the XCTest method
    /// the runner selected with `-only-testing:`. Carried through to stamp lane markers.
    let scenario: String
    /// The fixture terminal session this run's scenario operates on.
    let sessionID: String
    /// `<run root>/device-perf.jsonl`: the shared performance log this test appends `lane_marker` lines
    /// into, alongside the app's own performance events (`SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH`,
    /// set to the same path in `launchEnvironment`).
    let perfLogPath: String
    /// Pre-built `SPACES_MOBILE_TEST_DEVICE_SEED_JSON` payload (see `UITestConfiguration.deviceSeedJSON`
    /// for the shape): the runner already knows the paired auth token from its own pairing step, so it
    /// builds this JSON once rather than handing the test raw credentials to reassemble.
    let deviceSeedJSON: String?
    let installationID: String
    /// Port of the shaping proxy's control line protocol (`link down` / `link up` / `status`) on
    /// 127.0.0.1, used only by the reconnect scenario.
    let shaperControlPort: Int
    let idleSeconds: Int
    let reopenCount: Int
    let keyboardCycles: Int
    let flickCount: Int
    let backgroundCycles: Int

    private enum CodingKeys: String, CodingKey {
        case profile
        case scenario
        case sessionID
        case perfLogPath
        case deviceSeedJSON
        case installationID
        case shaperControlPort
        case idleSeconds
        case reopenCount
        case keyboardCycles
        case flickCount
        case backgroundCycles
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(String.self, forKey: .profile)
        scenario = try container.decode(String.self, forKey: .scenario)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        perfLogPath = try container.decode(String.self, forKey: .perfLogPath)
        deviceSeedJSON = try container.decodeIfPresent(String.self, forKey: .deviceSeedJSON)
        installationID = try container.decode(String.self, forKey: .installationID)
        shaperControlPort = try container.decode(Int.self, forKey: .shaperControlPort)
        idleSeconds = try container.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? 120
        reopenCount = try container.decodeIfPresent(Int.self, forKey: .reopenCount) ?? 5
        keyboardCycles = try container.decodeIfPresent(Int.self, forKey: .keyboardCycles) ?? 5
        flickCount = try container.decodeIfPresent(Int.self, forKey: .flickCount) ?? 8
        backgroundCycles = try container.decodeIfPresent(Int.self, forKey: .backgroundCycles) ?? 3
    }

    static func load(environment: [String: String]) throws -> Self {
        let configPath = environment["SPACES_MOBILE_BASELINE_CONFIG_PATH"] ?? defaultConfigPath
        let url = URL(fileURLWithPath: configPath)
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw BaselineLaneConfigurationError.missingConfigFile(configPath) }
        do { return try JSONDecoder().decode(Self.self, from: data) } catch {
            throw BaselineLaneConfigurationError.invalidConfigFile(configPath, error.localizedDescription)
        }
    }
}

enum BaselineLaneConfigurationError: LocalizedError {
    case missingConfigFile(String)
    case invalidConfigFile(String, String)

    var errorDescription: String? {
        switch self {
        case .missingConfigFile(let path): return "Missing baseline lane config file at \(path)"
        case .invalidConfigFile(let path, let message): return "Invalid baseline lane config file at \(path): \(message)"
        }
    }
}

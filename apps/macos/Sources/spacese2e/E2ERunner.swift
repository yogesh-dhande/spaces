import ArgumentParser
import Foundation

struct E2ECommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "e2e", abstract: "Run manual real-system E2E and profiling lanes.")

    @Argument(help: "Lane to run: app, terminal, mobile, device-api, all, exhaustive, or mobile-demo.") var lane: E2ELane

    @Argument(help: "Optional device-api target: all, local, remote, profile, or latency-compare.") var deviceAPITarget: E2EDeviceAPITarget?

    @Flag(name: .long, help: "List scenarios for the selected lane.") var list = false

    @Option(name: .long, parsing: .upToNextOption, help: "Scenario to run. May be passed multiple times.") var scenario: [String] = []

    @Option(name: .long, help: "Probe/sample count for latency and repeated profiling scenarios.") var samples: Int?

    @Option(name: .long, help: "Duration for soak scenarios.") var durationSeconds: Int?

    @Option(name: .long, help: "Mobile latency network profile: local or ios-constrained.") var networkProfile: E2ENetworkProfile = .local

    @Flag(name: .long, help: "Preserve the runner root and scenario roots where supported.") var keepRoot = false

    @Flag(name: .long, help: "mobile-demo only: bring up a local-only stack, skipping the remote Linux daemon build, install, and pairing.")
    var local = false

    func run() throws {
        try validateOptions()
        if list {
            printList()
            return
        }

        var runner = try E2ERunner(command: self)
        try runner.run()
    }

    private func validateOptions() throws {
        if let samples, samples <= 0 { throw ValidationError("--samples must be a positive integer.") }
        if let durationSeconds, durationSeconds <= 0 { throw ValidationError("--duration-seconds must be a positive integer.") }
        if lane != .deviceAPI, deviceAPITarget != nil { throw ValidationError("Only the device-api lane accepts a positional target.") }
        if local, lane != .mobileDemo { throw ValidationError("--local is only valid for the mobile-demo lane.") }

        let allowed = lane.scenarios
        for requested in scenario where !allowed.contains(requested) { throw ValidationError("Unknown \(lane.rawValue) scenario: \(requested)") }
    }

    private func printList() {
        switch lane {
        case .all:
            print("app: smoke")
            print("terminal: cli edit-shortcuts mac-input-latency")
            print("mobile: ownership-guard")
            print("device-api: local remote")
        case .exhaustive:
            print("app: \(E2ELane.app.scenarios.joined(separator: " "))")
            print("terminal: \(E2ELane.terminal.scenarios.joined(separator: " "))")
            let mobileScenarios = E2ELane.mobile.scenarios.filter { $0 != "demo" }
            print("mobile: \(mobileScenarios.joined(separator: " "))")
            print("mobile latency network profiles: local ios-constrained")
            print("device-api: local remote profile latency-compare")
            print("mobile-demo: demo")
        default: for item in lane.scenarios { print(item) }
        }
    }
}

enum E2ELane: String, ExpressibleByArgument {
    case app
    case terminal
    case mobile
    case deviceAPI = "device-api"
    case all
    case exhaustive
    case mobileDemo = "mobile-demo"

    var scenarios: [String] {
        switch self {
        case .app: return E2EScenarioDescriptor.app.map(\.name)
        case .terminal: return E2EScenarioDescriptor.terminal.map(\.name)
        case .mobile: return E2EScenarioDescriptor.mobile.map(\.name)
        case .deviceAPI: return E2EDeviceAPITarget.allCases.map(\.rawValue)
        case .all, .exhaustive: return []
        case .mobileDemo: return ["demo"]
        }
    }
}

/// Single source of truth for the app/terminal/mobile lanes' scenario names and how each one turns
/// into a script invocation. `E2ELane.scenarios`, the per-lane dispatch in `E2ERunner`, and
/// `runExhaustive()`'s latency/UI partitioning all read from these tables instead of re-listing
/// scenario names, so the lane/scenario/dispatch relationship can't drift between call sites.
private struct E2EScenarioDescriptor: Sendable {
    fileprivate let name: String
    fileprivate let kind: Kind

    /// How a scenario turns into a `runScript` invocation.
    fileprivate enum Kind: Sendable {
        /// Runs its own script invocation as soon as it's selected.
        case script(scriptName: String, arguments: [String], environment: @Sendable (E2ERunner) -> [String: String])
        /// Batches with sibling terminal-latency scenarios into one `e2e_terminal_latency.sh` call.
        case terminalLatency
        /// Batches with sibling mobile UI scenarios into one `e2e_mobile.sh` call; `needsRemote`
        /// scenarios force the whole batch to run with the remote daemon enabled.
        case mobileUI(needsRemote: Bool)
        /// Batches with sibling mobile-latency scenarios into one `e2e_mobile_latency.sh` call.
        case mobileLatency
    }

    fileprivate static let app: [E2EScenarioDescriptor] = [
        E2EScenarioDescriptor(
            name: "full", kind: .script(scriptName: "e2e_macos_app.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: true) })),
        E2EScenarioDescriptor(
            name: "smoke",
            kind: .script(scriptName: "e2e_macos_app.sh", arguments: ["--only-window-cycle-profile"], environment: { $0.appProfileEnvironment() })),
        E2EScenarioDescriptor(
            name: "window-cycle",
            kind: .script(scriptName: "e2e_macos_app.sh", arguments: ["--only-window-cycle-profile"], environment: { $0.appProfileEnvironment() })),
        E2EScenarioDescriptor(
            name: "window-cycle-small",
            kind: .script(
                scriptName: "e2e_macos_app.sh", arguments: ["--only-window-cycle-small"],
                environment: { $0.appProfileEnvironment(remoteEnabled: true) })),
        E2EScenarioDescriptor(
            name: "code-pane",
            kind: .script(scriptName: "e2e_macos_app.sh", arguments: ["--only-code-pane"], environment: { $0.codePaneEnvironment() })),
        E2EScenarioDescriptor(
            name: "code-pane-streaming",
            kind: .script(scriptName: "e2e_macos_app.sh", arguments: ["--only-code-pane-streaming"], environment: { $0.codePaneEnvironment() })),
        E2EScenarioDescriptor(
            name: "code-pane-churn",
            kind: .script(scriptName: "e2e_macos_app.sh", arguments: ["--only-code-pane-churn"], environment: { $0.codePaneEnvironment() })),
        E2EScenarioDescriptor(
            name: "code-pane-soak",
            kind: .script(scriptName: "e2e_macos_app.sh", arguments: ["--only-code-pane-soak"], environment: { $0.codePaneEnvironment(soak: true) })),
    ]

    fileprivate static let terminal: [E2EScenarioDescriptor] = [
        E2EScenarioDescriptor(
            name: "cli",
            kind: .script(scriptName: "e2e_terminal_cli_commands.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "daemon-idle-shutdown",
            kind: .script(scriptName: "e2e_daemon_idle_shutdown.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "daemon-exec-handoff",
            kind: .script(scriptName: "e2e_daemon_exec_handoff.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "daemon-signal-shutdown",
            kind: .script(scriptName: "e2e_daemon_signal_shutdown.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "edit-shortcuts",
            kind: .script(scriptName: "e2e_terminal_edit_shortcuts.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "mouse-reporting-scroll",
            kind: .script(scriptName: "e2e_terminal_mouse_reporting_scroll.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "ended-session-scroll",
            kind: .script(scriptName: "e2e_terminal_ended_session_scroll.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "selection-scroll",
            kind: .script(scriptName: "e2e_terminal_selection_scroll.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "agent-orchestration",
            kind: .script(scriptName: "e2e_agent_orchestration.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(name: "mac-input-latency", kind: .terminalLatency),
        E2EScenarioDescriptor(name: "mac-scrollback-latency", kind: .terminalLatency),
        E2EScenarioDescriptor(name: "mac-scrollback-partial-latency", kind: .terminalLatency),
        E2EScenarioDescriptor(name: "mac-command-output-catchup", kind: .terminalLatency),
        E2EScenarioDescriptor(
            name: "built-in-terminal-profile",
            kind: .script(scriptName: "profile_built_in_terminal.sh", arguments: [], environment: { $0.sampleEnvironment(defaultValue: 3) })),
        E2EScenarioDescriptor(
            name: "workspace-terminal-open",
            kind: .script(scriptName: "profile_workspace_terminal_open.sh", arguments: [], environment: { $0.sampleEnvironment(defaultValue: 3) })),
        E2EScenarioDescriptor(
            name: "workspace-process-terminal",
            kind: .script(scriptName: "profile_workspace_process_terminal.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "spaces-terminal-hotkeys",
            kind: .script(scriptName: "profile_spaces_terminal_hotkeys.sh", arguments: [], environment: { $0.sampleEnvironment(defaultValue: 5) })),
        E2EScenarioDescriptor(
            name: "spaces-terminal-palette",
            kind: .script(scriptName: "profile_spaces_terminal_palette.sh", arguments: [], environment: { $0.sampleEnvironment(defaultValue: 5) })),
        E2EScenarioDescriptor(
            name: "stress",
            kind: .script(scriptName: "profile_built_in_terminal_stress.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
        E2EScenarioDescriptor(
            name: "soak", kind: .script(scriptName: "soak_built_in_terminal.sh", arguments: [], environment: { $0.soakEnvironment() })),
        E2EScenarioDescriptor(
            name: "device-api-profile",
            kind: .script(scriptName: "profile_device_api.sh", arguments: [], environment: { $0.remoteEnvironment(enabled: false) })),
    ]

    fileprivate static let mobile: [E2EScenarioDescriptor] = [
        E2EScenarioDescriptor(name: "takeover", kind: .mobileUI(needsRemote: true)),
        E2EScenarioDescriptor(name: "codex", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "codex-resume-reopen", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "roundtrip", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "scrollback", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "mouse-reporting-scroll", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "terminal-link-preview", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "two-session", kind: .mobileUI(needsRemote: true)),
        E2EScenarioDescriptor(name: "ctrl-c-final-frame", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "ctrl-c-final-frame-codex-survivor", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "ownership-guard", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "workspace-delete-scroll", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "workspace-hide-scroll", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "workspace-delete-tab-lists", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "session-end-scroll", kind: .mobileUI(needsRemote: false)),
        E2EScenarioDescriptor(name: "ios-input-latency", kind: .mobileLatency),
        E2EScenarioDescriptor(name: "ios-scrollback-latency", kind: .mobileLatency),
        E2EScenarioDescriptor(
            name: "demo", kind: .script(scriptName: "run_mobile_terminal_demo.sh", arguments: [], environment: { $0.mobileDemoEnvironment() })),
    ]
}

enum E2EDeviceAPITarget: String, CaseIterable, ExpressibleByArgument {
    case all
    case local
    case remote
    case profile
    case latencyCompare = "latency-compare"
}

enum E2ENetworkProfile: String, ExpressibleByArgument {
    case local
    case iosConstrained = "ios-constrained"
}

private struct E2ERunner {
    private let command: E2ECommand
    private let fileManager = FileManager.default
    private let rootDirectory: URL
    private let macOSDirectory: URL
    private let testsDirectory: URL
    private let runRoot: URL
    private let reportDirectory: URL
    private let logsDirectory: URL
    private let artifactsDirectory: URL
    private let spacese2ePath: String
    private let startedAt = Date()
    private var finishedAt: Date?
    private var failureDescription: String?
    private var steps: [E2EStepReport] = []
    private var succeeded = false

    init(command: E2ECommand) throws {
        self.command = command
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath).standardizedFileURL
        self.rootDirectory = try Self.resolveRepositoryRoot(startingAt: currentDirectory, fileManager: fileManager)
        self.macOSDirectory = rootDirectory.appendingPathComponent("apps/macos", isDirectory: true)
        self.testsDirectory = macOSDirectory.appendingPathComponent("Tests", isDirectory: true)
        self.runRoot = try Self.createRunRoot(fileManager: fileManager)
        self.reportDirectory = try Self.createReportDirectory(rootDirectory: rootDirectory, lane: command.lane, fileManager: fileManager)
        self.logsDirectory = reportDirectory.appendingPathComponent("logs", isDirectory: true)
        self.artifactsDirectory = reportDirectory
        self.spacese2ePath = Self.resolveSpacese2ePath(
            argv0: CommandLine.arguments.first, currentDirectory: currentDirectory, macOSDirectory: macOSDirectory)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    mutating func run() throws {
        defer {
            finishedAt = Date()
            writeReport()
            cleanupRunRoot()
        }
        do {
            try prepareSharedProducts()
            try runLane()
            succeeded = true
        } catch {
            failureDescription = String(describing: error)
            throw error
        }
    }

    private mutating func runLane() throws {
        switch command.lane {
        case .app: try runApp()
        case .terminal: try runTerminal()
        case .mobile: try runMobile()
        case .deviceAPI: try runDeviceAPI(command.deviceAPITarget ?? .all)
        case .all: try runAll()
        case .exhaustive: try runExhaustive()
        case .mobileDemo: try runScript("run_mobile_terminal_demo.sh", environment: mobileDemoEnvironment())
        }
    }

    /// Syncs the local GhosttyKit/libghostty-vt artifacts to the pinned submodule *before* building,
    /// matching `verify-prep.sh`. The order matters: `spacesterminalghostty` compiles against the
    /// `.local` Ghostty headers, so a `.local` tree left skewed by another worktree or an iOS/Linux
    /// artifact swap fails the build outright. Building first makes every lane die in the shared
    /// bootstrap step with a Ghostty compile error and never reach the sync that would have repaired it.
    private mutating func prepareSharedProducts() throws {
        let ghosttySetup = macOSDirectory.appendingPathComponent("scripts/setup_ghosttykit.sh").path
        try runProcess(executable: ghosttySetup, arguments: [], environment: [:])
        let buildScript = rootDirectory.appendingPathComponent("scripts/swiftpm.sh").path
        try runProcess(executable: buildScript, arguments: ["build"], environment: ["SPACES_E2E_BOOTSTRAP_BUILD": "1"])
    }

    /// Runs a scenario whose descriptor kind is `.script`; the terminal-latency and mobile
    /// batching kinds are dispatched by their owning lane function instead.
    private mutating func runDescriptorScript(_ descriptor: E2EScenarioDescriptor) throws {
        guard case .script(let scriptName, let arguments, let environment) = descriptor.kind else {
            throw E2ERunnerError("Scenario \(descriptor.name) does not run as a standalone script")
        }
        try runScript(scriptName, arguments: arguments, environment: environment(self))
    }

    private mutating func runApp() throws { try runApp(selected: command.scenario.isEmpty ? ["full"] : command.scenario) }

    private mutating func runApp(selected: [String]) throws {
        for scenario in selected {
            guard let descriptor = E2EScenarioDescriptor.app.first(where: { $0.name == scenario }) else {
                throw E2ERunnerError("Unknown app scenario: \(scenario)")
            }
            try runDescriptorScript(descriptor)
        }
    }

    private mutating func runTerminal() throws {
        try runTerminal(selected: command.scenario.isEmpty ? ["cli", "edit-shortcuts", "mac-input-latency"] : command.scenario)
    }

    private mutating func runTerminal(selected: [String]) throws {
        var latencyScenarios: [String] = []

        for scenario in selected {
            guard let descriptor = E2EScenarioDescriptor.terminal.first(where: { $0.name == scenario }) else {
                throw E2ERunnerError("Unknown terminal scenario: \(scenario)")
            }
            switch descriptor.kind {
            case .terminalLatency: latencyScenarios.append(scenario)
            case .script: try runDescriptorScript(descriptor)
            default: throw E2ERunnerError("Unknown terminal scenario: \(scenario)")
            }
        }

        guard !latencyScenarios.isEmpty else { return }
        var arguments: [String] = latencyScenarios.flatMap { ["--scenario", $0] }
        if let samples = command.samples { arguments += ["--samples", String(samples)] }
        if command.keepRoot { arguments.append("--keep-root") }
        try runScript("e2e_terminal_latency.sh", arguments: arguments, environment: remoteEnvironment(enabled: false))
    }

    private mutating func runMobile() throws {
        try runMobile(selected: command.scenario.isEmpty ? ["takeover"] : command.scenario, networkProfile: command.networkProfile)
    }

    private mutating func runMobile(selected: [String], networkProfile: E2ENetworkProfile) throws {
        var uiScenarios: [String] = []
        var latencyScenarios: [String] = []
        var uiNeedsRemote = false

        for scenario in selected {
            guard let descriptor = E2EScenarioDescriptor.mobile.first(where: { $0.name == scenario }) else {
                throw E2ERunnerError("Unknown mobile scenario: \(scenario)")
            }
            switch descriptor.kind {
            case .mobileLatency: latencyScenarios.append(scenario)
            case .script: try runDescriptorScript(descriptor)
            case .mobileUI(let needsRemote):
                uiScenarios.append(scenario)
                if needsRemote { uiNeedsRemote = true }
            case .terminalLatency: throw E2ERunnerError("Unknown mobile scenario: \(scenario)")
            }
        }

        if !uiScenarios.isEmpty {
            var arguments = uiScenarios.flatMap { ["--scenario", $0] }
            if command.keepRoot { arguments.append("--keep-root") }
            try runScript("e2e_mobile.sh", arguments: arguments, environment: remoteEnvironment(enabled: uiNeedsRemote))
        }

        if !latencyScenarios.isEmpty {
            var arguments = ["--network-profile", networkProfile.rawValue]
            arguments += latencyScenarios.flatMap { ["--scenario", $0] }
            if let samples = command.samples { arguments += ["--samples", String(samples)] }
            if command.keepRoot { arguments.append("--keep-root") }
            try runScript("e2e_mobile_latency.sh", arguments: arguments, environment: remoteEnvironment(enabled: false))
        }
    }

    private mutating func runDeviceAPI(_ target: E2EDeviceAPITarget) throws {
        switch target {
        case .all:
            try runDeviceAPI(.local)
            try runDeviceAPI(.remote)
        case .local: try runScript("e2e_local_device_api.sh", environment: deviceAPIEnvironment(remote: false))
        case .remote: try runScript("e2e_remote_device_api.sh", environment: deviceAPIEnvironment(remote: true))
        case .profile: try runScript("profile_device_api.sh", environment: remoteEnvironment(enabled: false))
        case .latencyCompare:
            var arguments: [String] = []
            if let samples = command.samples { arguments += ["--samples", String(samples)] }
            if command.keepRoot { arguments.append("--keep-root") }
            try runScript("e2e_remote_terminal_latency_compare.sh", arguments: arguments, environment: deviceAPIEnvironment(remote: true))
        }
    }

    private mutating func runAll() throws {
        try runApp(selected: ["smoke"])
        try runTerminal(selected: ["cli"])
        try runTerminal(selected: ["edit-shortcuts"])

        // Unlike runTerminal/runMobile's batched dispatch, the "all" lane's latency and mobile
        // steps intentionally don't thread --keep-root through to the underlying scripts, so
        // these two stay hand-written rather than going through the shared batching helpers.
        var terminalLatencyArguments = ["--scenario", "mac-input-latency"]
        if let samples = command.samples { terminalLatencyArguments += ["--samples", String(samples)] }
        try runScript("e2e_terminal_latency.sh", arguments: terminalLatencyArguments, environment: remoteEnvironment(enabled: false))
        try runScript("e2e_mobile.sh", arguments: ["--scenario", "ownership-guard"], environment: remoteEnvironment(enabled: false))
        try runDeviceAPI(.all)
    }

    private mutating func runExhaustive() throws {
        try runApp(selected: ["full"])
        try runTerminal(selected: E2ELane.terminal.scenarios)
        let mobileNonLatencyScenarios = E2EScenarioDescriptor.mobile.filter {
            if case .mobileUI = $0.kind { return true }
            return false
        }.map(\.name)
        let mobileLatencyScenarios = E2EScenarioDescriptor.mobile.filter {
            if case .mobileLatency = $0.kind { return true }
            return false
        }.map(\.name)
        try runMobile(selected: mobileNonLatencyScenarios, networkProfile: .local)
        try runMobile(selected: mobileLatencyScenarios, networkProfile: .local)
        try runMobile(selected: mobileLatencyScenarios, networkProfile: .iosConstrained)
        try runDeviceAPI(.all)
        try runDeviceAPI(.profile)
    }

    fileprivate func sampleEnvironment(defaultValue: Int) -> [String: String] {
        var environment = remoteEnvironment(enabled: false)
        environment["ITERATIONS"] = String(command.samples ?? defaultValue)
        return environment
    }

    fileprivate func appProfileEnvironment(remoteEnabled: Bool = false) -> [String: String] {
        var environment = remoteEnvironment(enabled: remoteEnabled)
        if let samples = command.samples { environment["REAL_SYSTEM_PROFILE_REPETITIONS"] = String(samples) }
        return environment
    }

    fileprivate func codePaneEnvironment(soak: Bool = false) -> [String: String] {
        var environment = appProfileEnvironment(remoteEnabled: true)
        environment["REAL_SYSTEM_PROFILE_WARMUPS"] = "1"
        if let samples = command.samples { environment["SPACES_CODE_PANE_CHURN_ITERATIONS"] = String(samples) }
        if soak { environment["SPACES_CODE_PANE_SOAK_SECONDS"] = String(command.durationSeconds ?? 1800) }
        return environment
    }

    private func deviceAPIEnvironment(remote: Bool) -> [String: String] {
        var environment = remoteEnvironment(enabled: remote)
        if let samples = command.samples { environment["SPACES_E2E_DEVICE_TERMINAL_LATENCY_SAMPLES"] = String(samples) }
        return environment
    }

    /// The mobile-demo lane pairs a remote Linux daemon by default because its remote mobile-UI
    /// scenarios need one to exercise. `--local` trades that away for a fast local-only stack (no
    /// Linux artifact build, no remote install, no remote pairing), which is what iOS-only changes
    /// need to iterate quickly. Built on `sharedEnvironment` directly rather than
    /// `remoteEnvironment(enabled:)` because that helper also injects
    /// `SPACES_MOBILE_LATENCY_TERMINAL_TARGETS`, which only `e2e_mobile_latency.sh` reads and which
    /// is meaningless here.
    fileprivate func mobileDemoEnvironment() -> [String: String] {
        var environment = sharedEnvironment
        environment["SPACES_E2E_RUN_REMOTE"] = command.local ? "0" : "1"
        environment["SPACES_MOBILE_DEMO_BUILD_MACOS"] = "0"
        let inheritedPort = ProcessInfo.processInfo.environment["SPACES_MOBILE_DEMO_PORT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if inheritedPort?.isEmpty ?? true { environment["SPACES_MOBILE_DEMO_PORT"] = "0" }
        return environment
    }

    /// `soak`'s only special case beyond the shared remote-disabled environment: an optional
    /// operator-provided run length threaded into the script's environment.
    fileprivate func soakEnvironment() -> [String: String] {
        var environment = remoteEnvironment(enabled: false)
        if let durationSeconds = command.durationSeconds { environment["DURATION_SECONDS"] = String(durationSeconds) }
        return environment
    }

    fileprivate func remoteEnvironment(enabled: Bool) -> [String: String] {
        var environment = sharedEnvironment
        environment["SPACES_E2E_RUN_REMOTE"] = enabled ? "1" : "0"
        if !enabled { environment["SPACES_MOBILE_LATENCY_TERMINAL_TARGETS"] = "local" }
        return environment
    }

    private var sharedEnvironment: [String: String] {
        [
            "SPACES_E2E_RUN_ROOT": runRoot.path, "SPACES_E2E_CLI": spacese2ePath, "SPACES_E2E": spacese2ePath, "SPACES_E2E_SKIP_MACOS_BUILD": "1",
            "SPACES_E2E_SKIP_GHOSTTYKIT_SETUP": "1",
        ]
    }

    private mutating func runScript(_ scriptName: String, arguments: [String] = [], environment: [String: String]) throws {
        let script = testsDirectory.appendingPathComponent(scriptName).path
        let stepIndex = steps.count + 1
        let stepSlug = Self.slug(([scriptName] + arguments).joined(separator: " "))
        let stepDirectory = runRoot.appendingPathComponent("steps/\(Self.stepPrefix(stepIndex))-\(stepSlug)", isDirectory: true)
        let stepWorkRoot = stepDirectory.appendingPathComponent("work", isDirectory: true)
        let stepTemporaryRoot = stepDirectory.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: stepWorkRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stepTemporaryRoot, withIntermediateDirectories: true)

        var scriptEnvironment = environment
        scriptEnvironment["TMPDIR"] = stepTemporaryRoot.path
        scriptEnvironment["WORK_ROOT"] = stepWorkRoot.path
        scriptEnvironment["KEEP_ROOT"] = "1"
        scriptEnvironment.merge(reportingEnvironment(scriptName: scriptName, stepWorkRoot: stepWorkRoot), uniquingKeysWith: { _, new in new })

        try runProcess(
            executable: "/bin/bash", arguments: [script] + reportingArguments(scriptName: scriptName, arguments: arguments),
            environment: scriptEnvironment, artifactSearchRoot: stepDirectory, reportName: ([scriptName] + arguments).joined(separator: " "))
    }

    private mutating func runProcess(
        executable: String, arguments: [String], environment: [String: String], artifactSearchRoot: URL? = nil, reportName: String? = nil
    ) throws {
        let stepIndex = steps.count + 1
        let commandText = shellCommand(executable: executable, arguments: arguments)
        let stepName = reportName ?? URL(fileURLWithPath: executable).lastPathComponent
        let logPath = logsDirectory.appendingPathComponent("\(Self.stepPrefix(stepIndex))-\(Self.slug(stepName)).log")
        fileManager.createFile(atPath: logPath.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logPath)
        let started = Date()
        var status: Int32 = -1
        var processError: Error?

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = rootDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, new in new })

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardOutput.write(data)
            logHandle.write(data)
        }

        print("[e2e] \(commandText)")
        logHandle.write(Data("[e2e] \(commandText)\n".utf8))
        do {
            try process.run()
            process.waitUntilExit()
            status = process.terminationStatus
        } catch { processError = error }
        readHandle.readabilityHandler = nil
        let remaining = readHandle.readDataToEndOfFile()
        if !remaining.isEmpty {
            FileHandle.standardOutput.write(remaining)
            logHandle.write(remaining)
        }
        try? logHandle.close()

        let artifacts = collectArtifacts(searchRoot: artifactSearchRoot, stepIndex: stepIndex, stepName: stepName)
        steps.append(
            E2EStepReport(
                index: stepIndex, command: commandText, startedAt: started, finishedAt: Date(), exitCode: status, logPath: logPath,
                artifacts: artifacts))

        if let processError { throw processError }
        guard status == 0 else { throw E2ERunnerError("Command failed with exit \(status): \(commandText)") }
    }

    private func reportingArguments(scriptName: String, arguments: [String]) -> [String] {
        let scriptsWithKeepRoot = Set(["e2e_mobile.sh", "e2e_mobile_latency.sh", "e2e_terminal_latency.sh"])
        guard scriptsWithKeepRoot.contains(scriptName), !arguments.contains("--keep-root") else { return arguments }
        return arguments + ["--keep-root"]
    }

    private func reportingEnvironment(scriptName: String, stepWorkRoot: URL) -> [String: String] {
        var environment: [String: String] = [:]
        switch scriptName {
        case "e2e_macos_app.sh":
            environment["TMP_PREFIX"] = stepWorkRoot.appendingPathComponent("spaces-real-e2e").path
            environment["APP_LOG"] = stepWorkRoot.appendingPathComponent("spaces-e2e-app.log").path
            environment["EVENT_LOG"] = stepWorkRoot.appendingPathComponent("events.log").path
            environment["METRICS_LOG"] = stepWorkRoot.appendingPathComponent("metrics.log").path
            environment["DEBUG_LOG"] = stepWorkRoot.appendingPathComponent("debug.log").path
            environment["RESULTS_LOG"] = stepWorkRoot.appendingPathComponent("results.log").path
            environment["RECORDER_LOG"] = stepWorkRoot.appendingPathComponent("recorder.log").path
            environment["SEED_FILE"] = stepWorkRoot.appendingPathComponent("seed.json").path
            environment["SECOND_SEED_FILE"] = stepWorkRoot.appendingPathComponent("seed-2.json").path
            environment["THIRD_SEED_FILE"] = stepWorkRoot.appendingPathComponent("seed-3.json").path
            environment["PROFILE_ARTIFACT_DIR"] = stepWorkRoot.appendingPathComponent("real-system-profiles", isDirectory: true).path
        case "e2e_local_device_api.sh":
            environment["SPACES_E2E_LOCAL_DEVICE_RESULT_JSON"] = stepWorkRoot.appendingPathComponent("result.json").path
            environment["SPACES_E2E_LOCAL_DEVICE_TERMINAL_LATENCY_JSON"] = stepWorkRoot.appendingPathComponent("terminal-latency-summary.json").path
        case "e2e_remote_device_api.sh":
            environment["SPACES_E2E_REMOTE_DEVICE_RESULT_JSON"] = stepWorkRoot.appendingPathComponent("result.json").path
            environment["SPACES_E2E_REMOTE_DEVICE_TERMINAL_LATENCY_JSON"] = stepWorkRoot.appendingPathComponent("terminal-latency-summary.json").path
        case "e2e_remote_terminal_latency_compare.sh":
            environment["SPACES_E2E_REMOTE_TERMINAL_COMPARE_SUMMARY_JSON"] =
                stepWorkRoot.appendingPathComponent("remote-terminal-latency-compare-summary.json").path
        case "profile_device_api.sh": environment["METRICS_PATH"] = stepWorkRoot.appendingPathComponent("metrics.json").path
        case "run_mobile_terminal_demo.sh":
            environment["SPACES_MOBILE_DEMO_ROOT_PARENT"] = stepWorkRoot.appendingPathComponent("mobile-demo", isDirectory: true).path
            environment["SPACES_MOBILE_DEMO_KEEP_ROOT"] = "1"
        default: break
        }
        return environment
    }

    private func collectArtifacts(searchRoot: URL?, stepIndex: Int, stepName: String) -> [E2EArtifactReport] {
        guard let searchRoot, fileManager.fileExists(atPath: searchRoot.path) else { return [] }
        var artifacts: [E2EArtifactReport] = []
        guard let enumerator = fileManager.enumerator(at: searchRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }

        for case let source as URL in enumerator {
            guard shouldCollectArtifact(source) else { continue }
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = relativePath(from: searchRoot, to: source)
            let destination = uniqueArtifactDestination(stepIndex: stepIndex, stepName: stepName, relativePath: relative)
            do {
                try fileManager.copyItem(at: source, to: destination)
                artifacts.append(
                    E2EArtifactReport(
                        sourcePath: source, sourceName: source.lastPathComponent, reportPath: destination, kind: artifactKind(for: source)))
            } catch { fputs("[e2e] Failed to collect artifact \(source.path): \(error)\n", stderr) }
        }
        return artifacts.sorted { $0.reportPath.path < $1.reportPath.path }
    }

    private func uniqueArtifactDestination(stepIndex: Int, stepName: String, relativePath: String) -> URL {
        let baseName = Self.flatArtifactName(stepIndex: stepIndex, stepName: stepName, relativePath: relativePath)
        let base = artifactsDirectory.appendingPathComponent(baseName)
        let ext = base.pathExtension
        let stem = ext.isEmpty ? base.lastPathComponent : String(base.lastPathComponent.dropLast(ext.count + 1))
        var candidate = base
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let fileName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            candidate = artifactsDirectory.appendingPathComponent(fileName)
            suffix += 1
        }
        return candidate
    }

    private func shouldCollectArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if [
            "metrics.json", "summary.txt", "terminal-latency-summary.json", "result.json", "metrics.log", "results.log", "events.log", "debug.log",
            "perf.log", "metrics-history.csv", "report.html",
        ].contains(name) {
            return true
        }
        if ext == "csv" || ext == "html" || ext == "jsonl" || ext == "tsv" { return true }
        if ext == "json", name.hasSuffix("-summary.json") || name.hasSuffix("-result.json") || name.contains("parity") { return true }
        return false
    }

    private func artifactKind(for url: URL) -> E2EArtifactKind {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if ext == "json" { return .json }
        if ext == "jsonl" { return .jsonl }
        if ext == "tsv" || name == "metrics.log" || name == "results.log" { return .tsv }
        if name == "summary.txt" || name == "events.log" || name == "debug.log" || name == "perf.log" { return .text }
        return .other
    }

    private func writeReport() {
        do {
            let reportPath = reportDirectory.appendingPathComponent("summary.md")
            try renderMarkdownReport().write(to: reportPath, atomically: true, encoding: .utf8)
            print("[e2e] Report: \(reportPath.path)")
        } catch { fputs("[e2e] Failed to write report: \(error)\n", stderr) }
    }

    private func renderMarkdownReport() throws -> String {
        var lines: [String] = []
        lines.append("# Spaces E2E Run")
        lines.append("")
        lines.append("| Field | Value |")
        lines.append("| --- | --- |")
        lines.append("| Status | \(succeeded ? "PASS" : "FAIL") |")
        lines.append("| Lane | \(markdown(command.lane.rawValue)) |")
        if let deviceAPITarget = command.deviceAPITarget { lines.append("| Device API target | \(markdown(deviceAPITarget.rawValue)) |") }
        if !command.scenario.isEmpty { lines.append("| Scenarios | \(markdown(command.scenario.joined(separator: ", "))) |") }
        lines.append("| Started | \(markdown(Self.isoDateFormatter.string(from: startedAt))) |")
        lines.append("| Finished | \(markdown(Self.isoDateFormatter.string(from: finishedAt ?? Date()))) |")
        lines.append("| Duration | \(formatDuration((finishedAt ?? Date()).timeIntervalSince(startedAt))) |")
        lines.append("| Report directory | `\(reportDirectory.path)` |")
        if let failureDescription { lines.append("| Failure | \(markdown(failureDescription)) |") }
        lines.append("")
        lines.append("## Steps")
        lines.append("")
        lines.append("| # | Status | Duration | Command | Log | Artifacts |")
        lines.append("| ---: | --- | ---: | --- | --- | ---: |")
        for step in steps {
            let logLink = markdownLink("log", to: step.logPath)
            lines.append(
                "| \(step.index) | \(step.exitCode == 0 ? "PASS" : "FAIL") | \(formatDuration(step.duration)) | \(markdown(step.command)) | \(logLink) | \(step.artifacts.count) |"
            )
        }
        if steps.isEmpty { lines.append("|  |  |  | No commands ran. |  |  |") }
        lines.append("")
        lines.append("## Case Timings")
        lines.append("")
        let caseTimings = collectCaseTimings()
        if caseTimings.isEmpty {
            lines.append("No case timings were collected.")
        } else {
            lines.append("| Status | Duration | Suite | Case | Source | Detail |")
            lines.append("| --- | ---: | --- | --- | --- | --- |")
            for timing in caseTimings.sorted(by: { $0.durationMS > $1.durationMS }) {
                lines.append(
                    "| \(markdown(timing.status)) | \(formatDuration(TimeInterval(timing.durationMS) / 1_000)) | \(markdown(timing.suite)) | \(markdown(timing.name)) | \(markdown(timing.source)) | \(markdown(timing.detail)) |"
                )
            }
        }
        lines.append("")
        lines.append("## Metrics")
        lines.append("")
        var renderedMetric = false
        for step in steps {
            let metricArtifacts = step.artifacts.filter { $0.kind != .other }
            guard !metricArtifacts.isEmpty else { continue }
            renderedMetric = true
            lines.append("### \(step.index). \(markdown(step.command))")
            lines.append("")
            for artifact in metricArtifacts {
                lines.append("#### \(markdown(relativePath(from: artifactsDirectory, to: artifact.reportPath)))")
                lines.append("")
                lines.append(markdownLink("artifact", to: artifact.reportPath))
                lines.append("")
                lines.append(try renderArtifact(artifact))
                lines.append("")
            }
        }
        if !renderedMetric {
            lines.append("No metric artifacts were produced.")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func renderArtifact(_ artifact: E2EArtifactReport) throws -> String {
        switch artifact.kind {
        case .json: return try renderJSONArtifact(artifact.reportPath)
        case .jsonl:
            let lineCount = try countLines(in: artifact.reportPath)
            return "Raw JSONL performance log: \(lineCount) lines, \(formatBytes(fileSize(artifact.reportPath)))."
        case .tsv: return try renderTSVArtifact(artifact)
        case .text: return try renderTextArtifact(artifact.reportPath)
        case .other: return "Artifact: \(formatBytes(fileSize(artifact.reportPath)))."
        }
    }

    private func renderJSONArtifact(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return "_Empty JSON artifact._" }
        let value = try JSONSerialization.jsonObject(with: data)
        let flattened = flattenJSON(value)
        guard !flattened.isEmpty else { return "_No scalar metrics found._" }
        return markdownTable(headers: ["Metric", "Value"], rows: flattened)
    }

    private func renderTSVArtifact(_ artifact: E2EArtifactReport) throws -> String {
        let url = artifact.reportPath
        let content = try String(contentsOf: url, encoding: .utf8)
        let rows = content.split(whereSeparator: \.isNewline).map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        guard !rows.isEmpty else { return "_Empty TSV artifact._" }
        let headers: [String]
        if artifact.sourceName == "metrics.log" {
            headers = ["Metric", "Value", "Terminal Host", "Workspace Scope"]
        } else if artifact.sourceName == "results.log" {
            headers = ["Status", "Case", "Duration ms", "Detail"]
        } else if artifact.sourceName == "scenario-results.tsv" {
            headers = ["Status", "Target", "Scenario", "Duration ms", "Detail"]
        } else {
            let width = rows.map(\.count).max() ?? 0
            headers = (1...max(width, 1)).map { "Column \($0)" }
        }
        return markdownTable(headers: headers, rows: rows)
    }

    private func renderTextArtifact(_ url: URL) throws -> String {
        let maxInlineBytes = 200_000
        let size = fileSize(url)
        guard size <= maxInlineBytes else { return "Text artifact: \(formatBytes(size))." }
        let content = try String(contentsOf: url, encoding: .utf8)
        return "```text\n\(content)\n```"
    }

    private func collectCaseTimings() -> [E2ECaseTiming] {
        var timings: [E2ECaseTiming] = []
        for step in steps {
            let countBeforeStep = timings.count
            for artifact in step.artifacts { timings += caseTimings(from: artifact, step: step) }
            if timings.count == countBeforeStep, step.command.contains("/Tests/") {
                timings.append(
                    E2ECaseTiming(
                        status: step.exitCode == 0 ? "PASS" : "FAIL", suite: "runner", name: step.command,
                        durationMS: Int((step.duration * 1_000).rounded()), source: "step", detail: ""))
            }
        }
        return timings
    }

    private func caseTimings(from artifact: E2EArtifactReport, step: E2EStepReport) -> [E2ECaseTiming] {
        let name = artifact.sourceName
        do {
            if name == "results.log" { return try appResultTimings(from: artifact) }
            if name == "scenario-results.tsv" { return try scenarioResultTimings(from: artifact) }
            if artifact.kind == .json { return try jsonCaseTimings(from: artifact) }
        } catch { fputs("[e2e] Failed to parse case timings from \(artifact.reportPath.path): \(error)\n", stderr) }
        return []
    }

    private func appResultTimings(from artifact: E2EArtifactReport) throws -> [E2ECaseTiming] {
        let source = relativePath(from: artifactsDirectory, to: artifact.reportPath)
        return try String(contentsOf: artifact.reportPath, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { line -> E2ECaseTiming? in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 4, let durationMS = Int(columns[2]) else { return nil }
            return E2ECaseTiming(status: columns[0], suite: "app", name: columns[1], durationMS: durationMS, source: source, detail: columns[3])
        }
    }

    private func scenarioResultTimings(from artifact: E2EArtifactReport) throws -> [E2ECaseTiming] {
        let source = relativePath(from: artifactsDirectory, to: artifact.reportPath)
        return try String(contentsOf: artifact.reportPath, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { line -> E2ECaseTiming? in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 5, let durationMS = Int(columns[3]) else { return nil }
            return E2ECaseTiming(
                status: columns[0], suite: "mobile:\(columns[1])", name: columns[2], durationMS: durationMS, source: source, detail: columns[4])
        }
    }

    private func jsonCaseTimings(from artifact: E2EArtifactReport) throws -> [E2ECaseTiming] {
        let data = try Data(contentsOf: artifact.reportPath)
        guard !data.isEmpty else { return [] }
        let source = relativePath(from: artifactsDirectory, to: artifact.reportPath)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let scenarios = object["scenarios"] as? [String: Any] {
            return scenarios.compactMap { scenarioName, value -> E2ECaseTiming? in
                guard let scenario = value as? [String: Any], let durationMS = durationMilliseconds(scenario["duration_ms"]) else { return nil }
                return E2ECaseTiming(
                    status: "PASS", suite: "latency", name: scenarioName, durationMS: Int(durationMS.rounded()), source: source, detail: "")
            }
        }
        if let scenarioName = object["scenario"] as? String, let durationMS = durationMilliseconds(object["duration_ms"]) {
            return [
                E2ECaseTiming(status: "PASS", suite: "profile", name: scenarioName, durationMS: Int(durationMS.rounded()), source: source, detail: "")
            ]
        }
        return []
    }

    private func durationMilliseconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private mutating func cleanupRunRoot() {
        if command.keepRoot || !succeeded {
            fputs("Preserved E2E runner root: \(runRoot.path)\n", stderr)
            return
        }
        try? fileManager.removeItem(at: runRoot)
    }

    private static func resolveRepositoryRoot(startingAt url: URL, fileManager: FileManager) throws -> URL {
        var candidate = url
        while true {
            let package = candidate.appendingPathComponent("apps/macos/Package.swift").path
            if fileManager.fileExists(atPath: package) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw E2ERunnerError("Could not find repository root from \(url.path). Run from the Spaces checkout.")
            }
            candidate = parent
        }
    }

    private static func createRunRoot(fileManager: FileManager) throws -> URL {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = parent.appendingPathComponent("spaces-e2e.\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("tmp", isDirectory: true), withIntermediateDirectories: true)
        return root
    }

    private static func resolveSpacese2ePath(argv0: String?, currentDirectory: URL, macOSDirectory: URL) -> String {
        guard let argv0, !argv0.isEmpty else { return macOSDirectory.appendingPathComponent(".build/debug/spacese2e").path }
        if argv0.hasPrefix("/") { return URL(fileURLWithPath: argv0).standardizedFileURL.path }
        if argv0.contains("/") { return URL(fileURLWithPath: argv0, relativeTo: currentDirectory).standardizedFileURL.path }
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(argv0)
        }
        if let match = pathCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return match.standardizedFileURL.path
        }
        return macOSDirectory.appendingPathComponent(".build/debug/spacese2e").path
    }

    private static func createReportDirectory(rootDirectory: URL, lane: E2ELane, fileManager: FileManager) throws -> URL {
        let reportRoot = rootDirectory.appendingPathComponent("apps/macos/.artifacts/e2e-runs", isDirectory: true)
        try fileManager.createDirectory(at: reportRoot, withIntermediateDirectories: true)
        let timestamp = reportTimestamp()
        let baseName = "\(timestamp)-\(slug(lane.rawValue))"
        var candidate = reportRoot.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = reportRoot.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private static func reportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // Cached because ISO8601DateFormatter construction is expensive; ISO8601DateFormatter is
    // documented thread-safe so one shared instance is safe to reuse.
    nonisolated(unsafe) private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func stepPrefix(_ index: Int) -> String { String(format: "%03d", index) }

    /// Maximum slug length. Slugs name single path components (`steps/<NNN>-<slug>`, `<NNN>-<slug>.log`);
    /// batching many scenarios into one runScript call (e.g. the exhaustive mobile lane) can otherwise
    /// push the component past the filesystem's 255-byte per-name limit, and creating the child `work`/`tmp`
    /// directories then fails with "the file name 'work' is invalid".
    private static let maxSlugLength = 120

    private static func slug(_ value: String) -> String {
        let slug = value.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(
            in: CharacterSet(charactersIn: "-"))
        let capped = slug.count > maxSlugLength ? String(slug.prefix(maxSlugLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) : slug
        return capped.isEmpty ? "step" : capped
    }

    private static func flatArtifactName(stepIndex: Int, stepName: String, relativePath: String) -> String {
        let step = "\(stepPrefix(stepIndex))-\(slug(stepName))"
        let path = relativePath.replacingOccurrences(of: "/", with: "-").replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return path.isEmpty ? step : "\(step)-\(path)"
    }

    private func shellCommand(executable: String, arguments: [String]) -> String { ([executable] + arguments).map(shellQuote).joined(separator: " ") }

    private func shellQuote(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func relativePath(from base: URL, to child: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(basePath + "/") else { return child.lastPathComponent }
        return String(childPath.dropFirst(basePath.count + 1))
    }

    private func markdownLink(_ label: String, to url: URL) -> String {
        "[\(markdown(label))](\(markdown(relativePath(from: reportDirectory, to: url))))"
    }

    private func markdown(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 1 { return "\(Int((interval * 1_000).rounded()))ms" }
        if interval < 60 { return String(format: "%.1fs", interval) }
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return "\(minutes)m \(seconds)s"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1_024
        if kb < 1_024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1_024
        if mb < 1_024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1_024)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        return size ?? 0
    }

    private func countLines(in url: URL) throws -> Int {
        let content = try String(contentsOf: url, encoding: .utf8)
        guard !content.isEmpty else { return 0 }
        return content.split(whereSeparator: \.isNewline).count
    }

    private func markdownTable(headers: [String], rows: [(String, String)]) -> String {
        markdownTable(headers: headers, rows: rows.map { [$0.0, $0.1] })
    }

    private func markdownTable(headers: [String], rows: [[String]]) -> String {
        let width = max(headers.count, rows.map(\.count).max() ?? 0)
        let paddedHeaders = headers + Array(repeating: "", count: max(0, width - headers.count))
        var lines = [
            "| \(paddedHeaders.map(markdown).joined(separator: " | ")) |", "| \(Array(repeating: "---", count: width).joined(separator: " | ")) |",
        ]
        for row in rows {
            let padded = row + Array(repeating: "", count: max(0, width - row.count))
            lines.append("| \(padded.prefix(width).map(markdown).joined(separator: " | ")) |")
        }
        return lines.joined(separator: "\n")
    }

    private func flattenJSON(_ value: Any, prefix: String = "") -> [(String, String)] {
        if let object = value as? [String: Any] {
            return object.keys.sorted().flatMap { key in
                let nextPrefix = prefix.isEmpty ? key : "\(prefix).\(key)"
                return flattenJSON(object[key] as Any, prefix: nextPrefix)
            }
        }
        if let array = value as? [Any] { return array.enumerated().flatMap { index, item in flattenJSON(item, prefix: "\(prefix)[\(index)]") } }
        return [(prefix.isEmpty ? "value" : prefix, jsonScalar(value))]
    }

    private func jsonScalar(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject([value]), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        return String(describing: value)
    }
}

private struct E2EStepReport {
    let index: Int
    let command: String
    let startedAt: Date
    let finishedAt: Date
    let exitCode: Int32
    let logPath: URL
    let artifacts: [E2EArtifactReport]

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

private struct E2EArtifactReport {
    let sourcePath: URL
    let sourceName: String
    let reportPath: URL
    let kind: E2EArtifactKind
}

private struct E2ECaseTiming {
    let status: String
    let suite: String
    let name: String
    let durationMS: Int
    let source: String
    let detail: String
}

private enum E2EArtifactKind {
    case json
    case jsonl
    case tsv
    case text
    case other
}

private struct E2ERunnerError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}

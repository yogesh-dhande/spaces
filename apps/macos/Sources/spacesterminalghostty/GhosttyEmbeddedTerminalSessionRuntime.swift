import AppKit
import Foundation
import GhosttyKit
import spacesterminalcore

@MainActor private final class GhosttyEmbeddedHostView: NSView {}

public final class GhosttyEmbeddedTerminalSessionRuntime: TerminalSessionBackendRuntime, @unchecked Sendable {
    public let backendKind: TerminalSessionBackendKind = .ghosttyEmbedded
    public let launchConfiguration: TerminalSessionLaunchConfiguration
    public let paths: TerminalSessionPaths

    private let now: @Sendable () -> String
    private let controlQueue: DispatchQueue
    private let outputQueue: DispatchQueue

    private var hiddenWindow: NSWindow?
    private var hostView: GhosttyEmbeddedHostView?
    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var surface: ghostty_surface_t?
    private var controlServer: TerminalControlServer?
    private var outputHandle: FileHandle?
    private var stateTimer: Timer?
    private var exitCode: Int32 = 0
    private var didStop = false
    private var lastKnownChildPID: Int32?

    public init(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        self.now = now
        controlQueue = DispatchQueue(label: "spaces.terminal.ghostty.control.\(launchConfiguration.sessionID)")
        outputQueue = DispatchQueue(label: "spaces.terminal.ghostty.output.\(launchConfiguration.sessionID)")
    }

    public func run() throws -> Never { try MainActor.assumeIsolated { try runOnMain() } }

    @MainActor private func runOnMain() throws -> Never {
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
        FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
        outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
        try outputHandle?.seekToEnd()

        let resourcesPath = try resolvedResourcesPath()
        try Self.initializeGhosttyIfNeeded(resourcesPath: resourcesPath)
        let config = try loadConfig()
        self.config = config

        let app = try createGhosttyApp(config: config)
        self.app = app

        let surface = try createSurface(app: app)
        self.surface = surface
        ghostty_surface_set_data_callback(surface, Self.surfaceDataCallback, Unmanaged.passUnretained(self).toOpaque())

        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: observedChildPID(),
                state: .running, updatedAt: now()), paths: paths)

        try startControlServer()
        startStateTimer()

        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.run()

        cleanup()
        exit(exitCode)
    }

    private func resolvedResourcesPath() throws -> String {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        switch availability {
        case .available(let paths):
            if let resourcesPath = paths.resourcesDirectoryPath { return resourcesPath }
            throw GhosttyEmbeddedTerminalSessionRuntimeError.missingResources
        case .unavailable(let reason): throw GhosttyEmbeddedTerminalSessionRuntimeError.configuration(reason)
        }
    }

    @MainActor private static var didInitializeGhostty = false

    @MainActor private static func initializeGhosttyIfNeeded(resourcesPath: String) throws {
        if !didInitializeGhostty {
            setenv("GHOSTTY_RESOURCES_DIR", resourcesPath, 1)
            let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
            guard result == GHOSTTY_SUCCESS else { throw GhosttyEmbeddedTerminalSessionRuntimeError.initializationFailed(Int(result)) }
            didInitializeGhostty = true
            return
        }

        setenv("GHOSTTY_RESOURCES_DIR", resourcesPath, 1)
    }

    private func loadConfig() throws -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { throw GhosttyEmbeddedTerminalSessionRuntimeError.configuration("ghostty_config_new failed") }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        return config
    }

    private func createGhosttyApp(config: ghostty_config_t?) throws -> ghostty_app_t? {
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyEmbeddedTerminalSessionRuntime>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { runtime.tick() }
        }
        runtimeConfig.action_cb = { _, _, _ in true }
        runtimeConfig.read_clipboard_cb = { _, _, _ in false }
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.write_clipboard_cb = { _, _, _, _, _ in }
        runtimeConfig.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyEmbeddedTerminalSessionRuntime>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { runtime.handleSurfaceClosed() }
        }

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            throw GhosttyEmbeddedTerminalSessionRuntimeError.configuration("ghostty_app_new failed")
        }

        ghostty_app_set_color_scheme(app, GHOSTTY_COLOR_SCHEME_DARK)
        return app
    }

    @MainActor private func createSurface(app: ghostty_app_t?) throws -> ghostty_surface_t? {
        guard let app else { throw GhosttyEmbeddedTerminalSessionRuntimeError.configuration("ghostty app missing") }

        let contentRect = NSRect(x: 0, y: 0, width: 960, height: 640)
        let window = NSWindow(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let hostView = GhosttyEmbeddedHostView(frame: contentRect)
        hostView.wantsLayer = true
        window.contentView = hostView
        window.orderOut(nil)
        hiddenWindow = window
        self.hostView = hostView

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(hostView).toOpaque()))
        surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        surfaceConfig.scale_factor = 2.0
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        var allocatedStrings: [UnsafeMutablePointer<CChar>] = []
        defer { for pointer in allocatedStrings { free(pointer) } }

        if let command = launchConfiguration.command, let wrapped = strdup(Self.loginShellCommand(shell: launchConfiguration.shell, command: command))
        {
            allocatedStrings.append(wrapped)
            surfaceConfig.command = UnsafePointer(wrapped)
            surfaceConfig.wait_after_command = false
        }

        let workingDirectory = launchConfiguration.workingDirectory
        let surface: ghostty_surface_t? = workingDirectory.withCString { cwd in
            surfaceConfig.working_directory = cwd
            return ghostty_surface_new(app, &surfaceConfig)
        }

        guard let surface else { throw GhosttyEmbeddedTerminalSessionRuntimeError.configuration("ghostty_surface_new failed") }

        ghostty_surface_set_content_scale(surface, 2.0, 2.0)
        ghostty_surface_set_focus(surface, false)
        ghostty_surface_set_occlusion(surface, true)
        ghostty_surface_set_size(surface, 960, 640)
        ghostty_surface_refresh(surface)
        return surface
    }

    private func startControlServer() throws {
        let controlServer = TerminalControlServer(socketPath: paths.controlSocketPath, queue: controlQueue) { [weak self] request in
            guard let self else { return TerminalControlResponse(ok: false, message: "Terminal session is shutting down.") }
            switch request.command {
            case "send":
                guard let text = request.text else { return TerminalControlResponse(ok: false, message: "Missing text payload.") }
                let payload = text + (request.appendNewline ? "\n" : "")
                return self.sendRawBytes(Data(payload.utf8), successMessage: "Sent input.")
            case "key":
                guard let key = request.key, let bytes = TerminalKeyInput.bytes(for: key) else {
                    return TerminalControlResponse(ok: false, message: "Unsupported terminal key.")
                }
                return self.sendRawBytes(Data(bytes), successMessage: "Sent key.")
            default: return TerminalControlResponse(ok: false, message: "Unsupported terminal command '\(request.command)'.")
            }
        }
        try controlServer.start()
        self.controlServer = controlServer
    }

    private func sendRawBytes(_ data: Data, successMessage: String) -> TerminalControlResponse {
        guard !data.isEmpty else { return TerminalControlResponse(ok: true, message: successMessage) }
        return DispatchQueue.main.sync { [weak self] in
            guard let self, let surface = self.surface else { return TerminalControlResponse(ok: false, message: "Terminal surface is not ready.") }
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_surface_send_input_raw(surface, baseAddress, UInt(data.count))
            }
            return TerminalControlResponse(ok: true, message: successMessage)
        }
    }

    private nonisolated static let surfaceDataCallback: ghostty_surface_data_cb = { userdata, bytes, len in
        guard let userdata, let bytes, len > 0 else { return }
        let runtime = Unmanaged<GhosttyEmbeddedTerminalSessionRuntime>.fromOpaque(userdata).takeUnretainedValue()
        runtime.appendOutput(bytes: bytes, len: len)
    }

    private func appendOutput(bytes: UnsafePointer<UInt8>, len: uintptr_t) {
        let data = Data(bytes: bytes, count: Int(len))
        outputQueue.async { [weak self] in
            guard let self, let outputHandle = self.outputHandle else { return }
            do {
                try outputHandle.write(contentsOf: data)
                try outputHandle.synchronize()
            } catch { fputs("spaces: ghostty output write failed: \(error)\n", stderr) }
        }
    }

    @MainActor private func startStateTimer() {
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshRuntimeState() }
        }
        if let stateTimer { RunLoop.main.add(stateTimer, forMode: .common) }
    }

    @MainActor private func refreshRuntimeState() {
        guard !didStop else { return }
        try? TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: observedChildPID(),
                state: .running, updatedAt: now()), paths: paths)
    }

    @MainActor private func observedChildPID() -> Int32? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        if pid > 0 {
            let intPID = Int32(pid)
            lastKnownChildPID = intPID
            return intPID
        }
        return lastKnownChildPID
    }

    @MainActor private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    @MainActor private func handleSurfaceClosed() {
        guard !didStop else { return }
        didStop = true
        stateTimer?.invalidate()
        stateTimer = nil
        try? TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: observedChildPID(),
                state: .exited, updatedAt: now(), exitedAt: now()), paths: paths)
        exitCode = 0
        controlServer?.stop()
        NSApplication.shared.stop(nil)
    }

    @MainActor private func cleanup() {
        stateTimer?.invalidate()
        stateTimer = nil
        controlServer?.stop()
        controlServer = nil
        ghostty_surface_set_data_callback(surface, nil, nil)
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        if let app { ghostty_app_free(app) }
        self.app = nil
        if let config { ghostty_config_free(config) }
        self.config = nil
        try? outputHandle?.close()
        outputHandle = nil
        hiddenWindow?.orderOut(nil)
        hiddenWindow = nil
        hostView = nil
    }

    private static func loginShellCommand(shell: String, command: String) -> String {
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "\(shell) -l -c '\(escaped)'"
    }
}

public enum GhosttyEmbeddedTerminalSessionRuntimeError: LocalizedError {
    case configuration(String)
    case initializationFailed(Int)
    case missingResources

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): message
        case .initializationFailed(let code): "ghostty_init failed with status \(code)"
        case .missingResources: "Ghostty runtime resources are not configured."
        }
    }
}

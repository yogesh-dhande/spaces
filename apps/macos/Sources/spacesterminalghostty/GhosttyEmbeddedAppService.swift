import AppKit
import Foundation
import GhosttyKit

@MainActor public final class GhosttyEmbeddedAppService {
    public static let shared = GhosttyEmbeddedAppService()

    public private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var initialized = false
    private var surfaceActionHandlers: [UInt: @MainActor (GhosttyActionEvent) -> Void] = [:]

    private init() {}

    public func startIfNeeded() throws {
        guard app == nil else { return }

        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        let paths: GhosttyEmbeddedPaths
        switch availability {
        case .available(let resolvedPaths): paths = resolvedPaths
        case .unavailable(let reason): throw GhosttyEmbeddedAppServiceError.configuration(reason)
        }

        if let resourcesPath = paths.resourcesDirectoryPath {
            setenv("GHOSTTY_RESOURCES_DIR", resourcesPath, 1)
        } else {
            throw GhosttyEmbeddedAppServiceError.configuration("Ghostty runtime resources are not configured.")
        }

        if !initialized {
            let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
            guard result == GHOSTTY_SUCCESS else { throw GhosttyEmbeddedAppServiceError.initializationFailed(Int(result)) }
            initialized = true
        }

        guard let config = ghostty_config_new() else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty_config_new failed") }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { _ in DispatchQueue.main.async { GhosttyEmbeddedAppService.shared.tick() } }
        runtimeConfig.action_cb = { _, target, action in
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
            guard let event = GhosttyActionEventParser.parse(action) else { return true }
            GhosttyEmbeddedAppService.shared.handleAction(event, target: target)
            return true
        }
        runtimeConfig.read_clipboard_cb = { userdata, _, state in GhosttyClipboardBridge.readClipboard(userdata: userdata, state: state) }
        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            GhosttyClipboardBridge.confirmReadClipboard(userdata: userdata, content: content, state: state)
        }
        runtimeConfig.write_clipboard_cb = { _, _, content, len, _ in GhosttyClipboardBridge.writeClipboard(content: content, len: UInt(len)) }
        runtimeConfig.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let view = Unmanaged<GhosttyEmbeddedTerminalView>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { view.handleSurfaceClosed() } }
        }

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            throw GhosttyEmbeddedAppServiceError.configuration("ghostty_app_new failed")
        }

        ghostty_app_set_color_scheme(app, Self.currentColorScheme())
        self.config = config
        self.app = app
    }

    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    public func registerActionHandler(for surface: ghostty_surface_t, handler: @escaping @MainActor (GhosttyActionEvent) -> Void) {
        surfaceActionHandlers[surfaceKey(surface)] = handler
    }

    public func unregisterActionHandler(for surface: ghostty_surface_t?) {
        guard let surface else { return }
        surfaceActionHandlers.removeValue(forKey: surfaceKey(surface))
    }

    private func handleAction(_ event: GhosttyActionEvent, target: ghostty_target_s) {
        let key = surfaceKey(target.target.surface)
        guard let handler = surfaceActionHandlers[key] else { return }
        Task { @MainActor in handler(event) }
    }

    private func surfaceKey(_ surface: ghostty_surface_t) -> UInt { UInt(bitPattern: surface) }

    private static func currentColorScheme() -> ghostty_color_scheme_e {
        let bestMatch = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return bestMatch == .darkAqua ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }
}

public enum GhosttyEmbeddedAppServiceError: LocalizedError {
    case configuration(String)
    case initializationFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): message
        case .initializationFailed(let status): "ghostty_init failed with status \(status)"
        }
    }
}

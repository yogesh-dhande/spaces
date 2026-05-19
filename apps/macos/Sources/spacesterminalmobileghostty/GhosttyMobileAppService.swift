import Foundation

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    @MainActor public final class GhosttyMobileAppService {
        public static let shared = GhosttyMobileAppService()

        public private(set) var app: ghostty_app_t?

        private var config: ghostty_config_t?
        private var initialized = false

        private init() {}

        public func startIfNeeded() throws {
            guard app == nil else { return }

            let resourcesPath = try resolveResourcesPath()
            setenv("GHOSTTY_RESOURCES_DIR", resourcesPath, 1)
            configureProcessEnvironment()

            if !initialized {
                let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
                guard result == GHOSTTY_SUCCESS else { throw GhosttyMobileAppServiceError.initializationFailed(Int(result)) }
                initialized = true
            }

            guard let config else {
                guard let newConfig = ghostty_config_new() else { throw GhosttyMobileAppServiceError.configuration("ghostty_config_new failed") }
                ghostty_config_load_default_files(newConfig)
                ghostty_config_finalize(newConfig)
                self.config = newConfig
                try startApp(config: newConfig)
                return
            }

            try startApp(config: config)
        }

        public func tick() {
            guard let app else { return }
            ghostty_app_tick(app)
        }

        private func startApp(config: ghostty_config_t) throws {
            var runtimeConfig = Self.makeRuntimeConfig()

            guard let app = ghostty_app_new(&runtimeConfig, config) else {
                throw GhosttyMobileAppServiceError.configuration("ghostty_app_new failed")
            }

            ghostty_app_set_color_scheme(app, Self.currentColorScheme())
            self.app = app
        }

        static func makeRuntimeConfig() -> ghostty_runtime_config_s {
            var runtimeConfig = ghostty_runtime_config_s()
            runtimeConfig.userdata = nil
            runtimeConfig.supports_selection_clipboard = false
            runtimeConfig.wakeup_cb = { _ in Task { @MainActor in GhosttyMobileAppService.shared.tick() } }
            runtimeConfig.action_cb = { _, _, _ in true }
            runtimeConfig.read_clipboard_cb = { _, _, _ in false }
            runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
            runtimeConfig.write_clipboard_cb = { _, _, content, len, _ in
                guard let content, len > 0 else { return }
                let data = Data(bytes: content, count: Int(len))
                UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
            }
            runtimeConfig.close_surface_cb = { _, _ in }
            return runtimeConfig
        }

        private func resolveResourcesPath() throws -> String {
            let environment = ProcessInfo.processInfo.environment
            if let override = environment["SPACES_GHOSTTY_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty,
                FileManager.default.fileExists(atPath: override)
            {
                return override
            }

            let fileURL = URL(fileURLWithPath: #filePath)
            let macOSRoot = fileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let candidate = macOSRoot.appendingPathComponent(".local/ghosttykit/Resources/ghostty", isDirectory: true).path
            guard FileManager.default.fileExists(atPath: candidate) else {
                throw GhosttyMobileAppServiceError.configuration("Ghostty runtime resources are not configured for iOS.")
            }
            return candidate
        }

        private static func currentColorScheme() -> ghostty_color_scheme_e {
            UIScreen.main.traitCollection.userInterfaceStyle == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        }

        private func configureProcessEnvironment() {
            let environment = ProcessInfo.processInfo.environment
            if environment["HOME"]?.isEmpty != false { setenv("HOME", NSHomeDirectory(), 0) }
            if environment["SHELL"]?.isEmpty != false { setenv("SHELL", "/bin/sh", 0) }
        }
    }

    public enum GhosttyMobileAppServiceError: LocalizedError {
        case configuration(String)
        case initializationFailed(Int)

        public var errorDescription: String? {
            switch self {
            case .configuration(let message): return message
            case .initializationFailed(let status): return "ghostty_init failed with status \(status)"
            }
        }
    }
#endif

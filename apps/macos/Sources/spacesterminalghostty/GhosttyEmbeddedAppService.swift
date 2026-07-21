import Foundation

#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import GhosttyKit
    import spacesterminalcore

    @MainActor public final class GhosttyEmbeddedAppService {
        public static let shared = GhosttyEmbeddedAppService()

        public private(set) var app: ghostty_app_t?
        private var config: ghostty_config_t?
        private var initialized = false
        private var surfaceActionHandlers: [UInt: @MainActor (GhosttyActionEvent) -> Void] = [:]
        private var liveSurfaces: [UInt: ghostty_surface_t] = [:]

        /// The light/dark scheme currently pushed into the app and every live surface.
        ///
        /// Seeded from the same NSApp-less computation `startIfNeeded` uses, so it matches the scheme
        /// new surfaces inherit at creation (light in the daemon, where there is no NSApp). Callers read
        /// it to avoid redundant re-themes and to know whether an `applyColorScheme(_:)` actually changed
        /// anything.
        public private(set) var currentAppearance: ThemeAppearance =
            GhosttyEmbeddedAppService.currentColorScheme() == GHOSTTY_COLOR_SCHEME_DARK ? .dark : .light

        private init() {}

        public func startIfNeeded() throws {
            guard app == nil else { return }

            let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
            let paths: GhosttyEmbeddedPaths
            switch availability {
            case .available(let resolvedPaths): paths = resolvedPaths
            case .unavailable(let reason): throw GhosttyEmbeddedAppServiceError.configuration(reason)
            }

            setenv("GHOSTTY_RESOURCES_DIR", paths.resourcesDirectoryPath, 1)

            if !initialized {
                let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
                guard result == GHOSTTY_SUCCESS else { throw GhosttyEmbeddedAppServiceError.initializationFailed(Int(result)) }
                initialized = true
            }

            let config = try Self.makeThemeConfiguration()

            var runtimeConfig = ghostty_runtime_config_s()
            runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
            runtimeConfig.supports_selection_clipboard = true
            runtimeConfig.wakeup_cb = { _ in Task { @MainActor in GhosttyEmbeddedAppService.shared.tick() } }
            runtimeConfig.action_cb = { _, target, action in
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
                guard let event = GhosttyActionEventParser.parse(action) else { return true }
                let surfaceKey = UInt(bitPattern: target.target.surface)
                Task { @MainActor in GhosttyEmbeddedAppService.shared.handleAction(event, surfaceKey: surfaceKey) }
                return true
            }
            runtimeConfig.read_clipboard_cb = { userdata, _, state in GhosttyClipboardBridge.readClipboard(userdata: userdata, state: state) }
            runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
                GhosttyClipboardBridge.confirmReadClipboard(userdata: userdata, content: content, state: state)
            }
            runtimeConfig.write_clipboard_cb = { _, _, content, len, _ in GhosttyClipboardBridge.writeClipboard(content: content, len: UInt(len)) }
            runtimeConfig.close_surface_cb = { userdata, _ in
                guard let userdata else { return }
                let surfaceUserData = Unmanaged<GhosttyEmbeddedSurfaceUserData>.fromOpaque(userdata).takeUnretainedValue()
                Task { @MainActor in surfaceUserData.handleClose() }
            }

            guard let app = ghostty_app_new(&runtimeConfig, config) else {
                ghostty_config_free(config)
                throw GhosttyEmbeddedAppServiceError.configuration("ghostty_app_new failed")
            }

            // The generated config carries light: and dark: theme variants; the scheme pushed
            // here selects the variant new surfaces inherit at creation. A later OS appearance
            // change re-themes existing surfaces live via applyColorScheme(_:).
            ghostty_app_set_color_scheme(app, Self.currentColorScheme())
            self.config = config
            self.app = app
        }

        /// Generates the Spaces theme config files for the active profile and loads them into a fresh
        /// finalized Ghostty config handle. Embedded terminals load ONLY this generated config — never
        /// the user's `~/.config/ghostty` files — so the look is owned by the active Spaces theme.
        private static func makeThemeConfiguration() throws -> ghostty_config_t {
            guard let config = ghostty_config_new() else { throw GhosttyEmbeddedAppServiceError.configuration("ghostty_config_new failed") }
            let configRoot = URL(fileURLWithPath: try SpacesProfile.current().rootDirectory, isDirectory: true).appendingPathComponent(
                "ghostty", isDirectory: true)
            try GhosttyThemeConfigGenerator.writeConfiguration(theme: ActiveTheme.descriptor, configRootDirectory: configRoot).withCString { path in
                ghostty_config_load_file(config, path)
            }
            ghostty_config_finalize(config)
            return config
        }

        /// Regenerates the Spaces theme config for the active profile and re-points the running app at
        /// it, replacing the previously loaded config handle.
        ///
        /// The generated root config references the light/dark theme files by absolute path, so
        /// `applyColorScheme(_:)`'s `ghostty_app_update_config` re-reads them from disk. Tests run each
        /// case under a throwaway profile root that is deleted on teardown, so the config handle a
        /// process-wide app service loaded during an earlier test can reference since-deleted files.
        /// Calling this re-anchors the config to the current test's live files. Not used in the
        /// single-profile daemon, where the profile root persists for the app service's lifetime.
        func reloadThemeConfigurationForTesting() throws {
            guard let app else { return }
            let newConfig = try Self.makeThemeConfiguration()
            ghostty_app_update_config(app, newConfig)
            if let previousConfig = config { ghostty_config_free(previousConfig) }
            config = newConfig
            ghostty_app_tick(app)
        }

        public func tick() {
            guard let app else { return }
            ghostty_app_tick(app)
        }

        public func registerActionHandler(for surface: ghostty_surface_t, handler: @escaping @MainActor (GhosttyActionEvent) -> Void) {
            let key = surfaceKey(surface)
            surfaceActionHandlers[key] = handler
            liveSurfaces[key] = surface
        }

        public func unregisterActionHandler(for surface: ghostty_surface_t?) {
            guard let surface else { return }
            let key = surfaceKey(surface)
            surfaceActionHandlers.removeValue(forKey: key)
            liveSurfaces.removeValue(forKey: key)
        }

        /// Re-themes every live surface to the given appearance and makes later surfaces inherit it.
        ///
        /// Each surface keeps its own light/dark conditional state, so flipping the app scheme alone
        /// does not re-theme open terminals. The recipe: push the scheme into every live surface and
        /// the app, then replay the SAME stored config so each surface re-derives its colors from its
        /// now-updated conditional state. The config file contents are unchanged (the variant is
        /// conditional-state-driven), and the host retains ownership of the config handle, so it is
        /// reused and never freed here. The io thread applies the colors asynchronously on the tick.
        ///
        /// A no-op when the requested appearance already matches `currentAppearance`, so repeated
        /// attaches on the same scheme do not churn the surfaces. Returns whether a re-theme was
        /// applied; callers use this to decide whether to force a full render rebroadcast.
        @discardableResult public func applyColorScheme(_ appearance: ThemeAppearance) -> Bool {
            guard appearance != currentAppearance else { return false }
            guard let app, let config else { return false }
            let scheme: ghostty_color_scheme_e = appearance == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            for surface in liveSurfaces.values { ghostty_surface_set_color_scheme(surface, scheme) }
            ghostty_app_set_color_scheme(app, scheme)
            ghostty_app_update_config(app, config)
            ghostty_app_tick(app)
            currentAppearance = appearance
            return true
        }

        private func handleAction(_ event: GhosttyActionEvent, surfaceKey: UInt) {
            guard let handler = surfaceActionHandlers[surfaceKey] else { return }
            Task { @MainActor in handler(event) }
        }

        private func surfaceKey(_ surface: ghostty_surface_t) -> UInt { UInt(bitPattern: surface) }

        private static func currentColorScheme() -> ghostty_color_scheme_e {
            let bestMatch = (NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua))?.bestMatch(from: [.darkAqua, .aqua])
            return bestMatch == .darkAqua ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        }
    }
#endif

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

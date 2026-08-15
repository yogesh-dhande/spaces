#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Dispatch
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    /// Process-global glue shared by the two embedded ghostty app services: the daemon's
    /// `GhosttyEmbeddedAppService` (isolated to the terminal engine actor) and the app-process
    /// `GhosttyMirrorAppService` (`@MainActor`). Each runs `ghostty_app_new` with its own runtime-config
    /// wiring and handler maps; only the truly process-global pieces live here.
    ///
    /// One-live-app-per-process contract: `ghostty_init` consumes `argv` and mutates process-global
    /// runtime state, and exactly one embedded `ghostty_app_t` may be live per process. In production the
    /// daemon never mirrors and the app never runs embedded cores, so each process starts exactly one; in
    /// the shared test process only the daemon-core suites start a live app (the mirror suites build
    /// windowless views whose `ensureMirrorIfNeeded` bails on `window == nil`, so they never call
    /// `startIfNeeded`). `initializeOnce` asserts that contract.
    enum GhosttyProcessAppRuntime {
        /// Which service owns the single live embedded app in this process.
        enum Owner: String { case daemon, mirror }

        private static let lock = NSLock()
        // Guarded by `lock` on every access, so the mutation is serialized despite being process-global.
        private nonisolated(unsafe) static var didInit = false
        private nonisolated(unsafe) static var startingOwner: Owner?

        /// Runs `ghostty_init` at most once per process and records the owning service. A second start by
        /// a *different* owner traps: it would mean both an embedded daemon core and the app mirror tried
        /// to drive ghostty in one process, which the one-app-per-process contract forbids.
        static func initializeOnce(owner: Owner) throws {
            lock.lock()
            defer { lock.unlock() }
            if let startingOwner, startingOwner != owner {
                preconditionFailure(
                    "Only one embedded ghostty app may be live per process; \(startingOwner.rawValue) already started one, \(owner.rawValue) may not")
            }
            startingOwner = owner
            guard !didInit else { return }
            let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
            guard result == GHOSTTY_SUCCESS else { throw GhosttyEmbeddedAppServiceError.initializationFailed(Int(result)) }
            didInit = true
        }

        /// Generates the Spaces theme config files for the active profile and loads them into a fresh
        /// finalized ghostty config handle. Embedded terminals load ONLY this generated config — never the
        /// user's `~/.config/ghostty` files — so the look is owned by the active Spaces theme.
        static func makeThemeConfiguration() throws -> ghostty_config_t {
            let configRoot = URL(fileURLWithPath: try SpacesProfile.current().rootDirectory, isDirectory: true).appendingPathComponent(
                "ghostty", isDirectory: true)
            let configPath = try GhosttyThemeConfigGenerator.writeConfiguration(theme: ActiveTheme.descriptor, configRootDirectory: configRoot)

            // ghostty_config_new allocates and ghostty_config_load_file fully parses the generated
            // config, walking deep into Zig-side parsing/allocation code (the same class of
            // large-stack consumer as `ghostty_session_new_headless`; see the SIGBUS this fixes,
            // diagnosed in GhosttyEmbeddedTerminalSessionDriver.configureNewSession()). Both calls run
            // on a dedicated large-stack thread rather than inline on the engine actor's home thread,
            // which can be a libdispatch workqueue thread with only ~512 KB of stack.
            guard
                let config = try configPath.withCString({ path -> ghostty_config_t? in
                    // Read-only input to the large-stack thread's closure, never touched again by
                    // this thread while it runs (the thread call blocks until the closure returns),
                    // so the concurrent access the compiler cannot verify never happens.
                    nonisolated(unsafe) let pathForCall = path
                    return try runOnDedicatedLargeStackThread { () -> ghostty_config_t? in
                        guard let config = ghostty_config_new() else { return nil }
                        ghostty_config_load_file(config, pathForCall)
                        return config
                    }
                })
            else {
                throw GhosttyEmbeddedAppServiceError.configuration("ghostty_config_new failed")
            }
            ghostty_config_finalize(config)
            return config
        }

        /// The light/dark scheme new surfaces inherit at creation. `NSApp`/`NSAppearance` are main-only,
        /// so this resolves them on the main actor: inline when already on main (the mirror service), and
        /// via the legal engine→main synchronous hop otherwise (the daemon service on the engine actor).
        /// The daemon has no active NSApp appearance (prohibited activation policy), so it yields light.
        static func currentColorScheme() -> ghostty_color_scheme_e {
            func resolveOnMain() -> ghostty_color_scheme_e {
                MainActor.assumeIsolated {
                    let bestMatch = (NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua))?.bestMatch(from: [.darkAqua, .aqua])
                    return bestMatch == .darkAqua ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
                }
            }
            if Thread.isMainThread { return resolveOnMain() }
            return DispatchQueue.main.sync { resolveOnMain() }
        }
    }
#endif

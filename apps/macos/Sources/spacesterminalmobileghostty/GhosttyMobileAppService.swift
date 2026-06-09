import Darwin
import Foundation

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    public enum GhosttyMobileActionEvent: Sendable, Equatable {
        public enum OpenURLKind: Sendable, Equatable {
            case unknown
            case text
            case html

            init(_ kind: ghostty_action_open_url_kind_e) {
                switch kind {
                case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: self = .text
                case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: self = .html
                default: self = .unknown
                }
            }
        }

        case openURL(kind: OpenURLKind, value: String)
        case mouseOverLink(String?)
    }

    enum GhosttyMobileActionEventParser {
        static func parse(_ action: ghostty_action_s) -> GhosttyMobileActionEvent? {
            switch action.tag {
            case GHOSTTY_ACTION_OPEN_URL:
                let openURL = action.action.open_url
                guard let value = string(pointer: openURL.url, count: Int(openURL.len)), !value.isEmpty else { return nil }
                return .openURL(kind: GhosttyMobileActionEvent.OpenURLKind(openURL.kind), value: value)
            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                let link = action.action.mouse_over_link
                guard link.len > 0 else { return .mouseOverLink(nil) }
                return .mouseOverLink(string(pointer: link.url, count: link.len))
            default: return nil
            }
        }

        private static func string(pointer: UnsafePointer<CChar>?, count: Int) -> String? {
            guard let pointer, count > 0 else { return nil }
            let data = Data(bytes: pointer, count: count)
            return String(data: data, encoding: .utf8)
        }
    }

    @MainActor public final class GhosttyMobileAppService {
        public static let shared = GhosttyMobileAppService()

        public private(set) var app: ghostty_app_t?

        private var config: ghostty_config_t?
        private var initialized = false
        private var retainedStandardInputWriteDescriptor: Int32?
        private var surfaceActionHandlers: [UInt: @MainActor (GhosttyMobileActionEvent) -> Void] = [:]

        private init() {}

        deinit { if let retainedStandardInputWriteDescriptor { _ = close(retainedStandardInputWriteDescriptor) } }

        public func startIfNeeded() throws {
            guard app == nil else { return }

            let resourcesPath = try Self.resolveResourcesPath(bundleResourceURL: Bundle.main.resourceURL)
            setenv("GHOSTTY_RESOURCES_DIR", resourcesPath, 1)
            try configureProcessEnvironment()

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

        public func registerActionHandler(for surface: ghostty_surface_t, handler: @escaping @MainActor (GhosttyMobileActionEvent) -> Void) {
            surfaceActionHandlers[surfaceKey(surface)] = handler
        }

        public func unregisterActionHandler(for surface: ghostty_surface_t?) {
            guard let surface else { return }
            surfaceActionHandlers.removeValue(forKey: surfaceKey(surface))
        }

        private func handleAction(_ event: GhosttyMobileActionEvent, surfaceKey: UInt) {
            guard let handler = surfaceActionHandlers[surfaceKey] else { return }
            handler(event)
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
            runtimeConfig.action_cb = { _, target, action in
                guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
                guard let event = GhosttyMobileActionEventParser.parse(action) else { return true }
                let surfaceKey = UInt(bitPattern: target.target.surface)
                if Thread.isMainThread {
                    MainActor.assumeIsolated { GhosttyMobileAppService.shared.handleAction(event, surfaceKey: surfaceKey) }
                } else {
                    Task { @MainActor in GhosttyMobileAppService.shared.handleAction(event, surfaceKey: surfaceKey) }
                }
                return true
            }
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

        private func surfaceKey(_ surface: ghostty_surface_t) -> UInt { UInt(bitPattern: surface) }

        public static func resolveResourcesPath(
            environment: [String: String] = ProcessInfo.processInfo.environment, bundleResourceURL: URL?, fileManager: FileManager = .default,
            sourceFilePath: String = #filePath
        ) throws -> String {
            if let override = environment["SPACES_GHOSTTY_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty,
                fileManager.fileExists(atPath: override)
            {
                return override
            }

            if let bundleResourceURL {
                let bundledCandidate = bundleResourceURL.appendingPathComponent("ghostty", isDirectory: true).path
                if fileManager.fileExists(atPath: bundledCandidate) { return bundledCandidate }
            }

            let fileURL = URL(fileURLWithPath: sourceFilePath)
            let macOSRoot = fileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let candidate = macOSRoot.appendingPathComponent(".local/ghosttykit/Resources/ghostty", isDirectory: true).path
            guard fileManager.fileExists(atPath: candidate) else {
                throw GhosttyMobileAppServiceError.configuration("Ghostty runtime resources are not configured for iOS.")
            }
            return candidate
        }

        private static func currentColorScheme() -> ghostty_color_scheme_e {
            UIScreen.main.traitCollection.userInterfaceStyle == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        }

        struct StandardFileDescriptorRepair { let retainedStandardInputWriteDescriptor: Int32? }

        nonisolated static func repairStandardFileDescriptors(
            isDescriptorValid: (Int32) -> Bool = GhosttyMobileAppService.isDescriptorValid(_:),
            createStandardInputPipe: () -> (read: Int32, write: Int32) = {
                var fileDescriptors: [Int32] = [-1, -1]
                return pipe(&fileDescriptors) == 0 ? (fileDescriptors[0], fileDescriptors[1]) : (-1, -1)
            }, openReadWriteNull: () -> Int32 = { open("/dev/null", O_RDWR) }, duplicateDescriptor: (Int32, Int32) -> Int32 = { dup2($0, $1) },
            closeDescriptor: (Int32) -> Int32 = { close($0) }
        ) throws -> StandardFileDescriptorRepair {
            let missingDescriptors = [STDOUT_FILENO, STDERR_FILENO].filter { !isDescriptorValid($0) }
            if !missingDescriptors.isEmpty {
                let nullDescriptor = openReadWriteNull()
                guard nullDescriptor >= 0 else {
                    let failureCode = errno
                    throw GhosttyMobileAppServiceError.configuration("Unable to open /dev/null while preparing Ghostty stdio (\(failureCode)).")
                }
                defer { if nullDescriptor > STDERR_FILENO { _ = closeDescriptor(nullDescriptor) } }

                for descriptor in missingDescriptors where descriptor != nullDescriptor {
                    guard duplicateDescriptor(nullDescriptor, descriptor) != -1 else {
                        let failureCode = errno
                        throw GhosttyMobileAppServiceError.configuration("Unable to repair Ghostty stdio descriptor \(descriptor) (\(failureCode)).")
                    }
                }
            }

            let standardInputPipe = createStandardInputPipe()
            guard standardInputPipe.read >= 0, standardInputPipe.write >= 0 else {
                let failureCode = errno
                throw GhosttyMobileAppServiceError.configuration("Unable to create a keepalive pipe for Ghostty stdin (\(failureCode)).")
            }

            do {
                guard duplicateDescriptor(standardInputPipe.read, STDIN_FILENO) != -1 else {
                    let failureCode = errno
                    throw GhosttyMobileAppServiceError.configuration("Unable to repair Ghostty stdin descriptor (\(failureCode)).")
                }
            } catch {
                _ = closeDescriptor(standardInputPipe.read)
                _ = closeDescriptor(standardInputPipe.write)
                throw error
            }

            if standardInputPipe.read != STDIN_FILENO { _ = closeDescriptor(standardInputPipe.read) }

            return StandardFileDescriptorRepair(retainedStandardInputWriteDescriptor: standardInputPipe.write)
        }

        nonisolated private static func isDescriptorValid(_ descriptor: Int32) -> Bool {
            if fcntl(descriptor, F_GETFD) != -1 { return true }
            return errno != EBADF
        }

        static func configureGhosttyProcessEnvironment(
            homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            cachesDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first, fileManager: FileManager = .default,
            setEnvironment: (String, String, Int32) -> Int32 = { setenv($0, $1, $2) }
        ) throws {
            let supportRoot = applicationSupportDirectory ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
            let cacheRoot = cachesDirectory ?? homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
            let configDirectory = supportRoot.appendingPathComponent("ghostty/config", isDirectory: true)
            let stateDirectory = supportRoot.appendingPathComponent("ghostty/state", isDirectory: true)
            let cacheDirectory = cacheRoot.appendingPathComponent("ghostty/cache", isDirectory: true)

            try [homeDirectory, configDirectory, stateDirectory, cacheDirectory].forEach {
                try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
            }

            _ = setEnvironment("HOME", homeDirectory.path, 1)
            _ = setEnvironment("SHELL", "/bin/sh", 1)
            _ = setEnvironment("XDG_CONFIG_HOME", configDirectory.path, 1)
            _ = setEnvironment("XDG_STATE_HOME", stateDirectory.path, 1)
            _ = setEnvironment("XDG_CACHE_HOME", cacheDirectory.path, 1)
        }

        private func configureProcessEnvironment() throws {
            try Self.configureGhosttyProcessEnvironment()
            // Simulator stdin can remain guarded even when valid; always swap in a disposable pipe so Ghostty can close and re-open stdio.
            let repairedDescriptors = try Self.repairStandardFileDescriptors()
            if let previousDescriptor = retainedStandardInputWriteDescriptor,
                previousDescriptor != repairedDescriptors.retainedStandardInputWriteDescriptor
            {
                _ = close(previousDescriptor)
            }
            retainedStandardInputWriteDescriptor = repairedDescriptors.retainedStandardInputWriteDescriptor
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

import Foundation

public struct GhosttySDKCapabilityReport: Sendable, Equatable {
    public let headerPath: String
    public let exposesLaunchOwnedSurfaceConfig: Bool
    public let exposesRawInputAPI: Bool
    public let exposesDataCallbackAPI: Bool
    public let exposesCellReadbackAPI: Bool
    public let exposesTTYInspectionAPI: Bool
    public let exposesExternalSessionAttachAPI: Bool

    public init(
        headerPath: String, exposesLaunchOwnedSurfaceConfig: Bool, exposesRawInputAPI: Bool, exposesDataCallbackAPI: Bool,
        exposesCellReadbackAPI: Bool, exposesTTYInspectionAPI: Bool, exposesExternalSessionAttachAPI: Bool
    ) {
        self.headerPath = headerPath
        self.exposesLaunchOwnedSurfaceConfig = exposesLaunchOwnedSurfaceConfig
        self.exposesRawInputAPI = exposesRawInputAPI
        self.exposesDataCallbackAPI = exposesDataCallbackAPI
        self.exposesCellReadbackAPI = exposesCellReadbackAPI
        self.exposesTTYInspectionAPI = exposesTTYInspectionAPI
        self.exposesExternalSessionAttachAPI = exposesExternalSessionAttachAPI
    }

    public var supportsLocalEmbeddedRenderer: Bool {
        exposesLaunchOwnedSurfaceConfig && exposesRawInputAPI && exposesDataCallbackAPI && exposesCellReadbackAPI && exposesTTYInspectionAPI
    }

    public var supportsSharedSessionClientRenderer: Bool { supportsLocalEmbeddedRenderer && exposesExternalSessionAttachAPI }

    public var sharedSessionClientBlocker: String? {
        guard !supportsSharedSessionClientRenderer else { return nil }
        if !exposesExternalSessionAttachAPI {
            return "The public Ghostty SDK does not expose an attach/adopt API for an externally owned PTY or session stream."
        }
        return "The public Ghostty SDK is missing one or more local renderer hooks required by Spaces."
    }
}

public enum GhosttySDKCapabilityProbeError: Error, Equatable {
    case sdkUnavailable(String)
    case headerMissing(String)
}

public enum GhosttySDKCapabilityProbe {
    public static func loadResolvedSDK(
        environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default, currentDirectoryPath: String? = nil
    ) throws -> GhosttySDKCapabilityReport {
        switch GhosttyEmbeddedLocator.resolve(environment: environment, fileManager: fileManager, currentDirectoryPath: currentDirectoryPath) {
        case .available(let paths):
            let headerPath = URL(fileURLWithPath: paths.xcframeworkRootPath, isDirectory: true).appendingPathComponent(
                "macos-arm64_x86_64/Headers/ghostty.h"
            ).path
            guard fileManager.fileExists(atPath: headerPath) else { throw GhosttySDKCapabilityProbeError.headerMissing(headerPath) }
            let headerText = try String(contentsOfFile: headerPath, encoding: .utf8)
            return parse(headerText: headerText, headerPath: headerPath)
        case .unavailable(let reason): throw GhosttySDKCapabilityProbeError.sdkUnavailable(reason)
        }
    }

    public static func parse(headerText: String, headerPath: String = "ghostty.h") -> GhosttySDKCapabilityReport {
        let launchOwnedSurfaceConfig = containsAll(
            in: headerText, needles: ["working_directory", "command", "env_vars", "initial_input", "wait_after_command"])
        let rawInputAPI = headerText.contains("ghostty_surface_send_input_raw")
        let dataCallbackAPI = headerText.contains("ghostty_surface_set_data_callback")
        let cellReadbackAPI = containsAll(in: headerText, needles: ["ghostty_surface_read_cells", "ghostty_surface_free_cells"])
        let ttyInspectionAPI = containsAll(in: headerText, needles: ["ghostty_surface_tty_name", "ghostty_surface_foreground_pid"])
        let externalSessionAttachAPI = externalAttachSymbols.contains { headerText.contains($0) }

        return GhosttySDKCapabilityReport(
            headerPath: headerPath, exposesLaunchOwnedSurfaceConfig: launchOwnedSurfaceConfig, exposesRawInputAPI: rawInputAPI,
            exposesDataCallbackAPI: dataCallbackAPI, exposesCellReadbackAPI: cellReadbackAPI, exposesTTYInspectionAPI: ttyInspectionAPI,
            exposesExternalSessionAttachAPI: externalSessionAttachAPI)
    }

    private static let externalAttachSymbols = [
        "ghostty_surface_attach", "ghostty_surface_adopt", "ghostty_surface_set_pty", "ghostty_surface_set_fd", "ghostty_surface_set_io",
        "ghostty_surface_attach_stream", "ghostty_surface_connect",
    ]

    private static func containsAll(in headerText: String, needles: [String]) -> Bool { needles.allSatisfy { headerText.contains($0) } }
}

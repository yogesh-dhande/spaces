import XCTest

@testable import spacesterminalghostty

final class GhosttySDKCapabilityProbeTests: XCTestCase {
    func testParseReportsSharedSessionClientUnsupportedWithoutAttachAPI() {
        let header = """
            const char* working_directory;
            const char* command;
            ghostty_env_var_s* env_vars;
            const char* initial_input;
            bool wait_after_command;
            GHOSTTY_API void ghostty_surface_set_data_callback(ghostty_surface_t, void*);
            GHOSTTY_API bool ghostty_surface_read_cells(ghostty_surface_t, ghostty_cells_s*);
            GHOSTTY_API void ghostty_surface_free_cells(ghostty_surface_t, ghostty_cells_s*);
            GHOSTTY_API ghostty_string_s ghostty_surface_tty_name(ghostty_surface_t);
            GHOSTTY_API uint64_t ghostty_surface_foreground_pid(ghostty_surface_t);
            GHOSTTY_API void ghostty_surface_send_input_raw(ghostty_surface_t, const uint8_t*, uintptr_t);
            """

        let report = GhosttySDKCapabilityProbe.parse(headerText: header, headerPath: "/tmp/ghostty.h")

        XCTAssertTrue(report.supportsLocalEmbeddedRenderer)
        XCTAssertFalse(report.exposesExternalSessionAttachAPI)
        XCTAssertFalse(report.supportsSharedSessionClientRenderer)
        XCTAssertEqual(
            report.sharedSessionClientBlocker,
            "The public Ghostty SDK does not expose an attach/adopt API for an externally owned PTY or session stream.")
    }

    func testParseReportsSharedSessionClientSupportedWhenAttachAPIExists() {
        let header = """
            const char* working_directory;
            const char* command;
            ghostty_env_var_s* env_vars;
            const char* initial_input;
            bool wait_after_command;
            GHOSTTY_API void ghostty_surface_set_data_callback(ghostty_surface_t, void*);
            GHOSTTY_API bool ghostty_surface_read_cells(ghostty_surface_t, ghostty_cells_s*);
            GHOSTTY_API void ghostty_surface_free_cells(ghostty_surface_t, ghostty_cells_s*);
            GHOSTTY_API ghostty_string_s ghostty_surface_tty_name(ghostty_surface_t);
            GHOSTTY_API uint64_t ghostty_surface_foreground_pid(ghostty_surface_t);
            GHOSTTY_API void ghostty_surface_send_input_raw(ghostty_surface_t, const uint8_t*, uintptr_t);
            GHOSTTY_API void ghostty_surface_attach_stream(ghostty_surface_t, int);
            """

        let report = GhosttySDKCapabilityProbe.parse(headerText: header)

        XCTAssertTrue(report.exposesExternalSessionAttachAPI)
        XCTAssertTrue(report.supportsSharedSessionClientRenderer)
        XCTAssertNil(report.sharedSessionClientBlocker)
    }

    func testLoadResolvedSDKHeaderMatchesCurrentPublicCapabilities() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let environment = [
            GhosttyEmbeddedLocator.xcframeworkEnvironmentVariable: repoRoot.appendingPathComponent(
                "apps/macos/.local/ghosttykit/GhosttyKit.xcframework"
            ).path
        ]
        let report = try GhosttySDKCapabilityProbe.loadResolvedSDK(environment: environment, currentDirectoryPath: repoRoot.path)

        XCTAssertTrue(report.exposesLaunchOwnedSurfaceConfig)
        XCTAssertTrue(report.exposesRawInputAPI)
        XCTAssertTrue(report.exposesDataCallbackAPI)
        XCTAssertTrue(report.exposesCellReadbackAPI)
        XCTAssertTrue(report.exposesTTYInspectionAPI)
        XCTAssertFalse(report.exposesExternalSessionAttachAPI)
        XCTAssertFalse(report.supportsSharedSessionClientRenderer)
    }
}

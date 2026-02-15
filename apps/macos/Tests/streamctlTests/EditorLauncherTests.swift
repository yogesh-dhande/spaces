import Foundation
import XCTest

@testable import streamctl

final class EditorLauncherTests: XCTestCase {
    func testOpenReturnsWhenEditorIsNil() throws { XCTAssertNoThrow(try EditorLauncher.open(editor: nil, directory: "/path/that/does/not/exist")) }

    func testOpenReturnsWhenEditorIsNone() throws {
        XCTAssertNoThrow(try EditorLauncher.open(editor: EditorPreference.none, directory: "/path/that/does/not/exist"))
    }

    func testOpenUsesExpectedAppPerEditor() throws {
        let directory = "/tmp/workspace"
        let root = try makeTempDirectory()
        let logFile = root.appendingPathComponent("open.log")

        // Mocked dependency: `open` binary.
        // Why: assert app-selection arguments without launching GUI apps during tests.
        // Remaining risk: does not validate Finder/LaunchServices behavior or real app bundle availability.
        try withMockOpen {
            try withEnv(name: "OPEN_LOG_FILE", value: logFile.path) {
                try EditorLauncher.open(editor: .vscode, directory: directory)
                try EditorLauncher.open(editor: .cursor, directory: directory)
                try EditorLauncher.open(editor: .windsurf, directory: directory)
                try EditorLauncher.open(editor: .vim, directory: directory)
            }
        }

        let lines = try String(contentsOf: logFile).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("-a|Visual Studio Code|\(directory)|"))
        XCTAssertTrue(lines[1].contains("-a|Cursor|\(directory)|"))
        XCTAssertTrue(lines[2].contains("-a|Windsurf|\(directory)|"))
        XCTAssertTrue(lines[3].contains("-a|Terminal|\(directory)|"))
    }

    func testOpenDoesNotThrowWhenOpenCommandFails() throws {
        // Mocked dependency: failing `open` command exit code.
        // Why: document and assert current behavior (Shell.run status is ignored by EditorLauncher).
        // Remaining risk: callers may assume launch success because failures are intentionally non-throwing today.
        try withMockOpen {
            try withEnv(name: "OPEN_FAIL", value: "1") { XCTAssertNoThrow(try EditorLauncher.open(editor: .cursor, directory: "/tmp/workspace")) }
        }
    }

    private func withMockOpen(run: () throws -> Void) throws {
        // Mock mechanism: PATH shim with a scripted `open` replacement.
        // Why: isolate argument construction and failure handling from OS GUI side effects.
        // Remaining risk: integration with real `open` semantics is outside unit scope.
        let directory = try makeTempDirectory()
        let open = directory.appendingPathComponent("open")
        try Self.openScript.write(to: open, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)

        sharedPathMutationLock.lock()
        defer { sharedPathMutationLock.unlock() }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let updatedPath = originalPath.isEmpty ? directory.path : "\(directory.path):\(originalPath)"
        setenv("PATH", updatedPath, 1)
        defer { setenv("PATH", originalPath, 1) }

        try run()
    }

    private func withEnv(name: String, value: String, run: () throws -> Void) throws {
        let original = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let original { setenv(name, original, 1) } else { unsetenv(name) } }
        try run()
    }

    private static let openScript = """
        #!/bin/bash
        # Mock `open` command:
        # - logs args for assertions
        # - optionally forces non-zero exit via OPEN_FAIL
        # Residual risk: no end-to-end verification of actual app launches.
        if [[ -n "${OPEN_LOG_FILE:-}" ]]; then
          line=""
          for arg in "$@"; do
            line="${line}${arg}|"
          done
          echo "$line" >> "$OPEN_LOG_FILE"
        fi
        if [[ "${OPEN_FAIL:-}" == "1" ]]; then
          exit 1
        fi
        exit 0
        """
}

import Foundation
import spacesterminalcore

let sharedPathMutationLock = NSLock()
let sharedEnvironmentMutationLock = NSRecursiveLock()
let sharedAppleScriptTestOptInEnvVar = "SPACES_ALLOW_TEST_APPLESCRIPT"

func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
    let directory = try makeTempDirectory()
    for (name, script) in commands {
        let file = directory.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    // Shell resolves commands through a login-shell PATH probe. Tests that only prepend PATH can still
    // leak to the real system unless the probe itself also sees the mocked PATH and shell binary.
    let shellFile = directory.appendingPathComponent("mock-login-shell")
    let shellScript = """
        #!/bin/sh
        if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then
          printf '\\n__SPACES_PATH__'
          printenv PATH
          exit 0
        fi
        exec /bin/sh "$@"
        """
    try shellScript.write(to: shellFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellFile.path)

    sharedEnvironmentMutationLock.lock()
    sharedPathMutationLock.lock()
    defer {
        sharedPathMutationLock.unlock()
        sharedEnvironmentMutationLock.unlock()
    }

    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let originalShell = ProcessInfo.processInfo.environment["SHELL"]
    let originalHome = ProcessInfo.processInfo.environment["HOME"]
    let updatedPath = originalPath.isEmpty ? directory.path : "\(directory.path):\(originalPath)"
    setenv("PATH", updatedPath, 1)
    setenv("SHELL", shellFile.path, 1)
    setenv("HOME", directory.path, 1)
    let baselineTerminalSessionIDs = trackedTerminalSessionIDs()
    defer {
        setenv("PATH", originalPath, 1)
        if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
    }
    defer { terminateTrackedTerminalSessions(createdAfter: baselineTerminalSessionIDs) }

    try withTestAppleScriptOptIn(enabled: commands.keys.contains("osascript")) { try run() }
}

func withTestAppleScriptOptIn(enabled: Bool, run: () throws -> Void) throws {
    guard enabled else {
        try run()
        return
    }

    sharedEnvironmentMutationLock.lock()
    defer { sharedEnvironmentMutationLock.unlock() }
    let original = ProcessInfo.processInfo.environment[sharedAppleScriptTestOptInEnvVar]
    setenv(sharedAppleScriptTestOptInEnvVar, "1", 1)
    defer { if let original { setenv(sharedAppleScriptTestOptInEnvVar, original, 1) } else { unsetenv(sharedAppleScriptTestOptInEnvVar) } }
    try run()
}

private func trackedTerminalSessionIDs() -> Set<String> { Set((try? TerminalSessionPersistence.listKnownSessions().map(\.sessionID)) ?? []) }

private func terminateTrackedTerminalSessions(createdAfter baselineSessionIDs: Set<String>) {
    let liveSessionIDs = trackedTerminalSessionIDs().subtracting(baselineSessionIDs)
    for sessionID in liveSessionIDs { try? TerminalService.terminateSession(id: sessionID) }
}

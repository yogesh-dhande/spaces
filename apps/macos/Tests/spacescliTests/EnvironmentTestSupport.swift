import Foundation

private let sharedPathMutationLock = NSLock()
private let sharedEnvironmentMutationLock = NSRecursiveLock()
private let sharedAppleScriptTestOptInEnvVar = "SPACES_ALLOW_TEST_APPLESCRIPT"

func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for (name, script) in commands {
        let file = directory.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    // Force Shell's login-shell PATH probe to echo the mocked PATH so tests never fall back to real
    // osascript/browser/terminal binaries just because command lookup was enriched through the user shell.
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
    setenv("PATH", originalPath.isEmpty ? directory.path : "\(directory.path):\(originalPath)", 1)
    setenv("SHELL", shellFile.path, 1)
    defer {
        setenv("PATH", originalPath, 1)
        if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
    }

    try withTestAppleScriptOptIn(enabled: commands.keys.contains("osascript")) { try run() }
}

private func withTestAppleScriptOptIn(enabled: Bool, run: () throws -> Void) throws {
    guard enabled else {
        try run()
        return
    }

    let original = ProcessInfo.processInfo.environment[sharedAppleScriptTestOptInEnvVar]
    setenv(sharedAppleScriptTestOptInEnvVar, "1", 1)
    defer { if let original { setenv(sharedAppleScriptTestOptInEnvVar, original, 1) } else { unsetenv(sharedAppleScriptTestOptInEnvVar) } }
    try run()
}

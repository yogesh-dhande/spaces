import Foundation

let sharedPathMutationLock = NSLock()
let sharedEnvironmentMutationLock = NSRecursiveLock()
let sharedAppleScriptTestOptInEnvVar = "SPACES_ALLOW_TEST_APPLESCRIPT"

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

#if os(macOS)
    import Darwin
    import XCTest

    @testable import spacesterminalcore

    @_silgen_name("responsibility_get_pid_responsible_for_pid") private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

    /// Guards the undocumented responsibility-disclaim SPI the daemon's in-place exec depends on (#979). If
    /// Apple changes it, the replacement daemon would again inherit a stale TCC responsibility record, so every
    /// failure here is a hard failure, never a skip.
    final class DaemonExecSpawnAttributesTests: XCTestCase {
        func testTheUpdatesReplacementDaemonIsItsOwnResponsibleProcess() throws {
            var attributes = DaemonExecSpawnAttributes.make()
            guard attributes != nil else { return XCTFail("the exec attributes (including the disclaim) could not be built") }
            defer { posix_spawnattr_destroy(&attributes) }
            // The test must spawn a child, not replace itself, so drop SETEXEC and keep the rest.
            var flags = Int16(0)
            XCTAssertEqual(posix_spawnattr_getflags(&attributes, &flags), 0)
            XCTAssertEqual(posix_spawnattr_setflags(&attributes, flags & ~Int16(POSIX_SPAWN_SETEXEC)), 0)

            let disclaimed = try spawnSleep(attributes: &attributes)
            defer { reap(disclaimed) }
            XCTAssertEqual(responsibility_get_pid_responsible_for_pid(disclaimed), disclaimed)

            // Control: without the disclaim the child inherits this process's responsible process.
            let inherited = try spawnSleep(attributes: nil)
            defer { reap(inherited) }
            XCTAssertNotEqual(responsibility_get_pid_responsible_for_pid(inherited), inherited)
        }

        private func spawnSleep(attributes: UnsafePointer<posix_spawnattr_t?>?) throws -> pid_t {
            var pid = pid_t(0)
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("5"), nil]
            defer { for pointer in argv where pointer != nil { free(pointer) } }
            let status = posix_spawn(&pid, "/bin/sleep", nil, attributes, &argv, environ)
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EINVAL) }
            return pid
        }

        private func reap(_ pid: pid_t) {
            kill(pid, SIGKILL)
            var status = Int32(0)
            waitpid(pid, &status, 0)
        }
    }
#endif

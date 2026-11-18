#if os(macOS)
    import Darwin

    // Undocumented libSystem SPI, linked directly on purpose (#979). A removed symbol fails at load, which
    // tests and CI catch; an error return or a behavior change fails DaemonExecSpawnAttributesTests.
    @_silgen_name("responsibility_spawnattrs_setdisclaim") private func responsibility_spawnattrs_setdisclaim(
        _ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32
    ) -> Int32

    /// Spawn attributes for the daemon's in-place exec into a staged binary.
    ///
    /// macOS TCC attributes a terminal session's privacy checks (Apple Events, Accessibility) to the
    /// "responsible process", which for the launchd-started daemon is the daemon itself. `execv` keeps the
    /// kernel's responsibility record, which still names the ORIGINAL executable file; an app update deletes
    /// that file, so tccd cannot resolve it and denies every program in a Spaces terminal. `POSIX_SPAWN_SETEXEC`
    /// alone does not reset the record; the disclaim does, making the replacement image its own responsible
    /// process. Sessions started before the update keep the stale record; nothing can repair those.
    public enum DaemonExecSpawnAttributes {
        /// Returns attributes that replace the calling image (`POSIX_SPAWN_SETEXEC`), start it with an empty
        /// signal mask, and disclaim responsibility. The caller owns the result and must destroy it.
        ///
        /// The mask is set explicitly because exec preserves the calling thread's mask, and the engine executor
        /// is a libdispatch worker that blocks SIGTERM/SIGHUP/SIGINT; without this the replacement daemon would
        /// ignore graceful shutdown.
        public static func make() -> posix_spawnattr_t? {
            var attributes: posix_spawnattr_t?
            guard posix_spawnattr_init(&attributes) == 0 else { return nil }
            var emptyMask = sigset_t()
            sigemptyset(&emptyMask)
            let flags = Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGMASK)
            guard posix_spawnattr_setflags(&attributes, flags) == 0, posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
                responsibility_spawnattrs_setdisclaim(&attributes, 1) == 0
            else {
                posix_spawnattr_destroy(&attributes)
                return nil
            }
            return attributes
        }
    }
#endif

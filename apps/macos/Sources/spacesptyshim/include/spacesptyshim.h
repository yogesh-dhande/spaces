#ifndef SPACES_PTY_SHIM_H
#define SPACES_PTY_SHIM_H

/// The complete pre-exec body of a forked PTY child, in C on purpose.
///
/// The child of a fork taken from a heavily multithreaded Swift process may not
/// execute ANY Swift: compiled Swift enters the runtime beneath arbitrary
/// statements (lazy generic-metadata instantiation, protocol-conformance cache
/// lookups), and those paths take process-wide runtime locks. A fork landing
/// while another parent thread holds one leaves the child owning a locked mutex
/// whose owner thread does not exist in it, and the child parks in futex_wait
/// forever before ever reaching exec. This was captured live with a debugger:
/// pthread_mutex_lock <- ConformanceState::cacheResult <-
/// swift_conformsToProtocol... <- swift_getTypeByMangledName, entered from the
/// first Swift statement after fork, with zero CPU consumed and not a byte of
/// terminal output ever produced.
///
/// Everything this function consumes is materialized by the parent BEFORE the
/// fork; nothing in here may allocate or take a lock, and the caller must not
/// run any Swift between fork returning 0 and this call.
///
/// Never returns: on exec failure the child exits with status 127.
__attribute__((noreturn)) void spaces_pty_child_exec(
    const char *executable,
    char *const *argv,
    char *const *envp,
    const char *working_directory, /* NULL when the session sets none */
    int close_from_fd,
    int close_below_fd);

#endif /* SPACES_PTY_SHIM_H */

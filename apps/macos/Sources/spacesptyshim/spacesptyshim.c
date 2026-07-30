#include "spacesptyshim.h"

#include <signal.h>
#include <unistd.h>

void spaces_pty_child_exec(
    const char *executable,
    char *const *argv,
    char *const *envp,
    const char *working_directory,
    int close_from_fd,
    int close_below_fd) {
    /* Remote daemons may be launched by noninteractive shells or nohup, which can
     * leave terminal signals ignored. PTY children need defaults so VINTR/VSUSP
     * behave like a normal terminal without changing the daemon's handlers. */
    signal(SIGHUP, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGTSTP, SIG_DFL);
    signal(SIGTTIN, SIG_DFL);
    signal(SIGTTOU, SIG_DFL);

    /* A forked child also inherits the calling THREAD's signal mask, and the daemon
     * starts sessions on the terminal engine executor -- a libdispatch worker thread,
     * which blocks terminal signals so they are delivered to the main thread instead.
     * A PTY child that inherits SIGHUP/SIGTERM blocked cannot be gracefully
     * terminated: the signals stay pending and its shell's traps never run, so
     * terminate()'s HUP->TERM escalation is silently ineffective (only the final
     * SIGKILL lands). Reset the mask to empty so the child starts as if spawned from
     * a normal terminal. */
    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    sigprocmask(SIG_SETMASK, &empty_mask, NULL);

    for (int fd = close_from_fd; fd < close_below_fd; fd++) {
        close(fd);
    }

    if (working_directory != NULL) {
        /* Matching the historical behavior: a missing working directory falls back to
         * wherever the daemon runs rather than failing the spawn. */
        (void)chdir(working_directory);
    }

    execve(executable, argv, envp);
    _exit(127);
}

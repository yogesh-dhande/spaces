// Prints why and where a test process died, to stderr, so the CI log carries it.
//
// CI writes no crash report for the `swift test` process, and a libdispatch client crash ("BUG IN
// CLIENT OF LIBDISPATCH: ...", e.g. a failed dispatch_assert_queue) records its reason only in the
// crashed image's `__DATA,__crash_info` section, which the crash reporter shows as Application
// Specific Information. The handler reads that section from every loaded image and prints it with
// the signal, thread, dispatch queue and a symbolized stack. The faulting PC gets its own line
// because a backtrace() taken inside a signal handler walks frame pointers from the handler and
// skips the faulting function itself.
//
// Not everything here is async-signal-safe (snprintf, backtrace, dispatch calls). That is
// acceptable: the process is already dying and this is test-only. After printing, the default
// action is restored and the signal re-raised so the process still dies by the same signal.

#include <dispatch/dispatch.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define PREFIX "spaces-test-crash: "

// Leading fields of crashreporter_annotations_t (Libc CrashReporterClient.h).
struct crash_info_prefix {
    uint64_t version;
    uint64_t message;  // char *
    uint64_t signature_string;
    uint64_t backtrace;
    uint64_t message2;  // char *
};

static atomic_flag crash_reported = ATOMIC_FLAG_INIT;

static void write_line(const char *text) {
    size_t length = strlen(text);
    while (length > 0) {
        ssize_t written = write(STDERR_FILENO, text, length);
        if (written <= 0) {
            return;
        }
        text += written;
        length -= (size_t)written;
    }
}

static void write_formatted_line(const char *format, ...) __attribute__((format(printf, 1, 2)));

static void write_formatted_line(const char *format, ...) {
    char buffer[1024];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(buffer, sizeof(buffer), format, arguments);
    va_end(arguments);
    write_line(PREFIX);
    write_line(buffer);
    write_line("\n");
}

static void print_crash_annotations(void) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(index);
        if (header == NULL) {
            continue;
        }
        unsigned long size = 0;
        uint8_t *data = getsectiondata(header, "__DATA", "__crash_info", &size);
        if (data == NULL || size < sizeof(struct crash_info_prefix)) {
            continue;
        }
        const struct crash_info_prefix *info = (const struct crash_info_prefix *)data;
        const char *path = _dyld_get_image_name(index);
        const char *base = path != NULL ? strrchr(path, '/') : NULL;
        base = base != NULL ? base + 1 : (path != NULL ? path : "?");
        if (info->message != 0) {
            write_formatted_line("crash_info %s message: %s", base, (const char *)(uintptr_t)info->message);
        }
        if (info->message2 != 0) {
            write_formatted_line("crash_info %s message2: %s", base, (const char *)(uintptr_t)info->message2);
        }
    }
}

static const char *signal_name(int sig) {
    switch (sig) {
    case SIGTRAP: return "SIGTRAP";
    case SIGILL: return "SIGILL";
    case SIGSEGV: return "SIGSEGV";
    case SIGBUS: return "SIGBUS";
    case SIGABRT: return "SIGABRT";
    default: return "?";
    }
}

static void crash_handler(int sig, siginfo_t *info, void *context) {
    (void)info;
    if (!atomic_flag_test_and_set(&crash_reported)) {
        char threadName[64] = "";
        pthread_getname_np(pthread_self(), threadName, sizeof(threadName));
        if (pthread_main_np()) {
            snprintf(threadName, sizeof(threadName), "main");
        }
        const char *queueLabel = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
        write_formatted_line("signal %d (%s) thread \"%s\" queue \"%s\"", sig, signal_name(sig), threadName,
                             queueLabel != NULL ? queueLabel : "");

        print_crash_annotations();

        const ucontext_t *uc = (const ucontext_t *)context;
#if defined(__arm64__)
        void *pc = (void *)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
#else
        void *pc = (void *)uc->uc_mcontext->__ss.__rip;
#endif
        write_line(PREFIX "faulting pc:\n");
        backtrace_symbols_fd(&pc, 1, STDERR_FILENO);

        void *frames[128];
        int frameCount = backtrace(frames, 128);
        write_line(PREFIX "backtrace:\n");
        backtrace_symbols_fd(frames, frameCount, STDERR_FILENO);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

__attribute__((constructor)) static void install_crash_handlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = crash_handler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    const int signals[] = {SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT};
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
        sigaction(signals[index], &action, NULL);
    }
}

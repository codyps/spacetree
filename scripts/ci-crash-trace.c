#include <execinfo.h>
#include <signal.h>
#include <unistd.h>

static void trace_crash(int signal) {
    void *frames[128];
    const char message[] = "\nCI crash backtrace:\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    int count = backtrace(frames, 128);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    _exit(128 + signal);
}

__attribute__((constructor)) static void install_trace(void) {
    signal(SIGTRAP, trace_crash);
    signal(SIGILL, trace_crash);
    signal(SIGABRT, trace_crash);
}

#if defined(__linux__)
#include <signal.h>

// Linux has no per-descriptor SIGPIPE opt-out for a pipe (Darwin has
// F_SETNOSIGPIPE), so a write to a wake pipe whose reader has gone would end
// the whole test run (#602). The app never runs on Linux; only its tests do.
// A constructor, because XCTest on Linux has no hook that runs before the
// first test. Darwin keeps the default, so a lost NOSIGPIPE still fails there.
__attribute__((constructor))
static void localvoxtralTestSupportIgnoreSIGPIPE(void) {
    signal(SIGPIPE, SIG_IGN);
}
#else
// ISO C forbids an empty translation unit.
typedef int localvoxtralTestSupportSignalsUnused;
#endif

#ifdef __cplusplus
extern "C" {
#endif

// MinGW provides POSIX pthreads via winpthreads, and the upstream
// LZMA SDK's ThreadsWin32.h was never shipped with this fork. Treat
// MinGW the same as a POSIX target -- Common.h still goes through
// FREEARC_WIN for the Windows-API bits (mmap, tempfiles), but
// threading uses pthread_*. Native MSVC builds would need a real
// ThreadsWin32.h port (open task; see CHANGELOG known limitations).
#if defined(_WIN32) && !defined(__MINGW32__)
#include "ThreadsWin32.h"
#else
#include "ThreadsUnix.h"
#endif

#ifdef __cplusplus
}
#endif

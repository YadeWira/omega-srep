// MinGW: see comment in Threads.h. ThreadsWin32.c was never shipped
// with this fork; MinGW uses the POSIX path via winpthreads.
#if defined(_WIN32) && !defined(__MINGW32__)
#include "ThreadsWin32.c"
#else
#include "ThreadsUnix.c"
#endif

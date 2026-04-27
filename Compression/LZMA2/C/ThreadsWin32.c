/* ThreadsWin32.c -- Windows threading primitives for the LZMA SDK
   threading API used by SREP. Implementations map the 2008-era
   function names (Thread_Create, Event_Set, etc.) onto Win32 API
   calls (CreateThread, SetEvent, etc.). Built only on _WIN32 via
   Threads.c's #ifdef gate. */

#include "ThreadsWin32.h"
#include <errno.h>

/* Helpers --------------------------------------------------------- */

static WRes WaitObject(HANDLE h)
{
    DWORD r = WaitForSingleObject(h, INFINITE);
    return (r == WAIT_OBJECT_0) ? 0 : (WRes)GetLastError();
}

static WRes CloseAndNull(HANDLE *h)
{
    if (*h != NULL) {
        BOOL ok = CloseHandle(*h);
        *h = NULL;
        if (!ok) return (WRes)GetLastError();
    }
    return 0;
}

/* Threads --------------------------------------------------------- */

WRes Thread_Create(CThread *p, THREAD_FUNC_TYPE func, LPVOID param)
{
    DWORD threadId;
    *p = CreateThread(NULL, 0, func, param, 0, &threadId);
    if (*p == NULL) return (WRes)GetLastError();
    return 0;
}

WRes Thread_Wait(CThread *p)
{
    if (*p == NULL) return EINVAL;
    return WaitObject(*p);
}

WRes Thread_Close(CThread *p)
{
    return CloseAndNull(p);
}

/* Events ---------------------------------------------------------- */

static WRes Event_Create_Generic(CEvent *p, BOOL manualReset, int initialSignaled)
{
    *p = CreateEvent(NULL, manualReset, initialSignaled ? TRUE : FALSE, NULL);
    if (*p == NULL) return (WRes)GetLastError();
    return 0;
}

WRes ManualResetEvent_Create(CManualResetEvent *p, int initialSignaled)
{
    return Event_Create_Generic(p, TRUE, initialSignaled);
}

WRes ManualResetEvent_CreateNotSignaled(CManualResetEvent *p)
{
    return ManualResetEvent_Create(p, 0);
}

WRes AutoResetEvent_Create(CAutoResetEvent *p, int initialSignaled)
{
    return Event_Create_Generic(p, FALSE, initialSignaled);
}

WRes AutoResetEvent_CreateNotSignaled(CAutoResetEvent *p)
{
    return AutoResetEvent_Create(p, 0);
}

WRes Event_Set(CEvent *p)
{
    if (SetEvent(*p)) return 0;
    return (WRes)GetLastError();
}

WRes Event_Reset(CEvent *p)
{
    if (ResetEvent(*p)) return 0;
    return (WRes)GetLastError();
}

WRes Event_Wait(CEvent *p)
{
    return WaitObject(*p);
}

WRes Event_Close(CEvent *p)
{
    return CloseAndNull(p);
}

/* Semaphores ------------------------------------------------------ */

WRes Semaphore_Create(CSemaphore *p, UInt32 initCount, UInt32 maxCount)
{
    *p = CreateSemaphore(NULL, (LONG)initCount, (LONG)maxCount, NULL);
    if (*p == NULL) return (WRes)GetLastError();
    return 0;
}

WRes Semaphore_ReleaseN(CSemaphore *p, UInt32 num)
{
    LONG prev;
    if (ReleaseSemaphore(*p, (LONG)num, &prev)) return 0;
    return (WRes)GetLastError();
}

WRes Semaphore_Wait(CSemaphore *p)
{
    return WaitObject(*p);
}

WRes Semaphore_Close(CSemaphore *p)
{
    return CloseAndNull(p);
}

/* Critical sections ----------------------------------------------- */

WRes CriticalSection_Init(CCriticalSection *p)
{
    /* InitializeCriticalSection on pre-Vista could raise
       STATUS_NO_MEMORY; we target Windows 10/11 only, so it never
       fails and there is no return value to check. */
    InitializeCriticalSection(p);
    return 0;
}

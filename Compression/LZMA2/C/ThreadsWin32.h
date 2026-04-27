/* ThreadsWin32.h -- Windows threading primitives for the LZMA SDK
   threading API used by SREP. Modeled on Igor Pavlov's modern (26.x)
   LZMA SDK Threads.h Win32 path, kept ABI-compatible with the
   2008-era ThreadsUnix.h shipped in this fork so the C++ wrapper
   layer (Compression/LZMA2/MultiThreading/Thread.h, Synchronization.h)
   needs no changes. */

#ifndef __7Z_THRESDS_H
#define __7Z_THRESDS_H

#include "Types.h"
#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MAX_THREAD 256

/* Thread function signature: matches CreateThread's worker. */
typedef DWORD THREAD_FUNC_RET_TYPE;
#define THREAD_FUNC_CALL_TYPE WINAPI
#define THREAD_FUNC_DECL THREAD_FUNC_RET_TYPE THREAD_FUNC_CALL_TYPE
typedef THREAD_FUNC_RET_TYPE (THREAD_FUNC_CALL_TYPE * THREAD_FUNC_TYPE)(void *);

/* ---- Threads ----------------------------------------------------- */
typedef HANDLE CThread;
#define Thread_Construct(p)   (*(p) = NULL)
#define Thread_WasCreated(p)  (*(p) != NULL)
WRes Thread_Create(CThread *p, THREAD_FUNC_TYPE func, LPVOID param);
WRes Thread_Wait(CThread *p);
WRes Thread_Close(CThread *p);

/* ---- Events ------------------------------------------------------ */
typedef HANDLE CEvent;
typedef CEvent CAutoResetEvent;
typedef CEvent CManualResetEvent;
#define Event_Construct(p)    (*(p) = NULL)
#define Event_IsCreated(p)    (*(p) != NULL)
WRes ManualResetEvent_Create(CManualResetEvent *p, int initialSignaled);
WRes ManualResetEvent_CreateNotSignaled(CManualResetEvent *p);
WRes AutoResetEvent_Create(CAutoResetEvent *p, int initialSignaled);
WRes AutoResetEvent_CreateNotSignaled(CAutoResetEvent *p);
WRes Event_Set(CEvent *p);
WRes Event_Reset(CEvent *p);
WRes Event_Wait(CEvent *p);
WRes Event_Close(CEvent *p);

/* ---- Semaphores -------------------------------------------------- */
typedef HANDLE CSemaphore;
#define Semaphore_Construct(p) (*(p) = NULL)
WRes Semaphore_Create(CSemaphore *p, UInt32 initCount, UInt32 maxCount);
WRes Semaphore_ReleaseN(CSemaphore *p, UInt32 num);
#define Semaphore_Release1(p)  Semaphore_ReleaseN(p, 1)
WRes Semaphore_Wait(CSemaphore *p);
WRes Semaphore_Close(CSemaphore *p);

/* ---- Critical sections ------------------------------------------- */
typedef CRITICAL_SECTION CCriticalSection;
WRes CriticalSection_Init(CCriticalSection *p);
#define CriticalSection_Delete(p) DeleteCriticalSection(p)
#define CriticalSection_Enter(p)  EnterCriticalSection(p)
#define CriticalSection_Leave(p)  LeaveCriticalSection(p)

#ifdef __cplusplus
}
#endif

#endif

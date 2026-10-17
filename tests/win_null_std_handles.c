/* win_null_std_handles.exe MASK program args...
 *
 * Runs `program args...` with the standard handles MASK asks for and exits
 * with its exit code. MASK has three letters, for stdin, stdout and stderr:
 *   k  the launcher's own handle (inherited)
 *   n  NULL: no handle, as for a process started without a console
 *   i  INVALID_HANDLE_VALUE
 * Closing a Unix fd under wine does not give a Windows process a missing
 * handle (wine hands it one that fails), so tests/pascal_cli_conformance.sh
 * builds this with mingw and runs the .exe through it under wine.
 * Arguments are quoted with plain double quotes: no quotes or trailing
 * backslashes inside them. Exit 120: usage; 121: CreateProcessW failed. */
#include <windows.h>
#include <wchar.h>

int wmain(int argc, wchar_t **argv)
{
    static wchar_t cl[32768];
    DWORD ids[3] = {STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE};
    HANDLE h[3];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD rc = 0;
    int i;

    if (argc < 3 || wcslen(argv[1]) != 3) return 120;
    for (i = 0; i < 3; i++) {
        HANDLE cur = GetStdHandle(ids[i]);
        switch (argv[1][i]) {
        case L'n': h[i] = NULL; break;
        case L'i': h[i] = INVALID_HANDLE_VALUE; break;
        case L'k':
            h[i] = cur;
            SetHandleInformation(cur, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
            break;
        default: return 120;
        }
    }
    cl[0] = 0;
    for (i = 2; i < argc; i++) {
        if (wcslen(cl) + wcslen(argv[i]) + 4 >= sizeof cl / sizeof cl[0]) return 120;
        wcscat(cl, L"\"");
        wcscat(cl, argv[i]);
        wcscat(cl, L"\" ");
    }
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = h[0];
    si.hStdOutput = h[1];
    si.hStdError = h[2];
    if (!CreateProcessW(NULL, cl, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 121;
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &rc);
    return (int)rc;
}

/* bottler-place: start a game and keep its window at a target rect.
 *
 *   bottler-place.exe <x> <y> <w> <h> [--title <text>] -- <exe> [args...]
 *
 * Runs inside the game's Wine session, where one Windows program may move
 * another's window without any macOS permission. The rect comes from
 * `bottler geometry` (Win32 virtual-screen coordinates). The game window is the
 * largest visible top-level window in the session other than this program's,
 * optionally only those whose title contains --title; a game started through a
 * launcher (a different process) is found the same way. A window of another
 * size is centred on the rect. Re-applied every 250 ms, because some games move
 * their window back (Thinker does after a movie). Exits when the window is gone
 * after having been seen, or if none appears within 3 minutes.
 *
 * Build: i686-w64-mingw32-gcc -O2 -mwindows -o bottler-place.exe place.c
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct search { const char *title; HWND best; long long area; };

static BOOL CALLBACK consider(HWND hwnd, LPARAM lp)
{
    struct search *s = (struct search *)lp;
    DWORD pid = 0;
    char text[256];
    RECT r;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == GetCurrentProcessId() || !IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER))
        return TRUE;
    if (s->title) {
        GetWindowTextA(hwnd, text, sizeof(text));
        if (!strstr(text, s->title)) return TRUE;
    }
    if (!GetWindowRect(hwnd, &r)) return TRUE;
    long long area = (long long)(r.right - r.left) * (r.bottom - r.top);
    if (area >= 640 * 480 && area > s->area) { s->best = hwnd; s->area = area; }
    return TRUE;
}

static void place(HWND hwnd, int x, int y, int w, int h)
{
    RECT r;
    if (IsIconic(hwnd) || !GetWindowRect(hwnd, &r)) return;
    int ww = r.right - r.left, wh = r.bottom - r.top;
    int tx = x + (w - ww) / 2, ty = y + (h - wh) / 2;
    if (r.left != tx || r.top != ty)
        SetWindowPos(hwnd, NULL, tx, ty, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

int main(int argc, char **argv)
{
    int i, sep = -1;
    const char *title = NULL;
    for (i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "--")) { sep = i; break; }
        if (!strcmp(argv[i], "--title") && i + 1 < argc) title = argv[++i];
    }
    if (argc < 7 || sep < 0 || sep + 1 >= argc) {
        fprintf(stderr, "usage: bottler-place.exe <x> <y> <w> <h> [--title <text>] -- <exe> [args...]\n");
        return 2;
    }
    int x = atoi(argv[1]), y = atoi(argv[2]), w = atoi(argv[3]), h = atoi(argv[4]);

    /* the game's command line: exe and args, each quoted */
    char cmd[4096] = "";
    for (i = sep + 1; i < argc; i++) {
        if (strlen(cmd) + strlen(argv[i]) + 4 >= sizeof(cmd)) return 2;
        strcat(cmd, i > sep + 1 ? " \"" : "\"");
        strcat(cmd, argv[i]);
        strcat(cmd, "\"");
    }
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "bottler-place: cannot start %s (error %lu)\n", argv[sep + 1], GetLastError());
        return 1;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    BOOL seen = FALSE;
    for (int waited = 0;; waited += 250) {
        struct search s = { title, NULL, 0 };
        EnumWindows(consider, (LPARAM)&s);
        if (s.best) {
            seen = TRUE;
            place(s.best, x, y, w, h);
        } else if (seen || waited > 180000) {
            break;
        }
        Sleep(250);
    }
    return 0;
}

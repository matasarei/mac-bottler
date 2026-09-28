/* Window-relative cursor hooks, linked into a proxy DLL (see proxy.sh).
 *
 * Old games read the mouse with GetCursorPos and treat the result as if their
 * window sat at the screen's top-left corner, as it does in real full-screen.
 * Once the window is centred (kitchen-place.exe), edge scrolling breaks on the
 * side away from the origin. When the game loads this DLL, it redirects four
 * user32 imports in the game exe and in every module loaded from the game's
 * folder, so the game sees coordinates relative to its own window:
 *   GetCursorPos    screen -> window, clamped to the window (black borders act as edges)
 *   SetCursorPos    window -> screen
 *   ScreenToClient  input treated as window-relative "screen" coordinates
 *   ClientToScreen  output made window-relative
 * The game window is this process's largest visible top-level window.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <string.h>

static BOOL (WINAPI *real_GetCursorPos)(LPPOINT);
static BOOL (WINAPI *real_SetCursorPos)(int, int);
static BOOL (WINAPI *real_ScreenToClient)(HWND, LPPOINT);
static BOOL (WINAPI *real_ClientToScreen)(HWND, LPPOINT);

struct search { HWND best; long long area; };

static BOOL CALLBACK consider(HWND hwnd, LPARAM lp)
{
    struct search *s = (struct search *)lp;
    DWORD pid = 0;
    RECT r;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId() || !IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER)) return TRUE;
    if (!GetClientRect(hwnd, &r)) return TRUE;
    long long area = (long long)r.right * r.bottom;
    if (area > s->area) { s->best = hwnd; s->area = area; }
    return TRUE;
}

/* Screen position and size of the game window's client area. */
static BOOL game_origin(POINT *origin, SIZE *size)
{
    static HWND game;
    static DWORD checked;
    DWORD now = GetTickCount();
    if (!game || !IsWindow(game) || now - checked > 1000) {   /* the main window can change */
        struct search s = { NULL, 0 };
        EnumWindows(consider, (LPARAM)&s);
        game = s.best;
        checked = now;
    }
    if (!game) return FALSE;
    RECT rc;
    POINT p = { 0, 0 };
    if (!GetClientRect(game, &rc) || !real_ClientToScreen(game, &p)) return FALSE;
    *origin = p;
    size->cx = rc.right - rc.left;
    size->cy = rc.bottom - rc.top;
    return size->cx > 0 && size->cy > 0;
}

static BOOL WINAPI hook_GetCursorPos(LPPOINT pt)
{
    if (!real_GetCursorPos(pt)) return FALSE;
    POINT o; SIZE s;
    if (game_origin(&o, &s)) {
        pt->x -= o.x;
        pt->y -= o.y;
        if (pt->x < 0) pt->x = 0;
        if (pt->y < 0) pt->y = 0;
        if (pt->x > s.cx - 1) pt->x = s.cx - 1;
        if (pt->y > s.cy - 1) pt->y = s.cy - 1;
    }
    return TRUE;
}

static BOOL WINAPI hook_SetCursorPos(int x, int y)
{
    POINT o; SIZE s;
    if (game_origin(&o, &s)) { x += o.x; y += o.y; }
    return real_SetCursorPos(x, y);
}

static BOOL WINAPI hook_ScreenToClient(HWND hwnd, LPPOINT pt)
{
    POINT o; SIZE s;
    if (game_origin(&o, &s)) { pt->x += o.x; pt->y += o.y; }
    return real_ScreenToClient(hwnd, pt);
}

static BOOL WINAPI hook_ClientToScreen(HWND hwnd, LPPOINT pt)
{
    if (!real_ClientToScreen(hwnd, pt)) return FALSE;
    POINT o; SIZE s;
    if (game_origin(&o, &s)) { pt->x -= o.x; pt->y -= o.y; }
    return TRUE;
}

/* Point a module's USER32 import slots for the four functions at the hooks. */
static void patch_imports(HMODULE mod)
{
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return;
    for (IMAGE_IMPORT_DESCRIPTOR *imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress); imp->Name; imp++) {
        if (lstrcmpiA((char *)(base + imp->Name), "USER32.dll") != 0 || !imp->OriginalFirstThunk) continue;
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
        IMAGE_THUNK_DATA *slots = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, slots++) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            const char *fn = (const char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name;
            void *hook = NULL;
            if (!strcmp(fn, "GetCursorPos")) hook = hook_GetCursorPos;
            else if (!strcmp(fn, "SetCursorPos")) hook = hook_SetCursorPos;
            else if (!strcmp(fn, "ScreenToClient")) hook = hook_ScreenToClient;
            else if (!strcmp(fn, "ClientToScreen")) hook = hook_ClientToScreen;
            if (!hook) continue;
            DWORD old;
            if (VirtualProtect(&slots->u1.Function, sizeof(slots->u1.Function), PAGE_READWRITE, &old)) {
                slots->u1.Function = (ULONG_PTR)hook;
                VirtualProtect(&slots->u1.Function, sizeof(slots->u1.Function), old, &old);
            }
        }
    }
}

/* Directory part of a path, lower-cased, for comparing module locations. */
static void dir_of(const char *path, char *out, size_t n)
{
    lstrcpynA(out, path, (int)n);
    char *slash = strrchr(out, '\\');
    if (slash) *slash = 0;
    CharLowerA(out);
}

/* Patch the game exe and every module loaded from its folder, except this DLL. */
static void patch_game_modules(HINSTANCE self)
{
    char exe[MAX_PATH], game_dir[MAX_PATH], mod_dir[MAX_PATH];
    GetModuleFileNameA(NULL, exe, sizeof(exe));
    dir_of(exe, game_dir, sizeof(game_dir));
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
    if (snap == INVALID_HANDLE_VALUE) { patch_imports(GetModuleHandleA(NULL)); return; }
    MODULEENTRY32 me = { sizeof(me) };
    for (BOOL ok = Module32First(snap, &me); ok; ok = Module32Next(snap, &me)) {
        if (me.hModule == (HMODULE)self) continue;
        dir_of(me.szExePath, mod_dir, sizeof(mod_dir));
        if (!strcmp(mod_dir, game_dir)) patch_imports(me.hModule);
    }
    CloseHandle(snap);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        HMODULE user32 = GetModuleHandleA("user32.dll");
        real_GetCursorPos = (void *)GetProcAddress(user32, "GetCursorPos");
        real_SetCursorPos = (void *)GetProcAddress(user32, "SetCursorPos");
        real_ScreenToClient = (void *)GetProcAddress(user32, "ScreenToClient");
        real_ClientToScreen = (void *)GetProcAddress(user32, "ClientToScreen");
        if (real_GetCursorPos && real_SetCursorPos && real_ScreenToClient && real_ClientToScreen)
            patch_game_modules(inst);
    }
    return TRUE;
}

/* bottler-modecache.dll: cache the display modes a game enumerates.
 *
 * Some old games walk the whole display-mode list once per mode, a check that
 * grows with the square of the list. A 2002 PC had ~20 modes; a Retina Mac reports
 * ~400 through Wine (every resolution at several refresh rates, in 8/16/32-bit),
 * and each EnumDisplaySettings call costs ~50 us there: Counter-Strike spent ~15 s
 * in 158,000 calls before its menu. Here the first call for each mode asks Windows
 * and later calls are answered from memory. The current and registry settings are
 * never cached, and any ChangeDisplaySettings clears the cache.
 *
 * bottler-place.exe --inject loads it into the game before the game runs. It then
 * re-points user32's exported EnumDisplaySettings(Ex)A/W and ChangeDisplaySettings
 * (Ex)A/W at the functions below, in the export table: every module that imports or
 * looks them up afterwards (a game's engine DLL, the DirectDraw it loads) gets the
 * cached ones. No game file and no code byte is changed.
 *
 * Build: i686-w64-mingw32-gcc -O2 -shared -o bottler-modecache.dll modecache.c
 */
#include <windows.h>
#include <stddef.h>
#include "modecache_store.h"

typedef BOOL (WINAPI *enum_a_fn)(LPCSTR, DWORD, DEVMODEA *, DWORD);
typedef BOOL (WINAPI *enum_w_fn)(LPCWSTR, DWORD, DEVMODEW *, DWORD);
typedef LONG (WINAPI *change_ex_a_fn)(LPCSTR, DEVMODEA *, HWND, DWORD, LPVOID);
typedef LONG (WINAPI *change_ex_w_fn)(LPCWSTR, DEVMODEW *, HWND, DWORD, LPVOID);
typedef LONG (WINAPI *change_a_fn)(DEVMODEA *, DWORD);
typedef LONG (WINAPI *change_w_fn)(DEVMODEW *, DWORD);

static enum_a_fn real_enum_ex_a;
static enum_w_fn real_enum_ex_w;
static change_ex_a_fn real_change_ex_a;
static change_ex_w_fn real_change_ex_w;
static change_a_fn real_change_a;
static change_w_fn real_change_w;

static CRITICAL_SECTION lock;
static struct mc_store store;

/* Copy a cached DEVMODE into the caller's, keeping the caller's own size fields. */
static void give(void *dm, const struct mc_entry *e)
{
    WORD *size = (WORD *)((BYTE *)dm + (e->wide ? offsetof(DEVMODEW, dmSize) : offsetof(DEVMODEA, dmSize)));
    WORD *extra = size + 1;   /* dmDriverExtra follows dmSize in both */
    WORD caller_size = *size, caller_extra = *extra;
    memcpy(dm, e->data, caller_size < e->size ? caller_size : e->size);
    *size = caller_size;
    *extra = caller_extra;
}

static void narrow(char *out, LPCWSTR in)
{
    int i = 0;
    for (; in && in[i] && i < MC_DEVICE - 1; i++) out[i] = (char)in[i];
    out[i] = 0;
}

static BOOL WINAPI cached_ex_a(LPCSTR device, DWORD index, DEVMODEA *dm, DWORD flags)
{
    if (!dm || index == ENUM_CURRENT_SETTINGS || index == ENUM_REGISTRY_SETTINGS)
        return real_enum_ex_a(device, index, dm, flags);
    EnterCriticalSection(&lock);
    struct mc_entry *e = mc_find(&store, 0, device ? device : "", index, flags);
    if (!e) {
        DEVMODEA mode;
        memset(&mode, 0, sizeof(mode));
        mode.dmSize = sizeof(mode);
        BOOL ok = real_enum_ex_a(device, index, &mode, flags);
        e = mc_add(&store, 0, device ? device : "", index, flags, ok, &mode, sizeof(mode));
        if (!e) { LeaveCriticalSection(&lock); return real_enum_ex_a(device, index, dm, flags); }
    }
    BOOL ok = e->ok;
    if (ok) give(dm, e);
    LeaveCriticalSection(&lock);
    return ok;
}

static BOOL WINAPI cached_ex_w(LPCWSTR device, DWORD index, DEVMODEW *dm, DWORD flags)
{
    if (!dm || index == ENUM_CURRENT_SETTINGS || index == ENUM_REGISTRY_SETTINGS)
        return real_enum_ex_w(device, index, dm, flags);
    char key[MC_DEVICE];
    narrow(key, device);
    EnterCriticalSection(&lock);
    struct mc_entry *e = mc_find(&store, 1, key, index, flags);
    if (!e) {
        DEVMODEW mode;
        memset(&mode, 0, sizeof(mode));
        mode.dmSize = sizeof(mode);
        BOOL ok = real_enum_ex_w(device, index, &mode, flags);
        e = mc_add(&store, 1, key, index, flags, ok, &mode, sizeof(mode));
        if (!e) { LeaveCriticalSection(&lock); return real_enum_ex_w(device, index, dm, flags); }
    }
    BOOL ok = e->ok;
    if (ok) give(dm, e);
    LeaveCriticalSection(&lock);
    return ok;
}

static BOOL WINAPI cached_a(LPCSTR device, DWORD index, DEVMODEA *dm) { return cached_ex_a(device, index, dm, 0); }
static BOOL WINAPI cached_w(LPCWSTR device, DWORD index, DEVMODEW *dm) { return cached_ex_w(device, index, dm, 0); }

/* A display change makes every cached mode stale. */
static void forget(void) { EnterCriticalSection(&lock); mc_clear(&store); LeaveCriticalSection(&lock); }

static LONG WINAPI change_ex_a(LPCSTR d, DEVMODEA *m, HWND w, DWORD f, LPVOID p) { forget(); LONG r = real_change_ex_a(d, m, w, f, p); forget(); return r; }
static LONG WINAPI change_ex_w(LPCWSTR d, DEVMODEW *m, HWND w, DWORD f, LPVOID p) { forget(); LONG r = real_change_ex_w(d, m, w, f, p); forget(); return r; }
static LONG WINAPI change_a(DEVMODEA *m, DWORD f) { forget(); LONG r = real_change_a(m, f); forget(); return r; }
static LONG WINAPI change_w(DEVMODEW *m, DWORD f) { forget(); LONG r = real_change_w(m, f); forget(); return r; }

/* Point an export of `mod` at `hook`; returns the function it pointed at before
 * (NULL if the name is not exported or is a forwarder). */
static void *repoint(HMODULE mod, const char *name, void *hook)
{
    BYTE *base = (BYTE *)mod;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (!dir.VirtualAddress) return NULL;
    IMAGE_EXPORT_DIRECTORY *exp = (IMAGE_EXPORT_DIRECTORY *)(base + dir.VirtualAddress);
    DWORD *names = (DWORD *)(base + exp->AddressOfNames);
    WORD *ordinals = (WORD *)(base + exp->AddressOfNameOrdinals);
    DWORD *functions = (DWORD *)(base + exp->AddressOfFunctions);
    for (DWORD i = 0; i < exp->NumberOfNames; i++) {
        if (strcmp((char *)(base + names[i]), name)) continue;
        DWORD *slot = &functions[ordinals[i]], old;
        if (*slot >= dir.VirtualAddress && *slot < dir.VirtualAddress + dir.Size) return NULL;   /* forwarder */
        void *before = base + *slot;
        if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old)) return NULL;
        *slot = (DWORD)((BYTE *)hook - base);   /* 32-bit arithmetic wraps, as the loader's does */
        VirtualProtect(slot, sizeof(*slot), old, &old);
        return before;
    }
    return NULL;
}

BOOL WINAPI DllMain(HINSTANCE self, DWORD reason, LPVOID reserved)
{
    (void)self; (void)reserved;
    if (reason == DLL_PROCESS_DETACH) { mc_free(&store); return TRUE; }
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    InitializeCriticalSection(&lock);
    mc_init(&store);
    HMODULE user32 = GetModuleHandleA("user32.dll");
    if (!user32) return TRUE;
    /* the real Ex functions first: the non-Ex hooks call through them */
    real_enum_ex_a = (enum_a_fn)(void (*)(void))GetProcAddress(user32, "EnumDisplaySettingsExA");
    real_enum_ex_w = (enum_w_fn)(void (*)(void))GetProcAddress(user32, "EnumDisplaySettingsExW");
    real_change_ex_a = (change_ex_a_fn)(void (*)(void))GetProcAddress(user32, "ChangeDisplaySettingsExA");
    real_change_ex_w = (change_ex_w_fn)(void (*)(void))GetProcAddress(user32, "ChangeDisplaySettingsExW");
    real_change_a = (change_a_fn)(void (*)(void))GetProcAddress(user32, "ChangeDisplaySettingsA");
    real_change_w = (change_w_fn)(void (*)(void))GetProcAddress(user32, "ChangeDisplaySettingsW");
    if (!real_enum_ex_a || !real_enum_ex_w || !real_change_ex_a || !real_change_ex_w || !real_change_a || !real_change_w)
        return TRUE;   /* leave everything as it was */
    repoint(user32, "EnumDisplaySettingsExA", cached_ex_a);
    repoint(user32, "EnumDisplaySettingsExW", cached_ex_w);
    repoint(user32, "EnumDisplaySettingsA", cached_a);
    repoint(user32, "EnumDisplaySettingsW", cached_w);
    repoint(user32, "ChangeDisplaySettingsExA", change_ex_a);
    repoint(user32, "ChangeDisplaySettingsExW", change_ex_w);
    repoint(user32, "ChangeDisplaySettingsA", change_a);
    repoint(user32, "ChangeDisplaySettingsW", change_w);
    return TRUE;
}

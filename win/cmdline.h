/* Append one argument to a Windows command line, quoted only when it needs it
 * (empty, or containing a space, tab or quote), with the escaping rules
 * CommandLineToArgvW and the C runtime use. Quoting every argument broke old
 * games that parse their command line themselves: one took "-game" "x" for no
 * options at all. Returns 0, or -1 if cap is too small.
 * Plain C, so a native test can include it (tests/fixtures/cmdline-test.c). */
#include <string.h>

static int append_arg(char *cmd, size_t cap, const char *arg)
{
    size_t len = strlen(cmd), i, n;
    char out[4096];
    size_t o = 0;
    if (len) out[o++] = ' ';
    if (*arg && !strpbrk(arg, " \t\"")) {
        n = strlen(arg);
        if (o + n >= sizeof(out)) return -1;
        memcpy(out + o, arg, n); o += n;
    } else {
        out[o++] = '"';
        for (i = 0; arg[i]; i++) {
            size_t slashes = 0;
            while (arg[i] == '\\') { slashes++; i++; }
            if (o + 2 * slashes + 3 >= sizeof(out)) return -1;
            if (!arg[i]) { while (slashes--) { out[o++] = '\\'; out[o++] = '\\'; } break; }
            if (arg[i] == '"') { slashes = 2 * slashes + 1; }
            while (slashes--) out[o++] = '\\';
            out[o++] = arg[i];
        }
        out[o++] = '"';
    }
    if (len + o + 1 > cap) return -1;
    memcpy(cmd + len, out, o);
    cmd[len + o] = 0;
    return 0;
}

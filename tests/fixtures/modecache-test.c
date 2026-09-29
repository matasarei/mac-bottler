/* Checks win/modecache_store.h: the lookup table behind the display-mode cache. */
#include <stdio.h>
#include <string.h>
#include "../../win/modecache_store.h"

static int failed = 0;
#define CHECK(name, cond) do { if (!(cond)) { printf("modecache: %s\n", name); failed++; } } while (0)

int main(void)
{
    struct mc_store s; mc_init(&s);
    unsigned char mode[40]; memset(mode, 7, sizeof(mode));
    CHECK("empty store finds nothing", mc_find(&s, 0, "", 3, 0) == NULL);
    struct mc_entry *e = mc_add(&s, 0, "", 3, 0, 1, mode, sizeof(mode));
    CHECK("add returns the entry", e && e->ok == 1 && e->size == sizeof(mode));
    CHECK("the same key finds it", mc_find(&s, 0, "", 3, 0) == e);
    CHECK("another index does not", mc_find(&s, 0, "", 4, 0) == NULL);
    CHECK("another flag does not", mc_find(&s, 0, "", 3, 2) == NULL);
    CHECK("the wide variant is separate", mc_find(&s, 1, "", 3, 0) == NULL);
    CHECK("another device does not", mc_find(&s, 0, "\\\\.\\display2", 3, 0) == NULL);
    mc_add(&s, 0, "", 400, 0, 0, NULL, 0);
    CHECK("the end of the list (FALSE) is cached too", mc_find(&s, 0, "", 400, 0) && mc_find(&s, 0, "", 400, 0)->ok == 0);
    for (unsigned i = 0; i < 3000; i++) mc_add(&s, i & 1, "", 1000 + i, 0, 1, mode, sizeof(mode));
    /* growing moves the entries: look them up again, never keep a pointer across adds */
    CHECK("thousands of modes stay findable", mc_find(&s, 1, "", 1000 + 2999, 0) != NULL
          && mc_find(&s, 0, "", 3, 0) && mc_find(&s, 0, "", 3, 0)->ok == 1 && mc_find(&s, 0, "", 3, 0)->data[0] == 7);
    mc_clear(&s);
    CHECK("clear empties it (a display change)", mc_find(&s, 0, "", 3, 0) == NULL);
    CHECK("device names match case-insensitively", (mc_add(&s, 0, "\\\\.\\DISPLAY1", 1, 0, 1, mode, 4), mc_find(&s, 0, "\\\\.\\display1", 1, 0) != NULL));
    mc_free(&s);
    if (failed) return 1;
    printf("modecache: ok\n");
    return 0;
}

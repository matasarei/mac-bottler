/* The lookup table behind the display-mode cache (win/modecache.c): one entry per
 * (A or W call, display device, mode index, flags), holding what Windows returned:
 * the BOOL and the DEVMODE bytes. Open addressing on a table that doubles, so the
 * ~400 modes a Retina Mac reports stay a constant-time lookup. Plain C, so a native
 * test can include it (tests/fixtures/modecache-test.c). Not thread-safe: the
 * caller holds a lock. */
#ifndef MODECACHE_STORE_H
#define MODECACHE_STORE_H
#include <stdlib.h>
#include <string.h>

#define MC_DEVICE 64
#define MC_DATA 256   /* larger than DEVMODEW's public part (220 bytes) */

struct mc_entry {
    int used, wide;
    char device[MC_DEVICE];   /* lower-case, "" for the primary display */
    unsigned index, flags;
    int ok;
    unsigned size;
    unsigned char data[MC_DATA];
};

struct mc_store { struct mc_entry *slots; unsigned capacity, count; };

static void mc_key(char *out, const char *device)
{
    size_t i = 0;
    for (; device && device[i] && i < MC_DEVICE - 1; i++) {
        char c = device[i];
        out[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
    }
    out[i] = 0;
}

static unsigned mc_hash(int wide, const char *device, unsigned index, unsigned flags)
{
    unsigned h = 2166136261u ^ (unsigned)wide;
    for (; *device; device++) h = (h ^ (unsigned char)*device) * 16777619u;
    h = (h ^ index) * 16777619u;
    return (h ^ flags) * 16777619u;
}

static void mc_init(struct mc_store *s) { s->slots = NULL; s->capacity = s->count = 0; }

static void mc_free(struct mc_store *s) { free(s->slots); mc_init(s); }

static void mc_clear(struct mc_store *s)
{
    if (s->slots) memset(s->slots, 0, s->capacity * sizeof(*s->slots));
    s->count = 0;
}

static struct mc_entry *mc_slot(struct mc_store *s, int wide, const char *key, unsigned index, unsigned flags)
{
    unsigned i = mc_hash(wide, key, index, flags) & (s->capacity - 1);
    for (;; i = (i + 1) & (s->capacity - 1)) {
        struct mc_entry *e = &s->slots[i];
        if (!e->used || (e->wide == wide && e->index == index && e->flags == flags && !strcmp(e->device, key)))
            return e;
    }
}

static struct mc_entry *mc_find(struct mc_store *s, int wide, const char *device, unsigned index, unsigned flags)
{
    char key[MC_DEVICE];
    if (!s->capacity) return NULL;
    mc_key(key, device);
    struct mc_entry *e = mc_slot(s, wide, key, index, flags);
    return e->used ? e : NULL;
}

static int mc_grow(struct mc_store *s)
{
    unsigned old = s->capacity, n = old ? old * 2 : 1024;
    struct mc_entry *prev = s->slots, *slots = calloc(n, sizeof(*slots));
    if (!slots) return 0;
    s->slots = slots; s->capacity = n; s->count = 0;
    for (unsigned i = 0; i < old; i++) {
        if (!prev[i].used) continue;
        *mc_slot(s, prev[i].wide, prev[i].device, prev[i].index, prev[i].flags) = prev[i];
        s->count++;
    }
    free(prev);
    return 1;
}

/* Add (or replace) an entry; NULL when memory runs out (the caller then just
 * returns what Windows said, uncached). The table can grow and move its entries:
 * use the returned pointer before the next add, and look entries up again after. */
static struct mc_entry *mc_add(struct mc_store *s, int wide, const char *device, unsigned index, unsigned flags,
                               int ok, const void *data, unsigned size)
{
    char key[MC_DEVICE];
    if ((s->count + 1) * 2 > s->capacity && !mc_grow(s)) return NULL;
    mc_key(key, device);
    struct mc_entry *e = mc_slot(s, wide, key, index, flags);
    if (!e->used) s->count++;
    memset(e, 0, sizeof(*e));
    e->used = 1; e->wide = wide; e->index = index; e->flags = flags; e->ok = ok;
    strcpy(e->device, key);
    e->size = size > MC_DATA ? MC_DATA : size;
    if (data && e->size) memcpy(e->data, data, e->size);
    return e;
}
#endif

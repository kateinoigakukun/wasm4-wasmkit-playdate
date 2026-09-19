#include "CPlaydate.h"
#include <stdlib.h>
#include <stdint.h>

PlaydateAPI *playdate = NULL;

// Implemented in Swift.
extern int w4_eventHandler(PlaydateAPI *pd, PDSystemEvent event, uint32_t arg);

void w4_log(const char *message) {
    if (playdate != NULL) {
        playdate->system->logToConsole("%s", message);
    }
}

unsigned int w4_atomic_load(const volatile unsigned int *slot) {
    return __atomic_load_n(slot, __ATOMIC_ACQUIRE);
}

void w4_atomic_store(volatile unsigned int *slot, unsigned int value) {
    __atomic_store_n(slot, value, __ATOMIC_RELEASE);
}

#ifdef _WINDLL
__declspec(dllexport)
#endif
int eventHandler(PlaydateAPI *pd, PDSystemEvent event, uint32_t arg) {
    playdate = pd;
    return w4_eventHandler(pd, event, arg);
}

#if defined(TARGET_PLAYDATE) && TARGET_PLAYDATE
/// Registry of over-aligned allocations.
///
/// Embedded Swift's allocator calls posix_memalign, which newlib does not
/// provide. Alignments the Playdate's allocator already satisfies are served by
/// malloc directly; anything stricter has to be over-allocated and offset,
/// which means free() receives a pointer that is not the allocation base.
///
/// The base is recorded here rather than in a header below the block, because
/// finding such a header would mean reading memory before every pointer passed
/// to free -- unmapped for a block at the start of a heap region, and able to
/// match by accident.
///
/// Every free() consults this table, including the overwhelming majority that
/// were never over-aligned, so the lookup is a hash probe rather than a scan:
/// an earlier linear scan of a fixed 256 entries cost more per free than the
/// allocation itself. The table grows, because a fixed ceiling turns into a
/// failed allocation, and a failed allocation in Swift is a trap.
#define ALIGNED_INITIAL 256
#define ALIGNED_TOMBSTONE ((void *)(uintptr_t)1)

struct aligned_entry {
    void *body;
    void *base;
};

static struct aligned_entry *g_aligned;
static unsigned g_aligned_capacity;
static unsigned g_aligned_live;
static unsigned g_aligned_used;  // live entries plus tombstones

void __real_free(void *pointer);

static unsigned aligned_slot(void *body, unsigned capacity) {
    // The low bits are always zero for an aligned pointer, so shift them out
    // before mixing.
    uintptr_t key = (uintptr_t)body >> 4;
    return (unsigned)((key * 2654435761u) & (uintptr_t)(capacity - 1));
}

/// Reallocates the table at `capacity` and reinserts the live entries.
static int aligned_rehash(unsigned capacity) {
    struct aligned_entry *table = calloc(capacity, sizeof(struct aligned_entry));
    if (table == NULL) {
        return 0;
    }
    for (unsigned i = 0; i < g_aligned_capacity; i++) {
        void *body = g_aligned[i].body;
        if (body == NULL || body == ALIGNED_TOMBSTONE) {
            continue;
        }
        unsigned slot = aligned_slot(body, capacity);
        while (table[slot].body != NULL) {
            slot = (slot + 1) & (capacity - 1);
        }
        table[slot] = g_aligned[i];
    }
    // __real_free: the table is an ordinary allocation, and going through the
    // wrapper here would re-enter the lookup mid-rehash.
    if (g_aligned != NULL) {
        __real_free(g_aligned);
    }
    g_aligned = table;
    g_aligned_capacity = capacity;
    g_aligned_used = g_aligned_live;
    return 1;
}

static int aligned_insert(void *body, void *base) {
    // Grow at 70% occupancy, counting tombstones, so probes stay short.
    if ((g_aligned_used + 1) * 10 >= g_aligned_capacity * 7) {
        unsigned capacity = g_aligned_capacity == 0 ? ALIGNED_INITIAL : g_aligned_capacity;
        while ((g_aligned_live + 1) * 10 >= capacity * 7) {
            capacity *= 2;
        }
        if (!aligned_rehash(capacity)) {
            return 0;
        }
    }
    unsigned slot = aligned_slot(body, g_aligned_capacity);
    while (g_aligned[slot].body != NULL && g_aligned[slot].body != ALIGNED_TOMBSTONE) {
        slot = (slot + 1) & (g_aligned_capacity - 1);
    }
    if (g_aligned[slot].body == NULL) {
        g_aligned_used++;
    }
    g_aligned[slot].body = body;
    g_aligned[slot].base = base;
    g_aligned_live++;
    return 1;
}

/// Removes `body` and returns the allocation base, or NULL if it was not one
/// of ours.
static void *aligned_take(void *body) {
    if (g_aligned_live == 0) {
        return NULL;
    }
    unsigned slot = aligned_slot(body, g_aligned_capacity);
    for (unsigned probe = 0; probe < g_aligned_capacity; probe++) {
        void *entry = g_aligned[slot].body;
        if (entry == NULL) {
            return NULL;
        }
        if (entry == body) {
            void *base = g_aligned[slot].base;
            g_aligned[slot].body = ALIGNED_TOMBSTONE;
            g_aligned[slot].base = NULL;
            g_aligned_live--;
            return base;
        }
        slot = (slot + 1) & (g_aligned_capacity - 1);
    }
    return NULL;
}

int posix_memalign(void **out, size_t alignment, size_t size) {
    if (alignment <= 8) {
        void *allocation = malloc(size);
        if (allocation == NULL) {
            return 12;  // ENOMEM
        }
        *out = allocation;
        return 0;
    }
    if ((alignment & (alignment - 1)) != 0) {
        return 22;  // EINVAL
    }

    unsigned char *raw = (unsigned char *)malloc(size + alignment - 1);
    if (raw == NULL) {
        return 12;  // ENOMEM
    }
    uintptr_t body = ((uintptr_t)raw + alignment - 1) & ~(uintptr_t)(alignment - 1);

    if (!aligned_insert((void *)body, raw)) {
        __real_free(raw);
        return 12;  // ENOMEM
    }

    *out = (void *)body;
    return 0;
}

/// Frees blocks from either allocation path.
///
/// Interposed with `-Wl,--wrap=free` rather than by defining free, which
/// collides with newlib's own definition at link time.

void __wrap_free(void *pointer) {
    if (pointer == NULL) {
        return;
    }
    void *base = aligned_take(pointer);
    __real_free(base != NULL ? base : pointer);
}

// newlib assumes a host operating system underneath it. On bare metal these
// stubs have to be supplied; they are reached from abort() and from the
// standard library's random-seeding path, neither of which this program uses
// in anger.

void _exit(int status) {
    (void)status;
    if (playdate != NULL) {
        playdate->system->error("w4: _exit called");
    }
    for (;;) {
    }
}

int _getpid(void) { return 1; }

int _kill(int pid, int sig) {
    (void)pid;
    (void)sig;
    return -1;
}

// Seeds the standard library's hasher. It need not be cryptographic here, but
// it must vary between runs, or every Dictionary in the process shares a
// predictable layout. The millisecond clock at startup supplies that variation.
int getentropy(void *buffer, size_t length) {
    uint32_t state = 0x2545F491u;
    if (playdate != NULL) {
        state ^= playdate->system->getCurrentTimeMilliseconds();
    }
    unsigned char *out = (unsigned char *)buffer;
    for (size_t i = 0; i < length; i++) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        out[i] = (unsigned char)(state & 0xFF);
    }
    return 0;
}

#endif  // TARGET_PLAYDATE



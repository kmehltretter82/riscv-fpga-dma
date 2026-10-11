#include <stdint.h>

#include "dif/dma.h"

#define BUF8(addr) ((volatile uint8_t *)(uintptr_t)(addr))
#define CONFIG_SEED (*(volatile uint32_t *)(uintptr_t)0x4000fec0)
#define CONFIG_COUNT (*(volatile uint32_t *)(uintptr_t)0x4000fec4)
#define CONFIG_FLAGS (*(volatile uint32_t *)(uintptr_t)0x4000fec8)
#define CONFIG_SKIP (*(volatile uint32_t *)(uintptr_t)0x4000fecc)
#define CONFIG_MASK (*(volatile uint32_t *)(uintptr_t)0x4000fed0)
#define DIAG ((volatile struct diagnostic *)(uintptr_t)0x4000fd00)

#define DIAG_MAGIC 0x524e4447u
#define GUARD_BYTES 32u
#define MAX_CASES 1024u
#define FLAG_DURATION_PROFILE 1u

enum case_kind {
    CASE_1D = 1,
    CASE_2D = 2,
};

enum failure_reason {
    FAIL_BAD_CONFIG = 1,
    FAIL_1D_PAYLOAD = 2,
    FAIL_1D_LEFT_GUARD = 3,
    FAIL_1D_RIGHT_GUARD = 4,
    FAIL_1D_SOURCE = 5,
    FAIL_2D_PAYLOAD = 6,
    FAIL_2D_GAP = 7,
    FAIL_2D_LEFT_GUARD = 8,
    FAIL_2D_RIGHT_GUARD = 9,
    FAIL_2D_SOURCE = 10,
    FAIL_DESCRIPTOR_RANGE = 11,
};

struct dma_case {
    uint32_t kind;
    uint32_t conf;
    uint32_t src;
    uint32_t dst;
    uint32_t len;
    uint32_t src_stride;
    uint32_t dst_stride;
    uint32_t rows;
};

struct diagnostic {
    uint32_t magic;
    uint32_t seed;
    uint32_t requested;
    uint32_t completed;
    uint32_t index;
    uint32_t kind;
    uint32_t reason;
    uint32_t conf;
    uint32_t src;
    uint32_t dst;
    uint32_t len;
    uint32_t src_stride;
    uint32_t dst_stride;
    uint32_t rows;
    uint32_t descriptor_hash;
    uint32_t rng_state;
};

static const uint32_t boundary_lengths[32] = {
       1,    2,    7,    8,    9,   15,   16,   17,
      31,   32,   33,   63,   64,   65,  127,  128,
     129,  255,  256,  257,  511,  512,  513, 1023,
    1024, 1025, 2047, 2048, 2049, 4095, 4096, 4097,
};

static const uint16_t duration_lengths[32] = {
      1,   2,   7,   8,   9,  15,  16,  17,
     31,  32,  33,  63,  64,  65, 127, 128,
    129, 255, 256, 257,   3,   5,   6,  10,
     14,  18,  30,  34,  62,  66, 126, 130,
};

static uint32_t rng_next(uint32_t *state) {
    uint32_t x = *state;

    if (x == 0) x = 0x6d2b79f5u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static uint32_t fnv_word(uint32_t hash, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) {
        hash ^= (uint8_t)(value >> (i * 8));
        hash *= 16777619u;
    }
    return hash;
}

static uint32_t case_hash(uint32_t hash, uint32_t index,
                          const struct dma_case *test) {
    hash = fnv_word(hash, index);
    hash = fnv_word(hash, test->kind);
    hash = fnv_word(hash, test->conf);
    hash = fnv_word(hash, test->src);
    hash = fnv_word(hash, test->dst);
    hash = fnv_word(hash, test->len);
    hash = fnv_word(hash, test->src_stride);
    hash = fnv_word(hash, test->dst_stride);
    hash = fnv_word(hash, test->rows);
    return hash;
}

static uint32_t dma_conf(unsigned index) {
    switch (index & 3u) {
    case 0: return DMA_CONF_DECOUPLE_NONE;
    case 1: return DMA_CONF_DECOUPLE_AW;
    case 2: return DMA_CONF_DECOUPLE_RW;
    default: return DMA_CONF_DECOUPLE_ALL;
    }
}

/* Consume exactly nine PRNG words for every descriptor. */
static struct dma_case generate_case(uint32_t *state, unsigned index,
                                     uint32_t flags) {
    const uint32_t r_kind = rng_next(state);
    const uint32_t r_len_mode = rng_next(state);
    const uint32_t r_len = rng_next(state);
    const uint32_t r_src_lane = rng_next(state);
    const uint32_t r_dst_lane = rng_next(state);
    const uint32_t r_page = rng_next(state);
    const uint32_t r_rows = rng_next(state);
    const uint32_t r_src_gap = rng_next(state);
    const uint32_t r_dst_gap = rng_next(state);
    struct dma_case test;
    uint32_t src_lane = r_src_lane & 7u;
    uint32_t dst_lane = r_dst_lane & 7u;
    uint32_t len;

    if (dst_lane == src_lane) dst_lane ^= 1u;
    if ((r_len_mode & 3u) != 0) {
        len = (flags & FLAG_DURATION_PROFILE) ?
            duration_lengths[r_len & 31u] : boundary_lengths[r_len & 31u];
    } else {
        len = (r_len & ((flags & FLAG_DURATION_PROFILE) ? 255u : 4095u)) + 1u;
    }

    test.kind = ((r_kind & 3u) == 0) ? CASE_2D : CASE_1D;
    test.conf = dma_conf(index);
    test.len = len;
    test.src_stride = len;
    test.dst_stride = len;
    test.rows = 1;

    if (test.kind == CASE_2D) {
        if (!(flags & FLAG_DURATION_PROFILE) && test.len > 1025u)
            test.len = 514u + ((r_len >> 8) & 511u);
        test.rows = 1u + (r_rows &
            ((flags & FLAG_DURATION_PROFILE) ? 3u : 7u));
        test.src_stride = test.len + (r_src_gap &
            ((flags & FLAG_DURATION_PROFILE) ? 31u : 127u));
        test.dst_stride = test.len + (r_dst_gap &
            ((flags & FLAG_DURATION_PROFILE) ? 31u : 127u));
        if ((r_page & 3u) == 0) {
            test.src = 0x40001ff8u + src_lane;
            test.dst = 0x40009ff8u + dst_lane;
        } else {
            test.src = 0x40001040u + src_lane;
            test.dst = 0x40009040u + dst_lane;
        }
    } else {
        const uint32_t src_slot = (r_page >> 4) & 3u;
        const uint32_t dst_slot = (r_page >> 6) & 1u;
        if ((r_page & 3u) == 0) {
            test.src = 0x40001ff8u + src_slot * 0x1000u + src_lane;
            test.dst = 0x40009ff8u + dst_slot * 0x1000u + dst_lane;
        } else {
            test.src = 0x40001200u + src_slot * 0x1000u + src_lane;
            test.dst = 0x40009200u + dst_slot * 0x1000u + dst_lane;
        }
    }
    return test;
}

static uint8_t pattern(uint32_t seed, uint32_t offset) {
    return (uint8_t)((offset * 37u + seed * 29u + 11u) & 0xffu);
}

static uint64_t pattern_word(uint32_t seed, uint32_t offset) {
    uint64_t value = 0;

    for (unsigned byte = 0; byte < 8; ++byte)
        value |= (uint64_t)pattern(seed, offset + byte) << (byte * 8);
    return value;
}

static uint64_t fill_word(uint8_t fill) {
    uint64_t value = 0;

    for (unsigned byte = 0; byte < 8; ++byte)
        value |= (uint64_t)fill << (byte * 8);
    return value;
}

/*
 * External DMA memory is uncached.  Keep endpoint checks byte-exact, but use
 * aligned 64-bit accesses for the body so long randomized runs spend their
 * time in iDMA rather than issuing eight serialized CPU bus transactions per
 * word.  No unaligned C load or store is performed.
 */
static void write_pattern(uint32_t addr, uint32_t len, uint32_t seed,
                          uint32_t offset) {
    while (len && (addr & 7u)) {
        *BUF8(addr++) = pattern(seed, offset++);
        --len;
    }
    while (len >= 8u) {
        *(volatile uint64_t *)(uintptr_t)addr = pattern_word(seed, offset);
        addr += 8u;
        offset += 8u;
        len -= 8u;
    }
    while (len) {
        *BUF8(addr++) = pattern(seed, offset++);
        --len;
    }
}

static void write_fill(uint32_t addr, uint32_t len, uint8_t fill) {
    const uint64_t word = fill_word(fill);

    while (len && (addr & 7u)) {
        *BUF8(addr++) = fill;
        --len;
    }
    while (len >= 8u) {
        *(volatile uint64_t *)(uintptr_t)addr = word;
        addr += 8u;
        len -= 8u;
    }
    while (len) {
        *BUF8(addr++) = fill;
        --len;
    }
}

static int check_pattern(uint32_t addr, uint32_t len, uint32_t seed,
                         uint32_t offset) {
    while (len && (addr & 7u)) {
        if (*BUF8(addr++) != pattern(seed, offset++)) return 0;
        --len;
    }
    while (len >= 8u) {
        if (*(volatile uint64_t *)(uintptr_t)addr !=
            pattern_word(seed, offset)) return 0;
        addr += 8u;
        offset += 8u;
        len -= 8u;
    }
    while (len) {
        if (*BUF8(addr++) != pattern(seed, offset++)) return 0;
        --len;
    }
    return 1;
}

static int check_fill(uint32_t addr, uint32_t len, uint8_t fill) {
    const uint64_t word = fill_word(fill);

    while (len && (addr & 7u)) {
        if (*BUF8(addr++) != fill) return 0;
        --len;
    }
    while (len >= 8u) {
        if (*(volatile uint64_t *)(uintptr_t)addr != word) return 0;
        addr += 8u;
        len -= 8u;
    }
    while (len) {
        if (*BUF8(addr++) != fill) return 0;
        --len;
    }
    return 1;
}

static void publish_case(uint32_t seed, uint32_t requested,
                         uint32_t completed, uint32_t index,
                         const struct dma_case *test, uint32_t hash,
                         uint32_t rng_state) {
    DIAG->magic = DIAG_MAGIC;
    DIAG->seed = seed;
    DIAG->requested = requested;
    DIAG->completed = completed;
    DIAG->index = index;
    DIAG->kind = test->kind;
    DIAG->reason = 0;
    DIAG->conf = test->conf;
    DIAG->src = test->src;
    DIAG->dst = test->dst;
    DIAG->len = test->len;
    DIAG->src_stride = test->src_stride;
    DIAG->dst_stride = test->dst_stride;
    DIAG->rows = test->rows;
    DIAG->descriptor_hash = hash;
    DIAG->rng_state = rng_state;
}

static int fail(unsigned index, unsigned reason) {
    DIAG->reason = reason;
    DIAG->completed = index;
    asm volatile("fence rw, rw" ::: "memory");
    return (int)(0x8000u | ((index & 0x7fu) << 4) | (reason & 0xfu));
}

static int descriptor_in_range(const struct dma_case *test) {
    uint32_t src_span = test->len;
    uint32_t dst_span = test->len;

    if (test->kind == CASE_2D) {
        src_span = (test->rows - 1u) * test->src_stride + test->len;
        dst_span = test->rows * test->dst_stride;
    }
    if (test->src < 0x40000020u || test->dst < 0x40008020u)
        return 0;
    if (test->src + src_span + GUARD_BYTES >= 0x40008000u)
        return 0;
    if (test->dst + dst_span + GUARD_BYTES >= 0x4000f000u)
        return 0;
    return 1;
}

static int run_1d(unsigned index, uint32_t seed,
                  const struct dma_case *test) {
    const uint32_t src_all = test->src - GUARD_BYTES;
    const uint32_t dst_all = test->dst - GUARD_BYTES;
    const uint32_t total = test->len + 2u * GUARD_BYTES;
    const uint32_t pattern_seed = seed ^ (index * 0x9e3779b9u);
    const uint8_t fill = (uint8_t)(0xa5u ^ seed ^ (index * 13u));

    write_pattern(src_all, total, pattern_seed, 0);
    write_fill(dst_all, total, fill);

    sys_dma_blk_memcpy(test->dst, test->src, test->len, test->conf);

    if (!check_pattern(test->dst, test->len, pattern_seed, GUARD_BYTES))
        return fail(index, FAIL_1D_PAYLOAD);
    if (!check_fill(dst_all, GUARD_BYTES, fill))
        return fail(index, FAIL_1D_LEFT_GUARD);
    if (!check_fill(test->dst + test->len, GUARD_BYTES, fill))
        return fail(index, FAIL_1D_RIGHT_GUARD);
    if (!check_pattern(src_all, total, pattern_seed, 0))
        return fail(index, FAIL_1D_SOURCE);
    return 0;
}

static int run_2d(unsigned index, uint32_t seed,
                  const struct dma_case *test) {
    const uint32_t src_all = test->src - GUARD_BYTES;
    const uint32_t dst_all = test->dst - GUARD_BYTES;
    const uint32_t src_span =
        (test->rows - 1u) * test->src_stride + test->len;
    const uint32_t dst_span = test->rows * test->dst_stride;
    const uint32_t src_total = src_span + 2u * GUARD_BYTES;
    const uint32_t dst_total = dst_span + 2u * GUARD_BYTES;
    const uint32_t pattern_seed = seed ^ 0x51ed270bu ^ (index * 0x85ebca6bu);
    const uint8_t fill = (uint8_t)(0x5au ^ seed ^ (index * 17u));

    write_pattern(src_all, src_total, pattern_seed, 0);
    write_fill(dst_all, dst_total, fill);

    sys_dma_2d_blk_memcpy(test->dst, test->src, test->len,
                          test->dst_stride, test->src_stride, test->rows,
                          test->conf);

    for (uint32_t row = 0; row < test->rows; ++row) {
        if (!check_pattern(test->dst + row * test->dst_stride, test->len,
                           pattern_seed,
                           GUARD_BYTES + row * test->src_stride))
            return fail(index, FAIL_2D_PAYLOAD);
        if (!check_fill(test->dst + row * test->dst_stride + test->len,
                        test->dst_stride - test->len, fill))
            return fail(index, FAIL_2D_GAP);
    }
    if (!check_fill(dst_all, GUARD_BYTES, fill))
        return fail(index, FAIL_2D_LEFT_GUARD);
    if (!check_fill(test->dst + dst_span, GUARD_BYTES, fill))
        return fail(index, FAIL_2D_RIGHT_GUARD);
    if (!check_pattern(src_all, src_total, pattern_seed, 0))
        return fail(index, FAIL_2D_SOURCE);
    return 0;
}

uint64_t main(void) {
    const uint32_t seed = CONFIG_SEED;
    const uint32_t requested = CONFIG_COUNT;
    const uint32_t flags = CONFIG_FLAGS;
    const uint32_t skip = CONFIG_SKIP;
    const uint32_t mask = CONFIG_MASK;
    uint32_t state = seed;
    uint32_t hash = 2166136261u;
    struct dma_case test = {0};

    if (requested == 0 || requested > MAX_CASES || skip > requested ||
        (flags & ~FLAG_DURATION_PROFILE)) {
        publish_case(seed, requested, 0, 0, &test, hash, state);
        return (uint16_t)fail(0, FAIL_BAD_CONFIG);
    }

    for (uint32_t index = 0; index < requested; ++index) {
        test = generate_case(&state, index, flags);
        hash = case_hash(hash, index, &test);
        publish_case(seed, requested, index, index, &test, hash, state);
        if (!descriptor_in_range(&test))
            return (uint16_t)fail(index, FAIL_DESCRIPTOR_RANGE);
        if (index < skip) {
            DIAG->completed = index + 1u;
            continue;
        }
        if (mask != 0) {
            const uint32_t relative = index - skip;

            if (relative >= 32u || !(mask & (1u << relative))) {
                DIAG->completed = index + 1u;
                continue;
            }
        }

        int rc = test.kind == CASE_1D ?
            run_1d(index, seed, &test) : run_2d(index, seed, &test);
        if (rc) return (uint16_t)rc;
        DIAG->completed = index + 1u;
    }

    DIAG->index = requested;
    DIAG->kind = 0;
    DIAG->reason = 0;
    DIAG->completed = requested;
    DIAG->descriptor_hash = hash;
    DIAG->rng_state = state;
    asm volatile("fence rw, rw" ::: "memory");
    return (uint64_t)(requested & 0xffffu) << 16;
}

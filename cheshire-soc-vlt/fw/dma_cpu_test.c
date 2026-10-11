#include <stdint.h>

#include "dif/dma.h"

#define BUF8(addr) ((volatile uint8_t *)(uintptr_t)(addr))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define GUARD_BYTES 32u

struct copy_1d {
    uintptr_t src;
    uintptr_t dst;
    uint32_t len;
};

struct copy_2d {
    uintptr_t src;
    uintptr_t dst;
    uint32_t len;
    uint32_t src_stride;
    uint32_t dst_stride;
    uint32_t rows;
};

/*
 * Exercise byte, 64-bit beat, likely burst and 4 KiB boundaries.  Every
 * unaligned case uses different source and destination lane offsets.
 */
static const struct copy_1d one_d_cases[] = {
    {0x40000200, 0x40004000,    1},
    {0x40000201, 0x40004003,    2},
    {0x40000207, 0x40004005,    7},
    {0x40000200, 0x40004000,    8},
    {0x40000205, 0x40004007,    9},
    {0x40000201, 0x40004006,   15},
    {0x40000200, 0x40004000,   16},
    {0x40000203, 0x40004001,   17},
    {0x40000207, 0x40004003,   31},
    {0x40000200, 0x40004000,   32},
    {0x40000201, 0x40004005,   33},
    {0x40000203, 0x40004007,   63},
    {0x40000200, 0x40004000,   64},
    {0x40000207, 0x40004001,   65},
    {0x40000201, 0x40004003,  255},
    {0x40000200, 0x40004000,  256},
    {0x40000203, 0x40004005,  257},
    {0x40000201, 0x40004007, 4095},
    {0x40000200, 0x40004000, 4096},
    {0x40000207, 0x40004003, 4097},
    /* Both payloads cross a 4 KiB boundary after an unaligned start. */
    {0x40000ff9, 0x40004ffb,   17},
};

static const struct copy_2d two_d_cases[] = {
    {0x40001800, 0x40006800,   1,   1,   1, 1},
    {0x40001801, 0x40006803,   7,   9,  11, 2},
    {0x40001800, 0x40006800,   8,   8,   8, 3},
    {0x40001805, 0x40006807,   9,  17,  19, 4},
    {0x40001801, 0x40006803,  13,  32,  24, 7},
    {0x40001807, 0x40006805,  63,  80,  72, 3},
    {0x40001803, 0x40006801, 257, 300, 280, 2},
    /* Each row starts on the far side of a page-crossing first row. */
    {0x40001ff9, 0x40006ffb,  13,  32,  24, 3},
};

static uint8_t pattern(unsigned seed, unsigned offset) {
    return (uint8_t)((offset * 37u + seed * 29u + 11u) & 0xffu);
}

static int error_code(unsigned family, unsigned index, unsigned reason) {
    return (int)(family | ((index & 0xffu) << 4) | (reason & 0xfu));
}

static int run_1d_case(unsigned index, const struct copy_1d *test) {
    volatile uint8_t *src = BUF8(test->src);
    volatile uint8_t *dst = BUF8(test->dst);
    volatile uint8_t *src_all = src - GUARD_BYTES;
    volatile uint8_t *dst_all = dst - GUARD_BYTES;
    const unsigned total = test->len + 2u * GUARD_BYTES;
    const uint8_t fill = (uint8_t)(0xa5u ^ (index * 13u));

    for (unsigned i = 0; i < total; ++i) {
        src_all[i] = pattern(index + 1u, i);
        dst_all[i] = fill;
    }

    sys_dma_blk_memcpy((uintptr_t)dst, (uintptr_t)src, test->len,
                       DMA_CONF_DECOUPLE_NONE);

    for (unsigned i = 0; i < test->len; ++i)
        if (dst[i] != src[i]) return error_code(0x1000, index, 1);
    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst_all[i] != fill) return error_code(0x1000, index, 2);
    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst[test->len + i] != fill) return error_code(0x1000, index, 3);
    for (unsigned i = 0; i < total; ++i)
        if (src_all[i] != pattern(index + 1u, i))
            return error_code(0x1000, index, 4);
    return 0;
}

static int run_2d_case(unsigned index, const struct copy_2d *test) {
    volatile uint8_t *src = BUF8(test->src);
    volatile uint8_t *dst = BUF8(test->dst);
    volatile uint8_t *src_all = src - GUARD_BYTES;
    volatile uint8_t *dst_all = dst - GUARD_BYTES;
    const unsigned src_span = (test->rows - 1u) * test->src_stride + test->len;
    const unsigned dst_span = test->rows * test->dst_stride;
    const unsigned src_total = src_span + 2u * GUARD_BYTES;
    const unsigned dst_total = dst_span + 2u * GUARD_BYTES;
    const uint8_t fill = (uint8_t)(0x5au ^ (index * 17u));

    for (unsigned i = 0; i < src_total; ++i)
        src_all[i] = pattern(index + 0x40u, i);
    for (unsigned i = 0; i < dst_total; ++i)
        dst_all[i] = fill;

    sys_dma_2d_blk_memcpy((uintptr_t)dst, (uintptr_t)src, test->len,
                          test->dst_stride, test->src_stride, test->rows,
                          DMA_CONF_DECOUPLE_NONE);

    for (unsigned row = 0; row < test->rows; ++row) {
        for (unsigned col = 0; col < test->len; ++col)
            if (dst[row * test->dst_stride + col] !=
                src[row * test->src_stride + col])
                return error_code(0x2000, index, 1);
        for (unsigned col = test->len; col < test->dst_stride; ++col)
            if (dst[row * test->dst_stride + col] != fill)
                return error_code(0x2000, index, 2);
    }
    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst_all[i] != fill) return error_code(0x2000, index, 3);
    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst[dst_span + i] != fill) return error_code(0x2000, index, 4);
    for (unsigned i = 0; i < src_total; ++i)
        if (src_all[i] != pattern(index + 0x40u, i))
            return error_code(0x2000, index, 5);
    return 0;
}

static int run_concurrent(unsigned *iterations_out) {
    volatile uint8_t *src = BUF8(0x40008000);
    volatile uint8_t *dst = BUF8(0x4000a000);
    volatile uint8_t *scratch = BUF8(0x4000c000);
    volatile uint8_t *src_all = src - GUARD_BYTES;
    volatile uint8_t *dst_all = dst - GUARD_BYTES;
    const unsigned len = 4097;
    const unsigned total = len + 2u * GUARD_BYTES;
    const uint8_t fill = 0x96;
    unsigned iterations = 0;

    for (unsigned i = 0; i < total; ++i) {
        src_all[i] = pattern(0x91u, i);
        dst_all[i] = fill;
    }
    for (unsigned i = 0; i < 64; ++i) scratch[i] = 0;

    const uint64_t transfer_id =
        sys_dma_memcpy((uintptr_t)dst, (uintptr_t)src, len,
                       DMA_CONF_DECOUPLE_NONE);
    while (*sys_dma_done_ptr() != transfer_id) {
        const unsigned slot = iterations & 63u;
        const uint8_t value = pattern(0xd3u, iterations);
        scratch[slot] = value;
        if (scratch[slot] != value) return 0x3001;
        if (++iterations == 0x100000u) return 0x3002;
    }
    if (iterations == 0) return 0x3003;

    for (unsigned i = 0; i < len; ++i)
        if (dst[i] != src[i]) return 0x3004;
    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst_all[i] != fill) return 0x3005;
    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst[len + i] != fill) return 0x3006;
    for (unsigned i = 0; i < total; ++i)
        if (src_all[i] != pattern(0x91u, i)) return 0x3007;

    *iterations_out = iterations;
    return 0;
}

uint64_t main(void) {
    int rc;

    for (unsigned i = 0; i < ARRAY_SIZE(one_d_cases); ++i) {
        rc = run_1d_case(i, &one_d_cases[i]);
        if (rc) return (uint16_t)rc;
    }
    for (unsigned i = 0; i < ARRAY_SIZE(two_d_cases); ++i) {
        rc = run_2d_case(i, &two_d_cases[i]);
        if (rc) return (uint16_t)rc;
    }

    unsigned concurrent_iterations = 0;
    rc = run_concurrent(&concurrent_iterations);
    if (rc) return (uint16_t)rc;

    if (concurrent_iterations > 0xffffu) concurrent_iterations = 0xffffu;
    return (uint64_t)concurrent_iterations << 16;
}

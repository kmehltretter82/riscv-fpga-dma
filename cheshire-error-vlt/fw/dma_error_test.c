#include <stdint.h>

#include "dif/dma.h"

#define BUF8(addr) ((volatile uint8_t *)(uintptr_t)(addr))
#define CONFIG_MODE (*(volatile uint32_t *)(uintptr_t)0x4000ffe0)
#define GUARD_BYTES 32u
#define FIRST_LEN 4097u
#define RECOVERY_LEN 257u
#define POLL_LIMIT 20000u

enum test_mode {
    MODE_CLEAN = 0,
    MODE_EXPECT_CONTINUE = 1,
    MODE_EXPECT_ABORT = 2,
    MODE_EXPECT_ABORT_ALLOW_FULL = 3,
};

static uint8_t pattern(unsigned seed, unsigned offset) {
    return (uint8_t)((offset * 37u + seed * 29u + 11u) & 0xffu);
}

static int wait_done(uint64_t transfer_id) {
    for (unsigned i = 0; i < POLL_LIMIT; ++i)
        if (*sys_dma_done_ptr() == transfer_id) return 0;
    return -1;
}

static int wait_idle(void) {
    for (unsigned i = 0; i < POLL_LIMIT; ++i)
        if (sys_dma_get_status() == 0) return 0;
    return -1;
}

static unsigned matching_prefix(volatile uint8_t *src,
                                volatile uint8_t *dst,
                                unsigned len) {
    unsigned i = 0;
    while (i < len && dst[i] == src[i]) ++i;
    return i;
}

static int guards_and_source_ok(volatile uint8_t *src,
                                volatile uint8_t *dst,
                                unsigned len,
                                unsigned seed,
                                uint8_t fill) {
    volatile uint8_t *src_all = src - GUARD_BYTES;
    volatile uint8_t *dst_all = dst - GUARD_BYTES;
    const unsigned total = len + 2u * GUARD_BYTES;

    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst_all[i] != fill) return 1;
    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst[len + i] != fill) return 2;
    for (unsigned i = 0; i < total; ++i)
        if (src_all[i] != pattern(seed, i)) return 3;
    return 0;
}

static void initialize(volatile uint8_t *src, volatile uint8_t *dst,
                       unsigned len, unsigned seed, uint8_t fill) {
    volatile uint8_t *src_all = src - GUARD_BYTES;
    volatile uint8_t *dst_all = dst - GUARD_BYTES;
    const unsigned total = len + 2u * GUARD_BYTES;

    for (unsigned i = 0; i < total; ++i) {
        src_all[i] = pattern(seed, i);
        dst_all[i] = fill;
    }
}

uint64_t main(void) {
    const unsigned mode = CONFIG_MODE;
    volatile uint8_t *src = BUF8(0x40001000);
    volatile uint8_t *dst = BUF8(0x40003000);
    volatile uint8_t *recovery_src = BUF8(0x40006000);
    volatile uint8_t *recovery_dst = BUF8(0x40008000);
    const uint8_t first_fill = 0xa5;
    const uint8_t recovery_fill = 0x5a;

    if (mode > MODE_EXPECT_ABORT_ALLOW_FULL) return 0x0001;

    initialize(src, dst, FIRST_LEN, 0x31u, first_fill);
    const uint64_t first_id =
        sys_dma_memcpy((uintptr_t)dst, (uintptr_t)src, FIRST_LEN,
                       DMA_CONF_DECOUPLE_NONE);
    if (wait_done(first_id)) return 0x1001;
    if (wait_idle()) return 0x1002;

    const unsigned prefix = matching_prefix(src, dst, FIRST_LEN);
    const int first_integrity =
        guards_and_source_ok(src, dst, FIRST_LEN, 0x31u, first_fill);
    if (first_integrity) return (uint16_t)(0x1010u + (unsigned)first_integrity);

    if (mode == MODE_EXPECT_ABORT) {
        if (prefix == FIRST_LEN) return 0x1101;
    } else if (mode != MODE_EXPECT_ABORT_ALLOW_FULL) {
        if (prefix != FIRST_LEN) return 0x1102;
    }

    initialize(recovery_src, recovery_dst, RECOVERY_LEN, 0x73u, recovery_fill);
    const uint64_t recovery_id =
        sys_dma_memcpy((uintptr_t)recovery_dst, (uintptr_t)recovery_src,
                       RECOVERY_LEN, DMA_CONF_DECOUPLE_NONE);
    if (wait_done(recovery_id)) return 0x2001;
    if (wait_idle()) return 0x2002;
    if (matching_prefix(recovery_src, recovery_dst, RECOVERY_LEN) != RECOVERY_LEN)
        return 0x2101;
    const int recovery_integrity = guards_and_source_ok(
        recovery_src, recovery_dst, RECOVERY_LEN, 0x73u, recovery_fill);
    if (recovery_integrity)
        return (uint16_t)(0x2110u + (unsigned)recovery_integrity);

    return (uint64_t)prefix << 16;
}

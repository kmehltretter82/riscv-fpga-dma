#include <stdint.h>

#include "dif/dma.h"

#define BUF8(addr) ((volatile uint8_t *)(uintptr_t)(addr))
#define ABORT_STATUS (*(volatile uint32_t *)(uintptr_t)0x01000100)
#define ABORT_REQUEST 1u
#define ABORT_PENDING (1u << 0)
#define ABORT_BUSY    (1u << 1)
#define ABORT_ACTIVE  (1u << 2)
#define GUARD_BYTES 32u
#define FIRST_LEN 32769u
#define RECOVERY_LEN 257u
#define POLL_LIMIT 1000000u

static uint8_t pattern(unsigned seed, unsigned offset)
{
    return (uint8_t)((offset * 37u + seed * 29u + 11u) & 0xffu);
}

static void initialize(volatile uint8_t *src, volatile uint8_t *dst,
                       unsigned len, unsigned seed, uint8_t fill)
{
    volatile uint8_t *src_all = src - GUARD_BYTES;
    volatile uint8_t *dst_all = dst - GUARD_BYTES;
    const unsigned total = len + 2u * GUARD_BYTES;

    for (unsigned i = 0; i < total; ++i) {
        src_all[i] = pattern(seed, i);
        dst_all[i] = fill;
    }
}

static unsigned matching_prefix(volatile uint8_t *src,
                                volatile uint8_t *dst,
                                unsigned len)
{
    unsigned i = 0;

    while (i < len && dst[i] == src[i])
        ++i;
    return i;
}

static int guards_and_source_ok(volatile uint8_t *src,
                                volatile uint8_t *dst,
                                unsigned len,
                                unsigned seed,
                                uint8_t fill)
{
    volatile uint8_t *src_all = src - GUARD_BYTES;
    volatile uint8_t *dst_all = dst - GUARD_BYTES;
    const unsigned total = len + 2u * GUARD_BYTES;

    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst_all[i] != fill)
            return 1;
    for (unsigned i = 0; i < GUARD_BYTES; ++i)
        if (dst[len + i] != fill)
            return 2;
    for (unsigned i = 0; i < total; ++i)
        if (src_all[i] != pattern(seed, i))
            return 3;
    return 0;
}

static int wait_inactive(void)
{
    for (unsigned i = 0; i < POLL_LIMIT; ++i)
        if (!(ABORT_STATUS & ABORT_ACTIVE))
            return 0;
    return -1;
}

static int finish_id(uint64_t expected)
{
    uint64_t done;

    if (wait_inactive())
        return -1;
    done = *sys_dma_done_ptr();
    return done == expected ? 0 : -2;
}

uint64_t main(void)
{
    volatile uint8_t *src = BUF8(0x40011000);
    volatile uint8_t *dst = BUF8(0x40021000);
    volatile uint8_t *recovery_src = BUF8(0x40031000);
    volatile uint8_t *recovery_dst = BUF8(0x40033000);
    const uint8_t first_fill = 0xa5;
    const uint8_t recovery_fill = 0x5a;
    uint64_t first_id, recovery_id;
    unsigned prefix;
    int integrity;

    /* A reset-state DONE_ID read establishes IRQ_ACK_ID == DONE_ID. */
    (void)*sys_dma_done_ptr();

    initialize(src, dst, FIRST_LEN, 0x31u, first_fill);
    first_id = sys_dma_memcpy((uintptr_t)dst, (uintptr_t)src, FIRST_LEN,
                              DMA_CONF_DECOUPLE_NONE);
    ABORT_STATUS = ABORT_REQUEST;
    if (finish_id(first_id))
        return 0x1001;
    if (ABORT_STATUS & (ABORT_PENDING | ABORT_ACTIVE))
        return 0x1002;

    prefix = matching_prefix(src, dst, FIRST_LEN);
    if (prefix >= FIRST_LEN)
        return 0x1101;
    integrity = guards_and_source_ok(src, dst, FIRST_LEN, 0x31u, first_fill);
    if (integrity)
        return (uint16_t)(0x1110u + (unsigned)integrity);

    initialize(recovery_src, recovery_dst, RECOVERY_LEN, 0x73u,
               recovery_fill);
    recovery_id = sys_dma_memcpy((uintptr_t)recovery_dst,
                                 (uintptr_t)recovery_src,
                                 RECOVERY_LEN, DMA_CONF_DECOUPLE_NONE);
    if (finish_id(recovery_id))
        return 0x2001;
    if (matching_prefix(recovery_src, recovery_dst, RECOVERY_LEN) !=
        RECOVERY_LEN)
        return 0x2101;
    integrity = guards_and_source_ok(recovery_src, recovery_dst, RECOVERY_LEN,
                                     0x73u, recovery_fill);
    if (integrity)
        return (uint16_t)(0x2110u + (unsigned)integrity);

    return (uint64_t)prefix << 16;
}

# Phase 9 design: Linux DMA mapping matrix

Snapshot: 2026-10-11

## Acceptance boundary

Run the phase-8 interrupt-driven Cheshire DMAengine provider in two otherwise
identical Linux boots:

1. the normal RISC-V direct-DMA path;
2. `swiotlb=4096,force`, with every streaming mapping proved to reside in the
   SWIOTLB pool.

Both kernels retain `CONFIG_DMA_API_DEBUG=y`, `CONFIG_DMA_API_DEBUG_SG=y`, the
noncoherent Cheshire whole-cache hook, and the same RTL.  A boot passes only
when the client payload, guard, mapping, callback, cookie, cache-operation and
DMA-debug counters all meet an exact gate.  The forced boot is not accepted
merely because `swiotlb=force` appears in the command line: the client must
verify each streaming DMA address with `swiotlb_find_pool()` and must verify
that it differs from the original buffer's physical address.

## Why scatter-gather is a client-side chain

The Linux DMAengine API has no generic memory-to-memory SG-pair preparation
callback.  `device_prep_slave_sg()` describes memory versus a fixed peripheral
address and is the wrong interface for this engine.  The test therefore maps
source and destination scatterlists with `dma_map_sg()`, walks their returned
DMA segments, splits mismatched segment boundaries if necessary, and submits
one ordinary DMAengine memcpy descriptor per paired chunk.  This exercises the
real SG DMA-mapping path and the provider's queue while preserving DMAengine's
public contract.

The initial matrix deliberately leaves a cache-line-sized gap in every page,
so direct DMA cannot merge neighboring entries.  The test still implements a
general paired iterator and records both original and mapped entry counts.

## Test groups

### Streaming and address geometry

Allocate guarded page-backed buffers and cover:

- cache-line-aligned but non-page-aligned mapping starts;
- exact lengths below, equal to and above one page;
- byte-unaligned hardware source and destination addresses while mapping the
  surrounding cache-line-complete allocation;
- lengths that necessarily cross 4 KiB, 64 KiB and 1 MiB boundaries;
- a direct-path transfer larger than 1 MiB.

Every source is mapped `DMA_TO_DEVICE`, every destination is mapped
`DMA_FROM_DEVICE`, and CPU verification occurs only after the destination is
unmapped or synchronized.  Source contents and guards are checked again after
DMA so an over-read/write or reversed direction cannot pass.

### Scatter-gather

Build separate source and destination lists from individually allocated pages,
using cache-line-aligned offsets and gaps.  Fill each logical source segment
with a unique deterministic pattern and each destination with a distinct fill.
Map the complete lists, submit the paired DMA chunks as one queued group, then
wait for every cookie before unmapping.  Require:

- all original entries covered exactly once and in logical order;
- total source, destination and submitted byte counts equal;
- mapped entry counts and chunk count recorded explicitly;
- all callbacks exactly once;
- every payload and every untouched prefix/suffix guard preserved.

The forced-SWIOTLB list is also the large bounce test: multiple sub-256-KiB
segments together transfer at least 1 MiB without exceeding SWIOTLB's
per-mapping segment limit.

### Coherent allocations

Allocate source and destination pairs with `dma_alloc_coherent()`, initialize
them through their CPU mappings, order CPU writes before submission, run the
same DMAengine memcpy path, and check payloads and guards before freeing them.
Record the returned DMA addresses and verify that the coherent allocations are
not misreported as streaming SWIOTLB mappings.  Include a non-page-sized case
and a 64-KiB boundary-crossing case.

### Negative controls

Retain one source-cache and one destination-cache negative control in the RTL
testbench.  Suppressing the source-side maintenance must produce stale source
data; suppressing destination invalidation must produce stale destination data.
The positive matrix is accepted only if both controls fail their payload oracle
for the intended reason and the unmodified run passes.

## SWIOTLB proof

The forced boot must establish all of the following from inside the client:

- `is_swiotlb_force_bounce(dev)` is true;
- every streaming single and SG DMA address resolves to a non-NULL
  `swiotlb_find_pool(dev, dma_to_phys(dev, dma_addr))`;
- the translated DMA physical address differs from the original page/buffer
  physical address;
- mappings remain within `dma_max_mapping_size(dev)`;
- source data reaches the bounce buffer before DMA and destination data reaches
  the original CPU buffer after unmap, as proved by the final payload checks.

The direct boot requires the inverse for streaming mappings: force mode false
and no address in a SWIOTLB pool.  This A/B distinction prevents a nominal
"bounce" boot from silently taking the direct path.

## Exact evidence gate

For each boot retain:

- one submitted, terminal completion IRQ and successful provider result for
  every hardware chunk;
- no error IRQ, abort, timeout, spurious IRQ, duplicate callback or unexpected
  provider state;
- exact client group counts, mapped bytes, SG entries/chunks, bounce/direct
  proofs, coherent jobs, and boundary cases;
- provider submitted/completed/success/callback/free counts equal to the
  client's hardware-chunk total;
- maximum hardware-active depth one and a software queue depth greater than
  one during the SG group;
- the expected noncoherent cache-hook delta calculated from the mapping calls;
- `/sys/kernel/debug/dma-api/error_count == 0` and no DMA API, SG, cache,
  lockdep, IRQ, warning, fault, panic or timeout signature in the kernel log;
- RTL issue/retire and completion IRQ/ack counts equal to Linux's hardware
  chunk total, with balanced AXI channels and no protocol assertion;
- exact kernel, module, DTB, firmware, simulator and source-patch hashes.

The two raw logs and native exit statuses must be stored separately.  A report
must call the SWIOTLB result a software bounce-buffer test, not an IOMMU test.
Translated DMA and IOTLB behavior remain phase 10.

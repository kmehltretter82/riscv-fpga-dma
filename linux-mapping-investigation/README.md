# Cheshire Linux DMA-mapping and DMA-API-debug matrix

This workspace exercises Linux's direct-DMA and forced-SWIOTLB mapping paths
through the interrupt-driven Cheshire iDMA DMAengine provider.  It uses the
same kernel and RTL for all boots; only the DT boot arguments and embedded DTB
differ.  A third direct-DMA boot deliberately performs five bounded API
mistakes.  `swiotlb=4096,force` is treated as a software bounce-buffer test,
not as an IOMMU test.

## Current status

The early-console and `/dev/console` repairs, three payloads, and the
DMA-API-negative cell are built and checksum-verified. A 100-cycle negative
control reaches the first platform fetch and fails on the testbench timeout as
required.

The final negative run, sealed as
`regression/runs/20261011T184621Z-2-4ca094ea/`, reached 188 million cycles of
normal Linux initialization before the 7,200-second wall limit. It emitted no
panic, RTL assertion, test failure, or iDMA issue, but it did not reach PID 1,
so none of the five deliberate DMA-API mistakes ran. Its evidence passes the
integrity verifier and its two post-run input audits match. No full positive or
negative Linux mapping cell is accepted, and no simulator remains active.

## Coverage

The client performs the following checks through
`dmaengine_prep_dma_memcpy()`:

- four streaming single mappings common to both boots: a non-page-aligned
  sub-page range, an exact-page byte-unaligned hardware range, and ranges that
  necessarily cross 4-KiB and 64-KiB boundaries;
- one direct-only 1-MiB-plus-257-byte physically contiguous mapping;
- 265 individually allocated SG pages per direction, each with a 64-byte
  prefix and suffix guard and a 3,968-byte payload.  The logical SG transfer
  is 1,051,520 bytes, is queued before issue, and uses one DMAengine memcpy
  descriptor per paired mapped segment;
- two `dma_alloc_coherent()` pairs: a 777-byte non-page-sized range and a
  65,537-byte range that necessarily crosses a 64-KiB boundary.

The coherent-allocation cases exercise Linux's coherent-allocation API on the
legacy CVA6 configuration.  They use the API-required ordering barriers, which
this CVA6 turns into whole-cache FENCE operations.  They do not claim that the
Cheshire iDMA has a hardware-coherent interconnect; that comparison remains a
phase-11 target.

Every streaming map is checked against `dma_max_mapping_size()`.  In the
direct boot, `dma_to_phys()` must equal the original physical address and
`swiotlb_find_pool()` must return NULL.  In the forced boot, both endpoints of
every mapping must belong to one SWIOTLB pool, the DMA physical address must
differ from the original address, and every source bounce copy is compared
before DMA submission.  Coherent allocations must never be identified as
streaming SWIOTLB mappings.

Payloads are deterministic.  CPU verification happens after streaming
unmap, and all source data plus untouched prefix/suffix guards are checked.
Every callback, result, residue and cookie reaches an exact gate.  The tiny
PID 1 additionally requires zero DMA-API-debug errors and exact provider,
client, cache-maintenance and queue-depth counters.

The direct-only negative cell keeps every backing allocation valid while it
deliberately performs exactly five mistakes:

- omit `dma_mapping_error()` before a correct single-buffer unmap;
- unmap a 256-byte mapping with size 128;
- sync a `DMA_TO_DEVICE` mapping as `DMA_FROM_DEVICE`;
- sync one entry from an SG mapping created with two entries;
- correctly unmap a mapping and then unmap it a second time.

PID 1 enables `all_errors`, requires five distinct warning signatures and an
`error_count` of five, and requires the DMA-debug free-entry count to return to
its initial value.  The RTL gate simultaneously requires zero iDMA
issue/retire, AXI, BusErr, interrupt, and abort activity.  This cell is
direct-only because malformed and duplicate unmaps must not be passed to a
stateful bounce-buffer allocator.

## Exact positive-run gates

| Counter | Direct | `swiotlb=4096,force` |
|---|---:|---:|
| Streaming single jobs | 5 | 4 |
| SG entries/chunks | 265 | 265 |
| Coherent jobs | 2 | 2 |
| Hardware jobs/callbacks/terminal IRQs | 272 | 271 |
| Streaming mapping proofs | 540 | 538 |
| Source bounce-copy checks | 0 | 269 |
| Client cache-operation delta | 814 | 811 |
| Minimum RTL FENCE cache operations | 815 | 812 |

`CONFIG_DMA_DIRECT_REMAP` prepares one 128-KiB atomic coherent pool during
boot.  Its one cache operation precedes the client's snapshot, which explains
the one-operation difference between the client delta and the minimum
RTL/global count.  The DT fixes that pool at `coherent_pool=128K`.  The RTL
counter also observes ordinary Linux ordering FENCEs (for example ordered
MMIO), so the testbench requires that lower bound and exact request/ack balance
while Linux's dedicated hook counter supplies the exact 814/811 gate.

The pinned kernel has no separate `CONFIG_DMA_API_DEBUG_SG` symbol.  SG map
and unmap checking is part of `CONFIG_DMA_API_DEBUG=y`; the build script
requires that symbol along with `CONFIG_SWIOTLB=y`, static SWIOTLB, and
`CONFIG_DMA_DIRECT_REMAP=y`.

## Build and run

From this directory:

```sh
BUILD_JOBS=2 scripts/build-software.sh
BUILD_JOBS=4 scripts/build-sim.sh
WALL_SECONDS=7200 MAX_CYCLES=250000000 scripts/run-smoke.sh direct
WALL_SECONDS=7200 MAX_CYCLES=250000000 scripts/run-smoke.sh swiotlb
WALL_SECONDS=7200 MAX_CYCLES=250000000 scripts/run-smoke.sh negative
```

`build-software.sh` creates one kernel/initramfs and three OpenSBI payloads:

- `out/fw_payload-direct.{elf,bin,memh}` embeds the direct-path DTB;
- `out/fw_payload-swiotlb.{elf,bin,memh}` embeds the forced-SWIOTLB DTB.
- `out/fw_payload-negative.{elf,bin,memh}` embeds the direct-only deliberate
  DMA-API misuse cell and the provider-scoped DMA-debug filter.

The mapping-specific testbench accepts only the two exact positive job/cache
tuples or the explicit zero-job negative mode.  It requires balanced iDMA,
interrupt and cache state and rejects unexpected AXI errors, BusErr records,
aborts and live terminal state.  The run script preserves separate raw logs
and native exit statuses in
`out/verilator-linux-mapping-{direct,swiotlb,negative}.{log,exit}`.

## Source relationships

The provider and binding are local copies of phase 8.  The locked patched
Cheshire, iDMA and no-trace CVA6 trees are read through symlinks into the phase
8 worktree; this workspace does not modify their targets.  The kernel contains
the existing Cheshire whole-cache noncoherent hook.

The stale-source and stale-destination negative controls require deliberately
altered cache behavior and belong to the phase-11 cache-comparison harness.
They must pass before the full phase-9/phase-11 cache claim is sealed.  The two
positive Linux runs described here have their own fail-closed gates and do not
stand in for those negative controls.

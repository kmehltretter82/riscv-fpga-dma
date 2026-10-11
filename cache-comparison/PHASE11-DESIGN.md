# Phase 11: CVA6 cache and DMA-coherence comparison

Date: 2026-10-11 UTC

Status: source audit and experiment design complete; no Phase 11 RTL run has
been made.

## Scope and acceptance boundary

Run the same one-core Cheshire/iDMA payload against three cache contracts:

| Cell | CPU data cache | Device contract | Required result |
|---|---|---|---|
| `legacy-wb-noncoherent` | legacy CVA6 WB | Linux noncoherent DMA operations issue a whole-cache writeback+invalidate | positive copy passes; both skipped-maintenance controls expose stale data |
| `hpdcache-wb-noncoherent` | HPDcache WB | the same Linux noncoherent contract, implemented by HPDcache `FLUSH_INVAL_ALL` | positive copy passes; both skipped-maintenance controls expose stale data |
| `wt-idma-coherent-reference` | CVA6 WT | a hardware bridge drains ordered CPU writes and invalidates L1 lines written by iDMA | positive copy passes with zero Linux cache operations; disabling each coherence leg exposes stale data |

A cached copy by itself is not evidence of coherency.  A cell is accepted only
when its positive run passes, its stale-source and stale-destination controls
fail in the prescribed way, and independent RTL counters prove which cache or
coherence operation occurred.

Use a 256-byte, 16-byte-aligned source and destination in different L1 sets.
The locked configurations have a 128-bit (16-byte) D-cache line, so a complete
destination transfer touches exactly 16 L1 lines.  Put a guard line on both
sides of each buffer and use three byte patterns:

- `OLD_SRC`: the backing-memory contents before the CPU dirties/fills source;
- `NEW_SRC`: the CPU-visible source that iDMA must copy; and
- `OLD_DST`: the value deliberately installed in the CPU destination cache.

The testbench observes iDMA read/write beats and the external-memory model.  It
therefore distinguishes stale source data from a stale CPU destination view.

## Pinned evidence

| Input | Revision |
|---|---|
| Cheshire | `292d2c091ffed3e194b0f437b5b3460813905e26` |
| CVA6 | `4c02b24fe7c04690f626776a92274da24f80d1da` (`pulp-v2.0.0`) |
| Linux | `388b607d107c07aaade04c7f22f344cab6bdccd3` (7.2 plus the retained Cheshire noncoherent-cache patch) |

The local CVA6 worktree carries only the already-retained optional trace
change in `core/cva6.sv`; all files cited below match the pinned commit.  The
static checker verifies their exact hashes.

Absolute source root:

```
/home/karl/linux-work/dmadebug2/riscv-fpga-dma
```

## What locked Cheshire actually provides

Cheshire instantiates each CVA6 core and iDMA as independent managers on an
ordinary `axi_xbar`:

- `cheshire/hw/cheshire_soc.sv:251-280` instantiates the AXI crossbar;
- `cheshire/hw/cheshire_soc.sv:632-665` connects CVA6 through `noc_req_o` and
  `noc_resp_i`;
- `cheshire/hw/cheshire_soc.sv:1480-1511` connects iDMA through
  `axi_in_req[AxiIn.dma]`; and
- `cheshire/hw/cheshire_pkg.sv:481-520` forces CVA6's `NOCType` to
  `NOC_TYPE_AXI4_ATOP` and disables CVXIF in this SoC.

The LLC at `cheshire/hw/cheshire_soc.sv:523-568` is downstream of the crossbar.
It can be shared by CPU and DMA traffic, but there is no return snoop or L1
invalidation channel from it to the cores.  The SoC module has no ACE, CHI,
snoop, or external D-cache invalidation interface.

The phrase "self-invalidation-based coherence" in
`cheshire/docs/um/arch.md:8,136` describes the core/fence scheme.  It is not a
hardware-coherent DMA contract.  The current test DT correctly omits the
`dma-coherent` property and says why in
`linux-fpga-investigation/dts/cheshire-linux-dma.dts:49-63`.

HPDcache's signals named `snoop_*` do not change this conclusion.  In
`core/cache_subsystem/cva6_hpdcache_wrapper.sv:255-327` they are driven from
the cache's own load, store/AMO, and CMO request ports into the stride
prefetcher.  They are not an external coherence interface.

### OpenPiton is evidence of a possible cache interface, not current DMA coherency

CVA6 contains an OpenPiton path:

- `config_pkg.sv` defines `NOC_TYPE_L15_BIG_ENDIAN` and
  `NOC_TYPE_L15_LITTLE_ENDIAN`;
- `cv64a6_imafdc_sv39_openpiton_config_pkg.sv` selects WT plus L15; and
- `wt_l15_adapter.sv:303-379` decodes L15 eviction messages into I/D-cache
  invalidations.

Cheshire overrides that NOC choice with AXI and contains no L15 port.  More
critically, its iDMA is an AXI manager rather than a P-Mesh directory agent.
Putting CVA6 behind L15 while leaving DMA downstream of the coherent fabric
would still be noncoherent.  An OpenPiton cell is acceptable only after iDMA
transactions are converted into real directory requests and directory-driven
L1 invalidations are counted.  No such adapter exists in the pinned tree, so
OpenPiton is not the Phase 11 reference cell.

## Cell 1: locked legacy WB, noncoherent

### Exact configuration

Keep the existing Bender target:

```
cv64a6_imafdchsclic_sv39_wb
```

Its package selects:

```
CVA6ConfigDcacheType              = config_pkg::WB
CVA6ConfigDcacheFlushOnFence      = 1'b1
CVA6ConfigDcacheInvalidateOnFlush = 1'b0
```

The last field is an HPDcache adapter input and does not control the legacy
cache.  Legacy WB uses `ariane_pkg::INVALIDATE_ON_FLUSH`, which is `1'b1` at
this pin.  `miss_handler.sv:340-421` writes dirty lines back and clears valid
state on the same whole-cache operation.

Keep the DT noncoherent.  The retained Linux hook in
`arch/riscv/mm/cache-ops.c` maps writeback, invalidate, and
writeback+invalidate to `FENCE rw,rw`.  For one direct-mapped copy, require an
exact cache-hook delta of three:

1. source `DMA_TO_DEVICE` map: writeback;
2. destination `DMA_FROM_DEVICE` map: pre-DMA writeback+invalidate; and
3. destination unmap/sync for CPU: post-DMA invalidate.

Immediately after step 2, the focused cache oracle deliberately refills one
`OLD_DST` line before starting iDMA.  That test-only ownership violation makes
the post-DMA invalidation observable rather than relying on a speculative CPU
refill.  The positive run performs step 3 and must return `NEW_SRC`; the stale
destination control omits step 3 and must return `OLD_DST`.

The RTL must observe exactly three rising cache-flush requests and three
acknowledgements in the focused cell.  iDMA must perform the expected 256-byte
read and write, all guards must remain intact, and no DMA API debug report may
appear.  The focused oracle uses raw register writes even in this positive
cell, after the DMA API operations have supplied the required ordering.  A
normal `writel()` would execute another FENCE for every register write and
would make the RTL flush count measure MMIO traffic rather than the three DMA
cache operations.  The production-style ordered-MMIO run remains a separate
positive coverage cell without an exact three-flush gate.

### Negative controls

Use a test-only raw-MMIO doorbell so Linux's normal `writel()`
`FENCE(w,o)` cannot accidentally perform the missing maintenance.

1. **Stale source:** prepare the destination and perform every unrelated map
   or cache operation first.  Then dirty `NEW_SRC` into cached source, leave
   backing memory at `OLD_SRC`, snapshot the counters, skip the source
   map/sync, and launch through raw MMIO.  The iDMA read-beat oracle and
   destination memory must contain `OLD_SRC`; the CPU comparison must fail.
   The critical counter delta from the CPU source store through the first DMA
   read is exactly zero.  Cleanup operations run only after that observation.
2. **Stale destination:** correctly map source and destination first so source
   memory already contains `NEW_SRC`.  After the destination's pre-DMA
   operation, deliberately refill `OLD_DST` into its CPU cache as a test-only
   ownership violation, snapshot the counters, and launch through raw MMIO.
   Skip the post-DMA CPU sync.  iDMA write beats and backing memory must
   contain `NEW_SRC`, while the CPU read of the primed line returns `OLD_DST`.
   The critical counter delta from the refill through that CPU read is exactly
   zero.  This models the stale line that a speculative refill can create and
   separates an active destination cache from an iDMA transfer failure.

If either negative copy passes, reject the cell because the workload did not
make the relevant line stale or an incidental fence/eviction repaired it.

## Cell 2: HPDcache WB, noncoherent

### The locked target needs a small configuration correction

The target `cv64a6_imafdchsclic_sv39_hpdcache` exists, but its package is not a
usable comparison configuration at this pin.  It contains the obsolete token
`config_pkg::HPDCACHE`, while `config_pkg.sv` defines only
`HPDCACHE_WT`, `HPDCACHE_WB`, and `HPDCACHE_WT_WB`.  It also sets both fence
knobs to zero.

Make the Phase 11 patch explicit and limited to this configuration package:

```diff
- localparam CVA6ConfigDcacheFlushOnFence = 1'b0;
- localparam CVA6ConfigDcacheInvalidateOnFlush = 1'b0;
+ localparam CVA6ConfigDcacheFlushOnFence = 1'b1;
+ localparam CVA6ConfigDcacheInvalidateOnFlush = 1'b1;
...
- localparam config_pkg::cache_type_t CVA6ConfigDcacheType = config_pkg::HPDCACHE;
+ localparam config_pkg::cache_type_t CVA6ConfigDcacheType = config_pkg::HPDCACHE_WB;
```

`cv64a6_imafdc_sv39_hpdcache_wb_config_pkg.sv` at the same pin proves that
`HPDCACHE_WB` is the intended write-back selector.  The CLIC/H-extension
package remains the base so the rest of Cheshire's CPU contract is unchanged.

`cva6_hpdcache_if_adapter.sv:268-288` turns
`DcacheInvalidateOnFlush=1` into
`HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL`; zero selects only
`HPDCACHE_REQ_CMO_FLUSH_ALL`.  `DcacheFlushOnFence=1` is separately required
because the Linux hook executes a FENCE.  Setting only one knob is an invalid
test configuration.

The runtime elaboration gate must require all three conditions:

```
DCacheType == config_pkg::HPDCACHE_WB
DcacheFlushOnFence == 1
DcacheInvalidateOnFlush == 1
```

Keep the DT noncoherent and reuse the exact three-operation Linux cache-hook
sequence and raw-register focused oracle from the legacy cell.  In addition
to three request/ack pairs, count three accepted
`HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL` operations and zero plain
`HPDCACHE_REQ_CMO_FLUSH_ALL` operations.

Run the same stale-source and stale-destination raw-MMIO controls.  Their data
oracles are identical to the legacy cell.  This is essential because an HPD
positive copy could otherwise pass through eviction or an incidental fence
without exercising the configured CMO.

## Cell 3: hardware-coherent WT+iDMA reference

### Why this is the bounded coherent model

Start from the existing target:

```
cv64a6_imafdchsclic_sv39
```

It selects:

```
CVA6ConfigDcacheType              = config_pkg::WT
CVA6ConfigDcacheFlushOnFence      = 1'b0
CVA6ConfigDcacheInvalidateOnFlush = 1'b0
```

The WT cache cannot hide a dirty source line indefinitely.  A normal Linux
MMIO write contains `FENCE(w,o)`.  CVA6 commits FENCE only when
`no_st_pending_commit` is true, and `cva6.sv:1127` defines that as the CPU
store queue empty **and** `dcache_commit_wbuffer_empty`.  Thus the ordered
doorbell makes all preceding CPU source writes visible before iDMA starts,
without a DMA cache-clean operation.

For the other direction, the existing WT AXI adapter already accepts an
address/valid/ready invalidation request.  At
`wt_axi_adapter.sv:553-569` it converts that request to `DCACHE_INV_REQ`; the
miss unit invalidates all ways at the addressed index.  Today that request can
come only from the optional accelerator path.  Cheshire forces `CvxifEn=0`
and supplies no iDMA invalidations, so this source capability is not current
hardware coherency.

### Required bridge

Implement a Phase 11 RTL variant with a dedicated external D-cache
invalidation port; do not masquerade iDMA as CVXIF.

1. Add `dcache_inval_addr_i`, `dcache_inval_valid_i`, and
   `dcache_inval_ready_o` to CVA6 and connect them only in the WT generate
   branch to the existing `wt_cache_subsystem` invalidation inputs.  Reject
   elaboration if the port is enabled with legacy WB or HPDcache.
2. Interpose an iDMA write-coherence bridge before the Cheshire AXI crossbar.
   Track every accepted AW/W burst and the set of 16-byte destination lines.
3. Let the memory/LLC accept the writes.  After the corresponding B response,
   request a coarse cache quiesce, stop new CPU cache requests, and wait for
   outstanding WT cache/memory traffic and the WT write buffer to drain.  The
   existing adapter comments that its accelerator invalidation is safe because
   no other transaction is active; the new bridge must enforce that condition
   rather than assume its port is an asynchronous snoop interface.
4. While quiesced, issue one invalidation for every unique touched line.
   Withhold the downstream B response from iDMA until all invalidations are
   acknowledged, then release quiesce and B.  iDMA DONE and the Linux callback
   therefore cannot precede invalidation.  Assertions must reject a lost AXI
   response or any CPU cache request accepted during quiesce.
5. In the initial one-core cell, one acknowledgement completes an
   invalidation.  A future multicore version must broadcast to every core and
   collect every acknowledgement before releasing completion.
6. Count accepted DMA write lines, quiesce requests/acknowledgements,
   invalidation requests/acknowledgements, delayed B responses, and maximum
   invalidation FIFO occupancy.  Overflow, duplicate terminal completion, or
   completion with a pending quiesce/invalidation is fatal.

This is a hardware-coherent DMA model for the tested one-core shared-memory
region: ordered CPU writes reach memory through WT, and device writes evict
the CPU's stale destination lines before completion.  It does not claim that
unmodified Cheshire is coherent or that arbitrary concurrent CPU/device
writes are race-free.

Only after the bridge passes may this cell add `dma-coherent` to its private
DT.  Build it without `CONFIG_RISCV_CHESHIRE_CACHE_OPS` (or prevent that hook
from registering) and require a Linux cache-operation delta of exactly zero.

### Positive and negative controls

Positive run:

- CPU writes `NEW_SRC` and primes destination with `OLD_DST`;
- driver uses the ordinary ordered MMIO doorbell and no noncoherent cache op;
- iDMA reads `NEW_SRC`, memory receives `NEW_SRC`, and its 16 destination
  lines produce exactly 16 invalidation requests and acknowledgements;
- iDMA completion is released only after invalidation 16; and
- the first CPU destination read misses/refills and returns `NEW_SRC`.

Stale-source control:

- apply AXI backpressure so a WT source write is accepted into the CPU cache
  path but has not reached memory;
- bypass the ordered doorbell with a testbench force-start, then let iDMA read;
- require iDMA to observe `OLD_SRC` and the copy to fail; and
- release backpressure afterward and prove the normal ordered cell passes.

This deliberately breaks the ordering leg of coherent DMA and proves that
the source oracle can see stale backing memory.

Stale-destination control:

- prime destination cache with `OLD_DST`;
- suppress exactly one bridge invalidation while still completing the DMA;
- require correct `NEW_SRC` iDMA write beats and backing memory but an
  `OLD_DST` CPU read from the specifically dropped line (all acknowledged
  lines must refill with `NEW_SRC`); and
- re-enable the invalidation and prove the positive cell passes.

This deliberately breaks the hardware snoop/invalidation leg.  A test that
merely removes `dma-coherent` or adds a software flush is not this control.

## Common machine-readable gates

Each run emits one record with at least these fields:

```
cell=
expected_outcome=
observed_outcome=
cache_type=
cache_hook_delta=
critical_cache_hook_delta=
cache_flush_req=
cache_flush_ack=
critical_cache_flush_req=
hpd_flush_inval_all=
hpd_flush_only=
dma_read_beats=
dma_write_beats=
dma_written_lines=
coherent_inval_req=
coherent_inval_ack=
coherent_quiesce_req=
coherent_quiesce_ack=
completion_with_pending_inval=
source_ram_pattern=
dma_read_pattern=
destination_ram_pattern=
destination_cpu_pattern=
guard_failures=
dma_api_errors=
```

Focused expected values:

| Cell/run | cache hooks | full-cache/HPD CMO | coherent invalidations | data outcome |
|---|---:|---:|---:|---|
| legacy positive | 3 | 3 request + 3 ack | 0 | CPU destination `NEW_SRC` |
| legacy stale source | 0 in critical interval | 0 from source dirty through DMA read | 0 | DMA reads `OLD_SRC` |
| legacy stale destination | 0 in critical interval | 0 from destination refill through CPU read | 0 | RAM `NEW_SRC`, CPU `OLD_DST` |
| HPD positive | 3 | 3 `FLUSH_INVAL_ALL`, 3 ack | 0 | CPU destination `NEW_SRC` |
| HPD stale source | 0 in critical interval | 0 from source dirty through DMA read | 0 | DMA reads `OLD_SRC` |
| HPD stale destination | 0 in critical interval | 0 from destination refill through CPU read | 0 | RAM `NEW_SRC`, CPU `OLD_DST` |
| WT coherent positive | 0 | 0 | 16 request + 16 ack | CPU destination `NEW_SRC` |
| WT coherent stale source | 0 | 0 | destination count as issued | DMA reads `OLD_SRC` |
| WT coherent stale destination | 0 | 0 | 15 ack, one injected drop | RAM `NEW_SRC`, CPU has stale line |

Every run also requires balanced iDMA issue/terminal completion, exact AXI
beat accounting, zero guard failures, and no unexpected kernel warning.  A
negative run passes the harness only when the expected stale-data signature is
observed; a timeout or unrelated mismatch is not an accepted negative result.

## Implementation order

1. Reuse the Phase 8 DMAengine provider and create the single-copy cache
   oracle with raw-MMIO negative mode.  Run it first on legacy WB.
2. Add the three-line HPDcache configuration patch, an elaboration gate, and
   HPD CMO counters.  Run the identical oracle.
3. Add the dedicated WT invalidation port and iDMA coherence bridge.  Keep its
   DT noncoherent during bring-up; switch only the passing private cell to
   `dma-coherent` and require zero cache hooks.
4. Add deliberate source-order and destination-invalidation fault knobs and
   run all nine focused cells.
5. Repeat the positive cells with boundary-crossing and SG mappings from Phase
   9.  The focused 256-byte controls remain the coherence acceptance test.

The static audit in `scripts/check-source-contracts.sh` should run before any
build.  It catches a repin, accidental `dma-coherent`, changes to the legacy
flush contract, and the mistaken interpretation of HPDcache's internal snoop
signals.

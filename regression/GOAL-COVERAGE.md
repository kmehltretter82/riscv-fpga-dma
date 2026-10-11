# Extended RISC-V DMA goal coverage

Date: 2026-10-11 UTC

This file maps the extended DMA-debug goal to concrete tests.  Acceptance is
CPU-hosted execution of synthesizable RTL.  No physical FPGA result is claimed
or required because no supported Cheshire board is available.

## 2. Linux-visible AXI errors

`linux-axi-errors` boots Linux on the error-capable Cheshire/iDMA variant and
submits nine DMAengine jobs: five clean controls and read/write `SLVERR` and
`DECERR`.  Every fault is followed by a clean recovery.  Its exact gates
require 9/9 terminal jobs, four classified errors, four recorder FIFO
pushes/pops, balanced NEXT/DONE IDs, no FIFO overflow, and no timeout, panic,
RTL assertion, or duplicate terminal completion.

The complementary `baremetal-error-drain` phase already passes all twelve
read/write error positions with and without AXI backpressure.  That tier proves
the focused iDMA write-response drain fix across multi-burst jobs; the Linux
tier proves DMAengine-visible classification and recovery.

Runtime status: the corrected kernel and payload contain the 1,024-entry
option in the compiled command line and pass checksum and input audits. The
bounded Linux attempt stopped before a DMA job, so only the bare-metal error
matrix is accepted.

## 3. Fuller DMAengine provider

`linux-dmaengine` exercises the investigation provider's completion IRQ,
separate error IRQ, one hardware-active descriptor, software queue, completion
result, descriptor-granularity residue, active abort, queued termination, and
post-abort recovery.  The client submits:

- 8 serial copies;
- 16 ordered queued copies;
- 32 copies prepared by two concurrent submitters;
- 9 clean/error/recovery jobs; and
- 8 jobs terminated as one active plus seven queued descriptors.

The acceptance contract requires 67/67 hardware terminal responses and IRQ
acknowledgements, four error IRQs, one software abort, zero post-terminal
writes, 66 client callbacks, exact result/residue values, a maximum software
queue of 32, all 74 descriptors freed, and zero DMA API debug errors.  The
temporary DT binding is validated by dtschema 2026.9.

Runtime status: the corrected kernel and payload contain the 1,024-entry
option in the compiled command line and pass checksum and input audits. The
bounded Linux attempt stopped before a DMA job; the focused RTL IRQ/abort
control remains the accepted evidence.

## 4. DMA mapping coverage

`linux-mapping-direct` and `linux-mapping-swiotlb` use the same DMAengine
provider and kernel with `CONFIG_DMA_API_DEBUG=y`.  Together they cover:

- non-page-aligned and cache-line-unaligned streaming mappings;
- 4 KiB, 64 KiB, and 1 MiB boundary crossings;
- 265-entry source and destination scatterlists;
- two `dma_alloc_coherent()` cases, including a 64 KiB crossing; and
- forced SWIOTLB mappings with direct physical proof that streaming DMA
  addresses reside in the bounce pool and contain the copied source bytes.

The direct gates require 272 jobs, 540 mapping proofs and 814 cache operations.
The bounce gates require 271 jobs, 538 mapping proofs, 269 source-copy proofs
inside SWIOTLB, and 811 cache operations.  Both require exact IRQ/ID accounting,
payload and guard integrity, and zero DMA API debug errors.

Runtime status: the original direct boot exhausted its 7,200-second wall bound
at about 192 million cycles without reaching a job.  The redundant original
SWIOTLB boot was stopped at 159 million cycles.  Both are sealed as failed
diagnostic evidence. Their 1,024-entry replacements also stopped before a DMA
job. The final deliberate DMA-API-misuse boot reached 188 million cycles at
the 7,200-second wall limit without reaching PID 1; its 100-cycle fail-closed
control passed and its diagnostic bundle passes integrity and input audits.

## 5. RISC-V IOMMU model

`iommu-architecture` runs the locked Zero-Day Labs CVA6+iDMA+RISC-V-IOMMU RTL.
It passes 38/38 supported assertions for bare and translated DMA, rejected
accesses, fault records, first- and second-stage IOTLB invalidation, I/O fences,
WSI/MSI delivery, and HPM events.  The unsupported MRIF and debug-interface
tests are retained as a status-1 diagnostic rather than hidden.

`iommu-reference` is an independent control using the behavioral model from
the ratified RISC-V IOMMU specification repository.  Its corrected harness
passes all 30 tests in 300 normal and 30 ASan/UBSan processes.  The RTL and
reference-model bundles are separately checksum-sealed.

Runtime status: accepted.

## 6. Cache implementation comparison

The `cache` tier contains a fail-closed 100-cycle control and a full Linux cell
for each implementation:

| Cell | Positive path | Required negative controls |
| --- | --- | --- |
| legacy CVA6 WB | Linux noncoherent whole-cache maintenance | omitted source clean exposes old source; omitted destination invalidation exposes old destination |
| HPDcache WB | Linux noncoherent `FLUSH_INVAL_ALL` | the same two stale outcomes, with exactly three flush/invalidate commands |
| CVA6 WT coherent | real WT-buffer drain plus external destination invalidation | one held source line exposes old source; dropping only destination line 8 exposes old line 8 while the other 15 lines are fresh |

The HPDcache preparation found and corrected a real local configuration bug:
flush entry 7 and the uncached response path both used the all-ones four-bit
memory ID.  Reserving that ID by using seven flush entries passes focused
controls beyond the original assertion point.

Runtime status: the legacy, HPDcache and coherent fail-closed controls pass.
Their full Linux attempts stopped before a DMA job, so the three positive and
six stale-data outcomes remain pending. No cache simulator is active.

## 7. Repeatable regression

`run.py` and `manifest.json` define 17 runnable phases grouped into
`baremetal-ci`, `baremetal-error`, `linux`, `iommu-rtl`, `mapping`, `cache`, and
`ready-all`.  Every phase has argv rather than shell text, prerequisites,
source-revision capture, internal and wall bounds, exact-count regex gates,
forbidden signatures, native status checks, and a checksum-sealed result
directory.  Concurrent invocations use a random run-ID suffix.  `adopt.py`
seals completed wrapper runs under the same gates while preserving their direct
provenance.  `verify.py` rejects missing, extra, unsafe, or modified evidence
paths.

The complete phase set passed preflight and dry-run expansion
on 2026-10-11.  Already accepted bundles include the bounded CI tier, focused
AXI-error tier, cache fail-closed controls, IOMMU reference/RTL results, and the
coherent bound control. No full Linux cell passed its exact gates in this
campaign.

`selftest.py` independently checks 128 concurrent run IDs, one accepted sealed
bundle, rejection of a checksum-consistent exact-gate tamper, rejection of a
checksum-consistent manifest-hash tamper, and rejection plus integrity sealing
when a declared input changes while a phase is running.

`audit-inputs.py` is also copied into new evidence bundles.  It rehashes the
live simulator, payload, manifests, commands, and tracked source state against
the sealed preflight record without modifying the bundle.  Its standalone-copy
path is self-tested. The final negative bundle matches both of its sealed phase
inputs after execution.

The simulated kernels keep `CONFIG_DMA_API_DEBUG=y` and use
`dma_debug_entries=1024`.  This exceeds the mapping matrix's approximately 530
simultaneously live mappings while avoiding 64,512 unused boot-time
allocations.  See `../DMA-DEBUG-ENTRY-BUDGET.md` for the bounded diagnostics
and isolated payload preparation commands.

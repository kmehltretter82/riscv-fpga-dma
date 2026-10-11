# Phase 11 status

Date: 2026-10-11 UTC

## Ready

- Legacy CVA6 WB noncoherent runtime source, Linux payload builder, simulator
  builder, and fail-closed run wrapper.
- HPDcache WB noncoherent equivalent, including an independently applicable
  patch which selects `HPDCACHE_WB`, enables flush on FENCE, and selects
  flush+invalidate. The same patch now reserves the all-ones memory ID for the
  uncached handler.
- One tiny Linux client that runs the positive, stale-source, and
  stale-destination controls in sequence.  The first must copy `NEW_SRC`; the
  two controls are accepted only when iDMA sees `OLD_SRC` and the CPU retains
  `OLD_DST`, respectively.
- RTL gates for three balanced jobs, 32 read and 32 write beats per job,
  per-byte DMA patterns, zero cache operations in every critical interval,
  the exact three-operation spacing around each job, completion IRQs, and HPD
  `FLUSH_INVAL_ALL` versus `FLUSH_ALL` opcodes.
- A separate WT+iDMA bridge source and dedicated invalidation interface.  It
  lint-elaborates for WT and deliberately fails elaboration for a non-WT cache.

## Actually built or run

- The complete Phase 11 kernel, provider, cache-test module, freestanding init,
  both DTBs and both OpenSBI payloads build successfully. All 13 software
  artifact hashes verify. The initial full build exposed and corrected a
  fail-closed assertion which expected disabled Kconfig syntax in the wrong
  form; the rebuilt configuration retains `CONFIG_SMP=n` and both required DMA
  debug/cache symbols.
- Both legacy-WB and corrected HPDcache-WB Verilator models build successfully;
  all simulator/source hashes verify. Their separate 100-cycle internal-bound
  controls exit nonzero with no false pass token. The first HPDcache
  elaboration exposed a monitor reference to a block-local signal; the retained
  correction observes the public request handshake and CMO opcode instead.
  That failed elaboration is preserved under `out/hpd-elaboration-*`.
- The first full HPDcache attempt exposed a locked-integration write-response
  ID collision: flush entry 7 and the uncached handler both used `4'b1111`.
  The exact assertion and an instrumented reproduction are preserved under
  `out/failures/hpd-uc-unexpected-response-20261011/`. Reducing the local
  HPDcache buffer/flush depth to seven reserves that ID. Rebuilt 30,000-cycle
  and 250,000-cycle controls cross the original failure point without the
  assertion; `scripts/check-hpd-id-reservation.sh` verifies this evidence.
- The source-contract audit passes.
- The WT bridge positive lint passes and its non-WT elaboration control fails
  as required.

No full Phase 11 Linux cell or stale-data control completed, so this subtree
makes no DMA cache-oracle runtime claim. The legacy and HPD fail-closed
controls pass, but their full attempts stopped before a DMA job. The separate
CVA6-WT coherent bound control also passes; its full attempt was stopped before
a job. No simulator is active.

## Remaining runtime sequence

```sh
cd /home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-cache-investigation
BUILD_JOBS=2 scripts/build-software.sh
CELL=legacy BUILD_JOBS=2 scripts/build-sim.sh
CELL=legacy scripts/run-bound-control.sh
CELL=legacy WALL_SECONDS=7200 scripts/run-cell.sh
CELL=hpd BUILD_JOBS=2 scripts/build-sim.sh
CELL=hpd scripts/run-bound-control.sh
CELL=hpd WALL_SECONDS=7200 scripts/run-cell.sh
```

The WT coherent reference is implemented in a private Cheshire/CVA6 variant
with the real WT-buffer drain and external invalidation wiring described in
`rtl/coherent/INTEGRATION.md`. Its focused bridge tests, software and model
builds, DT validation and fail-closed regression pass. A future full Linux
cell must still produce its positive and two deliberate stale-data outcomes
before any coherent runtime claim is accepted.

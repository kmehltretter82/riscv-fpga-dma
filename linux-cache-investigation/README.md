# Phase 11 Linux cache/DMA investigation

This subtree implements the focused Phase 11 cache oracle described in
`../cache-comparison/PHASE11-DESIGN.md`.  It does not modify any pinned source
or any earlier phase workspace.

Two noncoherent cells are executable:

* `legacy-wb-noncoherent`: locked CVA6 legacy WB cache;
* `hpdcache-wb-noncoherent`: CVA6 HPDcache WB with the explicit WB, FENCE,
  flush-invalidate, and memory-ID reservation correction in
  `patches/cva6-hpdcache-wb-fence-invalidate.patch`.

Each cell boots the same tiny Linux payload and runs, in order, a positive
256-byte copy, a stale-source control, and a stale-destination control.  The
DMAengine provider uses deliberately unordered raw MMIO for this focused
oracle, so its register accesses cannot hide a missing DMA cache operation.
The client performs the normal DMA mappings (or the precisely documented
omission), while RTL independently checks iDMA issue/retirement, AXI beat data,
whole-cache requests/acks, and HPDcache CMO opcode counts.

`rtl/coherent/` contains the original synthesizable bridge and interface
contract. The completed CVA6/Cheshire WT integration, `dma-coherent` DT,
focused bridge test, full-system bound control and Linux cell live in the
separate `../linux-coherent-investigation/` subtree. Its full Linux attempt did
not reach a DMA job, so no coherent runtime result is claimed.

Run the cheap fail-closed checks first:

```sh
scripts/check-source-contracts.sh
scripts/check-coherent-static.sh
scripts/check-hpd-id-reservation.sh
```

`HPDCACHE-ID-RESERVATION.md` documents the locked upstream integration defect
found by the first HPD Linux attempt and the bounded validation of its local
correction.

Build software once, then build/run each RTL cell separately:

```sh
BUILD_JOBS=2 scripts/build-software.sh
CELL=legacy scripts/build-sim.sh
CELL=legacy scripts/run-bound-control.sh
CELL=legacy WALL_SECONDS=7200 scripts/run-cell.sh
CELL=hpd scripts/build-sim.sh
CELL=hpd scripts/run-bound-control.sh
CELL=hpd WALL_SECONDS=7200 scripts/run-cell.sh
```

The run script accepts a result only with the exact Linux and RTL pass tokens.
It treats timeout, a missing negative-control signature, an unexpected cache
operation, an AXI data mismatch, or an unbalanced request/ack count as failure.
Each full cell has a 200-million-cycle internal bound and a 7,200-second wall
bound by default.

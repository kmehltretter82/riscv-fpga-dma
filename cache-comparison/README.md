# Phase 11 cache comparison

This directory contains the source-audited design for comparing Cheshire DMA
with three CPU-cache contracts:

1. the locked legacy CVA6 write-back cache;
2. CVA6 HPDcache in write-back mode; and
3. a hardware-coherent reference cell based on CVA6's write-through cache and
   an iDMA-to-L1 invalidation bridge.

No RTL or Linux result is claimed here.  The design and its negative controls
are in `PHASE11-DESIGN.md`.  The static audit can be repeated with:

```sh
cd /home/karl/linux-work/dmadebug2/riscv-fpga-dma/cache-comparison
scripts/check-source-contracts.sh
```

The last validated output is in `evidence/source-contracts.log`.  The check is
deliberately fail-closed on the pinned Cheshire/CVA6 revisions and on the exact
source contracts used by the design.

The central audit conclusion is that locked Cheshire has no hardware-coherent
iDMA path into CVA6 L1.  Its shared AXI LLC and the documentation's
"self-invalidation-based coherence" do not provide DMA snooping.  The test DT
must remain noncoherent until the reference bridge is implemented and both
stale-data negative controls prove that it is active.

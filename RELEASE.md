# Cheshire RISC-V DMA-debug lab snapshot

This repository is a source-only snapshot of the CPU-hosted
Cheshire/CVA6/iDMA investigation performed on 2026-10-11. Generated kernels,
Verilator object trees, tool installations and multi-gigabyte traces are not
stored here.

The snapshot contains:

- deterministic bare-metal corruption, error-drain, randomized, interrupt and
  abort tests;
- prototype Linux DMAengine providers and clients for normal completion,
  AXI errors, queues, residue, abort and concurrency;
- direct-DMA, forced-SWIOTLB, coherent-allocation, scatter-gather and deliberate
  DMA-API misuse cells;
- legacy CVA6 WB, HPDcache WB and CVA6 WT coherent cache oracles;
- the CVA6+iDMA RISC-V IOMMU integration and an independent reference-model
  control; and
- a fail-closed regression runner with exact-count gates, input hashing,
  semantic replay and checksum-sealed evidence.

`SOURCES.tsv` locks every external repository and revision.  The files under
`upstream-patches/` reproduce every tracked local source-tree modification.
On an empty snapshot checkout, run:

```sh
./bootstrap-sources.sh
```

The script refuses to replace an existing source path.  It performs network
clones, checks out detached locked revisions, checks every patch before
applying it, and recreates the shared source symlinks used by the Linux cells.
Build and run commands are documented in the README in each phase directory.

Accepted regression bundles are stored below `evidence/regression-runs/`.
Each bundle has a complete checksum manifest.  Run the top-level
`verify-release.sh`, which uses the archived regression verifier, to validate
the source snapshot, patches and all included evidence without rebuilding the
large generated artifacts.

Failed but forensically useful bounded runs are stored separately below
`evidence/diagnostic-runs/`. The verifier checks their complete integrity and
replays the recorded failed gate semantics without treating them as passes.

Source files retain their original SPDX identifiers and copyright notices.
Common license texts are included under `LICENSES/`; restored upstream trees
carry their own complete licensing material.

These results cover CPU execution of synthesizable RTL.  They do not claim
FPGA timing closure, DDR PHY/controller behavior, board reset/clocking, signal
integrity or a run on a physical Cheshire board.

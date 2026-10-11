# RISC-V FPGA DMA workspace

This repository contains a reproducible, CPU-hosted open-source RTL lab for
finding DMA hardware, driver, mapping, cache-coherency, and IOMMU bugs in the
Cheshire/CVA6/iDMA stack. See [`STATUS.md`](STATUS.md) for accepted results and
remaining work, and [`RELEASE.md`](RELEASE.md) for archive and reproduction
details.

## Source layout

- `SOURCES.tsv`, `upstream-patches/`, and `bootstrap-sources.sh`: locked public
  source revisions and the exact local modifications needed to reconstruct the
  omitted upstream checkouts.
- `cheshire-idma-v064-vlt/`: open Verilator harness for Cheshire's real iDMA
  wrapper, including the retained corruption fault and `IsTwoD=0` fix patches.
- `cheshire-soc-vlt/`: open full-SoC harness and RISC-V firmware for
  CVA6-executed boundary/2D/concurrency DMA, deterministic AXI delay,
  mid-transfer reset recovery and full-SoC fault injection.
- `cheshire-error-vlt/`: CVA6-executed AXI read/write error and abort harness,
  including burst-position and delayed-response coverage plus the focused iDMA
  drain/terminal-response fix.
- `cheshire-random-vlt/`: seeded full-SoC duration harness, stock v0.6.4
  channel-coupler reproducers and the tested Cheshire backport of upstream AW
  credit fixes.
- `linux-fpga-investigation/`: buildable Linux/OpenSBI/initramfs and prototype
  DMAengine path. PC tracing proves Linux execution in the full RTL model, but
  the bounded runs did not reach PID 1 or a Linux DMA acceptance token.
- `reproduce-idma-campaign.sh`: disposable-worktree baseline and fault runner.

Generated object directories and the two permanent fault worktrees were
removed after their patches and evidence were sealed.  The runner reconstructs
them from the retained source revision.  The full-SoC harness README gives the
one-time Bender command that restores its locked dependency checkouts after
disk cleanup.  The AXI-error campaign's Verilator outputs and Bender caches are
also removed after sealing; its `CLEANUP-20261011.txt` records the exact paths
and sizes.

## Evidence

Compact accepted bundles are under `evidence/regression-runs/`. The final
bounded Linux diagnostic is separate under `evidence/diagnostic-runs/` so it
cannot be mistaken for a pass. Validate all included source and evidence with:

```sh
./verify-release.sh
```

Run from this directory:

```sh
./reproduce-idma-campaign.sh baseline /path/to/output
./reproduce-idma-campaign.sh strobe-fault /path/to/output
./reproduce-idma-campaign.sh data-fault /path/to/output
```

The current milestone validates standalone iDMA RTL, its AXI datapath and two
programming frontends.  The second milestone validates the exact v0.6.4
Cheshire wrapper pin, reproduces its alternate-frontend busy-status defect,
and verifies the fix.  The third milestone executes two guarded DMA jobs on
CVA6 through the full Cheshire SoC and proves the CPU payload oracle with an
injected valid-data fault.  The fourth milestone expands that execution to 30
boundary, unaligned, 2D and concurrent jobs, all-channel AXI delay, reset
recovery and an exact first-case corruption oracle.  The fifth milestone
enables explicit iDMA error handling, reproduces a delayed-response abort
completion bug, verifies the focused drain/last fix, and passes 12 read/write
SLVERR cases plus recovery through CVA6. The sixth milestone runs 3,456 seeded
transfers through CVA6, reproduces the two upstream-known channel-coupler
defects still present in Cheshire's v0.6.4 pin, and verifies a focused backport
across 27/27 cells. Linux executes in the full RTL model, and the negative
DMA-API cell's 100-cycle fail-closed control passes. Full Linux DMA acceptance
and execution on a physical FPGA remain future steps.

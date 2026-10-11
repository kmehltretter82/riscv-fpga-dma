# Phase 11 WT coherent iDMA investigation

This subtree is the isolated hardware-coherent Phase 11 cell.  It uses CVA6's
existing write-through D-cache invalidation path and adds the missing Cheshire
iDMA plumbing:

* source-side quiescence stalls new WT-cache traffic and waits for the cache
  and write buffer to drain before iDMA reads memory;
* destination-side completion withholds AXI `B` until every written cache line
  has been invalidated in the real CVA6 WT cache;
* completion therefore remains behind both coherency legs;
* explicit source-drain and destination-invalidation fault inputs exist only
  for fail-closed negative controls.

The short bridge/model regression is executable without booting Linux and
proves that the positive path observes `NEW_SRC`, skipping the source drain
observes `OLD_SRC`, and dropping one destination invalidation retains
`OLD_DST`.  The full Cheshire build uses copied override files and never edits
the locked campaign trees.

The full Linux stale-source control uses the real CVA6 WT buffer rather than a
fabricated DMA read value.  The client first executes a fence to establish
`OLD_SRC` in RAM, then pre-arms the existing iDMA source-address register with
one aligned 16-byte line.  The testbench captures that accepted MMIO write and
backpressures only the matching WT-buffer AXI write.  The CPU overwrites the
line with `NEW_SRC`, the injected bridge fault skips the normal pre-DMA drain,
and the hold remains active through the final DMA read beat.  The write is then
released so the bridge's post-transfer quiesce can drain it.  Acceptance
requires a nonzero number of cycles in which that real WT write was held.

The destination negative drops only invalidation FIFO index 8.  Its Linux
oracle therefore requires bytes 128--143 to retain `OLD_DST` and every other
byte in the 256-byte destination to expose `NEW_SRC`.

Prepared artifacts include a `dma-coherent` DTB, OpenSBI/Linux payload, both
modules, and an investigation-only DT binding.  `CONFIG_DMA_API_DEBUG` remains
enabled; `dma_debug_entries=1024` bounds its boot-time preallocation.

Validation commands:

```text
BUILD_JOBS=1 scripts/build-sim.sh
BUILD_JOBS=1 scripts/build-software.sh
scripts/run-bridge-regression.sh
scripts/run-bound-control.sh
scripts/check-source-contracts.sh
```

The focused bridge regression and full elaboration/build pass.  The 100-cycle
full-system control exits nonzero with zero jobs and no pass token, as required.
All simulator, software, bridge, control, and DT-contract hashes verify.
The final binding also passed independent `dt-doc-validate` with dtschema
2026.9 and Ubuntu's extracted `python3-libfdt`; the validator used a temporary
`dma/` path matching the schema `$id`.

No full Linux runtime result is claimed.  A long run must reach the exact
Linux and testbench acceptance gates before this cell can be marked runtime
passing.


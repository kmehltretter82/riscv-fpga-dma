# Cheshire iDMA v0.6.4 open Verilator harness

This harness elaborates Cheshire's unmodified `cheshire_idma_wrap.sv` against
the exact iDMA commit pinned by Cheshire (`ff5d56f`, v0.6.4).  It programs the
wrapper through its AXI register port and services its AXI DMA master port with
a byte-addressed memory model.

The baseline runs a guarded 4096-byte 1D copy and a strided 7-by-13-byte 2D
copy under deterministic AXI backpressure.  It checks payloads, untouched gaps,
guard bands, completion IDs, idle status and bus transaction accounting.

```sh
cd /home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire-idma-v064-vlt
./run.sh baseline
./run.sh data-fault
./run.sh one-d-unpatched
./run.sh one-d-fixed
```

`data-fault` creates a disposable worktree at the same v0.6.4 commit, applies
`fault-corrupt-final-write.patch`, and requires independent 1D and 2D payload
comparisons to fail at the expected offsets.  A detected injected fault makes
the runner succeed; an unexpected clean copy makes it fail.

The final two modes reproduce and fix the wrapper's `IsTwoD=0` busy-status
typo.  The unpatched mode requires both Verilator's implicit-net warning and a
false-idle status while the 4096-byte copy is active.  The fixed mode applies a
one-line patch in a disposable Cheshire worktree, treats implicit nets as
errors, and requires the guarded copy and busy-status checks to pass.

The harness verifies the real Cheshire DMA integration wrapper and exact iDMA
pin.  It still drives MMIO from the testbench; CVA6 does not execute the
software sequence yet.
